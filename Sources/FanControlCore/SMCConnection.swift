//
//  SMCConnection.swift
//  与 AppleSMC 内核驱动通信的底层封装。
//
//  本文件只使用 IOKit / Foundation，没有任何网络访问。
//  协议细节（80 字节结构、命令码 5/6/8/9、选择子 2、数据格式）参考自公开逆向资料，
//  代码为本项目自行实现。
//
//  读 SMC（命令 5/9）任何普通用户进程都可执行，无需 root；
//  写 SMC（命令 6）到风扇控制键需要 root（由守护进程执行）。
//

import Foundation
import IOKit

// MARK: - 80 字节参数结构（必须与内核 ABI 精确对齐）

/// SMC 版本信息（4 字节 + UInt16）
struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

/// 功率上限数据（16 字节，本项目用不到，仅占位以保证结构大小正确）
struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

/// 键信息：数据大小、数据类型（FourCC）、属性位
/// 公开：`SMCConnection.readKeyInfo` 会把它返回给库外调用方（FanController 等）。
public struct SMCKeyInfoData {
    public var dataSize: UInt32 = 0
    public var dataType: UInt32 = 0
    public var dataAttributes: UInt8 = 0

    public init() {}
}

/// 32 字节数据负载
typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

/// 与内核交换的 80 字节结构。字段顺序经实测可在 Swift 下对齐到正确的内核偏移。
/// 调用时必须使用 MemoryLayout.stride（而非 .size）作为大小。
struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (0, 0, 0, 0, 0, 0, 0, 0,
                           0, 0, 0, 0, 0, 0, 0, 0,
                           0, 0, 0, 0, 0, 0, 0, 0,
                           0, 0, 0, 0, 0, 0, 0, 0)
}

// MARK: - SMC 命令码与错误

private enum SMCCmd: UInt8 {
    case readBytes    = 5   // 读取键值
    case writeBytes   = 6   // 写入键值
    case getKeyFromIndex = 8  // 按索引取键名
    case getKeyInfo   = 9   // 读取键信息（大小/类型）
}

/// SMC 操作可能抛出的错误
public enum SMCError: Error, CustomStringConvertible {
    case driverNotFound          // 找不到 AppleSMC 服务
    case failedToOpen(kern_return_t)
    case notConnected
    case keyNotFound(String)     // SMC 返回 0x84
    case notPrivileged           // kIOReturnNotPrivileged，需要 root
    case ioError(kern_return_t)
    case smcError(UInt8)         // 其他 SMC result 码

    public var description: String {
        switch self {
        case .driverNotFound: return "找不到 AppleSMC 驱动"
        case .failedToOpen(let r): return "打开 SMC 连接失败 (kern_return=\(r))"
        case .notConnected: return "SMC 未连接"
        case .keyNotFound(let k): return "SMC 键不存在：\(k)"
        case .notPrivileged: return "写入被拒绝：需要 root 权限"
        case .ioError(let r): return "IOKit 错误 (\(String(format: "0x%x", r)))"
        case .smcError(let c): return "SMC 错误码 \(String(format: "0x%02x", c))"
        }
    }
}

// MARK: - 连接封装

/// 一个到 AppleSMC 的连接。线程不安全：每个使用线程各开一个，或自行加锁。
public final class SMCConnection {
    private var conn: io_connect_t = 0
    private var isOpen = false

    /// 键信息（大小/类型）在固件里是固定的，缓存起来可以让每次读值少一半 IOKit 调用。
    /// 控速循环每 0.7s 要读几十个传感器，这个缓存很关键。
    private var keyInfoCache: [String: SMCKeyInfoData] = [:]

    public init() {}

    deinit { close() }

    /// 打开到 AppleSMC 的连接
    public func open() throws {
        guard !isOpen else { return }
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.driverNotFound }
        defer { IOObjectRelease(service) }

        // 连接类型 0
        let result = IOServiceOpen(service, mach_task_self_, 0, &conn)
        guard result == kIOReturnSuccess else { throw SMCError.failedToOpen(result) }
        isOpen = true
    }

    public func close() {
        if isOpen {
            IOServiceClose(conn)
            isOpen = false
            conn = 0
            keyInfoCache.removeAll()
        }
    }

    // MARK: 底层调用

    /// 通过选择子 2 调用驱动，传入/传出均为 80 字节 SMCParamStruct
    private func call(_ input: inout SMCParamStruct) throws -> SMCParamStruct {
        guard isOpen else { throw SMCError.notConnected }
        var output = SMCParamStruct()
        let inputSize = MemoryLayout<SMCParamStruct>.stride   // 必须用 stride
        var outputSize = MemoryLayout<SMCParamStruct>.stride

        let kr = withUnsafeMutablePointer(to: &input) { inPtr in
            withUnsafeMutablePointer(to: &output) { outPtr in
                IOConnectCallStructMethod(conn,
                                          2,              // 选择子
                                          inPtr, inputSize,
                                          outPtr, &outputSize)
            }
        }

        if kr == kIOReturnNotPrivileged {
            throw SMCError.notPrivileged
        }
        guard kr == kIOReturnSuccess else {
            throw SMCError.ioError(kr)
        }
        // result 字段非 0 表示 SMC 固件层错误
        if output.result == 0x84 {            // SmcNotFound
            throw SMCError.keyNotFound(Self.keyToString(input.key))
        } else if output.result != 0x00 && output.result != 0x87 {
            // 0x87（大小不匹配）在写 F0Tg 时有时仍生效，故放行
            throw SMCError.smcError(output.result)
        }
        return output
    }

    // MARK: 键信息 / 读 / 写

    /// 读取某个键的信息（数据大小与类型）。命中缓存时不产生 IOKit 调用。
    public func readKeyInfo(_ key: String) throws -> SMCKeyInfoData {
        if let cached = keyInfoCache[key] { return cached }
        var input = SMCParamStruct()
        input.key = Self.stringToKey(key)
        input.data8 = SMCCmd.getKeyInfo.rawValue
        let out = try call(&input)
        keyInfoCache[key] = out.keyInfo
        return out.keyInfo
    }

    /// 读取某个键的原始字节（自动先取键信息）
    public func readRaw(_ key: String) throws -> (type: String, bytes: [UInt8]) {
        let info = try readKeyInfo(key)
        var input = SMCParamStruct()
        input.key = Self.stringToKey(key)
        input.keyInfo.dataSize = info.dataSize
        input.data8 = SMCCmd.readBytes.rawValue
        let out = try call(&input)
        let size = Int(info.dataSize)
        let all = Self.bytesToArray(out.bytes)
        let typeStr = Self.keyToString(info.dataType)
        return (typeStr, Array(all.prefix(size)))
    }

    /// 写入原始字节到某个键（需要 root）。dataType/dataSize 取自键信息。
    public func writeRaw(_ key: String, bytes: [UInt8]) throws {
        let info = try readKeyInfo(key)
        var input = SMCParamStruct()
        input.key = Self.stringToKey(key)
        input.keyInfo.dataSize = info.dataSize
        input.keyInfo.dataType = info.dataType
        input.data8 = SMCCmd.writeBytes.rawValue
        input.bytes = Self.arrayToBytes(bytes)
        _ = try call(&input)
    }

    /// SMC 中键的总数（读取 "#KEY"）
    public func keyCount() throws -> Int {
        let (_, bytes) = try readRaw("#KEY")
        return Int(SMCConnection.uint32BE(bytes))
    }

    /// 按索引取得键名（用于枚举全部传感器）
    public func keyName(atIndex index: Int) throws -> String {
        var input = SMCParamStruct()
        input.data8 = SMCCmd.getKeyFromIndex.rawValue
        input.data32 = UInt32(index)
        let out = try call(&input)
        return Self.keyToString(out.key)
    }

    // MARK: - FourCC / 字节工具

    static func stringToKey(_ s: String) -> UInt32 {
        let chars = Array(s.utf8)
        var v: UInt32 = 0
        for i in 0..<4 {
            let c: UInt8 = i < chars.count ? chars[i] : 0x20  // 不足补空格
            v = (v << 8) | UInt32(c)
        }
        return v
    }

    static func keyToString(_ key: UInt32) -> String {
        let bytes = [UInt8((key >> 24) & 0xff),
                     UInt8((key >> 16) & 0xff),
                     UInt8((key >> 8) & 0xff),
                     UInt8(key & 0xff)]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    static func bytesToArray(_ b: SMCBytes) -> [UInt8] {
        return [b.0, b.1, b.2, b.3, b.4, b.5, b.6, b.7,
                b.8, b.9, b.10, b.11, b.12, b.13, b.14, b.15,
                b.16, b.17, b.18, b.19, b.20, b.21, b.22, b.23,
                b.24, b.25, b.26, b.27, b.28, b.29, b.30, b.31]
    }

    static func arrayToBytes(_ a: [UInt8]) -> SMCBytes {
        var p = [UInt8](repeating: 0, count: 32)
        for i in 0..<min(32, a.count) { p[i] = a[i] }
        return (p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7],
                p[8], p[9], p[10], p[11], p[12], p[13], p[14], p[15],
                p[16], p[17], p[18], p[19], p[20], p[21], p[22], p[23],
                p[24], p[25], p[26], p[27], p[28], p[29], p[30], p[31])
    }

    static func uint32BE(_ b: [UInt8]) -> UInt32 {
        guard b.count >= 4 else { return 0 }
        return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
    }
}

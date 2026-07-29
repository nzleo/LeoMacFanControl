//
//  SMCReader.swift
//  高层读取：风扇转速/模式、CPU 温度。全部为只读操作，无需 root。
//

import Foundation

/// 单个风扇的快照
public struct FanSnapshot: Codable, Sendable {
    public var index: Int
    public var actualRPM: Double
    public var targetRPM: Double
    public var minRPM: Double
    public var maxRPM: Double
    public var mode: Int        // 0=自动 1=手动 3=系统；-1=未知

    public init(index: Int, actualRPM: Double, targetRPM: Double,
                minRPM: Double, maxRPM: Double, mode: Int) {
        self.index = index
        self.actualRPM = actualRPM
        self.targetRPM = targetRPM
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.mode = mode
    }
}

public final class SMCReader {
    private let smc: SMCConnection

    // 缓存：温度传感器键列表、风扇模式键大小写、Ftst 是否存在
    private var cpuTempKeys: [String]?
    private var fanModeKeyCache: [Int: String] = [:]
    private var ftstAvailable: Bool?

    public init(connection: SMCConnection) {
        self.smc = connection
    }

    // MARK: 数值读取

    /// 读取键并解码为 Double
    public func readDouble(_ key: String) -> Double? {
        guard let raw = try? smc.readRaw(key) else { return nil }
        return SMCDataDecoder.decode(type: raw.type, bytes: raw.bytes)
    }

    /// 读取单字节键（模式、FNum 等）
    public func readUInt8(_ key: String) -> Int? {
        guard let raw = try? smc.readRaw(key), let first = raw.bytes.first else { return nil }
        return Int(first)
    }

    // MARK: 风扇

    /// 风扇数量（FNum）
    public func fanCount() -> Int {
        return readUInt8("FNum") ?? 0
    }

    /// 探测某个风扇的模式键大小写（M4 等为大写 F0Md，M5 为小写 F0md）
    public func fanModeKey(_ index: Int) -> String? {
        if let cached = fanModeKeyCache[index] { return cached }
        let upper = "F\(index)Md"
        let lower = "F\(index)md"
        if (try? smc.readKeyInfo(upper)) != nil {
            fanModeKeyCache[index] = upper
            return upper
        }
        if (try? smc.readKeyInfo(lower)) != nil {
            fanModeKeyCache[index] = lower
            return lower
        }
        return nil
    }

    /// 读取一个风扇的完整快照
    public func fanSnapshot(_ index: Int) -> FanSnapshot {
        let actual = readDouble("F\(index)Ac") ?? 0
        let target = readDouble("F\(index)Tg") ?? 0
        let mn = readDouble("F\(index)Mn") ?? 0
        let mx = readDouble("F\(index)Mx") ?? 0
        var mode = -1
        if let mk = fanModeKey(index), let m = readUInt8(mk) { mode = m }
        return FanSnapshot(index: index, actualRPM: actual, targetRPM: target,
                           minRPM: mn, maxRPM: mx, mode: mode)
    }

    public func allFans() -> [FanSnapshot] {
        let n = fanCount()
        guard n > 0 else { return [] }
        return (0..<n).map { fanSnapshot($0) }
    }

    /// Ftst（解锁/诊断）键是否存在。
    /// 结果缓存：键不存在时 readKeyInfo 会抛错、不进连接层缓存，控速循环里每周期都问一次太浪费。
    public func hasFtst() -> Bool {
        if let cached = ftstAvailable { return cached }
        let available = (try? smc.readKeyInfo("Ftst")) != nil
        ftstAvailable = available
        return available
    }

    // MARK: 温度

    /// 扫描所有键，挑出 CPU 相关温度传感器并缓存。
    ///
    /// 平台必须分开：Apple 芯片用 P 核(Tp..) / E 核(Te..) 簇传感器，Intel 用 TC..。
    /// 早期版本对两者一律放行，结果在 Apple 芯片上把 TCMb/TCMz 之类的非 CPU 键
    /// 也混进了平均值里，拉高读数。
    private func discoverCPUTempKeys() -> [String] {
        if let cached = cpuTempKeys { return cached }
        var apple: [String] = []
        var intel: [String] = []
        let count = (try? smc.keyCount()) ?? 0
        if count > 0 {
            for i in 0..<count {
                guard let key = try? smc.keyName(atIndex: i), key.count == 4 else { continue }
                guard key.hasPrefix("Tp") || key.hasPrefix("Te") || key.hasPrefix("TC") else { continue }
                // 仅保留能解析成合理温度的键（过滤掉同名但非温度的类型）
                guard let v = readDouble(key), v > 5, v < 120 else { continue }
                if key.hasPrefix("TC") { intel.append(key) } else { apple.append(key) }
            }
        }
        // Apple 芯片上只要发现了核心簇传感器，就完全忽略 TC.. 键
        let found = apple.isEmpty ? intel : apple
        cpuTempKeys = found
        return found
    }

    /// 已识别到的 CPU 传感器键（诊断用）
    public func cpuTempKeyNames() -> [String] {
        return discoverCPUTempKeys()
    }

    /// 一次扫描同时得到平均温度与最高温度。
    /// 控速循环每周期要读几十个传感器，分两次读会让 IOKit 调用翻倍，所以合并成一次。
    /// - Returns: (average, max)，读不到任何传感器时两者均为 nil。
    public func cpuTemperatureStats() -> (average: Double?, max: Double?) {
        var keys = discoverCPUTempKeys()
        if keys.isEmpty {
            // 兜底：枚举失败时直接试几个常见键
            keys = ["TC0P", "TC0D", "TC0E", "TC0F", "Tp0T", "Tp09"]
        }
        var sum = 0.0
        var count = 0
        var maxV: Double? = nil
        for k in keys {
            guard let v = readDouble(k), v > 5, v < 125 else { continue }
            sum += v
            count += 1
            maxV = max(maxV ?? v, v)
        }
        guard count > 0 else { return (nil, nil) }
        return (sum / Double(count), maxV)
    }

    /// 当前 CPU 温度（℃）。取已发现 CPU 传感器的平均值；找不到时返回 nil。
    public func cpuTemperature() -> Double? {
        return cpuTemperatureStats().average
    }

    /// 最热的 CPU 传感器读数（用于安全保护判断）
    public func cpuTemperatureMax() -> Double? {
        return cpuTemperatureStats().max
    }
}

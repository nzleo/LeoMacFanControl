//
//  IPCProtocol.swift
//  GUI 与 root 守护进程之间的本机通信协议。
//
//  传输：本机 Unix domain socket（AF_UNIX），换行分隔的 JSON。
//  —— 仅限本机，不涉及任何网络。socket 文件权限 0600、root 所有。
//

import Foundation

public enum IPC {
    /// 守护进程监听的本机 socket 路径
    public static let socketPath = "/var/run/com.leo.fancontrol.sock"
    /// LaunchDaemon 标签
    public static let daemonLabel = "com.leo.fancontrol.helper"
    /// 守护进程持久化配置路径（重启后自动恢复上次设置）
    public static let configPath = "/Library/Application Support/LeoFanControl/config.json"
}

/// 客户端 → 守护进程 的请求
public struct IPCRequest: Codable, Sendable {
    public enum Command: String, Codable, Sendable {
        case setConfig   // 下发新配置
        case getStatus   // 取运行状态
        case ping        // 探活
        case stop        // 让守护进程归还系统控制（不退出进程）
    }
    public var command: Command
    public var config: FanConfig?

    public init(command: Command, config: FanConfig? = nil) {
        self.command = command
        self.config = config
    }
}

/// 守护进程 → 客户端 的响应
public struct IPCResponse: Codable, Sendable {
    public var ok: Bool
    public var status: DaemonStatus?
    public var error: String?

    public init(ok: Bool, status: DaemonStatus? = nil, error: String? = nil) {
        self.ok = ok
        self.status = status
        self.error = error
    }
}

/// 编解码工具（换行分隔的 JSON）
public enum IPCCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        var data = try JSONEncoder().encode(value)
        data.append(0x0A) // '\n'
        return data
    }
    public static func decode<T: Decodable>(_ type: T.Type, from line: Data) throws -> T {
        return try JSONDecoder().decode(T.self, from: line)
    }
}

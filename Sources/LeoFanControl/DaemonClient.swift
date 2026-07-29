//
//  DaemonClient.swift
//  通过本机 Unix socket 与 root 守护进程通信的客户端（仅本机，无网络）。
//  每次请求建立一个短连接：连接 → 发一行请求 → 收一行响应 → 关闭。
//

import Foundation
import Darwin
import FanControlCore

enum DaemonClient {

    /// 发送一个请求并等待响应。守护进程不可达时返回 nil。
    /// 注意：阻塞式调用，请在后台线程使用。
    static func send(_ request: IPCRequest, timeout: TimeInterval = 2.0) -> IPCResponse? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }

        // 设置收发超时
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cpath = IPC.socketPath.utf8CString
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let dst = raw.bindMemory(to: CChar.self)
            let limit = min(cpath.count, dst.count - 1)
            for i in 0..<limit { dst[i] = cpath[i] }
            dst[limit] = 0
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectRes = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, size)
            }
        }
        guard connectRes == 0 else { return nil }

        // 发送请求
        guard let payload = try? IPCCodec.encode(request) else { return nil }
        let sent = payload.withUnsafeBytes { ptr in
            write(fd, ptr.baseAddress, payload.count)
        }
        guard sent == payload.count else { return nil }

        // 读取一行响应
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.firstIndex(of: 0x0A) != nil { break }
            if buffer.count > 1_000_000 { break }
        }
        let line: Data
        if let nl = buffer.firstIndex(of: 0x0A) {
            line = buffer.subdata(in: buffer.startIndex..<nl)
        } else {
            line = buffer
        }
        guard !line.isEmpty else { return nil }
        return try? IPCCodec.decode(IPCResponse.self, from: line)
    }

    /// 守护进程是否在运行
    static func isRunning() -> Bool {
        return send(IPCRequest(command: .ping), timeout: 1.0)?.ok == true
    }
}

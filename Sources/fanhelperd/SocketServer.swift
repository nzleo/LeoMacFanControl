//
//  SocketServer.swift
//  本机 Unix domain socket 服务端（仅本机，无网络）。
//  每个连接处理一条换行结尾的请求，返回一条换行结尾的响应后关闭。
//

import Foundation
import Darwin

final class SocketServer {
    private let path: String
    private let handler: (Data) -> Data
    private var listenFD: Int32 = -1
    private var running = false
    private let queue = DispatchQueue(label: "com.leo.fancontrol.socket")

    /// handler: 收到一行请求数据，返回一行响应数据（已含换行）
    init(path: String, handler: @escaping (Data) -> Data) {
        self.path = path
        self.handler = handler
    }

    func start() throws {
        unlink(path)  // 清除残留 socket 文件

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw posixErr() }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cpath = path.utf8CString
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let dst = raw.bindMemory(to: CChar.self)
            let limit = min(cpath.count, dst.count - 1)
            for i in 0..<limit { dst[i] = cpath[i] }
            dst[limit] = 0
        }

        // bind 会按当前 umask 创建 socket 文件。先收紧 umask，
        // 避免在 bind 与下面 chmod 之间出现一个短暂的全局可写窗口。
        let previousMask = umask(0o177)
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindRes = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(listenFD, sa, size)
            }
        }
        umask(previousMask)
        guard bindRes == 0 else { throw posixErr() }

        applySocketPermissions()

        guard listen(listenFD, 16) == 0 else { throw posixErr() }

        running = true
        queue.async { [weak self] in self?.acceptLoop() }
    }

    /// 设定 socket 文件的属主与权限：`root:admin`、`0660`。
    ///
    /// 这里不能用 `0600`：守护进程是 root，而菜单栏 GUI 以普通用户身份运行，
    /// 连接 Unix domain socket 需要对该文件有写权限，`0600` 会让 GUI 永远连不上、
    /// 只能显示“仅监控”。放到 `admin` 组是最小可用授权——只有本机管理员用户
    /// （也就是本来就能 sudo 的那些人）能下发控速指令，其他用户和沙盒进程都被拒绝。
    private func applySocketPermissions() {
        let adminGID = getgrnam("admin")?.pointee.gr_gid
        if let gid = adminGID {
            chown(path, 0, gid)          // owner=root, group=admin
            chmod(path, 0o660)
        } else {
            // 极端情况下取不到 admin 组，退回最严格的权限（此时只有 root 能连）
            chown(path, 0, 0)
            chmod(path, 0o600)
        }
    }

    private func acceptLoop() {
        while running {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                if running { continue } else { break }
            }
            handleClient(clientFD)
        }
    }

    private func handleClient(_ fd: Int32) {
        defer { Darwin.close(fd) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.firstIndex(of: 0x0A) != nil { break }
            if buffer.count > 1_000_000 { return }  // 防御异常大输入
        }
        guard let nlIndex = buffer.firstIndex(of: 0x0A) else { return }
        let line = buffer.subdata(in: buffer.startIndex..<nlIndex)
        let response = handler(line)
        _ = response.withUnsafeBytes { ptr in
            write(fd, ptr.baseAddress, response.count)
        }
    }

    func stop() {
        running = false
        if listenFD >= 0 { Darwin.close(listenFD); listenFD = -1 }
        unlink(path)
    }

    private func posixErr() -> NSError {
        return NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                       userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
    }
}

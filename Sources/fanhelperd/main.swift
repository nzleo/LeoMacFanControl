//
//  main.swift
//  fanhelperd —— root 守护进程入口。
//
//  必须以 root 运行（由 /Library/LaunchDaemons 下的 LaunchDaemon 启动）。
//  职责：开 SMC、跑控速循环、监听本机 socket、收到退出信号时归还系统控制。
//

import Foundation
import FanControlCore

setbuf(stdout, nil)   // 日志即时刷新，便于排查

func log(_ msg: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    print("[\(ts)] \(msg)")
}

// 必须 root
guard geteuid() == 0 else {
    FileHandle.standardError.write(Data("fanhelperd 必须以 root 运行。\n".utf8))
    exit(1)
}

let daemon: Daemon
do {
    daemon = try Daemon()
} catch {
    log("初始化失败：\(error)")
    exit(1)
}

daemon.start()
log("控速循环已启动")

// 启动本机 socket 服务
let server = SocketServer(path: IPC.socketPath) { line in
    daemon.handle(requestLine: line)
}

do {
    try server.start()
    log("socket 已监听：\(IPC.socketPath)")
} catch {
    log("socket 启动失败：\(error)")
    daemon.shutdownAndReturnControl()
    exit(1)
}

// 优雅退出：先忽略默认行为，再用 DispatchSource 捕获，归还控制后退出
func installSignalHandler(_ sig: Int32) -> DispatchSourceSignal {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        log("收到退出信号，归还系统控制并退出。")
        server.stop()
        daemon.shutdownAndReturnControl()
        exit(0)
    }
    src.resume()
    return src
}

let sigTerm = installSignalHandler(SIGTERM)
let sigInt  = installSignalHandler(SIGINT)
_ = (sigTerm, sigInt)   // 持有引用，避免被释放

dispatchMain()

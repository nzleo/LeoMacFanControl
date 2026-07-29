// swift-tools-version:5.9
// LeoMacFanControl —— Mac 风扇控制（菜单栏 App + root 守护进程）
// 说明：本工程只使用 Apple 自带框架（IOKit / Foundation / SwiftUI / ServiceManagement），
//       全程没有任何网络代码，可逐行审计。
import PackageDescription

let package = Package(
    name: "LeoMacFanControl",
    platforms: [
        .macOS(.v13)   // 需要 macOS 13+（MenuBarExtra、SMAppService）
    ],
    targets: [
        // 共享核心库：SMC 读写、风扇控制、数据模型、本机 IPC 协议。纯 Foundation + IOKit。
        .target(
            name: "FanControlCore",
            path: "Sources/FanControlCore"
        ),
        // 菜单栏 GUI（普通权限，只负责读取与界面，写入通过守护进程）
        .executableTarget(
            name: "LeoFanControl",
            dependencies: ["FanControlCore"],
            path: "Sources/LeoFanControl"
        ),
        // root 守护进程：持有 SMC 连接，运行控速循环，监听本机 socket
        .executableTarget(
            name: "fanhelperd",
            dependencies: ["FanControlCore"],
            path: "Sources/fanhelperd"
        ),
    ]
)

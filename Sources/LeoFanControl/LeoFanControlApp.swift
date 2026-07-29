//
//  LeoFanControlApp.swift
//  应用入口：菜单栏图标（显示实时 CPU 温度），点击弹出控制面板。
//

import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 作为菜单栏常驻程序运行，不显示 Dock 图标、不抢占前台
        NSApp.setActivationPolicy(.accessory)
    }
}

@main
struct LeoFanControlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(state)
                .onAppear { state.start() }
        } label: {
            // 菜单栏标签：风扇图标 + 当前温度
            HStack(spacing: 3) {
                Image(systemName: "fanblades")
                if let t = state.cpuTemp {
                    Text("\(Int(t.rounded()))°")
                }
            }
        }
        .menuBarExtraStyle(.window)   // 用窗口式弹出，承载丰富界面
    }
}

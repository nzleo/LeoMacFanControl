//
//  AppState.swift
//  GUI 的状态中枢：轮询温度/转速、下发配置、管理开机自启。
//
//  读取策略：优先向 root 守护进程要状态（它是控速的唯一真相来源）；
//  守护进程未安装/未运行时，本 App 自己直接读 SMC 显示传感器（只读，无需权限）。
//
//  说明：本类不标 @MainActor，所有 @Published 的修改统一切回主线程；
//        所有 SMC 访问统一放在串行的 pollQueue 上，避免并发竞争。
//

import Foundation
import Combine
import ServiceManagement
import FanControlCore

final class AppState: ObservableObject {

    // 显示数据
    @Published var cpuTemp: Double? = nil
    @Published var cpuTempMax: Double? = nil
    @Published var smoothedTemp: Double? = nil
    @Published var fans: [FanSnapshot] = []
    @Published var daemonRunning = false
    @Published var controlActive = false
    @Published var safetyEngaged = false
    @Published var tempHistory: [Double] = []
    @Published var launchAtLogin = false
    @Published var lastError: String? = nil
    /// 守护进程报告的控速失败原因（例如系统拒绝手动模式）
    @Published var controlFailureReason: String? = nil

    // 用户配置
    @Published var config: FanConfig {
        didSet { saveConfigLocal() }
    }

    private let pollQueue = DispatchQueue(label: "com.leo.fancontrol.gui.poll")
    private var pollTimer: Timer?
    private let localSMC = SMCConnection()      // 仅在 pollQueue 上使用
    private var localReader: SMCReader?         // 仅在 pollQueue 上使用
    private let maxHistory = 90
    /// 是否已经用守护进程的配置对齐过本地配置（只在首次连上时做一次）
    private var hasAdoptedDaemonConfig = false

    init() {
        if let data = UserDefaults.standard.data(forKey: "fanConfig"),
           let cfg = try? JSONDecoder().decode(FanConfig.self, from: data) {
            config = cfg
        } else {
            config = .default
        }
        pollQueue.async { [weak self] in
            guard let self else { return }
            try? self.localSMC.open()
            self.localReader = SMCReader(connection: self.localSMC)
        }
        refreshLoginItemState()

        // 菜单栏标签要一直显示温度，所以启动就开始轮询，而不是等面板第一次弹出
        DispatchQueue.main.async { [weak self] in self?.start() }
    }

    /// 开始轮询。可以被重复调用（菜单栏面板每次弹出都会触发 onAppear），
    /// 必须保证幂等，否则会不断叠加 Timer、越轮询越快。
    func start() {
        guard pollTimer == nil else { return }
        poll()
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
        // 加进 .common 模式，菜单弹出（tracking run loop）时也能继续刷新
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: 轮询（poll 在主线程触发，SMC 工作切到 pollQueue）

    private func poll() {
        pollQueue.async { [weak self] in
            guard let self else { return }
            // 1) 先问守护进程
            if let resp = DaemonClient.send(IPCRequest(command: .getStatus)),
               resp.ok, let status = resp.status {
                self.publishDaemonStatus(status)
                return
            }
            // 2) 守护进程不可达 → 本地只读显示
            if self.localReader == nil {
                try? self.localSMC.open()
                self.localReader = SMCReader(connection: self.localSMC)
            }
            let stats = self.localReader?.cpuTemperatureStats() ?? (average: nil, max: nil)
            let fans = self.localReader?.allFans() ?? []
            DispatchQueue.main.async {
                self.daemonRunning = false
                self.controlActive = false
                self.safetyEngaged = false
                self.controlFailureReason = nil
                self.cpuTemp = stats.average
                self.cpuTempMax = stats.max
                self.smoothedTemp = nil
                self.fans = fans
                self.pushHistory(stats.average)
            }
        }
    }

    private func publishDaemonStatus(_ status: DaemonStatus) {
        DispatchQueue.main.async {
            self.daemonRunning = true
            self.controlActive = status.controlActive
            self.safetyEngaged = status.safetyEngaged
            self.controlFailureReason = status.controlFailureReason
            self.cpuTemp = status.cpuTempC
            self.cpuTempMax = status.cpuTempMaxC
            self.smoothedTemp = status.smoothedTempC
            self.fans = status.fans
            self.pushHistory(status.cpuTempC)

            // 守护进程是控速的唯一真相来源：首次连上时以它的配置为准，
            // 否则重启 App 后界面显示的模式可能和实际生效的不一致。
            if !self.hasAdoptedDaemonConfig, let daemonConfig = status.config {
                self.hasAdoptedDaemonConfig = true
                if daemonConfig != self.config { self.config = daemonConfig }
            }
        }
    }

    /// 必须在主线程调用
    private func pushHistory(_ t: Double?) {
        guard let t else { return }
        tempHistory.append(t)
        if tempHistory.count > maxHistory {
            tempHistory.removeFirst(tempHistory.count - maxHistory)
        }
    }

    // MARK: 下发配置

    func pushConfig() {
        let cfg = config
        pollQueue.async { [weak self] in
            let resp = DaemonClient.send(IPCRequest(command: .setConfig, config: cfg))
            if let resp, resp.ok {
                if let s = resp.status { self?.publishDaemonStatus(s) }
                DispatchQueue.main.async { self?.lastError = nil }
            } else {
                let running = DaemonClient.isRunning()
                DispatchQueue.main.async {
                    self?.daemonRunning = running
                    if !running {
                        self?.lastError = "守护进程未运行，无法控速（仅监控）。请先安装守护进程。"
                    }
                }
            }
        }
    }

    func setMode(_ mode: ControlMode) { config.mode = mode; pushConfig() }
    func setCurve(_ curve: CurvePreset) { config.curve = curve; pushConfig() }
    func setManualPercent(_ pct: Double) { config.manualPercent = pct; pushConfig() }

    func setSafetyTemp(_ celsius: Double) {
        let r = FanConfig.safetyTempRange
        config.safetyTempC = min(max(celsius, r.lowerBound), r.upperBound)
        pushConfig()
    }

    private func saveConfigLocal() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: "fanConfig")
        }
    }

    // MARK: 开机自启（登录项）

    func refreshLoginItemState() {
        if #available(macOS 13.0, *) {
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }

    func toggleLaunchAtLogin(_ on: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            lastError = "设置开机自启失败：\(error.localizedDescription)"
        }
        refreshLoginItemState()
    }
}

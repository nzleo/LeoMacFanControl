//
//  Daemon.swift
//  root 守护进程的核心逻辑：持有 SMC 连接，按配置控速，对外提供状态/配置接口。
//
//  所有 SMC 访问都集中在一个串行队列上，避免并发读写竞争。
//

import Foundation
import FanControlCore

final class Daemon {
    private let smc = SMCConnection()
    private let reader: SMCReader
    private let controller: FanController
    private let smcQueue = DispatchQueue(label: "com.leo.fancontrol.smc")
    private let engine = FanCurveEngine()

    private var config = FanConfig.default
    private var timer: DispatchSourceTimer?
    private var controlActive = false
    private var lastTick: Date?

    /// 控制周期（秒）。0.7s 足以压住 thermalmonitord 的抢回。
    private static let tickInterval: TimeInterval = 0.7

    init() throws {
        try smc.open()
        reader = SMCReader(connection: smc)
        controller = FanController(connection: smc, reader: reader)
        loadConfig()
    }

    // MARK: 生命周期

    func start() {
        let t = DispatchSource.makeTimerSource(queue: smcQueue)
        // 每 tickInterval 一次，足以对抗 thermalmonitord 在负载下约 250ms 的抢回（重写即可压住）
        let period = Int(Self.tickInterval * 1000)
        t.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(period))
        t.setEventHandler { [weak self] in self?.applyOnce() }
        t.resume()
        timer = t
    }

    /// 进程退出时调用：把所有风扇归还系统自动
    func shutdownAndReturnControl() {
        smcQueue.sync {
            controller.returnAllToAuto()
        }
    }

    // MARK: 控速主循环（在 smcQueue 上执行）

    /// 一个控制周期：读温度 → 平滑 → 曲线 → 限速 → 写入。
    private func applyOnce() {
        let now = Date()
        let dt = lastTick.map { now.timeIntervalSince($0) } ?? Self.tickInterval
        lastTick = now

        let fans = reader.allFans()
        let stats = reader.cpuTemperatureStats()

        // 平滑温度并更新高温保护的锁存状态（带滞回）
        engine.updateTemperature(rawTempC: stats.average,
                                 rawMaxC: stats.max ?? stats.average,
                                 dt: dt,
                                 config: config)

        let needControl = (config.mode != .system) || engine.safetyEngaged

        if needControl {
            for fan in fans {
                if let target = engine.targetRPM(for: fan, config: config, dt: dt) {
                    controller.reassert(fan: fan.index, rpm: target)
                }
            }
            controlActive = true
        } else if controlActive {
            // 从“控速”切回“系统自动”：归还控制权
            controller.returnAllToAuto()
            engine.resetRampState()
            controlActive = false
        }
    }

    // MARK: 对外接口（由 socket handler 调用）

    /// 处理一条请求，返回响应数据（含换行）
    func handle(requestLine: Data) -> Data {
        let response: IPCResponse
        do {
            let req = try IPCCodec.decode(IPCRequest.self, from: requestLine)
            response = smcQueue.sync { processLocked(req) }
        } catch {
            response = IPCResponse(ok: false, error: "无法解析请求：\(error)")
        }
        return (try? IPCCodec.encode(response)) ?? Data("{\"ok\":false}\n".utf8)
    }

    /// 在 smcQueue 上执行的请求处理
    private func processLocked(_ req: IPCRequest) -> IPCResponse {
        switch req.command {
        case .ping:
            return IPCResponse(ok: true)

        case .getStatus:
            return IPCResponse(ok: true, status: buildStatus())

        case .setConfig:
            guard let newConfig = req.config else {
                return IPCResponse(ok: false, error: "缺少配置")
            }
            config = Self.sanitized(newConfig)
            saveConfig()
            applyOnce()                 // 立即生效
            return IPCResponse(ok: true, status: buildStatus())

        case .stop:
            config.mode = .system
            saveConfig()
            controller.returnAllToAuto()
            engine.resetRampState()
            controlActive = false
            return IPCResponse(ok: true, status: buildStatus())
        }
    }

    private func buildStatus() -> DaemonStatus {
        let stats = reader.cpuTemperatureStats()
        return DaemonStatus(fans: reader.allFans(),
                            cpuTempC: stats.average,
                            cpuTempMaxC: stats.max,
                            smoothedTempC: engine.smoothedTempC,
                            smoothedMaxC: engine.smoothedMaxC,
                            controlActive: controlActive,
                            hasFtst: reader.hasFtst(),
                            appliedMode: config.mode,
                            safetyEngaged: engine.safetyEngaged,
                            version: appVersion,
                            config: config,
                            controlFailureReason: controlActive ? controller.lastFailureReason : nil,
                            targetUnreachable: engine.targetUnreachable,
                            hasForceMask: reader.hasForceMask(),
                            isAppleSilicon: Platform.isAppleSilicon)
    }

    // MARK: 配置校验与持久化

    /// 夹住来自 IPC / 磁盘的配置，避免非法值把风扇设成危险状态。
    /// 守护进程是 root，绝不能无条件相信外部输入。
    private static func sanitized(_ cfg: FanConfig) -> FanConfig {
        var c = cfg
        c.manualPercent = c.manualPercent.isFinite ? min(max(c.manualPercent, 0), 100)
                                                   : FanConfig.default.manualPercent
        c.safetyTempC = Self.clamp(c.safetyTempC,
                                   to: FanConfig.safetyTempRange,
                                   fallback: FanConfig.default.safetyTempC)
        c.targetTempC = Self.clamp(c.targetTempC,
                                   to: FanConfig.targetTempRange,
                                   fallback: FanConfig.default.targetTempC)
        c.targetDeadbandC = Self.clamp(c.targetDeadbandC,
                                       to: FanConfig.targetDeadbandRange,
                                       fallback: FanConfig.default.targetDeadbandC)
        return c
    }

    /// NaN / 无穷退回默认值，其余夹进合法区间。
    /// 守护进程跑在 root 下，任何来自 socket 或磁盘的数值都必须先过这一关。
    private static func clamp(_ value: Double,
                              to range: ClosedRange<Double>,
                              fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    private func loadConfig() {
        let url = URL(fileURLWithPath: IPC.configPath)
        guard let data = try? Data(contentsOf: url),
              let cfg = try? JSONDecoder().decode(FanConfig.self, from: data) else {
            config = .default
            return
        }
        config = Self.sanitized(cfg)
    }

    private func saveConfig() {
        let url = URL(fileURLWithPath: IPC.configPath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(config) {
            try? data.write(to: url)
        }
    }
}

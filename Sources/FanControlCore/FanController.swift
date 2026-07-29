//
//  FanController.swift
//  风扇写入与解锁逻辑（需要 root，由守护进程使用）。
//
//  Apple 芯片上，thermalmonitord 默认把风扇锁在“系统模式(3)”，会拦截/抢回手动写入。
//  解锁策略（两段式，自适应不同芯片）：
//    1. 先尝试直接写 模式键=1（M1 / 部分 M5 直接成功）。
//    2. 不成功且存在 Ftst：写 Ftst=1 进入诊断态，循环重试 模式键=1 直到成功（M4 等）。
//    3. 写目标转速 F%dTg。
//  归还系统控制：把模式写回 0；当所有风扇都归还且 Ftst=1 时，写 Ftst=0 让系统接管。
//
//  注意：min/max 只是建议值；为安全起见本控制器只把转速限制在 [min, max] 内，
//  且自动模式只会“升速降温”，不会把风扇压到危险的低速。
//

import Foundation

public final class FanController {
    private let smc: SMCConnection
    private let reader: SMCReader

    /// 记录当前处于手动控制的风扇集合（用于决定何时复位 Ftst）
    private var manualFans: Set<Int> = []

    /// 解锁失败时的可读原因，供 GUI 显示。nil 表示当前没有失败。
    public private(set) var lastFailureReason: String?

    /// 解锁失败退避：连续失败后逐步拉长重试间隔，避免每个控制周期都去阻塞重试
    private var unlockFailStreak = 0
    private var nextUnlockAttempt = Date.distantPast

    public init(connection: SMCConnection, reader: SMCReader) {
        self.smc = connection
        self.reader = reader
    }

    // MARK: 写数值

    /// 按键的实际类型编码并写入（需 root）
    private func writeNumeric(_ key: String, _ value: Double) throws {
        let info = try smc.readKeyInfo(key)
        let type = SMCConnection.keyToString(info.dataType)
        let bytes = SMCDataDecoder.encode(type: type, value: value, size: Int(info.dataSize))
        try smc.writeRaw(key, bytes: bytes)
    }

    private func writeMode(_ key: String, _ mode: Int) throws {
        try smc.writeRaw(key, bytes: [UInt8(mode & 0xff)])
    }

    // MARK: 解锁 + 手动控制

    /// 让指定风扇进入手动模式（成功返回 true）。timeout 秒。
    @discardableResult
    public func enableManual(fan index: Int, timeout: TimeInterval = 10) -> Bool {
        guard let modeKey = reader.fanModeKey(index) else { return false }

        // 阶段 1：直接写模式
        try? writeMode(modeKey, 1)
        if reader.readUInt8(modeKey) == 1 {
            manualFans.insert(index)
            return true
        }

        // 阶段 2：Ftst 诊断解锁（若硬件支持）
        if reader.hasFtst() {
            try? smc.writeRaw("Ftst", bytes: [1])
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                try? writeMode(modeKey, 1)
                if reader.readUInt8(modeKey) == 1 {
                    manualFans.insert(index)
                    return true
                }
                usleep(100_000) // 100ms
            }
        }
        return false
    }

    /// 设置某个风扇的目标转速（会先确保进入手动模式）。rpm 会被夹到 [min,max]。
    @discardableResult
    public func setTargetRPM(fan index: Int, rpm: Double) -> Bool {
        let snap = reader.fanSnapshot(index)
        if snap.mode != 1 {
            guard enableManual(fan: index) else { return false }
        }
        return writeTarget(fan: index, rpm: rpm, snapshot: snap)
    }

    /// 只写目标转速，不做解锁（调用方需保证已处于手动模式）
    @discardableResult
    private func writeTarget(fan index: Int, rpm: Double, snapshot snap: FanSnapshot) -> Bool {
        let lo = snap.minRPM > 0 ? snap.minRPM : 0
        let hi = snap.maxRPM > 0 ? snap.maxRPM : max(rpm, 1)
        let clamped = min(max(rpm, lo), hi)
        do {
            try writeNumeric("F\(index)Tg", clamped)
            return true
        } catch {
            lastFailureReason = "写入目标转速失败：\(error)"
            return false
        }
    }

    /// 重新压住控制权（控速循环每隔几百毫秒调用一次，对抗 thermalmonitord 抢回）。
    /// 仅在仍需手动控制时调用。
    ///
    /// 解锁失败时会退避重试，而不是每个周期都去跑一遍阻塞的解锁循环——
    /// 控速循环和 IPC 请求共用同一个串行队列，长时间阻塞会让 GUI 卡住。
    @discardableResult
    public func reassert(fan index: Int, rpm: Double) -> Bool {
        guard reader.fanModeKey(index) != nil else {
            lastFailureReason = "本机 SMC 没有风扇模式键（F\(index)Md / F\(index)md），无法手动控速"
            return false
        }

        let snap = reader.fanSnapshot(index)
        if snap.mode != 1 {
            guard Date() >= nextUnlockAttempt else { return false }   // 退避期内直接跳过
            if enableManual(fan: index, timeout: 2) {
                unlockFailStreak = 0
                lastFailureReason = nil
            } else {
                unlockFailStreak += 1
                let backoff = min(60.0, pow(2.0, Double(min(unlockFailStreak, 6))))
                nextUnlockAttempt = Date().addingTimeInterval(backoff)
                lastFailureReason = reader.hasFtst()
                    ? "系统拒绝进入手动模式（Ftst 解锁也未生效），\(Int(backoff))s 后重试"
                    : "系统拒绝进入手动模式，且本机没有 Ftst 解锁键，\(Int(backoff))s 后重试"
                return false
            }
        } else {
            unlockFailStreak = 0
            lastFailureReason = nil
        }

        return writeTarget(fan: index, rpm: rpm, snapshot: snap)
    }

    /// 归还控制权后清掉失败状态与退避计时
    private func clearFailureState() {
        lastFailureReason = nil
        unlockFailStreak = 0
        nextUnlockAttempt = .distantPast
    }

    /// 把某个风扇归还给系统自动控制
    public func returnToAuto(fan index: Int) {
        guard let modeKey = reader.fanModeKey(index) else { return }
        try? writeMode(modeKey, 0)
        manualFans.remove(index)
        clearFailureState()
        // 所有风扇都归还后，若 Ftst 处于 1，复位为 0 让 thermalmonitord 接管
        if manualFans.isEmpty, reader.hasFtst() {
            if reader.readUInt8("Ftst") == 1 {
                try? smc.writeRaw("Ftst", bytes: [0])
            }
        }
    }

    /// 把所有风扇归还系统（守护进程退出/清理时调用）
    public func returnAllToAuto() {
        let n = reader.fanCount()
        for i in 0..<max(n, 0) {
            if let modeKey = reader.fanModeKey(i) {
                try? writeMode(modeKey, 0)
            }
        }
        manualFans.removeAll()
        if reader.hasFtst(), reader.readUInt8("Ftst") == 1 {
            try? smc.writeRaw("Ftst", bytes: [0])
        }
        clearFailureState()
    }
}

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

    /// 写 `FS! ` 强制模式位掩码（旧款 Intel Mac 专用），大端 2 字节
    private func writeForceMask(_ mask: Int) throws {
        let m = UInt16(clamping: mask)
        try smc.writeRaw(SMCReader.forceMaskKey,
                         bytes: [UInt8((m >> 8) & 0xff), UInt8(m & 0xff)])
    }

    /// 把某个风扇在 `FS! ` 里的强制位置为 on/off。返回是否写成功。
    private func setForceBit(fan index: Int, on: Bool) -> Bool {
        guard index >= 0, index < 16, let current = reader.forceMask() else { return false }
        let updated = on ? (current | (1 << index)) : (current & ~(1 << index))
        do {
            try writeForceMask(updated)
        } catch {
            lastFailureReason = "写入 FS! 强制模式位失败：\(error)"
            return false
        }
        return reader.isForcedByMask(index) == on
    }

    // MARK: 解锁 + 手动控制

    /// 让指定风扇进入手动模式（成功返回 true）。timeout 秒。
    ///
    /// 三条路径，按机型自动选择：
    ///   · 有模式键（Apple 芯片、T2 Intel）：直写 F{i}Md = 1
    ///   · 直写被拒且有 Ftst（M4 等）：先进诊断态再重试
    ///   · 没有模式键（T2 之前的 Intel）：改用 `FS! ` 位掩码
    @discardableResult
    public func enableManual(fan index: Int, timeout: TimeInterval = 10) -> Bool {
        guard let modeKey = reader.fanModeKey(index) else {
            // 旧款 Intel Mac：没有 F{i}Md，只有 FS! 位掩码这一条路
            if reader.hasForceMask(), setForceBit(fan: index, on: true) {
                manualFans.insert(index)
                return true
            }
            return false
        }

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

        // 阶段 3：模式键写不动时，若机器同时提供 FS! 就再试一次
        // （见过少数 Intel 机型两个键都在，但只认 FS!）
        if reader.hasForceMask(), setForceBit(fan: index, on: true) {
            manualFans.insert(index)
            return true
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
        // 两种控制通道任一存在即可：模式键（Apple 芯片 / T2 Intel）或 FS! 位掩码（旧 Intel）
        guard reader.fanModeKey(index) != nil || reader.hasForceMask() else {
            lastFailureReason = "本机 SMC 既没有风扇模式键（F\(index)Md / F\(index)md）"
                              + "也没有 FS! 强制模式键，无法手动控速"
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
                if reader.fanModeKey(index) == nil {
                    lastFailureReason = "系统拒绝 FS! 强制模式（本机无风扇模式键），"
                                      + "\(Int(backoff))s 后重试"
                } else if reader.hasFtst() {
                    lastFailureReason = "系统拒绝进入手动模式（Ftst 解锁也未生效），"
                                      + "\(Int(backoff))s 后重试"
                } else {
                    lastFailureReason = "系统拒绝进入手动模式，且本机没有 Ftst 解锁键，"
                                      + "\(Int(backoff))s 后重试"
                }
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
        if let modeKey = reader.fanModeKey(index) {
            try? writeMode(modeKey, 0)
        }
        // 旧款 Intel：清掉 FS! 里对应的强制位。
        // 即使模式键存在也照做一遍——enableManual 阶段 3 可能是靠 FS! 才成功的，
        // 漏清会把风扇永久留在强制模式，比不控速更危险。
        if reader.hasForceMask() {
            _ = setForceBit(fan: index, on: false)
        }
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
        // FS! 一次清零即可覆盖所有风扇
        if reader.hasForceMask() {
            try? writeForceMask(0)
        }
        manualFans.removeAll()
        if reader.hasFtst(), reader.readUInt8("Ftst") == 1 {
            try? smc.writeRaw("Ftst", bytes: [0])
        }
        clearFailureState()
    }
}

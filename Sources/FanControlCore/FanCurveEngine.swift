//
//  FanCurveEngine.swift
//  自动温控的闭环控制器：温度平滑 + 曲线插值 + 升降速限速（滞回）+ 高温保护锁存。
//
//  为什么需要这一层：
//  1) Apple 芯片的单核温度传感器噪声极大（实测 M4 空闲时同一秒内不同核心相差 20℃+，
//     瞬时热点可以冲到 96℃），直接把瞬时值喂给曲线会让风扇一直在抖。
//     → 用一阶低通（EMA）把控制温度平滑掉。
//  2) 风扇转速一旦提上去，CPU 会降温，降温又让曲线要求降速——这是个负反馈环，
//     没有阻尼就会来回振荡。
//     → 升速快、降速慢的非对称限速，等效于滞回：只有温度真的持续下来了，转速才慢慢回落。
//  3) 高温保护如果用「瞬时值 ≥ 阈值」判定，会在空闲时被单核尖峰误触发并把风扇顶死在满速。
//     → 用平滑后的最高温判定，并且触发/释放用不同阈值（滞回），避免在阈值上反复横跳。
//
//  本类非线程安全，约定只在守护进程的 smcQueue 上使用。
//

import Foundation

public final class FanCurveEngine {

    /// 控制参数。默认值针对 0.7s 的控制周期整定。
    public struct Tuning: Sendable {
        /// 温度低通时间常数（秒）。越大越平滑、响应越慢。
        public var smoothingTau: Double = 8.0
        /// 升速最大速率（比例/秒）：0.30 表示最快 ~3.3 秒从最低冲到最高
        public var rampUpPerSecond: Double = 0.30
        /// 降速最大速率（比例/秒）：0.05 表示最快 ~20 秒从最高回落到最低。
        /// 明显慢于升速 → 这就是滞回，防止温度一抖就掉速。
        public var rampDownPerSecond: Double = 0.05
        /// 高温保护释放需要比触发阈值再低多少度（滞回带宽）
        public var safetyReleaseMarginC: Double = 5.0

        public init() {}
    }

    public private(set) var tuning: Tuning

    /// 平滑后的控制温度（喂给曲线）
    public private(set) var smoothedTempC: Double?
    /// 平滑后的最高温（喂给高温保护）
    public private(set) var smoothedMaxC: Double?
    /// 高温保护是否已触发（带滞回的锁存状态）
    public private(set) var safetyEngaged: Bool = false

    /// 每个风扇当前已下发的比例，用于限速
    private var fractionByFan: [Int: Double] = [:]

    public init(tuning: Tuning = Tuning()) {
        self.tuning = tuning
    }

    /// 推进一个控制周期的温度状态。
    /// - Parameters:
    ///   - rawTempC: 本周期读到的 CPU 簇平均温度（瞬时）
    ///   - rawMaxC: 本周期读到的最高传感器温度（瞬时）
    ///   - dt: 距上次调用的实际间隔（秒）
    public func updateTemperature(rawTempC: Double?, rawMaxC: Double?, dt: Double, config: FanConfig) {
        let step = max(0.01, min(dt, 10))          // 夹住异常 dt（休眠唤醒后可能很大）
        let alpha = 1 - exp(-step / max(0.5, tuning.smoothingTau))

        smoothedTempC = Self.ema(previous: smoothedTempC, sample: rawTempC, alpha: alpha)
        smoothedMaxC = Self.ema(previous: smoothedMaxC, sample: rawMaxC, alpha: alpha)

        // 高温保护：触发用 safetyTempC，释放用 safetyTempC - margin
        if let m = smoothedMaxC {
            if safetyEngaged {
                if m <= config.safetyTempC - tuning.safetyReleaseMarginC { safetyEngaged = false }
            } else {
                if m >= config.safetyTempC { safetyEngaged = true }
            }
        } else {
            safetyEngaged = false
        }
    }

    private static func ema(previous: Double?, sample: Double?, alpha: Double) -> Double? {
        guard let s = sample else { return previous }
        guard let p = previous else { return s }        // 首个样本直接采用，避免从 0 缓慢爬升
        return p + alpha * (s - p)
    }

    /// 算出某个风扇本周期应该下发的目标转速。返回 nil 表示交还系统自动控制。
    /// 内部已完成曲线插值与升降速限速。
    public func targetRPM(for fan: FanSnapshot, config: FanConfig, dt: Double) -> Double? {
        guard let desired = computeTargetFraction(config: config,
                                                  controlTempC: smoothedTempC,
                                                  safetyEngaged: safetyEngaged) else {
            // 不控速：记住风扇当前真实比例，下次重新接管时从这里平滑起步
            fractionByFan[fan.index] = currentFraction(of: fan)
            return nil
        }

        let applied: Double
        if safetyEngaged {
            applied = 1.0                       // 保护触发时不做限速，立刻满速
        } else {
            let previous = fractionByFan[fan.index] ?? currentFraction(of: fan)
            applied = Self.slew(from: previous, to: desired, dt: dt, tuning: tuning)
        }
        fractionByFan[fan.index] = applied
        return rpm(forFraction: applied, fan: fan)
    }

    /// 限速：朝目标移动，但每秒最多走 rampUp/rampDown 那么多
    private static func slew(from previous: Double, to desired: Double,
                             dt: Double, tuning: Tuning) -> Double {
        let step = max(0.01, min(dt, 10))
        if desired > previous {
            return min(desired, previous + tuning.rampUpPerSecond * step)
        } else {
            return max(desired, previous - tuning.rampDownPerSecond * step)
        }
    }

    /// 由风扇当前实际转速反推它在 [min,max] 中的比例
    private func currentFraction(of fan: FanSnapshot) -> Double {
        let lo = fan.minRPM > 0 ? fan.minRPM : 0
        let hi = fan.maxRPM > lo ? fan.maxRPM : (lo + 1)
        return max(0, min(1, (fan.actualRPM - lo) / (hi - lo)))
    }

    /// 清空限速状态（守护进程归还控制权后调用）
    public func resetRampState() {
        fractionByFan.removeAll()
    }
}

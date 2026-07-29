//
//  FanCurveEngine.swift
//  自动温控的控制器：温度平滑 + 曲线插值 / PI 闭环 + 升降速限速（滞回）+ 高温保护锁存。
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
//  4) 曲线模式（.auto）是开环的：给定温度就给定转速，无法保证温度落在哪里。
//     想要「把温度稳在 75℃」必须闭环。
//     → .target 模式用带死区和抗积分饱和的 PI 控制器，见 stepClosedLoop。
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

        /// 目标温度模式的比例增益（输出比例 / ℃）。
        /// 整定依据：本机实测风扇全量程（1000 → 4900 RPM）在满载下的控温能力约 22℃，
        /// 即这个被控对象的静态增益约 22℃/满量程，其倒数 1/22 ≈ 0.045 就是「一步到位」的比例增益。
        /// 取 0.035（略低于 0.045）留出裕度：单步不过冲，剩下的稳态偏差交给积分项慢慢消掉。
        /// 直观含义：温度每高出目标 1℃，转速提高 3.5% 量程（约 137 RPM）。
        public var targetKp: Double = 0.035

        /// 目标温度模式的积分增益（输出比例 / ℃ / 秒）。
        /// 整定依据：Kp/Ki = 0.035/0.0015 ≈ 23 秒的积分时间常数，
        /// 与本机的热时间尺度（温度 EMA 8 秒 + 实测阶跃 30 秒收敛）同量级但更慢，
        /// 保证积分项不与平滑环节共振。太大会振荡，太小则稳态偏差消得太慢。
        public var targetKi: Double = 0.0015

        /// 目标温度模式判定「不可达」需要持续满速且高于目标多久（秒）
        public var targetUnreachableSeconds: Double = 60

        public init() {}
    }

    public private(set) var tuning: Tuning

    /// 平滑后的控制温度（喂给曲线 / PI）
    public private(set) var smoothedTempC: Double?
    /// 平滑后的最高温（喂给高温保护）
    public private(set) var smoothedMaxC: Double?
    /// 高温保护是否已触发（带滞回的锁存状态）
    public private(set) var safetyEngaged: Bool = false

    /// `.target` 模式下 PI 控制器本周期的输出比例（0~1，限速前）。
    /// 非 target 模式为 nil。
    public private(set) var closedLoopFraction: Double?
    /// PI 的积分项（℃·秒）。暴露出来是为了能在离线仿真里断言它不发散。
    public private(set) var targetIntegral: Double = 0
    /// 已满速仍压不到目标温度超过 `targetUnreachableSeconds`
    public private(set) var targetUnreachable: Bool = false

    /// 已满速且仍高于目标的累计时长（秒）
    private var unreachableSeconds: Double = 0
    /// 上一周期生效的模式，用于检测切换进 `.target` 时重置积分
    private var lastMode: ControlMode?

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

        stepClosedLoop(dt: step, config: config)
        lastMode = config.mode
    }

    // MARK: 目标温度模式的 PI 闭环

    /// 推进一步 PI 控制器。每个控制周期只跑一次（与风扇个数无关），
    /// 结果放在 `closedLoopFraction` 里，之后每个风扇各自做限速。
    ///
    /// 四个要点，缺一个都会出问题：
    /// - **死区**：温度落在 `[目标-死区, 目标]` 内就冻结积分、保持输出。
    ///   风扇吹凉 CPU 会让温度下降、下降又要求降速，是个负反馈环；没有死区就会在目标线附近抽动。
    /// - **抗积分饱和**：输出被夹到 0/1 时停止累积同方向误差（条件积分法）。
    ///   不做这个，用户设一个不可达的目标（比如 50℃）就会让积分无限增长，
    ///   风扇被永久钉在满速，之后温度掉下来也要很久才降速——完全违背这个模式的意义。
    /// - **不可达检测**：满速仍压不住就报给用户，而不是默默一直吹。
    /// - **模式切换重置**：不带上一次的历史状态进来。
    private func stepClosedLoop(dt: Double, config: FanConfig) {
        guard config.mode == .target else {
            // 离开目标温度模式：清干净，下次进来从零起步
            closedLoopFraction = nil
            targetIntegral = 0
            unreachableSeconds = 0
            targetUnreachable = false
            return
        }

        // 刚切进来：积分归零，输出从风扇当前实际比例接续，避免转速突跳
        if lastMode != .target {
            targetIntegral = 0
            unreachableSeconds = 0
            targetUnreachable = false
            closedLoopFraction = fractionByFan.values.max() ?? 0
        }

        guard let temp = smoothedTempC else {
            // 读不到温度：给保守的中低速，且不动积分（没有可信的误差可以积）
            closedLoopFraction = 0.3
            return
        }

        var output = closedLoopFraction ?? 0
        let error = temp - config.targetTempC
        let deadband = max(0, config.targetDeadbandC)

        // 目标值非法（NaN）时不要让 NaN 污染积分项——那会永久毁掉控制器
        guard error.isFinite else {
            closedLoopFraction = output
            return
        }

        // 死区：低于目标但还没低过死区下沿 → 什么都不做（冻结积分 + 保持输出）
        if error <= 0 && error >= -deadband {
            closedLoopFraction = output
            unreachableSeconds = 0
            targetUnreachable = false
            return
        }

        // 条件积分（conditional integration）抗饱和：
        // 先算出「如果这一步积分了」会得到什么输出，只有这一步没有把输出推得更深地饱和时，
        // 才真的把它累加进积分项；否则原地回滚，积分项本周期不变。
        let candidateIntegral = targetIntegral + error * dt
        let candidate = tuning.targetKp * error + tuning.targetKi * candidateIntegral

        if candidate > 1 {
            output = 1
            // 已经顶到满速却还在高于目标：继续同向积分只会让积分项发散，回滚
            if error < 0 { targetIntegral = candidateIntegral }
        } else if candidate < 0 {
            output = 0
            // 已经降到最低却还在低于目标：同理回滚
            //
            // 副作用（离线仿真实测，是有意保留的）：负载撤掉后风扇回到最低档时，
            // 积分项不会归零，而是冻结在"恰好让输出等于 0"的那个边界值上
            // （例如目标 75℃ 时冻结在 ~230，对应 65℃ 起步）。
            // 这不是失控——它有确定的上界，而且相当于记住了"这台机器压到目标需要多少风量"，
            // 下一轮负载来的时候能更早响应、过冲更小。
            // 一旦风扇重新离开最低档（输出 > 0），负误差就会立刻把它积回去，几十秒内自愈。
            if error > 0 { targetIntegral = candidateIntegral }
        } else {
            output = candidate
            targetIntegral = candidateIntegral
        }

        // 兜底硬夹取：条件积分本身已经保证 Ki·I 落在 [0, 1] 附近，
        // 这一步只是防止异常 dt / 参数被改动时越界。
        if tuning.targetKi > 0 {
            let limit = 1.0 / tuning.targetKi
            targetIntegral = min(max(targetIntegral, -limit), limit)
        }

        closedLoopFraction = output

        // 不可达判定：必须是「满速」且「仍高于目标」同时连续成立
        if output >= 1 && error > 0 {
            unreachableSeconds += dt
            if unreachableSeconds >= tuning.targetUnreachableSeconds { targetUnreachable = true }
        } else {
            unreachableSeconds = 0
            // 只有温度真的回到目标以下才清除警示，避免在满速边缘反复闪烁
            if error <= 0 { targetUnreachable = false }
        }
    }

    private static func ema(previous: Double?, sample: Double?, alpha: Double) -> Double? {
        guard let s = sample else { return previous }
        guard let p = previous else { return s }        // 首个样本直接采用，避免从 0 缓慢爬升
        return p + alpha * (s - p)
    }

    /// 算出某个风扇本周期应该下发的目标转速。返回 nil 表示交还系统自动控制。
    /// 内部已完成曲线插值 / PI 闭环与升降速限速。
    /// 调用前必须先在本周期调用过 `updateTemperature`（PI 的一步在那里推进）。
    public func targetRPM(for fan: FanSnapshot, config: FanConfig, dt: Double) -> Double? {
        guard let desired = computeTargetFraction(config: config,
                                                  controlTempC: smoothedTempC,
                                                  safetyEngaged: safetyEngaged,
                                                  closedLoopFraction: closedLoopFraction) else {
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

    /// 清空限速与闭环状态（守护进程归还控制权后调用）。
    /// 归还控制权意味着风扇转速会被系统改成任意值，控制器的历史状态全部作废。
    public func resetRampState() {
        fractionByFan.removeAll()
        closedLoopFraction = nil
        targetIntegral = 0
        unreachableSeconds = 0
        targetUnreachable = false
        lastMode = nil
    }
}

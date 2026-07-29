//
//  FanModels.swift
//  控制模式、温控曲线、配置与状态的数据模型（GUI 与守护进程共用）。
//

import Foundation

/// 控制模式
public enum ControlMode: String, Codable, CaseIterable, Sendable {
    case system   // 系统自动：交还给 macOS（thermalmonitord），最安全
    case auto     // 自动温控：按温度曲线自动升降速
    case manual   // 手动固定转速

    public var displayName: String {
        switch self {
        case .system: return "系统自动"
        case .auto:   return "自动温控"
        case .manual: return "手动固定"
        }
    }
}

/// 运行平台判定。Apple 芯片与 Intel 的 CPU 温度量级完全不同，曲线必须分别校准。
public enum Platform {
    /// 是否为 Apple 芯片（运行期判定，Rosetta 下也正确）
    public static let isAppleSilicon: Bool = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 else { return false }
        return value == 1
    }()
}

/// 温控曲线上的一个控制点：温度 → 转速占 [min,max] 的比例
public struct CurvePoint: Sendable, Equatable {
    public let tempC: Double
    public let fraction: Double
    public init(_ tempC: Double, _ fraction: Double) {
        self.tempC = tempC
        self.fraction = fraction
    }
}

/// 温控曲线档位
public enum CurvePreset: String, Codable, CaseIterable, Sendable {
    case silent      // 静音：尽量安静，高温才提速
    case balanced    // 均衡
    case aggressive  // 强力降温：早提速、压温度优先

    public var displayName: String {
        switch self {
        case .silent: return "静音"
        case .balanced: return "均衡"
        case .aggressive: return "强力降温"
        }
    }

    /// Apple 芯片曲线。
    /// 输入量是「CPU 簇传感器平均温度」，不是单核瞬时热点。
    /// 校准依据（M4 Mac mini 实测）：空闲 ≈ 71℃，10 线程满载 ≈ 80℃，
    /// 单核瞬时热点空闲就能冲到 96℃——所以绝不能拿最高值喂曲线。
    private var appleSiliconPoints: [CurvePoint] {
        switch self {
        case .silent:
            return [CurvePoint(76, 0.0), CurvePoint(82, 0.18), CurvePoint(88, 0.45),
                    CurvePoint(94, 0.75), CurvePoint(100, 1.0)]
        case .balanced:
            return [CurvePoint(73, 0.0), CurvePoint(79, 0.22), CurvePoint(85, 0.50),
                    CurvePoint(91, 0.80), CurvePoint(97, 1.0)]
        case .aggressive:
            return [CurvePoint(70, 0.0), CurvePoint(76, 0.30), CurvePoint(82, 0.60),
                    CurvePoint(88, 0.85), CurvePoint(94, 1.0)]
        }
    }

    /// Intel 曲线（TC0P/TC0D 量级：空闲 40~50℃，满载 90℃+）
    private var intelPoints: [CurvePoint] {
        switch self {
        case .silent:
            return [CurvePoint(45, 0.0), CurvePoint(60, 0.10), CurvePoint(75, 0.40),
                    CurvePoint(85, 0.80), CurvePoint(92, 1.0)]
        case .balanced:
            return [CurvePoint(40, 0.0), CurvePoint(55, 0.25), CurvePoint(70, 0.55),
                    CurvePoint(80, 0.85), CurvePoint(90, 1.0)]
        case .aggressive:
            return [CurvePoint(35, 0.0), CurvePoint(50, 0.35), CurvePoint(65, 0.75),
                    CurvePoint(75, 1.0)]
        }
    }

    /// 当前机器实际使用的曲线控制点
    public var points: [CurvePoint] {
        Platform.isAppleSilicon ? appleSiliconPoints : intelPoints
    }

    /// 给定温度，按分段线性插值返回目标比例（0~1）。
    /// 曲线在整个定义域上连续：低于首点取首点值，高于末点取末点值，中间线性过渡。
    public func fraction(forTemp t: Double) -> Double {
        let pts = points
        guard let first = pts.first, let last = pts.last else { return 0 }
        if t <= first.tempC { return first.fraction }
        if t >= last.tempC { return last.fraction }
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            if t >= a.tempC && t <= b.tempC {
                let span = b.tempC - a.tempC
                guard span > 0 else { return b.fraction }
                let ratio = (t - a.tempC) / span
                return a.fraction + ratio * (b.fraction - a.fraction)
            }
        }
        return last.fraction
    }
}

/// 用户配置（GUI 写、守护进程读并执行；守护进程也会落盘以便重启后恢复）
public struct FanConfig: Codable, Sendable, Equatable {
    public var mode: ControlMode
    public var curve: CurvePreset
    /// 手动模式下的目标比例（0~100，相对 [min,max]）
    public var manualPercent: Double
    /// 安全保护温度（℃）：平滑后的最高传感器温度超过它就强制满速，无视当前模式。
    /// 判据是「平滑后的最高值」而不是瞬时值——Apple 芯片单核热点在空闲时就会瞬间冲到 95℃+，
    /// 用瞬时值会让保护在空闲时误触发、把风扇永久顶到满速。
    public var safetyTempC: Double

    /// 安全保护阈值允许的调节范围
    public static let safetyTempRange: ClosedRange<Double> = 85...110

    public init(mode: ControlMode = .system,
                curve: CurvePreset = .balanced,
                manualPercent: Double = 50,
                safetyTempC: Double = 100) {
        self.mode = mode
        self.curve = curve
        self.manualPercent = manualPercent
        self.safetyTempC = safetyTempC
    }

    public static let `default` = FanConfig()
}

/// 守护进程上报的运行状态
public struct DaemonStatus: Codable, Sendable {
    public var fans: [FanSnapshot]
    public var cpuTempC: Double?          // CPU 簇平均温度（瞬时）
    public var cpuTempMaxC: Double?       // 最热传感器读数（瞬时）
    public var smoothedTempC: Double?     // 平滑后的控制温度（曲线实际输入）
    public var smoothedMaxC: Double?      // 平滑后的最高温（安全保护实际输入）
    public var controlActive: Bool        // 守护进程是否正在主动控速
    public var hasFtst: Bool
    public var appliedMode: ControlMode
    public var safetyEngaged: Bool        // 是否触发了高温强制满速
    public var version: String
    /// 守护进程当前生效的配置（GUI 启动时据此对齐，避免两边不一致）
    public var config: FanConfig?
    /// 控速失败原因（例如无法进入手动模式）。nil 表示正常。
    public var controlFailureReason: String?

    public init(fans: [FanSnapshot], cpuTempC: Double?, cpuTempMaxC: Double?,
                smoothedTempC: Double? = nil, smoothedMaxC: Double? = nil,
                controlActive: Bool, hasFtst: Bool, appliedMode: ControlMode,
                safetyEngaged: Bool, version: String,
                config: FanConfig? = nil, controlFailureReason: String? = nil) {
        self.fans = fans
        self.cpuTempC = cpuTempC
        self.cpuTempMaxC = cpuTempMaxC
        self.smoothedTempC = smoothedTempC
        self.smoothedMaxC = smoothedMaxC
        self.controlActive = controlActive
        self.hasFtst = hasFtst
        self.appliedMode = appliedMode
        self.safetyEngaged = safetyEngaged
        self.version = version
        self.config = config
        self.controlFailureReason = controlFailureReason
    }
}

/// 把 [0,1] 的比例映射成某个风扇的实际转速（RPM），夹在硬件 [min,max] 内。
public func rpm(forFraction f: Double, fan: FanSnapshot) -> Double {
    let lo = fan.minRPM > 0 ? fan.minRPM : 0
    let hi = fan.maxRPM > lo ? fan.maxRPM : (lo + 1)
    return lo + max(0, min(1, f)) * (hi - lo)
}

/// 给定（已平滑的）控制温度，按配置算出目标比例 0~1。
/// 返回 nil 表示该模式下不主动写入（交还系统自动）。
/// - Parameter safetyEngaged: 由 `FanCurveEngine` 带滞回判定的高温保护状态。
public func computeTargetFraction(config: FanConfig,
                                  controlTempC: Double?,
                                  safetyEngaged: Bool) -> Double? {
    // 安全保护优先于一切模式
    if safetyEngaged { return 1.0 }

    switch config.mode {
    case .system:
        return nil
    case .manual:
        return config.manualPercent / 100.0
    case .auto:
        // 读不到温度时给一个保守的中低速，而不是停转
        guard let t = controlTempC else { return 0.3 }
        return config.curve.fraction(forTemp: t)
    }
}

/// 便捷包装：直接算出目标转速。返回 nil 表示不主动写入。
public func computeTargetRPM(config: FanConfig,
                             fan: FanSnapshot,
                             controlTempC: Double?,
                             safetyEngaged: Bool) -> Double? {
    guard let f = computeTargetFraction(config: config,
                                        controlTempC: controlTempC,
                                        safetyEngaged: safetyEngaged) else { return nil }
    return rpm(forFraction: f, fan: fan)
}

public let appVersion = "1.1"

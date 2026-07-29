//
//  FanModels.swift
//  控制模式、温控曲线、配置与状态的数据模型（GUI 与守护进程共用）。
//

import Foundation

/// 控制模式
///
/// rawValue 是持久化契约：config.json 里存的就是这些字符串，
/// 新增 case 只能追加、不能改动已有的 rawValue，否则旧配置会解码失败。
public enum ControlMode: String, Codable, CaseIterable, Sendable {
    case system   // 系统自动：交还给 macOS（thermalmonitord），最安全
    case auto     // 自动温控：按温度曲线自动升降速（开环：温度 → 查表 → 转速）
    case target   // 目标温度：PI 闭环，把温度稳定在用户设定的目标值附近
    case manual   // 手动固定转速

    public var displayName: String {
        switch self {
        case .system: return "系统自动"
        case .auto:   return "自动温控"
        case .target: return "目标温度"
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
    /// 输入量是「CPU 核心簇传感器平均温度（平滑后）」，不是单核瞬时热点。
    ///
    /// 校准依据 —— M4 Mac mini（Mac16,10，风扇 1000~4900 RPM）的四象限实测，
    /// 全部为平滑后的核心平均温度：
    ///
    /// | 场景            | 1000 RPM（最低）        | 4900 RPM（满速） |
    /// |-----------------|------------------------|-----------------|
    /// | 真空闲          | ~52℃（稳定）           | ~48℃（稳定）     |
    /// | 10 线程满载     | >87℃ 且持续上升（热失控）| ~65℃（30s 收敛） |
    ///
    /// 三条推论决定了控制点的取法：
    /// 1) **真空闲基线是 52℃**。曲线起点必须落在 52℃ 附近或之上，否则空闲时风扇就在无谓提速；
    ///    但也不能高到 70℃ 以上——那样日常使用曲线长期输出 0，等于没装这个软件，
    ///    等温度冲过 87℃ 时又突然满速，体验是「要么不动要么狂转」。
    /// 2) **风扇在负载下的控温能力约 22℃**（平均温度；峰值约 24℃），非常大，
    ///    所以曲线中段给多少比例，几乎线性地决定了系统最终收敛在哪个温度。
    /// 3) **满载满速的物理下限是 65℃**。满速点因此设在 76~90℃：曲线在 65℃ 处给出的比例
    ///    （aggressive ≈0.62、balanced ≈0.38）会让系统收敛在略高于 65℃ 的位置，
    ///    这是合理的负反馈平衡点，而不是把风扇钉死在满速。
    private var appleSiliconPoints: [CurvePoint] {
        switch self {
        case .silent:
            return [CurvePoint(60, 0.0), CurvePoint(68, 0.20), CurvePoint(75, 0.45),
                    CurvePoint(82, 0.75), CurvePoint(90, 1.0)]
        case .balanced:
            return [CurvePoint(55, 0.0), CurvePoint(62, 0.25), CurvePoint(68, 0.50),
                    CurvePoint(74, 0.75), CurvePoint(80, 1.0)]
        case .aggressive:
            return [CurvePoint(52, 0.0), CurvePoint(58, 0.30), CurvePoint(64, 0.60),
                    CurvePoint(70, 0.85), CurvePoint(76, 1.0)]
        }
    }

    /// Intel 曲线（TC0P/TC0D 量级：空闲 40~50℃，满载 90℃+）。
    /// ⚠️ 未经实机验证：作者手上只有 Apple 芯片机型，这套控制点沿用 Intel Mac 的传统量级，
    /// 没有像上面那样做过四象限实测校准。Intel 用户请自行观察后调整。
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

    /// 目标温度模式的目标值（℃，对应平滑后的核心平均温度）。
    /// PI 控制器会调节转速把温度稳在这个值附近。
    public var targetTempC: Double

    /// 目标温度模式的死区宽度（℃）：只有温度低于 `targetTempC - targetDeadbandC` 才允许降速。
    /// 没有死区风扇会在目标线附近来回抽——风扇吹凉 CPU → 温度降 → 降速 → 温度升，
    /// 这是个负反馈环，必须留一段"什么都不做"的区间。
    public var targetDeadbandC: Double

    /// 安全保护阈值允许的调节范围
    public static let safetyTempRange: ClosedRange<Double> = 85...110

    /// 目标温度允许的设定范围。
    /// 下限 65℃ 是**物理下限**：本机实测满载 + 满速也只能压到 65℃，
    /// 设得比这更低的目标根本不可达，只会让风扇永久满速。
    public static let targetTempRange: ClosedRange<Double> = 65...90

    /// 死区宽度允许的设定范围
    public static let targetDeadbandRange: ClosedRange<Double> = 1...10

    public init(mode: ControlMode = .system,
                curve: CurvePreset = .balanced,
                manualPercent: Double = 50,
                safetyTempC: Double = 100,
                targetTempC: Double = 75,
                targetDeadbandC: Double = 4) {
        self.mode = mode
        self.curve = curve
        self.manualPercent = manualPercent
        self.safetyTempC = safetyTempC
        self.targetTempC = targetTempC
        self.targetDeadbandC = targetDeadbandC
    }

    /// 手写解码：新增字段缺失时退回默认值，保证 1.1 及更早版本写下的 config.json 仍能读。
    /// （合成的 Codable 实现遇到缺字段会直接抛错，那会让守护进程重启后丢掉全部用户配置。）
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FanConfig()
        mode = try c.decodeIfPresent(ControlMode.self, forKey: .mode) ?? d.mode
        curve = try c.decodeIfPresent(CurvePreset.self, forKey: .curve) ?? d.curve
        manualPercent = try c.decodeIfPresent(Double.self, forKey: .manualPercent) ?? d.manualPercent
        safetyTempC = try c.decodeIfPresent(Double.self, forKey: .safetyTempC) ?? d.safetyTempC
        targetTempC = try c.decodeIfPresent(Double.self, forKey: .targetTempC) ?? d.targetTempC
        targetDeadbandC = try c.decodeIfPresent(Double.self, forKey: .targetDeadbandC) ?? d.targetDeadbandC
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
    /// 目标温度模式下：已满速仍压不到目标温度（持续 60s 以上）
    public var targetUnreachable: Bool

    public init(fans: [FanSnapshot], cpuTempC: Double?, cpuTempMaxC: Double?,
                smoothedTempC: Double? = nil, smoothedMaxC: Double? = nil,
                controlActive: Bool, hasFtst: Bool, appliedMode: ControlMode,
                safetyEngaged: Bool, version: String,
                config: FanConfig? = nil, controlFailureReason: String? = nil,
                targetUnreachable: Bool = false) {
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
        self.targetUnreachable = targetUnreachable
    }

    /// 手写解码：`targetUnreachable` 缺失时退回 false。
    /// 这条兼容性是必需的——升级 GUI 之后旧版守护进程可能还在跑（LaunchDaemon 不会自动换二进制），
    /// 它上报的 JSON 里没有这个字段，用合成的解码实现会让整个状态解析失败、界面变成"仅监控"。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fans = try c.decode([FanSnapshot].self, forKey: .fans)
        cpuTempC = try c.decodeIfPresent(Double.self, forKey: .cpuTempC)
        cpuTempMaxC = try c.decodeIfPresent(Double.self, forKey: .cpuTempMaxC)
        smoothedTempC = try c.decodeIfPresent(Double.self, forKey: .smoothedTempC)
        smoothedMaxC = try c.decodeIfPresent(Double.self, forKey: .smoothedMaxC)
        controlActive = try c.decode(Bool.self, forKey: .controlActive)
        hasFtst = try c.decode(Bool.self, forKey: .hasFtst)
        appliedMode = try c.decode(ControlMode.self, forKey: .appliedMode)
        safetyEngaged = try c.decode(Bool.self, forKey: .safetyEngaged)
        version = try c.decode(String.self, forKey: .version)
        config = try c.decodeIfPresent(FanConfig.self, forKey: .config)
        controlFailureReason = try c.decodeIfPresent(String.self, forKey: .controlFailureReason)
        targetUnreachable = try c.decodeIfPresent(Bool.self, forKey: .targetUnreachable) ?? false
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
///
/// 这是个**纯函数**：`.system/.auto/.manual` 都是开环的「温度 → 查表」，不需要任何历史状态。
/// `.target` 是闭环的，输出取决于积分项等控制器状态，放不进纯函数里，
/// 所以由 `FanCurveEngine` 每个周期先跑一步 PI、再把结果通过 `closedLoopFraction` 传进来。
///
/// - Parameters:
///   - safetyEngaged: 由 `FanCurveEngine` 带滞回判定的高温保护状态。
///   - closedLoopFraction: `.target` 模式下由 PI 控制器算出的比例。
///     传 nil 表示调用方没有控制器状态（例如只想预览其它模式），此时退化为保守的中低速。
public func computeTargetFraction(config: FanConfig,
                                  controlTempC: Double?,
                                  safetyEngaged: Bool,
                                  closedLoopFraction: Double? = nil) -> Double? {
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
    case .target:
        return closedLoopFraction ?? 0.3
    }
}

/// 便捷包装：直接算出目标转速。返回 nil 表示不主动写入。
public func computeTargetRPM(config: FanConfig,
                             fan: FanSnapshot,
                             controlTempC: Double?,
                             safetyEngaged: Bool,
                             closedLoopFraction: Double? = nil) -> Double? {
    guard let f = computeTargetFraction(config: config,
                                        controlTempC: controlTempC,
                                        safetyEngaged: safetyEngaged,
                                        closedLoopFraction: closedLoopFraction) else { return nil }
    return rpm(forFraction: f, fan: fan)
}

public let appVersion = "1.1"

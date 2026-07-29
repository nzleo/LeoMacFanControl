//
//  ContentView.swift
//  菜单栏弹出的控制面板。
//

import SwiftUI
import AppKit
import Combine
import FanControlCore

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var manualPercent: Double = 50
    @State private var safetyTemp: Double = FanConfig.default.safetyTempC

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            sparkline
            fanSection
            Divider()
            modeSection
            if state.config.mode == .auto { curveSection }
            if state.config.mode == .manual { manualSection }
            safetySection
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 340)
        .onAppear {
            manualPercent = state.config.manualPercent
            safetyTemp = state.config.safetyTempC
        }
        // 首次连上守护进程时会以它的配置为准，滑块要跟着更新
        .onReceive(state.$config) { newValue in
            manualPercent = newValue.manualPercent
            safetyTemp = newValue.safetyTempC
        }
    }

    // MARK: 头部：温度 + 状态

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("CPU 温度（核心平均）").font(.caption).foregroundColor(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(state.cpuTemp.map { "\(Int($0.rounded()))" } ?? "--")
                        .font(.system(size: 38, weight: .semibold, design: .rounded))
                    Text("°C").font(.title3).foregroundColor(.secondary)
                }
                if let peak = state.cpuTempMax {
                    Text("单核峰值 \(Int(peak.rounded()))°C")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                statusBadge(text: state.daemonRunning ? "守护进程运行中" : "仅监控（未控速）",
                            color: state.daemonRunning ? .green : .orange)
                if state.controlActive {
                    statusBadge(text: "正在控速", color: .blue)
                }
                if state.safetyEngaged {
                    statusBadge(text: "高温保护·满速", color: .red)
                }
            }
        }
    }

    private func statusBadge(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .clipShape(Capsule())
    }

    // MARK: 温度曲线

    private var sparkline: some View {
        GeometryReader { geo in
            let history = state.tempHistory
            let minT = 30.0, maxT = 100.0
            Path { path in
                guard history.count > 1 else { return }
                let w = geo.size.width, h = geo.size.height
                let stepX = w / CGFloat(history.count - 1)
                for (i, t) in history.enumerated() {
                    let clamped = min(max(t, minT), maxT)
                    let y = h - CGFloat((clamped - minT) / (maxT - minT)) * h
                    let x = CGFloat(i) * stepX
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(Color.accentColor, lineWidth: 2)
        }
        .frame(height: 42)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: 风扇列表

    private var fanSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.fans.isEmpty {
                Text("未检测到风扇（无风扇机型或读取失败）")
                    .font(.caption).foregroundColor(.secondary)
            }
            ForEach(state.fans, id: \.index) { fan in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("风扇 \(fan.index + 1)").font(.subheadline.weight(.medium))
                        Spacer()
                        Text("\(Int(fan.actualRPM.rounded())) RPM")
                            .font(.subheadline.monospacedDigit())
                    }
                    HStack(spacing: 10) {
                        Text("目标 \(Int(fan.targetRPM.rounded()))")
                        Text("范围 \(Int(fan.minRPM.rounded()))–\(Int(fan.maxRPM.rounded()))")
                        Text(modeText(fan.mode))
                    }
                    .font(.caption2).foregroundColor(.secondary)
                }
            }
        }
    }

    private func modeText(_ mode: Int) -> String {
        switch mode {
        case 0: return "模式：自动"
        case 1: return "模式：手动"
        case 3: return "模式：系统"
        default: return "模式：?"
        }
    }

    // MARK: 控制模式

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("控制模式").font(.caption).foregroundColor(.secondary)
            Picker("", selection: Binding(
                get: { state.config.mode },
                set: { state.setMode($0) }
            )) {
                ForEach(ControlMode.allCases, id: \.self) { m in
                    Text(m.displayName).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var curveSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("温控档位").font(.caption).foregroundColor(.secondary)
            Picker("", selection: Binding(
                get: { state.config.curve },
                set: { state.setCurve($0) }
            )) {
                ForEach(CurvePreset.allCases, id: \.self) { c in
                    Text(c.displayName).tag(c)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("温度越高，风扇自动越快；档位越强，提速越早。")
                .font(.caption2).foregroundColor(.secondary)
        }
    }

    private var manualSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("手动转速").font(.caption).foregroundColor(.secondary)
                Spacer()
                Text("\(Int(manualPercent))%").font(.caption.monospacedDigit())
            }
            Slider(value: $manualPercent, in: 0...100, step: 1) { editing in
                if !editing { state.setManualPercent(manualPercent) }
            }
            Text("百分比对应风扇最低～最高转速之间。")
                .font(.caption2).foregroundColor(.secondary)
        }
    }

    // MARK: 高温保护

    private var safetySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("高温保护").font(.caption).foregroundColor(.secondary)
                Spacer()
                Text("\(Int(safetyTemp))°C").font(.caption.monospacedDigit())
            }
            Slider(value: $safetyTemp,
                   in: FanConfig.safetyTempRange,
                   step: 1) { editing in
                if !editing { state.setSafetyTemp(safetyTemp) }
            }
            Text("单核峰值温度（平滑后）超过此值就强制满速，无视当前模式。")
                .font(.caption2).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 底部

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("开机自动启动", isOn: Binding(
                get: { state.launchAtLogin },
                set: { state.toggleLaunchAtLogin($0) }
            ))
            .toggleStyle(.switch)
            .font(.callout)

            if !state.daemonRunning {
                Text("提示：当前只能监控。要让“自动/手动控速”生效，需先安装 root 守护进程（见 README）。")
                    .font(.caption2).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let reason = state.controlFailureReason {
                Text("控速未生效：\(reason)")
                    .font(.caption2).foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let err = state.lastError {
                Text(err).font(.caption2).foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
    }
}

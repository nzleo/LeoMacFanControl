# 故障排查

← 返回 [README](../README.md)

找不到对应条目的话，请[提一个 bug 反馈](https://github.com/nzleo/LeoMacFanControl/issues/new?template=bug.yml)，模板里列了需要的信息。

---

## 常见问题

**面板一直显示"仅监控（未控速）"**

守护进程没装或没起来。检查：

```bash
sudo launchctl print system/com.leo.fancontrol.helper
sudo tail -f /Library/Logs/LeoFanControl/fanhelperd.log
```

**面板显示"仅监控"但守护进程确实在跑**

确认你的账号在 `admin` 组里：

```bash
id -Gn | grep admin
```

socket 权限是 `root:admin 0660`，非管理员账号连不上。

**选了某个模式但控速未生效，提示旧版本**

守护进程版本落后于 GUI。面板和状态里的 `version` 字段可以确认。重装：

```bash
swift build -c release --product fanhelperd
sudo ./Scripts/install.sh
```

**改了转速没反应**

面板底部会显示具体原因。若提示"系统拒绝进入手动模式"，说明命中了系统层限制（详见[技术原理](how-it-works.md#1-一个现实限制)）。守护进程会按 2/4/8…60 秒退避重试，不会把 CPU 占满。

**温度显示 `--`**

读不到 CPU 传感器，极少见。该机型传感器键可能特殊，请[提交机型适配报告](https://github.com/nzleo/LeoMacFanControl/issues/new?template=compat-report.yml)附上具体型号。

**`swift build` 报缺少命令行工具**

```bash
xcode-select --install
```

---

## 目标温度模式

**弹橙色"该目标对本机不可达"**

设的目标低于本机物理下限。M4 Mac mini 满载时满速也只能压到 65°C，把目标调高即可。

这条警示要满速且持续高于目标 60 秒才出现，不会误报。

**温度稳定在比目标低 2–4°C 的位置**

这是死区的正常表现，不是偏差。死区让风扇在 `[目标−4, 目标]` 区间里不动作，避免来回抽速。详见[温控算法](control-algorithm.md#4-目标温度闭环pi-控制器)。

---

## Intel Mac

**完全无法控速**

先确认走的是哪条通道。守护进程上报的状态里有 `hasForceMask`（是否存在 `FS!` 键）和 `isAppleSilicon` 两个诊断字段：

```bash
# 需要账号在 admin 组；这两个字段需要 1.2 及以上的守护进程
printf '{"command":"getStatus"}\n' | nc -U /var/run/com.leo.fancontrol.sock
```

若 `hasForceMask` 为 `false` 且风扇也没有 `F{i}Md` 键，说明该机型两条通道都不存在，当前实现覆盖不到——请[提交机型适配报告](https://github.com/nzleo/LeoMacFanControl/issues/new?template=compat-report.yml)。

**自动模式下风扇长期不动 / 一上来就狂转**

`intelPoints` 曲线未经实机校准，温度量级可能对不上你的机型。先用"手动固定"确认风扇响应正常，再按实测调整 `FanModels.swift` 里的 `intelPoints` 控制点。

**欢迎回报实测数据。** Intel 曲线要靠社区数据才能校准，[机型适配报告](https://github.com/nzleo/LeoMacFanControl/issues/new?template=compat-report.yml)里的空闲/满载温度和 RPM 范围非常有价值。

---

## 安装与分发

**DMG 拷给别人打不开，提示"已损坏"或"无法验证开发者"**

ad-hoc 签名 + 未公证的正常表现，不是文件损坏。

```bash
xattr -dr com.apple.quarantine /Applications/LeoFanControl.app
```

或按住 Control 点击 App 图标 → 选"打开" → 弹窗里再点一次"打开"。详见 [README 下载与安装](../README.md#下载与安装)。

**`install.sh` 报"守护进程二进制不支持本机架构"**

拿到的是只含单架构的包。用 `./Scripts/make-dmg.sh` 或 `./Scripts/build-app.sh --universal` 重新构建。

**菜单栏找不到图标**

它是菜单栏 App（`LSUIElement`），不会有窗口、也不在程序坞。图标在屏幕右上角，显示为风扇图标 + 当前温度（例如 `52°`）。

如果菜单栏图标太多挤掉了，按住 Command 键拖动可以调整顺序，或先关掉几个其他菜单栏程序确认。

# 从源码构建与打包

← 返回 [README](../README.md)

前置：macOS 13+、已装 Xcode 命令行工具（`xcode-select --install`）。**不需要完整 Xcode。**

---

## 1. 编译并打包 GUI

在项目根目录，普通用户身份（不用 sudo）：

```bash
./Scripts/build-app.sh              # 仅本机架构，本地开发用，快
./Scripts/build-app.sh --universal  # 通用二进制（Apple 芯片 + Intel），分发用
```

生成 `LeoFanControl.app`。可以拖进 `/Applications`，双击运行。此时已经能**监控**温度和转速。

> 也可以直接用 Xcode 打开：`File ▸ Open` 选中项目根目录的 `Package.swift`，选 `LeoFanControl` scheme 运行。

## 2. 安装 root 守护进程（控速才需要）

```bash
swift build -c release --product fanhelperd   # 普通用户编译
sudo ./Scripts/install.sh                     # root 安装并注册 LaunchDaemon
```

装好后面板右上角会从"仅监控"变成"守护进程运行中"。

> **升级时守护进程必须一起重装。** LaunchDaemon 不会自动换二进制。新版 GUI 里的新模式在旧守护进程的枚举里不存在，旧二进制会拒绝这条配置（面板显示控速未生效）。
>
> 配置文件本身向后兼容：旧 `config.json` 缺少新字段时会自动退回默认值，不会丢设置。

## 3. 打包 DMG

```bash
./Scripts/make-dmg.sh
```

产物 `dist/LeoFanControl-<版本>.dmg`，约 1.7 MB，内容：

- `LeoFanControl.app` —— 通用二进制（`x86_64 + arm64`）
- `应用程序` 软链接 —— 方便拖拽安装
- `守护进程（控速必需）/` —— 预编译的通用 `fanhelperd` + `install.sh` + `uninstall.sh`，**接收方不需要装 Xcode**
- `安装说明.txt` —— 含 Gatekeeper 放行步骤

## 4. 卸载

```bash
sudo ./Scripts/uninstall.sh
```

停止并移除守护进程，把风扇交还给 macOS 自动控制。GUI 直接删除 `LeoFanControl.app`；如开了自启，先在面板里关掉开关。

---

## 5. 版本号的单一来源

版本号只写在一处：`Sources/FanControlCore/FanModels.swift` 里的 `appVersion`。

`Info.plist` 的 `CFBundleVersion` / `CFBundleShortVersionString`、DMG 文件名都由脚本从这里读取（`lib-build.sh` 的 `read_version`）。

> 这是补的一个坑：早期 `Info.plist` 硬编码 `1.0`，而 `appVersion` 已经到 1.2，两边长期不一致。

---

## 6. 通用二进制怎么构建

`swift build --arch arm64 --arch x86_64` 依赖完整 Xcode 里的 `xcbuild`，只装了 Command Line Tools 的机器会直接失败。

所以 `Scripts/lib-build.sh` 改成**分别编译两个架构再用 `lipo` 合并**，只依赖 swiftc 自带的交叉编译能力：

```bash
swift build -c release --product X --scratch-path .build     -Xswiftc -target -Xswiftc arm64-apple-macos13.0
swift build -c release --product X --scratch-path .build-x86  -Xswiftc -target -Xswiftc x86_64-apple-macos13.0
lipo -create -output <out> .build/release/X .build-x86/release/X
```

合并后会**校验两个架构都在**，缺一个就直接失败——宁可不出包，也不要发出一个只能跑一半机器的包。

`install.sh` 里也有一道架构校验：装错架构的二进制会表现为"守护进程反复重启"，很难排查，不如在安装时直接拦住并说清原因。

---

## 7. App 图标的生成流程

图标是**混合方案**，由 `build-app.sh` 在打包时现场生成：

| 尺寸 | 来源 | 原因 |
|---|---|---|
| 16 / 32 / 64 px | `Scripts/make-icon.swift` 纯代码矢量绘制 | 位图素材细节太密（笑脸、冰块、滑块上的红黄绿圆点），缩到这个尺寸会糊成色斑。代码版在 ≤32 px 时会切到 4 片粗叶、去投影的简化几何，轮廓明显更清楚 |
| 128 px 及以上 | `Resources/AppIcon-source.png` 经 `Scripts/prepare-icon.swift` 处理 | 大尺寸下位图的表现力和细节远胜矢量 |

`Resources/AppIcon-source.png` 是**唯一进版本库的位图素材**（其余一切都是代码生成）。源图没有 alpha 通道、四角是纯黑，直接用会在 Finder / Dock 里显示成黑方块托着圆角蓝底，所以 `prepare-icon.swift` 要做三件事：

1. **自动测量圆角方形边界**——逐像素扫描非黑像素求包围盒，不硬编码 inset。换素材不用改代码。脚本会打印多个阈值下的测量结果，便于确认投影被正确排除。
2. **超椭圆（squircle）遮罩**——用 Lamé 曲线 `(|x|/a)^n + (|y|/a)^n = 1`，指数 `n` 由二分法解出，使其**最小曲率半径等于内容宽度的 22.37%**（Big Sur 圆角比例）。没有魔法常数，比例是解出来的。
3. **复检**——检查四角 alpha 是否为 0，并统计遮罩贴边区里的"中性近黑"像素。用色度而非亮度做判据：残留的黑底来自源图纯黑 `(0,0,0)`，是中性色；素材自带的深色边框是深蓝 `(0,21,141)` 这类，蓝通道远高于红通道。只有中性近黑才算残留。

两边配色刻意对齐：代码版的渐变控制点取自源图实测采样（顶部 `#60D0FE`、底部 `#002FB9`），避免用户在 64→128 px 的尺寸交界处看到明显色调跳变。

**源图不存在时自动退回纯代码绘制**，行为与引入素材之前完全一致。图标生成失败不阻断打包——没图标只影响观感，不影响功能。

调试时可以单独跑：

```bash
mkdir -p /tmp/iconbuild
swift Scripts/make-icon.swift /tmp/iconbuild
swift Scripts/prepare-icon.swift Resources/AppIcon-source.png /tmp/iconbuild/AppIcon.iconset
# 拼版预览：/tmp/iconcheck/preview.png（各尺寸 1:1）
#          /tmp/iconcheck/preview-small.png（小尺寸放大 6 倍）
```

---

## 8. 签名与 Gatekeeper

本工程用 **ad-hoc 签名**，没有 Apple Developer ID（每年 99 美元）、也未做公证（notarization）。签名本身是必需的——`SMAppService`（开机自启）要求 App 有签名才能注册。

后果：别人从 DMG 拷出来首次打开会被 Gatekeeper 拦。这是签名策略的必然结果，不是打包错误。放行方式见 [README 的下载安装一节](../README.md#下载与安装)。

要做到"双击即开、零提示"需要付费证书加公证流程。本工程刻意不引入，因为那要求把签名密钥放进构建环境。

---

## 9. 改脚本时的一个坑

macOS 自带的是 **bash 3.2**，它会把紧跟在变量后面的**多字节字符**（例如中文全角括号 `（`）的字节算进变量名里。配合 `set -u` 会直接报 `unbound variable` 并退出：

```bash
echo "日志在 $LOG_DIR（可删）"    # ✗ 报错：LOG_DIR�: unbound variable
echo "日志在 ${LOG_DIR}（可删）"  # ✓
```

所以脚本里凡是变量后面紧跟中文，**必须写成 `${VAR}`**。

这个坑真实咬过两次：`uninstall.sh` 曾因此一直在最后一行报错退出，让卸载成功看起来像失败；后来 `build-app.sh` 的图标回退分支也中过一次，导致回退路径完全不可用。

排查用的扫描命令：

```bash
rg -n '\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F]' Scripts/*.sh
```

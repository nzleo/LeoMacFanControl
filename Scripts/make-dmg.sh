#!/bin/bash
#
# make-dmg.sh —— 打包可分享的 DMG 磁盘映像。
#
# 用法（普通用户，不用 sudo）：  ./Scripts/make-dmg.sh
# 产物：dist/LeoFanControl-<版本>.dmg
#
# DMG 内容：
#   LeoFanControl.app          通用二进制（Apple 芯片 + Intel），拖到"应用程序"即安装
#   应用程序（软链接）          方便拖拽安装
#   守护进程/fanhelperd         通用二进制，控速必需
#   守护进程/install.sh         安装守护进程（需 sudo）
#   守护进程/uninstall.sh       卸载
#   安装说明.txt                含 Gatekeeper 首次打开步骤
#
# 关于签名：本工程用 ad-hoc 签名，没有 Apple Developer ID、也未做公证(notarization)。
# 别人从 DMG 拷出来首次打开会被 Gatekeeper 拦，需要手工放行——安装说明里写了步骤。
# 这是"不花钱买开发者证书"的必然代价，不是 bug。
#
set -euo pipefail

APP_NAME="LeoFanControl"
VOL_NAME="Leo 风扇控制"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck source=Scripts/lib-build.sh
source "$SCRIPT_DIR/lib-build.sh"

# 版本号取自源码里的 appVersion，保证 DMG 文件名和 App 里显示的版本一致
VERSION="$(read_version "$ROOT_DIR")" || exit 1
echo "==> 版本：${VERSION}"

DIST_DIR="$ROOT_DIR/dist"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# ── 1. 构建通用 App
echo ""
echo "=== 构建 GUI（通用二进制）==="
"$SCRIPT_DIR/build-app.sh" --universal

APP_SRC="$ROOT_DIR/$APP_NAME.app"
if [[ ! -d "$APP_SRC" ]]; then
    echo "错误：找不到 $APP_SRC" >&2
    exit 1
fi

# ── 2. 构建通用守护进程
echo ""
echo "=== 构建守护进程（通用二进制）==="
HELPER_OUT="$STAGE/helper/fanhelperd"
build_universal "fanhelperd" "$HELPER_OUT" "$ROOT_DIR"

# ── 3. 组装 DMG 内容
echo ""
echo "=== 组装 DMG 内容 ==="
PAYLOAD="$STAGE/payload"
mkdir -p "$PAYLOAD"

cp -R "$APP_SRC" "$PAYLOAD/"
ln -s /Applications "$PAYLOAD/应用程序"

HELPER_DIR="$PAYLOAD/守护进程（控速必需）"
mkdir -p "$HELPER_DIR"
cp "$HELPER_OUT" "$HELPER_DIR/fanhelperd"
chmod 755 "$HELPER_DIR/fanhelperd"
cp "$SCRIPT_DIR/install.sh" "$HELPER_DIR/install.sh"
cp "$SCRIPT_DIR/uninstall.sh" "$HELPER_DIR/uninstall.sh"
chmod 755 "$HELPER_DIR/install.sh" "$HELPER_DIR/uninstall.sh"

# 安装说明。Gatekeeper 那一段是重点：不写清楚对方大概率直接放弃。
cat > "$PAYLOAD/安装说明.txt" <<'GUIDE'
Leo 风扇控制 —— 安装说明
========================================

支持机型：Apple 芯片（M1–M4）与 Intel Mac，macOS 13 或更高。
App 是通用二进制，两种芯片都能跑。


第 1 步：安装 App
----------------------------------------
把 LeoFanControl.app 拖到旁边的"应用程序"文件夹。


第 2 步：首次打开（重要）
----------------------------------------
本 App 没有购买 Apple 开发者证书、也未做公证，所以首次打开会被系统拦下，
提示"无法打开，因为无法验证开发者"。这是正常的，按下面任一种方式放行：

方式 A（推荐）
  1. 在"应用程序"里找到 LeoFanControl
  2. 按住 Control 键点击它，选择"打开"
  3. 弹窗里再点一次"打开"

方式 B
  先双击一次（会被拦），然后打开
  系统设置 ▸ 隐私与安全性，往下翻找到相关提示，点"仍要打开"

方式 C（命令行，最快）
  在"终端"里执行：
      xattr -dr com.apple.quarantine /Applications/LeoFanControl.app

打开后不会有窗口，也不会出现在程序坞——它是菜单栏 App。
请看屏幕右上角菜单栏，会多出一个风扇图标和当前温度（例如 "52°"）。
如果菜单栏图标很多、挤得看不见，按住 Command 键拖动可以调整位置。

这一步完成后就能"监控"温度和转速了，不需要任何权限。


第 3 步：安装守护进程（只有要"控速"才需要）
----------------------------------------
控制风扇转速必须有 root 权限，由一个独立的守护进程负责。

打开"终端"，把"守护进程（控速必需）"文件夹拖进终端窗口获取路径，
然后执行（会要求输入你的登录密码）：

    cd "把上面拖进来的路径粘在这里"
    sudo ./install.sh

装好后，菜单栏面板右上角会从"仅监控"变成"守护进程运行中"，
这时"自动温控 / 目标温度 / 手动固定"才会真正生效。

守护进程会注册为开机自启，以后重启不用再操作。


使用
----------------------------------------
点菜单栏图标弹出面板，控制模式有四个：

  系统自动    交还给 macOS（默认，最安全）
  自动温控    按温度曲线自动升降速，可选 静音 / 均衡 / 强力降温
  目标温度    设一个目标温度，风扇自动调节把温度稳在附近（闭环控制）
  手动固定    用滑块设一个固定转速

另外有"高温保护"滑块：单核峰值温度超过它就强制满速，优先级高于所有模式。


卸载
----------------------------------------
    sudo ./uninstall.sh

会停止并移除守护进程，把风扇交还给 macOS 自动控制。
GUI 直接把 LeoFanControl.app 拖到废纸篓即可（如果开了开机自启，先在面板里关掉）。


已知限制
----------------------------------------
· 苹果没有公开的风扇控制 API，控速靠读写 SMC 私有接口。
  少数机型 macOS 会拒绝交出控制权，此时 App 仍可正常监控，
  面板上会明确显示失败原因，不会静默失效。
· 温控曲线是在 M4 Mac mini 上实测校准的。Intel Mac 的曲线未经实机验证，
  温度量级不同，建议先用"手动固定"确认风扇响应正常再切自动模式。
· 把风扇设得过低可能导致过热。自动模式只会按需升速，手动转速也被夹在
  硬件 min~max 之间，并内置高温强制满速保护。但仍请留意温度，自担风险。


遇到问题 / 反馈
----------------------------------------
项目主页（含完整文档与最新版本）：
    https://github.com/nzleo/LeoMacFanControl

· 报告问题：https://github.com/nzleo/LeoMacFanControl/issues/new?template=bug.yml
· 回报你的机型能不能用（很欢迎！）：
  https://github.com/nzleo/LeoMacFanControl/issues/new?template=compat-report.yml
· 提问与讨论：https://github.com/nzleo/LeoMacFanControl/discussions
· 故障排查文档：
  https://github.com/nzleo/LeoMacFanControl/blob/main/docs/troubleshooting.md

目前只有 M4 Mac mini 是实测校准过的，其他机型的温控曲线还是估算值。
如果你愿意花两分钟回报一下自己机型的风扇转速范围和空闲/满载温度，
就能让那个机型的曲线从「猜」变成「有依据」。


源码
----------------------------------------
全部源码可逐行审计，只用 Apple 自带框架，没有任何网络代码。
以 MIT 许可证发布。
GUIDE

# ── 4. 生成 DMG
echo ""
echo "=== 生成 DMG ==="
mkdir -p "$DIST_DIR"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"
rm -f "$DMG_PATH"

# UDZO = zlib 压缩的只读映像，兼容性最好
hdiutil create \
    -volname "$VOL_NAME" \
    -srcfolder "$PAYLOAD" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$DMG_PATH" >/dev/null

echo ""
echo "✅ 已生成：$DMG_PATH"
echo "   大小：$(du -h "$DMG_PATH" | cut -f1)"
echo ""
echo "分享前请确认："
echo "  · App 架构：$(lipo -archs "$APP_SRC/Contents/MacOS/$APP_NAME")"
echo "  · 守护进程架构：$(lipo -archs "$HELPER_DIR/fanhelperd")"
echo "  · 对方首次打开需按'安装说明.txt'放行 Gatekeeper"

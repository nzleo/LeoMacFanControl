#!/bin/bash
#
# build-app.sh —— 编译 GUI 并打包成标准的 LeoFanControl.app 应用包。
#
# 用法（普通用户，不用 sudo）：  ./Scripts/build-app.sh
# 产物：项目根目录下的 LeoFanControl.app
#
# 之后可把它拖进 /Applications，双击运行；在面板里打开“开机自动启动”。
#
set -euo pipefail

BUNDLE_ID="com.leo.fancontrol"
APP_NAME="LeoFanControl"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

echo "==> 编译 GUI（release）"
swift build -c release --product "$APP_NAME"

EXE="$ROOT_DIR/.build/release/$APP_NAME"
if [[ ! -f "$EXE" ]]; then
    echo "错误：编译产物不存在：$EXE"
    exit 1
fi

APP="$ROOT_DIR/$APP_NAME.app"
echo "==> 组装应用包 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$EXE" "$APP/Contents/MacOS/$APP_NAME"

# 图标由 make-icon.swift 现场矢量绘制，仓库里不存二进制素材。
# 生成失败不阻断打包——没图标只影响 Finder / 登录项列表的观感，不影响功能。
echo "==> 生成图标"
ICON_TMP="$(mktemp -d)"
trap 'rm -rf "$ICON_TMP"' EXIT
ICON_OK=0
if swift "$SCRIPT_DIR/make-icon.swift" "$ICON_TMP"; then
    if [[ -f "$ICON_TMP/AppIcon.icns" ]]; then
        cp "$ICON_TMP/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
        ICON_OK=1
    fi
fi
ICON_KEYS=""
if [[ "$ICON_OK" == "1" ]]; then
    # 只有图标真的存在才写这两个键，否则 Finder 会去找不存在的资源
    ICON_KEYS="    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>"
else
    echo "提示：图标生成失败，继续打包（App 将显示为空白图标）。"
fi

cat > "$APP/Contents/Info.plist" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>Leo 风扇控制</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
$ICON_KEYS
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <!-- 菜单栏程序：不在 Dock 显示 -->
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST_EOF

# 不用 --deep：Apple 已不推荐，而且这个 bundle 里没有嵌套代码，直接签外层即可。
# 签名是 SMAppService（开机自启）能正常注册的前提。
echo "==> 临时签名（ad-hoc）"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" || {
    echo "提示：ad-hoc 签名失败，可忽略，仍可本机运行（但“开机自启”可能注册不上）。"
}

echo ""
echo "✅ 已生成：$APP"
echo "   运行：双击它，或  open \"$APP\""
echo "   开机自启：在面板里打开开关（建议先把 App 拖到 /Applications）。"

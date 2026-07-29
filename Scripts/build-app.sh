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

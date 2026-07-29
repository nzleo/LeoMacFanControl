#!/bin/bash
#
# install.sh —— 安装 root 守护进程 fanhelperd 并注册为 LaunchDaemon。
#
# 两种用法：
#   A) 从源码仓库安装
#      1) 普通用户编译：  swift build -c release --product fanhelperd
#      2) root 安装：     sudo ./Scripts/install.sh
#   B) 从 DMG 安装（二进制已随包提供，无需 Xcode）
#      直接 root 运行本脚本即可，它会自动用同目录下的 fanhelperd。
#
# 本脚本不联网，只做：拷贝二进制 + 写 LaunchDaemon + 启动。
#
set -euo pipefail

LABEL="com.leo.fancontrol.helper"
INSTALL_DIR="/Library/Application Support/LeoFanControl"
BIN_DST="$INSTALL_DIR/fanhelperd"
PLIST="/Library/LaunchDaemons/$LABEL.plist"
LOG_DIR="/Library/Logs/LeoFanControl"

# 定位项目根目录（脚本所在目录的上一级）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "错误：请用 sudo 运行：  sudo ./Scripts/install.sh"
    exit 1
fi

# 依次找二进制：同目录（DMG 分发）→ 源码编译产物（开发）
SRC_BIN=""
for candidate in "$SCRIPT_DIR/fanhelperd" "$ROOT_DIR/.build/release/fanhelperd"; do
    if [[ -f "$candidate" ]]; then
        SRC_BIN="$candidate"
        break
    fi
done

if [[ -z "$SRC_BIN" ]]; then
    echo "错误：找不到守护进程二进制。"
    echo "  从源码安装请先运行：  swift build -c release --product fanhelperd"
    exit 1
fi

# 架构校验：装错架构的二进制会表现为"守护进程反复重启"，很难排查，
# 不如在这里直接拦住并说清楚原因。
HOST_ARCH="$(uname -m)"
BIN_ARCHS="$(lipo -archs "$SRC_BIN" 2>/dev/null || echo "unknown")"
if [[ "$BIN_ARCHS" != *"$HOST_ARCH"* ]]; then
    echo "错误：守护进程二进制不支持本机架构。"
    echo "  本机架构：$HOST_ARCH"
    echo "  二进制含：$BIN_ARCHS"
    echo "  请用 ./Scripts/build-app.sh --universal 重新构建，或从源码编译。"
    exit 1
fi
echo "==> 使用二进制：${SRC_BIN}（${BIN_ARCHS}）"

echo "==> 安装二进制到 $BIN_DST"
mkdir -p "$INSTALL_DIR"
cp "$SRC_BIN" "$BIN_DST"
chown root:wheel "$BIN_DST"
chmod 755 "$BIN_DST"

mkdir -p "$LOG_DIR"
chown root:wheel "$LOG_DIR"

echo "==> 写入 LaunchDaemon 配置 $PLIST"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN_DST</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/fanhelperd.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/fanhelperd.log</string>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
PLIST_EOF

chown root:wheel "$PLIST"
chmod 644 "$PLIST"

echo "==> 重新加载守护进程"
launchctl bootout system "$PLIST" 2>/dev/null || true
launchctl bootstrap system "$PLIST"
launchctl enable "system/$LABEL"

echo ""
echo "✅ 安装完成。守护进程已随系统启动，并会开机自启。"
echo "   查看日志：  sudo tail -f $LOG_DIR/fanhelperd.log"
echo "   卸载：      sudo ./Scripts/uninstall.sh"

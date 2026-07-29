#!/bin/bash
#
# lib-build.sh —— 供 build-app.sh / make-dmg.sh 复用的构建函数。
# 不可直接执行，用 source 引入。
#
# 为什么需要它：`swift build --arch arm64 --arch x86_64` 依赖完整 Xcode 的 xcbuild，
# 只装了 Command Line Tools 的机器上会失败。这里改成分别编译两个架构再 lipo 合并，
# 只依赖 swiftc 自带的交叉编译能力，任何装了命令行工具的 Mac 都能跑。
#

# 最低支持的 macOS 版本，需与 Package.swift 的 platforms 保持一致
MACOS_MIN="13.0"

# 从源码里的 appVersion 读版本号——单一来源，避免 Info.plist / DMG 文件名 / Release
# 标签各写一份然后互相不一致（之前 Info.plist 就一直停在 1.0 而 appVersion 已经是 1.2）。
read_version() {
    local root="$1"
    local v
    v="$(rg -o 'appVersion = "([^"]+)"' -r '$1' \
         "$root/Sources/FanControlCore/FanModels.swift" | head -1)"
    if [[ -z "$v" ]]; then
        echo "错误：无法从 FanModels.swift 解析 appVersion" >&2
        return 1
    fi
    printf '%s' "$v"
}

# 分架构编译并合并成通用二进制。
#   $1 = product 名（LeoFanControl / fanhelperd）
#   $2 = 输出路径
# 成功后 $2 是一个包含 x86_64 + arm64 的 fat 二进制。
build_universal() {
    local product="$1"
    local out="$2"
    local root="$3"

    echo "==> 编译 ${product}（arm64）"
    swift build -c release --product "$product" \
        --scratch-path "$root/.build" \
        -Xswiftc -target -Xswiftc "arm64-apple-macos$MACOS_MIN" >/dev/null

    echo "==> 编译 ${product}（x86_64，供 Intel Mac 使用）"
    swift build -c release --product "$product" \
        --scratch-path "$root/.build-x86" \
        -Xswiftc -target -Xswiftc "x86_64-apple-macos$MACOS_MIN" >/dev/null

    local arm="$root/.build/release/$product"
    local x86="$root/.build-x86/release/$product"
    for f in "$arm" "$x86"; do
        if [[ ! -f "$f" ]]; then
            echo "错误：编译产物缺失：$f" >&2
            return 1
        fi
    done

    mkdir -p "$(dirname "$out")"
    lipo -create -output "$out" "$arm" "$x86"

    # 校验：两个架构都在，缺一个就说明合并出了问题，宁可失败也不要发出一个只能跑一半机器的包
    local archs
    archs="$(lipo -archs "$out")"
    if [[ "$archs" != *"arm64"* || "$archs" != *"x86_64"* ]]; then
        echo "错误：通用二进制校验失败，实际架构：$archs" >&2
        return 1
    fi
    echo "    ✅ $product 通用二进制：$archs"
}

# 只编译当前机器架构（本地开发用，快）
build_native() {
    local product="$1"
    local out="$2"
    local root="$3"

    echo "==> 编译 ${product}（仅本机架构）"
    swift build -c release --product "$product" --scratch-path "$root/.build" >/dev/null
    local src="$root/.build/release/$product"
    if [[ ! -f "$src" ]]; then
        echo "错误：编译产物缺失：$src" >&2
        return 1
    fi
    mkdir -p "$(dirname "$out")"
    cp "$src" "$out"
    echo "    ✅ ${product}：$(lipo -archs "$out")"
}

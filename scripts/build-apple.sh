#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
build="$root/build/apple"
artifacts="$root/bindings/swift/Artifacts"
mkdir -p "$build/Headers" "$artifacts"
cp -R "$root/core/include/aetherunzip" "$build/Headers/"
cat > "$build/Headers/module.modulemap" <<'MAP'
module CAetherUnzip {
    umbrella header "aetherunzip/api.h"
    export *
}
MAP

build_slice() {
    local slice="$1" sdk="$2" system="$3" arch="$4" minimum="$5"
    local directory="$build/$slice"
    cmake -S "$root" -B "$directory" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_SYSTEM_NAME="$system" \
        -DCMAKE_OSX_SYSROOT="$(xcrun --sdk "$sdk" --show-sdk-path)" \
        -DCMAKE_OSX_ARCHITECTURES="$arch" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$minimum" \
        -DAETHER_UNZIP_BUILD_CLI=OFF -DAETHER_UNZIP_BUILD_TESTS=OFF
    cmake --build "$directory" --parallel "${AETHER_BUILD_JOBS:-8}" --target aetherunzip
    xcrun libtool -static -o "$directory/libCAetherUnzip.a" \
        "$directory/core/libaetherunzip.a" \
        "$directory/_deps/libarchive-build/libarchive/libarchive.a" \
        "$directory/_deps/xz-build/liblzma.a" \
        "$directory/_deps/lz4-build/liblz4.a" \
        "$directory/_deps/zstd-build/lib/libzstd.a" \
        "$directory/_deps/brotli-build/libbrotlidec.a" \
        "$directory/_deps/brotli-build/libbrotlicommon.a"
}

if [[ "${AETHER_APPLE_NATIVE_ONLY:-0}" == 1 ]]; then
    arch="$(uname -m)"
    build_slice "macos-$arch" macosx Darwin "$arch" 14.0
    mode="macOS $arch"
    package=(-library "$build/macos-$arch/libCAetherUnzip.a" -headers "$build/Headers")
else
    AETHER_BUILD_JOBS="${AETHER_BUILD_JOBS:-3}"
    pids=()
    start_slice() {
        local slice="$1"
        build_slice "$@" > "$build/$slice.log" 2>&1 &
        pids+=("$!")
    }
    start_slice macos-arm64 macosx Darwin arm64 14.0
    start_slice macos-x86_64 macosx Darwin x86_64 14.0
    start_slice ios iphoneos iOS arm64 17.0
    start_slice sim-arm64 iphonesimulator iOS arm64 17.0
    start_slice sim-x86_64 iphonesimulator iOS x86_64 17.0
    failed=0
    for pid in "${pids[@]}"; do
        wait "$pid" || failed=1
    done
    if [[ "$failed" == 1 ]]; then
        printf 'Apple build failed. See slice logs in %s\n' "$build" >&2
        exit 1
    fi
    mkdir -p "$build/macos" "$build/simulator"
    xcrun lipo -create "$build/macos-arm64/libCAetherUnzip.a" \
        "$build/macos-x86_64/libCAetherUnzip.a" -output "$build/macos/libCAetherUnzip.a"
    xcrun lipo -create "$build/sim-arm64/libCAetherUnzip.a" \
        "$build/sim-x86_64/libCAetherUnzip.a" -output "$build/simulator/libCAetherUnzip.a"
    mode="macOS, iOS and iOS Simulator"
    package=()
    for slice in macos ios simulator; do
        package+=(-library "$build/$slice/libCAetherUnzip.a" -headers "$build/Headers")
    done
fi
staging="$(mktemp -d "$artifacts/staging.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
xcodebuild -create-xcframework "${package[@]}" -output "$staging/CAetherUnzip.xcframework"
rm -rf "$artifacts/CAetherUnzip.xcframework"
mv "$staging/CAetherUnzip.xcframework" "$artifacts/"
printf 'Built CAetherUnzip for %s\n' "$mode"

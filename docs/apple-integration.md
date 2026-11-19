# Apple 集成

Swift Package 位于 `bindings/swift`，通过本地二进制 target 使用生成的 `CAetherUnzip.xcframework`。`scripts/build-apple.sh` 对每个 slice 独立配置 CMake 并合并对应静态库。macOS 与模拟器包含 arm64/x86_64，iOS 真机为 arm64。libarchive、liblzma、LZ4、Zstandard 和 Brotli 随 XCFramework 静态链接，zlib、bzip2 与字符集库来自 Apple SDK。生成目录由 gitignore 排除。

```sh
./scripts/build-apple.sh
swift test --package-path bindings/swift

xcodebuild -project apps/AetherUnzip/AetherUnzip.xcodeproj -scheme AetherUnzip \
  -destination 'platform=macOS' -derivedDataPath build/app-macos build
xcodebuild -project apps/AetherUnzip/AetherUnzip.xcodeproj -scheme AetherUnzip \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build/app-simulator \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -project apps/AetherUnzip/AetherUnzip.xcodeproj -scheme AetherUnzip \
  -destination 'generic/platform=iOS' -derivedDataPath build/app-device \
  CODE_SIGNING_ALLOWED=NO build
```

只调试本机 SDK 时可设 `AETHER_APPLE_NATIVE_ONLY=1`，产物只包含本机架构的 macOS slice。打开 App 工程前运行完整构建。Xcode 项目和 scheme 随源码保留。从 `project.yml` 修改工程后可用 `xcodegen generate --spec apps/AetherUnzip/project.yml` 重新生成。

本机 macOS 使用 ad-hoc 签名和沙盒。分发时请用自己的签名设置。iOS 真机安装需要开发团队和设备授权。macOS 的 XCTest 端到端用例通过系统文件面板导入 ZIP、预览条目并选择目标目录，使用图形登录会话里的 `xcodebuild ... -destination 'platform=macOS' test` 运行。

移动端 XCTest 通过系统 Files 面板打开样本。将 `destination_id` 设为 `xcrun simctl list devices booted` 中的 iPhone 或 iPad 模拟器 ID，再从仓库根目录运行以下命令。

```sh
xcodebuild -project apps/AetherUnzip/AetherUnzip.xcodeproj -scheme AetherUnzip \
  -destination "platform=iOS Simulator,id=$destination_id" -derivedDataPath build/app-ios-ui \
  CODE_SIGNING_ALLOWED=NO build-for-testing
xcrun simctl install "$destination_id" build/app-ios-ui/Build/Products/Debug-iphonesimulator/AetherUnzip.app
xcrun simctl install "$destination_id" build/app-ios-ui/Build/Products/Debug-iphonesimulator/AetherUnzipUITests-Runner.app
app_data=$(xcrun simctl get_app_container "$destination_id" org.aetherunzip.app data)
mkdir -p "$app_data/Documents"
cp tests/fixtures/nested.zip "$app_data/Documents/MobileNested.zip"
cp tests/fixtures/sample.xp3 "$app_data/Documents/MobileResources.xp3"
cp tests/fixtures/format-profile.json "$app_data/Documents/MobileFormatProfile.json"
cp tests/fixtures/profile-box.bin "$app_data/Documents/MobileProfileBox.bin"
xcodebuild -project apps/AetherUnzip/AetherUnzip.xcodeproj -scheme AetherUnzip \
  -destination "platform=iOS Simulator,id=$destination_id" -derivedDataPath build/app-ios-ui \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO test-without-building
```

SDK 在 Swift 并发后台任务内完成系统文件协调和 C 调用。读写期间分别持有输入和目标安全作用域，访问协调器返回的 URL。最近打开记录储存书签，权限过期时可以重新选择。目标可由每次提取时选择，也可通过设置使用 App Documents 下的 `Extracted Archives` 目录。

导入分卷时，在同一个系统文件面板中选择全部分卷。SDK 识别编号 ZIP/7z 字节分片、磁盘编号 ZIP 和 RAR 命名，按读取顺序排列，再以一次协调操作访问整组 URL。最近记录会存储同组分卷的书签。

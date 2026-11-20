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

在 macOS App 的系统文件面板中打开 `tests/fixtures/7z-aes-picker.7z` 可以验证加密文件名的 7z。先输入 `wrong-password` 确认显示错误，再输入 `fixture-pass` 打开归档。选择 **Extract All** 并在系统面板选定空目录，核对 `private.txt` 和 `second.txt` 与样本说明一致。[样本说明](../tests/fixtures/README.md)

RAR5 文件名加密使用 `tests/fixtures/rar5-aes-picker.rar`，密码同为 `fixture-pass`，提取后核对 `rar5-picker-note.txt`。[样本说明](../tests/fixtures/README.md)

移动端 XCTest 覆盖系统 Files 面板和 App 文件工作区。密码库用例使用模拟器的系统钥匙串，依赖 Xcode 生成的应用签名。将 `destination_id` 设为 `xcrun simctl list devices booted` 中的 iPhone 或 iPad 模拟器 ID，再从仓库根目录运行以下命令。

```sh
xcodebuild -project apps/AetherUnzip/AetherUnzip.xcodeproj -scheme AetherUnzip \
  -destination "platform=iOS Simulator,id=$destination_id" -derivedDataPath build/app-ios-ui build-for-testing
xcrun simctl install "$destination_id" build/app-ios-ui/Build/Products/Debug-iphonesimulator/AetherUnzip.app
xcrun simctl install "$destination_id" build/app-ios-ui/Build/Products/Debug-iphonesimulator/AetherUnzipUITests-Runner.app
app_data=$(xcrun simctl get_app_container "$destination_id" org.aetherunzip.app data)
mkdir -p "$app_data/Documents"
cp tests/fixtures/sample.zip "$app_data/Documents/MobileSample.zip"
mkdir -p "$app_data/Documents/AetherUnzip Settings Output"
cp tests/fixtures/nested.zip "$app_data/Documents/MobileNested.zip"
cp tests/fixtures/sample.xp3 "$app_data/Documents/MobileResources.xp3"
cp tests/fixtures/format-profile.json "$app_data/Documents/MobileFormatProfile.json"
cp tests/fixtures/profile-box.bin "$app_data/Documents/MobileProfileBox.bin"
cp tests/fixtures/7z-aes-picker.7z "$app_data/Documents/MobileProtected.7z"
cp tests/fixtures/rar5-aes-picker.rar "$app_data/Documents/MobileProtectedRAR.rar"
cp tests/fixtures/rar5-aes-solid-header.rar "$app_data/Documents/MobileSolidRAR.rar"
cp tests/fixtures/rar5-aes-picker.rar "$app_data/Documents/Library Locked.rar"
cp tests/fixtures/rar5-aes-picker.rar "$app_data/Documents/Library Renamed.rar"
cp tests/fixtures/aes256.zip "$app_data/Documents/Library Payload.zip"
cp tests/fixtures/chinese-gbk-aes256.zip "$app_data/Documents/Chinese Vault.zip"
cp tests/fixtures/chinese-gbk-aes256.zip "$app_data/Documents/Chinese Vault Renamed.zip"
cp tests/fixtures/workspace-photo.jpg "$app_data/Documents/Recognition Photo.jpg"
cat tests/fixtures/workspace-photo.jpg tests/fixtures/sample.zip > "$app_data/Documents/Recognition Hybrid.jpg"
cp tests/fixtures/sample.zip "$app_data/Documents/Recognition Copy.mp3"
cp tests/fixtures/sample.tar.gz "$app_data/Documents/Recognition Backup.mp4"
cp tests/fixtures/rar5-aes-picker.rar "$app_data/Documents/Recognition Locked.jpg"
layout="$app_data/Documents/Layout Workflow"
batch="$app_data/Documents/Batch Workflow"
mkdir -p "$layout" "$batch"
cp tests/fixtures/layout.zip "$layout/Top Layout.zip"
printf '%s\n' 'Existing notes' > "$layout/notes.txt"
cp tests/fixtures/sample.zip "$batch/Batch First.zip"
cp tests/fixtures/layout.tar.gz "$batch/Batch Second.tar.gz"
printf '%s\n' 'Invalid archive fixture' > "$batch/Batch Corrupt.zip"
workspace="$app_data/Documents/Project Downloads"
mkdir -p "$workspace/Guides"
cp tests/fixtures/sample.zip "$workspace/Project Assets.zip"
cp tests/fixtures/sample.tar.gz "$workspace/Release Backup.tar.gz"
unzip -p tests/fixtures/sample.zip notes.txt > "$workspace/Release Notes.txt"
cache="$app_data/tmp/aetherunzip-previews/087A3F02-C2EC-4EAB-8563-409838531B70"
mkdir -p "$cache"
head -c 131072 /dev/urandom > "$cache/Preview.txt"
python3 - "$app_data/Documents/Cache Limit.zip" <<'PY'
import sys
import zipfile

block = bytes(range(32, 127)) + b"\n"
with zipfile.ZipFile(sys.argv[1], "w", compression=zipfile.ZIP_DEFLATED) as archive:
    archive.writestr("large.txt", (block * (9 * 1024 * 1024 // len(block) + 1))[:9 * 1024 * 1024])
PY
printf '%s' ' 资源密碼！Ａ1 ' | xcrun simctl pbcopy "$destination_id"
xcodebuild -project apps/AetherUnzip/AetherUnzip.xcodeproj -scheme AetherUnzip \
  -destination "platform=iOS Simulator,id=$destination_id" -derivedDataPath build/app-ios-ui \
  -parallel-testing-enabled NO -testLanguage en -testRegion US test-without-building
```

归档识别用例覆盖 Quick Look、手动确认更名、保留原名打开和密码提示。更名用例会将测试文件 `Recognition Hybrid.jpg` 更名为 `Recognition Hybrid.zip`。重新运行前，清理该用例生成的 ZIP 并重新导入原测试文件。

中文密码用例会粘贴含全角字符和首尾空格的公开样本密码，验证 CP936 ZIP 解压及改名后的密码关联。重复运行前，从测试容器的 `Extracted Archives` 中清理本用例生成的 `Chinese Vault` 和 `Chinese Vault Renamed` 文件夹。

缓存用例用 8 MiB 的单文件上限拦截 9 MiB 的预览。手动清理用例在关闭自动清理的状态下测量并删除测试预览文件。由于其他用例启动 App 时会自动清理，请重新创建上述测试缓存，再用 `-only-testing:AetherUnzipUITests/ArchiveWorkflowTests/testCacheSettingsClearsUnusedPreviewsAndAdjustsLimits` 单独运行该用例。

布局用例在 `Layout Workflow` 去除顶层目录并保留两个同名文件，核对 `notes.txt` 和 `notes (2).txt`。批量用例在 `Batch Workflow` 保留归档内已有的 `Layout` 目录，为散落条目创建 `Batch First` 目录，并在活动中记录损坏的归档。重复运行前，从这两个测试目录清理旧的测试输出。

App 和 Swift SDK 使用 String Catalog，支持英文、简体中文和日文。系统按 App 的语言设置选择界面，按地区设置显示日期和数字。新增界面文案时同步更新 App 或 SDK 的 `Localizable.xcstrings`。三个 `test*Localization` 用例分别验证本地化排序、搜索计数和解压密码错误。

SDK 在 Swift 并发后台任务内完成系统文件协调和 C 调用。读写期间分别持有输入和目标安全作用域，访问协调器返回的 URL。最近打开记录储存书签，权限过期时可以重新选择。解压确认页默认选中已授权的归档目录，否则使用 App Documents 下的 `Extracted Archives`。用户可在设置中指定仅使用 App 文档或每次手动选择。

文件工作区默认显示 App Documents。添加位置时通过系统文件面板获得目录访问权。清单、文件编辑和传输在 SDK 的文件协调回调中执行。用户从授权目录打开压缩包时，目录权限会持续到预览和提取完成。macOS 的删除操作使用系统废纸篓，iOS/iPadOS 的删除操作在确认后直接移除项目。

导入分卷时，在同一个系统文件面板中选择全部分卷。SDK 识别编号 ZIP/7z 字节分片、磁盘编号 ZIP 和 RAR 命名，按读取顺序排列，再以一次协调操作访问整组 URL。最近记录会存储同组分卷的书签。

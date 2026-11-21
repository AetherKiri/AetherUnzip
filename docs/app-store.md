# App Store 发行与对应源码

## GPL-3.0-only 分发判断

公开仓库使用 [GPL-3.0-only](../LICENSE)。第 6 节约束二进制的对应源码供应，第 10 节约束对接收者所获权利施加额外限制。发行时需要对照准备上架地区的 Apple 使用规则、分发协议和实际适用的 EULA，核对接收者能否依 GPL 行使运行、修改和再分发等权利。Apple 标准 EULA 对开源组件的许可有例外措辞，同时也含有其他使用与再分发限制。[GPL-3.0-only](https://spdx.org/licenses/GPL-3.0-only.html) · [Apple 标准 EULA](https://www.apple.com/legal/internet-services/itunes/dev/stdeula/) · [Apple 使用规则](https://www.apple.com/legal/internet-services/itunes/us/terms.html)

采用 GPL-only 提审前，由项目权利人确认实际分发条款与上述要求相容。Apple 提供按地区配置自定义 EULA 的入口，仍需一并核对 Apple 使用规则及最低条款。若实际渠道无法满足 GPL-only 条件，先保留公开源码发布。经相关权利人确认授权后，可以另行评估范围明确的附加许可。当前仓库没有添加 App Store 例外。[Apple 自定义 EULA](https://developer.apple.com/help/app-store-connect/manage-app-information/provide-a-custom-license-agreement) · [Apple 分发协议](https://developer.apple.com/support/downloads/terms/schedules/Schedule-2-and-3-English.pdf)

## 让构建与源码一一对应

1. 从干净的 Git 提交构建 Release 归档。为每个平台、版本和构建号保存完整提交哈希及归档。App 的「关于 → 源代码」应指向该构建的公开源码页。
2. 将标签与实际归档核对。正式商店构建使用 `app-store-ios-<版本>-<构建号>`；归档验证用候选标签加 `-rc`。正式上传后，在发行记录中记下 App Store Connect 平台、版本、构建号和上传结果。标签保持指向相同提交。
3. 发布带校验值的完整对应源码包。包包含该提交的源码、项目和构建脚本、libarchive 补丁、第三方声明及五个锁定的依赖源归档。下载链接应与该版本一同保持可用。GitHub 自动生成的代码压缩包仅包含 Git 树，完整依赖源归档见发行附件。

下面的示例从当前提交生成 iOS 1.0（构建 1）的候选归档。正式发行时使用对应的版本、构建号和正式标签，并用发行团队签名。

```sh
revision="$(git rev-parse HEAD)"
tag="app-store-ios-1.0-1-rc"
source_url="https://github.com/AetherKiri/AetherUnzip/releases/tag/$tag"

./scripts/build-apple.sh
xcodebuild -project apps/AetherUnzip/AetherUnzip.xcodeproj \
  -scheme AetherUnzip -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "build/$tag.xcarchive" MARKETING_VERSION=1.0 CURRENT_PROJECT_VERSION=1 \
  AETHER_UNZIP_SOURCE_REVISION="$revision" AETHER_UNZIP_SOURCE_URL="$source_url" \
  CODE_SIGNING_ALLOWED=NO archive

bundle="build/$tag.xcarchive/Products/Applications/AetherUnzip.app"
plutil -lint "$bundle/PrivacyInfo.xcprivacy"
plutil -extract AetherUnzipSourceRevision raw "$bundle/Info.plist"
plutil -extract AetherUnzipSourceURL raw "$bundle/Info.plist"
./scripts/package-source.sh "$revision" "build/AetherUnzip-$tag-source.tar.gz"
```

打包脚本从选定的 Git 提交取出文件并验证上游源归档 SHA-256。解包后，`SOURCE-REVISION` 记录完整提交，`third_party/source-archives/` 由 CMake 自动选用。可在解包根目录依照 README 构建 Core 或运行 `./scripts/build-apple.sh`。构建仍需要系统编译器和目标平台 SDK。实际发布时，在对应 GitHub Release 中提供完整源码包与 SHA-256。

## 隐私与审核资料

- 在归档的 App bundle 根目录核对 `PrivacyInfo.xcprivacy`。App 的「关于 → 隐私政策」指向 [GitHub Pages](https://aetherkiri.github.io/AetherUnzip/privacy/)。在 App Store Connect 的隐私政策网址栏使用同一地址。
- 发布隐私标签前，对照实际归档和所有依赖。当前仓库版本在设备本地处理文件、密码及活动记录。Apple 的隐私标签以开发者或合作方实际收集的数据为准。新增任何上传、分析 SDK 或服务器后重新评估。[App 隐私标签](https://developer.apple.com/app-store/app-privacy-details/) · [管理隐私政策 URL](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/)

[GitHub Pages 隐私政策](https://aetherkiri.github.io/AetherUnzip/privacy/) 由根目录的 `PRIVACY.md` 生成，`gh-pages` 分支用于发布。修改政策后，使用 Python 3.10+ 和 Pandoc 重新生成静态页面，再提交并推送 `gh-pages`。

```sh
git worktree add build/privacy-pages gh-pages
python3 scripts/build-privacy-pages.py build/privacy-pages
git -C build/privacy-pages add .nojekyll index.html privacy
git -C build/privacy-pages commit -m 'docs: publish updated privacy policy'
git -C build/privacy-pages push origin gh-pages
```

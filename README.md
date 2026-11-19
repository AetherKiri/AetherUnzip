# AetherUnzip

AetherUnzip 是一个跨平台归档与资源处理框架。原生 SwiftUI App 通过 AetherUnzipKit 调用与 C 命令行示例相同的 Core，提供导入、目录树、文件内容预览、全部或选定文件提取、进度、取消、最近记录和解压设置。

| 当前读取范围 | 样本覆盖 |
| --- | --- |
| ZIP / ZIP64 | Deflate、空归档、UTF-8 路径、ZipCrypto、WinZip AES-256、磁盘编号分卷及带前缀 ZIP |
| 7z | LZMA2 |
| RAR / RAR5 | 单卷样本、跨卷文件和固实跨卷样本 |
| TAR | USTAR |
| CAB | 单卷，MSZIP 和 LZX |
| ISO 9660 | 标准卷描述符，Rock Ridge 样本 |
| LHA/LZH | LH7 样本 |
| GZIP、LZ4、Zstandard、XZ、BZIP2 | 独立压缩流、对应的 TAR 组合 |
| Brotli | 单个 `.br` 压缩流 |
| XP3 | KiriKiri 标准容器，原始或 zlib 索引和分段，Adler-32 校验 |

格式范围以 [驱动文档](docs/drivers.md) 和实测样本为准。加密范围扩展、分卷、游戏容器和多层挂载见 [路线图](docs/roadmap.md)。

在 App 的文件选择器中一次选中同组的所有分卷。支持 `name.7z.001` 和 `name.zip.001` 编号字节分片、`name.z01` 加末卷 `name.zip` 的磁盘编号 ZIP，以及 `name.part1.rar` 或 `name.rar` 加 `name.r00` 的 RAR 分卷。

在目录树中点按文件旁的眼睛按钮，即可用 Quick Look 预览常见文本、图片和 PDF。单个文件的预览上限为 32 MiB，同时遵循设置中的解压限制。

点按归档文件旁的归档图标即可进入内层。也可以从任一可读取文件的上下文菜单选择 **Open as Archive**，由 Core 检查实际格式。进入内层后可浏览、预览和提取文件，也可返回父归档。App 默认最多打开 3 层内嵌归档，同一祖先链的暂存数据合计最多 256 MiB。

处理带有固定包装头的文件时，在归档页工具栏选择 **Open with Format Profile…**，依次选择 JSON 配置和包装文件。最近打开记录会保存配置。配置格式和可运行的样本见[格式配置文档](docs/format-profiles.md)。

## 构建 Core

需要 CMake 3.24+、C17/C++17 工具链、`patch`，以及系统 zlib 和 bzip2 开发文件。ZIP AES 在 Apple 使用系统 CommonCrypto，在 Linux 使用系统 OpenSSL Crypto 开发库。首次构建下载并校验固定版本的开源依赖。Core 使用 POSIX 文件接口，Apple 与 Linux 共用实现。

```sh
cmake -S . -B build/core -DCMAKE_BUILD_TYPE=Release
cmake --build build/core --parallel
ctest --test-dir build/core --output-on-failure

build/core/aether-unzip tests/fixtures/sample.zip
build/core/aether-unzip --ls tests/fixtures/sample.zip docs
build/core/aether-unzip --cat tests/fixtures/sample.zip docs/readme.txt
mkdir -p build/output
build/core/aether-unzip tests/fixtures/sample.zip build/output
```

## 构建 Swift SDK 和 App

需要 Xcode 16+（Swift 6）及 CMake。最低运行系统为 macOS 14、iOS/iPadOS 17。完整脚本生成通用 macOS、iOS 真机和通用模拟器的 XCFramework。

```sh
./scripts/build-apple.sh
swift test --package-path bindings/swift
open apps/AetherUnzip/AetherUnzip.xcodeproj
```

在 Xcode 选择 **AetherUnzip** scheme，然后选择 Mac 或 iPhone/iPad 模拟器。真机运行需要配置开发团队。命令行构建、UI 测试和签名说明见 [Apple 集成文档](docs/apple-integration.md)。

## 开发文档

- [项目规格与验收标准](docs/spec.md)
- [开发指南与提交规范](AGENTS.md)
- [架构与依赖方向](docs/architecture.md)
- [C ABI、生命周期和错误](docs/api.md)
- [格式识别、驱动和能力](docs/drivers.md)
- [安全策略与文件提交](docs/security.md)
- [依赖版本与许可证](third_party/README.md)

项目代码采用 [MIT](LICENSE)，第三方组件保留各自的许可证。

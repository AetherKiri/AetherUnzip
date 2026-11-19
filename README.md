# AetherUnzip

AetherUnzip 是一个跨平台归档与资源处理框架。原生 SwiftUI App 通过 AetherUnzipKit 调用与 C 命令行示例相同的 Core，提供导入、目录树、文件内容预览、全部或选定文件提取、进度、取消、最近记录和解压设置。

| 当前读取范围 | 样本覆盖 |
| --- | --- |
| ZIP / ZIP64 | Deflate、空归档、UTF-8 路径、ZipCrypto、WinZip AES-256、磁盘编号分卷及带前缀 ZIP |
| 7z | LZMA2、AES-256，含固实归档和加密文件名 |
| RAR / RAR5 | 单卷样本、跨卷文件和固实跨卷样本。RAR5 单卷支持 AES-256 内容和文件名加密，含固实归档 |
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

需要 CMake 3.24+、C17/C++17 工具链、`patch`，以及系统 zlib 和 bzip2 开发文件。ZIP、7z 和 RAR5 的 AES 在 Apple 使用系统 CommonCrypto，在 Linux 使用系统 OpenSSL Crypto 开发库。首次构建下载并校验固定版本的开源依赖。Core 使用 POSIX 文件接口，Apple 与 Linux 共用实现。

```sh
cmake -S . -B build/core -DCMAKE_BUILD_TYPE=Release
cmake --build build/core --parallel
ctest --test-dir build/core --output-on-failure
```

## 使用 CLI 验证 Core

`aether-unzip` 只依赖 Core 和其第三方库，可以在 macOS 或 Linux 上独立运行。原有列表、按路径读取和提取命令仍可用。

```sh
build/core/aether-unzip --probe tests/fixtures/sample.tar.gz
build/core/aether-unzip tests/fixtures/sample.zip
build/core/aether-unzip --ls tests/fixtures/sample.zip docs
build/core/aether-unzip --cat tests/fixtures/sample.zip docs/readme.txt
build/core/aether-unzip --verify tests/fixtures/sample.zip
mkdir -p build/output
build/core/aether-unzip tests/fixtures/sample.zip build/output
```

`--probe` 报告识别依据、容器和外层压缩。列表第一列是从零开始的条目编号。`--verify` 将普通文件流式读取至结尾并执行驱动支持的内容校验，输出通过校验的文件数及其字节数，不写入解压文件。用 `--entry INDEX` 限定校验或提取的条目，多个编号按升序传入。用 `--max-total-bytes N` 测试总解码预算。命令退出码为 0 表示成功，1 表示操作失败，2 表示用法错误。失败时在标准错误输出中附上 Core 状态码。

```sh
# 使用测试样本的公开密码验证固实 RAR5 中的第三个条目
printf '%s\n' fixture-pass | build/core/aether-unzip --verify --entry 2 --password-stdin \
  tests/fixtures/rar5-aes-solid-header.rar

build/core/aether-unzip --verify \
  --volume tests/fixtures/volumes/sample.7z.002 \
  --volume tests/fixtures/volumes/sample.7z.003 \
  tests/fixtures/volumes/sample.7z.001
```

传入真实密码时，通过管道或重定向提供一行 UTF-8，不把密码写进命令行参数。分卷按照主路径在前、`--volume` 按解码顺序追加的规则传入。磁盘编号 ZIP 以 `.z01` 开始，最后追加 `.zip`。单独运行 CLI 回归可使用 `ctest --test-dir build/core -R '^cli[.]verify$' --output-on-failure`。

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

# 声明式格式配置

格式配置适用于带固定签名和偏移的包装文件。它将包装文件中的一段字节交给现有归档驱动，供后续浏览、预览和提取。App 工具栏的 **Open with Format Profile…** 接受 JSON 文件，确认配置后选择要打开的包装文件。

下面的配置可打开仓库中的 [profile-box.bin](../tests/fixtures/profile-box.bin)。可直接选择随样本生成的 [format-profile.json](../tests/fixtures/format-profile.json)。

```json
{
  "version": 1,
  "signatureOffset": 2,
  "signatureHex": "504b4731",
  "payloadOffset": 8,
  "payloadLength": 370,
  "payloadName": "payload.zip",
  "expectedFormat": "zip"
}
```

| 字段 | 规则 |
| --- | --- |
| `version` | 当前为 `1`。 |
| `signatureOffset` | 签名在包装文件中的字节偏移。可省略，默认为 `0`。 |
| `signatureHex` | 1 至 64 字节的十六进制签名。每字节用两个字符，接受大小写。 |
| `payloadOffset` | 内层归档在包装文件中的字节偏移。 |
| `payloadLength` | 内层归档的字节长度。可省略，默认从有效载荷偏移读取到文件末尾。 |
| `payloadName` | 可选的内层文件名，用于识别提示和独立压缩流的命名。Brotli 配置需要以 `.br` 结尾的内层文件名。 |
| `expectedFormat` | `zip`、`tar`、`7z`、`rar`、`rar5`、`gzip`、`lz4`、`zstd`、`xz`、`bzip2`、`cab`、`iso9660`、`lha`、`brotli` 或 `xp3`。 |

App 接受不超过 16 KiB 的 JSON 配置。Core 验证签名、偏移、长度和识别出的格式。包装头或尾部的字节不计入有效载荷的展开比预算。现有的条目数、解压量和路径限制继续生效。配置版本 1 支持固定签名和单段切片，适用范围取决于内层驱动。

Swift SDK 使用 `ArchiveService.loadFormatProfile` 读取配置，并用 `open(_:profile:limits:)` 打开包装文件。程序也可直接构造 `FormatProfile`。返回清单支持普通条目读取、提取、嵌套归档浏览及组合挂载。再次访问时 SDK 核对文件版本和包装签名。

C 调用方可直接填写 `au_format_profile`。`aether_unzip_profile_open` 返回已识别的归档句柄，并可返回供后续提取使用的切片。`aether_unzip_profile_slice` 可用于只检查包装签名和范围的场景。指针字段只在调用期间使用，切片句柄持有自己的底层源引用。底层检测的 I/O 及损坏错误会原样传递。[C ABI 文档](api.md)

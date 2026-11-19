# Format registry

当前注册 `xp3`、`libarchive` 和 `brotli` 驱动。驱动表保存 ID、版本、编译启用的格式和能力，还有 probe、next、read、skip、close 操作。一次成功打开会保留已验证的读取状态供枚举复用。

识别优先检查文件头签名、TAR 在 257 字节处的标识和 ISO 9660 第 16 扇区的卷描述符，再由驱动验证归档结构。扩展名作为独立提示保留，可能与实际格式不同。无明确签名时验证 TAR 结构和 ZIP 中央目录，由此也能识别带自解压前缀的 ZIP。前缀只作为输入字节处理。有已知偏移的其他包装格式可由调用方先创建切片。

| 格式 | 最小验证范围 |
| --- | --- |
| ZIP / ZIP64 | seekable ZIP reader，验证 Deflate、空归档、ZIP64、磁盘编号分卷、ZipCrypto 和 WinZip AES-256 |
| 7z | 固定版本 liblzma，样本采用 LZMA2 |
| RAR / RAR5 | 单卷、RAR 文件跨卷和固实 RAR5 跨卷样本 |
| TAR | USTAR，可由驱动结构识别 |
| CAB | 单卷 MSZIP、LZX |
| ISO 9660 | 标准卷描述符和 Rock Ridge 普通文件样本 |
| LHA / LZH | LH7 普通文件样本 |
| GZIP / LZ4 / Zstandard / XZ / BZIP2 | 一个压缩层。识别为 TAR 时枚举容器，否则用一个合成条目表示独立压缩流 |
| Brotli | 单个独立流。由于格式没有固定签名，以 `.br` 名称提示启用有界解码验证。解压 `.tar.br` 得到 TAR 文件。 |
| XP3 | 标准 KiriKiri 容器。支持原始和 zlib 索引、链式索引、UTF-16LE 文件名、原始与 zlib 混合分段、空文件和 Adler-32 校验。 |

每种格式的实际编解码方法取决于构建选项。流条目从提示名称推导输出名，优先移除对应扩展名，未知长度保留为未知。libarchive 驱动要求可随机访问的输入。资源条目按顺序读取。ZIP 会报告加密能力，实际解密仍由条目的加密方法决定。

XP3 驱动使用系统 zlib，流式读取文件分段。打开时检查索引块边界、段长度与偏移。索引块最多 256 个，压缩和展开后的索引各有 32 MiB 总预算。文件读取到结尾时核对 Adler-32。带 MZ 前缀的归档在前 16 MiB 内检查 16 字节对齐的 XP3 签名，通过切片解析。已知偏移的其他包装可使用切片源。App 对标记为受保护的条目显示为不可提取，游戏专用变换仍待扩展。[KiriKiri Z 归档工具](https://wamsoft.github.io/krkrz_dev/en/guide/Xp3Tool/) · [KiriKiri Z XP3 读取器](https://github.com/krkrz/krkrz/blob/master/base/XP3Archive.cpp)

分卷输入使用 `aether_unzip_source_concat` 构建。调用方传入所有分卷并按顺序排列。

- 字节分片在拼接视图中保持原归档的偏移量。
- 磁盘编号 ZIP 从 `.z01` 开始，最后传入 `.zip`。libarchive 通过 I/O 回调取得物理卷边界，再将目录和条目的卷内偏移映射到逻辑地址。ZIP64 支持扩展磁盘号和跨盘中央目录。
- RAR 与 RAR5 支持 `.partN.rar`。SDK 还识别从 `.rar`、`.r00` 开始的旧式命名。完整分卷由调用方授权并选择。

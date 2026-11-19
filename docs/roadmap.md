# 路线图

- 当前阶段交付 C ABI、CMake Core、C CLI、回调 I/O、流式归档读取、安全提取、带路径索引和预算的嵌套资源挂载、Swift SDK 和支持文件内容及嵌套归档浏览的原生 SwiftUI App。ZIP 支持 ZipCrypto 和 WinZip AES-256。7z 支持 AES-256 文件内容和文件名加密。分卷涵盖编号 ZIP/7z 字节分片、磁盘编号 ZIP/ZIP64 和 RAR/RAR5 独立卷。GZIP 对已读取的完整成员校验 CRC-32 和 ISIZE。
- 下一阶段扩展 RAR/RAR5 加密和 ZIP/7z/RAR 样本矩阵。新增格式以构建配置和测试样本确认。
- 标准 KiriKiri XP3 已有独立驱动，Core 与 Swift SDK 支持组合挂载。App 和 SDK 支持固定签名与偏移的声明式格式配置。ARC、PAK、DAT 将按引擎和变种建立驱动。
- ABI 稳定后提供 C++ 与 Rust 接入。Aether 模拟器将作为独立的未来 SDK 使用方。

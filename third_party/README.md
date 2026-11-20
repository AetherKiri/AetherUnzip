# Third-party dependencies

CMake uses SHA-256-checked source archives pinned in [source-archives.tsv](../cmake/source-archives.tsv). The Apple script packages the same static libraries per architecture. [Corresponding Source bundles](../docs/app-store.md) include those source archives for offline builds. Binary build products stay outside the tracked tree.

| Component | Pin | License | Enabled in the shipped build |
| --- | --- | --- | --- |
| [libarchive](https://github.com/libarchive/libarchive) | 3.8.11 | [BSD and bundled notices](libarchive.txt) | Static archive engine, ZIP/TAR/7z/RAR/RAR5/CAB/ISO9660/LHA readers, GZIP/LZ4/Zstandard/XZ/BZIP2 filters |
| [XZ Utils liblzma](https://github.com/tukaani-project/xz) | 5.8.2 | [0BSD](liblzma.txt) | Static liblzma for 7z and XZ; CLI and external SHA-256 disabled |
| [LZ4](https://github.com/lz4/lz4) | 1.10.0 | [BSD-2-Clause](lz4.txt) | Static LZ4 frame library; CLI disabled |
| [Zstandard](https://github.com/facebook/zstd) | 1.5.7 | [BSD](zstd.txt) | Static Zstandard; legacy, CLI and multithreading disabled |
| [Brotli](https://github.com/google/brotli) | 1.2.1 | [MIT](brotli.txt) | Static decoder and common library; CLI disabled |
| [zlib](https://zlib.net/) | Platform SDK/system package | zlib | Deflate and GZIP; >= 1.2.1 |
| [bzip2](https://sourceware.org/bzip2/) | Platform SDK/system package | bzip2 | BZIP2 streams and compressed archive entries |
| iconv / charset | Platform SDK/system package | Platform distribution | Filename encoding conversion |
| CommonCrypto / OpenSSL Crypto | Apple system library / Linux system package | Platform distribution | WinZip AES, 7z AES-256-CBC and SHA-256, RAR5 AES-256-CBC and HMAC-SHA-256 |

libarchive tools, tests, ACL, xattr and optional XML and regex dependencies are disabled. Apple uses CommonCrypto, while the Linux build links system OpenSSL Crypto. The driver registers only the readers and filters exercised by this project. When updating a library, update the source URL and hash together, check upstream release notes and notices, rebuild all Apple slices, and rerun format and security fixtures on Apple and Linux.

The fixed libarchive source receives local patches for ZIP disk-relative offsets, GZIP trailer CRC-32 and ISIZE, and AES-256 decryption in 7z and RAR5. The two added AES helper headers, `archive_7zip_aes_private.h` and `archive_rar5_aes_private.h`, retain their explicit [MIT notice](libarchive-aether-helpers.txt). RARLAB's command-line RAR 7.23 was used to generate the synthetic RAR5 test archives. [libarchive patches](../cmake/patches)

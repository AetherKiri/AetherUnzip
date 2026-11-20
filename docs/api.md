# C ABI

公共入口为 `#include <aetherunzip/api.h>`。可直接编译的完整 C 示例在 [examples/cli/main.c](../examples/cli/main.c)。调用方使用 CMake 的 `aetherunzip` 目标可获得头文件和静态依赖传递。Apple 用构建脚本生成的 XCFramework 和系统 zlib、bzip2、iconv、charset。

## 生命周期

1. `aether_unzip_context_create` 创建静态驱动注册上下文。
2. `aether_unzip_source_file`、`aether_unzip_source_memory` 或 `aether_unzip_source_slice` 创建输入。`aether_unzip_source_concat` 依调用方给出的顺序拼接多个源的字节视图，并保留子源引用。调用方可立即释放各子源。磁盘编号 ZIP 需要为每个物理卷传入一个子源，并把末卷 `.zip` 放在最后。
3. `aether_unzip_probe` 返回候选、扩展名提示、验证出的格式、外层滤镜和能力。可直接调用 `archive_open` 省去独立识别流程。
4. `aether_unzip_archive_next_entry` 返回当前条目。用 `archive_read` 分块读取，返回 0 字节表示当前条目结尾。推进游标会丢弃当前条目未读内容。
5. `aether_unzip_extract` 重新打开输入游标。传入 `NULL, 0` 提取全部，或传入严格递增的条目索引提取选定项。索引绑定于当前输入内容。
6. 关闭各自拥有的句柄。归档和切片保留底层源，可在打开后释放调用方的引用。资源文件可在卸载原挂载后继续读。

`aether_unzip_archive_open_catalog` 打开仅用于枚举的游标，允许驱动跳过文件数据。对目录游标调用 `aether_unzip_archive_read` 会返回 `AU_UNSUPPORTED`。读取或验证内容时用相同参数另开普通游标，条目编号保持一致。Swift 归档清单和 Core 资源索引使用目录游标。

`AU_OK` 表示成功，`AU_END` 表示枚举结束，负值为错误。使用 `aether_unzip_error_message` 获取静态消息。严重的条目读取错误会终止当前游标。文件和内存 sink 支持顺序、偏移写入与 flush。内存视图由 sink 所有，在下一次写入或关闭前有效。

## 格式配置

公共定义位于 `aetherunzip/profile.h`。配置验证包装文件的固定签名并提供有界切片。`aether_unzip_profile_open` 还会验证内层归档的实际格式。调用方可保留返回的切片用于归档枚举、资源挂载与安全提取。[格式配置](format-profiles.md)

## 回调 I/O

- `aether_unzip_source_callback` 接受顺序读取 `read`、偏移读取 `read_at` 或两者。通过 `length` 参数提供可选的固定长度。Core 复制回调表及长度。成功读到源尾时返回 `AU_OK` 和 0 字节。已知长度的源提前返回 0 会产生 `AU_IO`。偏移读取自动合并短读。Core 报告的能力以实际提供的回调和长度为准。
- 当前归档驱动、切片和拼接需要可随机访问且长度已知的源。缺少任一能力时，调用返回 `AU_UNSUPPORTED`，顺序游标保持原位置。回调的 `read_at` 不改变顺序位置。跨归档并发使用同一回调源时，由提供者保证该回调的并发安全。
- `aether_unzip_sink_callback` 接受 `write`、`write_at` 或两者。成功状态表示整个传入缓冲区已被接收。偏移写入不改变顺序位置。可选 `flush` 和 `close` 返回的错误会传回调用方。
- 调用方为回调表设置 `struct_size`，并管理 `user` 及其数据。成功创建源后，`close` 在最后一个引用释放时调用一次。成功创建 sink 后，`aether_unzip_sink_close` 调用可选的 `close` 并释放句柄。缓冲区仅在当次回调中有效。

## 资源挂载与路径索引

- `aether_unzip_resource_mount` 创建资源挂载，`resource_next` 按归档顺序枚举。`resource_build_index` 按需建立路径索引，使用独立的归档游标。调用方指定名称字节预算，预算包含每个 UTF-8 名称的终止符。扫描同时使用挂载的条目数、路径深度、解码和取消设置。失败后可重试，成功后重复调用返回 `AU_OK`。
- `resource_lookup` 返回正规化路径对应的文件或显式目录元数据。它按 UTF-8 字节精确匹配，去掉开头的 `./` 和目录末尾的 `/`。路径越界项、链接、特殊条目和根目录标记从索引中排除。正规化后有重名时返回 `AU_EXISTS`，没有匹配时返回 `AU_NOT_FOUND`。索引元数据由挂载持有，直到卸载时释放。
- `resource_open_path` 根据索引打开普通文件。`resource_open` 也可直接使用归档条目编号。两者均创建独立的顺序读取游标，访问固实归档中的条目可能需要从头解码。输入源内容必须在挂载和衍生读取期间保持稳定。
- `resource_directory_open` 打开显式目录或由子条目推导出的目录。空路径打开根目录。`resource_directory_next` 每次返回一个直接子条目。推导出的目录使用 `UINT64_MAX` 作为条目编号，调用方可按路径继续打开。重名或文件占用目录位置时返回 `AU_EXISTS`，随后可继续枚举其他子条目。目录游标保留挂载，关闭前可继续枚举。条目视图有效期到下一次枚举或关闭为止。
- 建立索引与卸载由调用方串行执行。成功建立索引后，可并发查找。每个目录游标由调用方串行推进。独立打开文件时，回调源及应用提供的取消回调须支持相应的并发访问。

### 组合挂载

- `aether_unzip_resource_compose` 将多个已索引的挂载合并到一个命名空间。调用方按顺序传入 `au_resource_layer`，为每层设置 `struct_size`，并可指定相对 UTF-8 前缀。空前缀挂到根目录。构建过程执行条目数、名称字节数和路径深度限制，名称和条目预算在合并同名项前计算。
- 各层目录可以合并。`AU_RESOURCE_STRICT` 报告同名文件冲突。`AU_RESOURCE_PREFER_LAST` 选择最后一层的同名文件，该层内部的重名仍报告冲突。文件与目录占用同一路径时，两种策略都返回 `AU_EXISTS`。路径冲突通过查找和目录枚举报告。可用组合挂载分配的条目编号明确打开某个文件。
- `resource_next` 按路径枚举组合索引中的条目。`resource_index_size` 返回索引的条目数和名称存储量。组合挂载汇集多个源，`resource_info` 返回 `NULL`，`resource_source` 返回 `AU_UNSUPPORTED`。组合挂载保留实际文件所需的底层挂载。组合挂载和原始挂载都关闭后，已打开的文件和目录仍可读。嵌套打开沿用提供目标文件的归档层所设置的限制与密码。
- Swift 通过 `ResourceLayer` 传入归档清单、前缀和可选密码。`ArchiveService.listResources` 返回直接子项，`streamResource` 以数据块交付指定路径。Swift 在后台协调所有输入，重新核对文件版本，并对初始索引应用累计预算。严格模式发现重名会抛出 `ArchiveError.ambiguousResource`。

### 嵌套归档

`aether_unzip_resource_mount_nested` 在已建立索引的父挂载中选择一个普通文件，完整读取并校验后按内容识别归档。调用方提供可信的可写暂存目录，并设置 `au_nested_limits.struct_size`、`max_depth` 和 `max_staged_bytes`。根挂载深度为 0。字节预算累计同一祖先链中各层暂存的归档大小，各层还执行父挂载的归档读取限制。子层可以收紧上限，兄弟挂载分别计费。

暂存使用独占创建的文件。Core 在写入归档字节前移除目录项，并通过文件描述符持有数据。子挂载可在父挂载卸载后独立使用。建立子索引后可继续按路径读取或再打开一层。`child_context` 可为内层提供不同的密码，传入 `NULL` 时复用父上下文。父选项的回调数据需一直有效，直至所有衍生挂载和资源关闭。

`aether_unzip_resource_source` 返回拥有独立引用的源，可将同一暂存数据交给常规归档 API。调用方用 `aether_unzip_source_close` 释放该引用。

## Swift 条目读取

`ArchiveService.supportedExtractionFormats()` 从已链接 Core 的驱动表读取注册了提取能力的格式，返回去重后的格式集合。具体文件的能力由打开归档时探测，压缩方法、分卷布局和加密方式仍需分别验证。

`ArchiveService.readEntry` 将单个普通文件读入 `Data`。`streamEntry` 在后台文件访问队列按顺序交付数据块，等待消费方返回后再继续读取。两者都检查清单的输入版本、所选条目、取消和调用方指定的字节上限，也接受当前读取所需的密码。消费方抛出的错误原样传播。流式消费方可先暂存数据，等待操作成功返回后再发布，以处理末尾校验失败的情况。

`ArchiveService.openNested` 根据父清单中的条目 ID 打开内层归档。`passphrase` 用于读取受保护的父条目，`childPassphrase` 用于打开内层归档。返回的清单持有 Core 暂存源，可继续读取、提取和打开下一层。默认 3 层和 256 MiB 上限可由调用方指定，子层继承祖先链的剩余预算。

## Swift 文件工作区

`WorkspaceAccess` 持有系统授予的文件或目录访问权。使用 `bookmark()` 保存位置，使用 `restore(_:)` 恢复访问。`FileWorkspace` 在后台协调目录枚举、新建文件夹、重命名、复制、移动和删除。批量传输会先检查目标重名，传输途中发生 I/O 错误时，已经完成的项目保留。从授权目录访问归档时，调用方应在 `ArchiveService` 操作期间保留对应的 `WorkspaceAccess`。

`ArchiveService.extractionLayout(for:selecting:limits:)` 使用 Core 的路径规则分析选定条目的实际顶层结构。`ExtractionLayout.placement(for:)` 返回建议创建的新文件夹及传给 `ExtractionOptions.stripRoot` 的共同前缀。调用者可用 `FileWorkspace.makeUniqueFolder` 独占创建新文件夹。`archiveGroups(in:)` 归并同目录、同名的已选归档分卷，打开每组时验证卷号与内容。

C 调用者可用 `aether_unzip_normalize_entry_path` 获取归档条目的安全路径字节范围。`aether_unzip_extract_stripping_root` 可在现有目标目录中移除一个匹配的共同顶层目录，先验证全部选定路径。传入 NULL 时与 `aether_unzip_extract` 行为一致。`AU_CONFLICT_KEEP_BOTH` 在现有文件同名时独占发布编号副本。直接替换时 Core 会保护当前文件、切片与拼接源的输入文件身份。

目标文件系统空间用尽或达到配额时，Core 返回 `AU_NO_SPACE`，Swift SDK 映射为 `ArchiveError.insufficientSpace`。正常返回此错误前会清理正在写入的暂存文件，已提交的文件保留。

`FileWorkspace.makeTextFile` 独占创建一个 UTF-8 文件。`readText` 返回文本和用于保存的 `WorkspaceTextFile` 快照，快照保留目录授权。`saveText` 在协调写入中核对文件版本和原始字节，匹配时原子替换，并返回可供下次编辑使用的新快照。读写上限为 1 MiB。编辑会保留已有的 UTF-8 BOM。二进制数据、符号链接和其他非普通文件无法作为文本打开。文件发生外部变更时，`WorkspaceTextError.changed` 保留磁盘上的内容。

`FileWorkspace.rename(_:to:access:)` 接受已打开的单文件 `ArchiveManifest` 时，会在协调写入中核对归档的文件版本。文件已被修改或替换时抛出 `ArchiveError.changed`。目标名称已存在时保留两个文件。调用方应提供归档所在目录的 `WorkspaceAccess`。

## 加密归档

用 `aether_unzip_context_create_with_passphrase` 创建带密码的上下文。密码为非空、NUL 结尾的 UTF-8 字符串，Core 复制输入。读取归档的驱动持有自己的密码副本。资源挂载保留上下文，以便为每个打开的条目创建独立读取游标。结束时关闭这些句柄并释放上下文。

密码保留全半角、Unicode 序列和首尾空格。ZIP 驱动可额外尝试能无损转换的 CP936、CP950 密码字节。Swift 候选密码返回的下标仍对应调用方传入的原始字符串。[格式兼容性](drivers.md)

ZIP 条目和文件名可见的 7z、RAR5 条目可以无密码枚举。7z 或 RAR5 文件名加密时，探测和打开归档也需要密码。`AU_ENCRYPTED` 表示需要密码，`AU_BAD_PASSPHRASE` 表示密码校验失败或加密数据损坏，`AU_UNSUPPORTED_ENCRYPTION` 表示加密布局或方法不支持。

Swift 通过 `ArchiveService.open(..., passphrase:)` 提供打开密码，生成的清单在内存中保留该密码供后续操作使用。也可以通过 `ExtractionOptions.passphrase` 或读取 API 为单次操作提供密码。

`ArchiveService.extract(..., passwordCandidates:)` 按调用方提供的顺序验证选中的加密文件。每条候选密码在写入输出前流式读取并校验所选加密条目。仅密码相关错误会继续尝试，取消、读取错误和超限会直接返回。任务成功后，`acceptedPasswordCandidateIndex()` 返回所用密码在候选数组中的零基下标，未使用候选时返回 `nil`。

`ArchiveService.archiveFingerprint(for:)` 流式计算单文件或按归档顺序排列的分卷的 SHA-256 指纹。显式传入的格式配置也计入指纹。通过清单计算时核对输入文件版本，适用于磁盘和文件提供器上的归档。

## ABI 与并发

- 当前版本为 0.1.0，仍可调整 ABI。检查 `aether_unzip_abi_version`，使用 `aether_unzip_options_default()` 并初始化探测结果的 `struct_size`。较小的输入结构会返回 `AU_INVALID`。
- 文件系统路径、提示和静态名称为 NUL 结尾的 UTF-8。条目名还有 `name_length` 字段，长度按字节计。视图属于归档，推进游标或关闭前复制需要保留的数据。驱动元数据和错误消息为静态存储。
- 输入源的随机读与长度查询可以跨独立归档并行使用，使用期间需要持有有效引用。文件源在使用期间应保持内容稳定。顺序源位置、sink、归档游标和资源挂载枚举均由调用方串行访问。
- Core 同步调用进度与取消回调。回调数据由调用方持有，覆盖同步操作或归档、挂载及衍生资源文件的完整寿命。回调应快速返回，且不能重入同一游标。
- 解压进度传递条目视图、累计写入字节、本条目暂存字节、已处理条目数。完成某条目时，本条目暂存字节归零。跳过的冲突计入已处理条目数。

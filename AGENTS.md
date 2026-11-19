# AetherUnzip 开发指南

项目范围、平台支持和验收标准见 [项目规格](docs/spec.md)。构建入口见 [README](README.md)。

## 提交规范

每项工作完成并通过对应验证后，在汇报结果或开始下一项工作前创建本地 Git 提交。一次任务包含多项可独立验证的改动时，按逻辑单元分别提交。提交只包含该项工作的相关改动，保留工作区中其他未提交的改动。最终汇报注明提交哈希。

提交标题使用 `type: English description`。类型小写，冒号后留一个空格，描述使用简短的英文动词短语。

| 类型 | 用途 |
| --- | --- |
| `feat` | 新功能、新格式或新增公开能力 |
| `fix` | 修复行为、兼容性或安全缺陷 |
| `docs` | 文档与说明 |
| `test` | 测试与测试样本 |
| `refactor` | 保持外部行为的重构 |
| `perf` | 性能改进 |
| `build` | 构建、打包或依赖 |
| `ci` | 持续集成 |
| `chore` | 其他仓库维护 |

```text
feat: add archive entry streaming
fix: reject symlink destinations during extraction
docs: document the Apple build workflow
```

## 实现约定

- 保持 App → AetherUnzipKit → Core C ABI 的依赖方向。第三方归档库经驱动调用，Apple 文件授权和协调由 Swift SDK 管理。
- 公共 C 接口使用 `aether_unzip_` 前缀、opaque handle 和明确的所有权、UTF-8、错误及线程约定。改动公共接口时同步更新头文件、Swift 包装和 [API 文档](docs/api.md) 中受影响的部分。
- 保持流式处理，按内容识别格式，并根据实际构建与样本声明能力。依赖变更同步更新固定版本、哈希和许可记录。
- 将归档数据和文件名视为不可信输入。所有提取入口共用 Core 的路径验证、输出预算、冲突处理和取消逻辑。
- 在后台执行阻塞文件访问与 Core 操作。SwiftUI 只接收值类型、任务句柄和进度。
- 将生成产物保留在忽略目录中。App 工程配置变更应同步更新 `apps/AetherUnzip/project.yml` 与 Xcode 工程。

## 按变更验证

- Core 或驱动变更运行 CMake 构建与 CTest。格式变更验证识别、枚举和提取内容，提取安全变更验证对应防护路径。
- Swift SDK 或 C ABI 变更先重新生成 Core XCFramework，再运行 `swift test --package-path bindings/swift`。
- App 或 Apple 构建变更验证受影响的平台目标。涉及导入或提取流程时，使用系统选择器走一遍实际流程。
- 仅文档变更核对本地链接、命令和实现描述即可。[Apple 集成文档](docs/apple-integration.md) 包含完整构建命令。

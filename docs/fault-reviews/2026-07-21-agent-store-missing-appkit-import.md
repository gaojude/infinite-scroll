# 故障复盘：Agent store 缺少 AppKit 导入导致无法编译

## 基本信息

| 字段 | 内容 |
|---|---|
| 日期 | 2026-07-21 |
| 发现人 | Codex |
| 严重程度 | P3-轻微 |
| 影响范围 | 新增 Agent 状态与待处理队列功能的 debug/release 构建 |
| 关联 Issue/PR | 无 |
| 关联提交 | 未提交 |

## 1. 问题描述

### 1.1 问题场景

新增 `AgentWorkspaceStore` 后首次执行 `swift build`。该 store 在用户提交空任务或无法启动任务时调用 `NSSound.beep()` 提供本地反馈。

### 1.2 具体表现

`InfiniteScroll` target 无法完成编译，Agent 队列功能不能链接进应用；既有工作区代码未受运行时影响。

### 1.3 错误信息

```text
Sources/InfiniteScroll/AgentWorkspaceStore.swift:54:13: error: cannot find 'NSSound' in scope
Sources/InfiniteScroll/AgentWorkspaceStore.swift:70:13: error: cannot find 'NSSound' in scope
```

## 2. 根本原因分析

### 2.1 问题分析过程

1. 新文件最初只导入了 `Combine` 和 `Foundation`，用于 `ObservableObject`、定时器和持久化。
2. 首次 debug 构建准确报出 `NSSound` 不在当前模块作用域。
3. 检查调用位置后确认 `NSSound` 属于 AppKit，而不是 Foundation 或 SwiftUI 自动可见的符号。
4. 在文件顶部加入 `import AppKit` 后，debug 与 release 构建均恢复通过。

### 2.2 直接原因

新增文件调用了 AppKit API，但遗漏对应模块导入。

**相关代码位置**：`Sources/InfiniteScroll/AgentWorkspaceStore.swift:1-3,53-58,65-73`

### 2.3 根本原因

- **开发层面**：新 store 的主体是 Foundation/Combine 逻辑，添加 macOS 提示音时没有重新核对 API 所属框架。
- **流程层面**：在首次实现完成前没有先做一次最小编译检查，错误直到完整 build 才暴露。

### 2.4 为什么没有提前发现

- 该文件此前没有被独立编译过。
- 工程没有可用的 XCTest 运行环境；`swift test` 无法加载 XCTest，因此不能把首次编译错误提前暴露在测试阶段。

## 3. 解决方案

### 3.1 根本解决方案

在 `AgentWorkspaceStore.swift` 顶部显式导入 AppKit：

```swift
import AppKit
import Combine
import Foundation
```

### 3.2 验证结果

- `swift build` 通过。
- `swift build -c release` 通过。
- 一次性 Swift 断言脚本验证了 Codex/Claude 包装进程识别与“进程结束不等于任务完成”的状态规则。

## 4. 预防措施

### 4.1 代码层面

- [x] 使用 AppKit 类型时，在定义文件显式导入 AppKit，不依赖其他文件的间接导入。
- [x] 新增 Swift 源文件后先执行一次 debug build，再继续扩展 UI。

### 4.2 测试层面

- [ ] 当环境提供 XCTest 时，为 `AgentProvider.detect` 和任务状态机加入正式单元测试。

## 5. 经验总结（一句话）

> macOS Swift 文件应显式导入所使用 API 的所属框架，并在新文件落地后立即进行最小编译验证。

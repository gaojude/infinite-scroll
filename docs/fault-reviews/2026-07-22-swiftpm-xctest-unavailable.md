# 故障复盘：SwiftPM 状态解析测试无法导入 XCTest

## 基本信息

| 字段 | 内容 |
|---|---|
| 日期 | 2026-07-22 |
| 发现人 | Codex |
| 严重程度 | P3-轻微 |
| 影响范围 | Agent 状态解析的新增回归测试；未影响应用运行代码 |
| 关联 Issue/PR | 无 |
| 关联提交 | 未提交 |

## 1. 问题描述

### 1.1 问题场景

为 `AgentProcessInspector.inferredState(from:)` 新增 SwiftPM 单元测试时，按常规方式添加了 `testTarget` 和 `XCTest` 测试文件。

### 1.2 具体表现

`swift test` 在编译测试模块时失败，应用主目标仍可编译。

### 1.3 错误信息

```text
error: no such module 'XCTest'
```

同时验证 `import Testing`，该工具链也没有该模块。

## 2. 根本原因分析

### 2.1 问题分析过程

1. 新增测试目标后运行 `swift test`。
2. 构建日志定位到测试文件的 `import XCTest`。
3. 用独立 Swift 命令验证，当前本地 Swift 工具链不能提供 `XCTest` 或 `Testing` 模块。
4. 确认这是测试运行时/SDK 可用性限制，而非 Agent 状态解析实现的编译错误。

### 2.2 直接原因

在未确认本地 SwiftPM 测试框架可用性的情况下，向 `Package.swift` 添加了依赖 `XCTest` 的测试目标。

**相关代码位置**：`Package.swift`（临时测试目标，已移除）

### 2.3 根本原因

开发环境提供 Swift 编译器，但不包含可被 SwiftPM 解析的 `XCTest` 或 `Testing` 模块；项目此前也没有可复用的测试目标配置。

### 2.4 为什么没有提前发现

新增测试前没有先运行最小模块导入检查，默认假设 macOS Swift 工具链一定提供 XCTest。

## 3. 解决方案

### 3.1 根本解决方案

移除无法运行的测试目标和测试文件，保留 `AgentProcessInspector.inferredState(from:)` 为内部纯函数，使用临时 `swiftc` 编译同一份源文件进行无框架回归校验，并继续执行 `swift build`、release 打包和实机状态验证。

**修改文件**：

- `Sources/InfiniteScroll/AgentProcessInspector.swift`
- `Package.swift`（恢复为无测试目标）

### 3.2 影响范围评估

未引入运行时依赖，也未改变应用发布包。状态解析仍会通过主目标编译和实机 tmux 会话验证。

## 4. 预防措施

### 4.1 代码层面

- [x] 将状态判定抽成可独立调用的纯函数，避免测试依赖真实 tmux 会话。
- [ ] 后续增加正式测试目标前，先确认项目选定的测试框架与工具链兼容。

### 4.2 测试层面

- [x] 在测试框架不可用时，使用同源 `swiftc` 编译探针覆盖关键状态样例。
- [ ] CI 环境恢复 XCTest/Testing 后，将探针迁回正式 SwiftPM 测试。

## 5. 经验总结（一句话）

> 为 SwiftPM 新增测试目标前，先验证测试框架模块可导入；编译器可用不代表 XCTest 或 Testing 运行时已安装。

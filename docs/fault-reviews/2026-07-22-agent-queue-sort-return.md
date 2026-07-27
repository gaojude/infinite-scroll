# 故障复盘：Agent 状态列表排序遗漏返回值导致构建失败

## 基本信息

| 字段 | 内容 |
|------|------|
| 日期 | 2026-07-22 |
| 发现人 | Codex 构建校验 |
| 严重程度 | P3-轻微 |
| 影响范围 | `AgentQueueView` 的 Agent 状态列表；未进入安装包 |
| 关联 Issue/PR | 无 |
| 关联提交 | 未提交 |

## 1. 问题描述

### 1.1 问题场景

将 Agent 面板从手动任务编排改为按状态排序的活动列表时，`visibleRuns` 计算属性新增了 `recentCutoff` 局部变量。

### 1.2 具体表现

调试构建失败，无法生成应用二进制；运行中的已安装应用未受影响。

### 1.3 错误信息

```text
error: missing return in getter expected to return '[AgentRun]'
warning: result of call to 'sorted(by:)' is unused
```

## 2. 根本原因分析

### 2.1 问题分析过程

1. 运行 `swift build` 后，编译器将错误定位到 `visibleRuns`。
2. 检查发现计算属性先声明了 `recentCutoff`，因此 getter 已不是单表达式形式。
3. 随后的过滤和排序链没有显式 `return`，Swift 将排序结果视为未使用值。
4. 在链式表达式前加上 `return` 后，调试构建和差异检查均通过。

### 2.2 直接原因

`Sources/InfiniteScroll/AgentQueueView.swift:10-25` 的计算属性遗漏了 `return`。

```swift
let recentCutoff = Date().addingTimeInterval(-Self.recentStoppedRunInterval)
return agentStore.runs.values
    .filter { $0.state != .stopped || $0.lastActivityAt >= recentCutoff }
    .sorted { /* status priority */ }
```

### 2.3 根本原因

重构时将原本可省略返回值的单表达式 getter 改为带局部变量的多语句 getter，却没有同步调整 Swift 的返回语义。

### 2.4 为什么没有提前发现

该变更后首次执行的构建就是发现点；没有单独的编译前静态检查来发现这类语法遗漏。

## 3. 解决方案

在 `visibleRuns` 的排序链前显式添加 `return`，保持状态优先级排序和最近停止项的过滤逻辑不变。

## 4. 预防措施

- [x] 每次修改 Swift 计算属性后立即运行 `swift build`。
- [x] 在安装包生成前继续执行 `git diff --check` 和 Release 构建。
- [ ] 代码审查时检查“新增局部变量的计算属性”是否仍有正确返回值。

## 5. 经验总结（一句话）

Swift 计算属性一旦从单表达式改为多语句实现，必须显式返回最终值，并用构建校验立即拦截遗漏。

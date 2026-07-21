# Infinite Scroll

A terminal workspace manager for macOS. Organize multiple terminals in an infinitely scrollable canvas instead of switching between tabs.

## Features

- Grid layout with rows and cells of terminal panels
- Infinite vertical scrolling (`Cmd+Scroll`)
- Keyboard-driven navigation (`Cmd+Arrows`)
- Tmux-backed session persistence
- Inline markdown notes per row
- Auto-saved workspace state
- Agent task queue with process-tree provider detection

## Requirements

- macOS 13+
- tmux

## Install

Download the latest DMG from [infinite-scroll.dev](https://infinite-scroll.dev).

Or build from source:

```
swift build
```

## Agent Queue

Use the right sidebar to queue a task, choose a provider, and start it in a
dedicated worker terminal. Codex, Claude, Gemini, and Aider are recognized from
the tmux process tree; the app does not capture terminal output or prompts to
derive a status.

Process presence means an agent is active. When a process exits, its task is
blocked for your review rather than being marked complete automatically. Queue
state is saved separately from the workspace layout in `~/.infinite-scroll/`.

## Shortcuts

| Key               | Action             |
| ----------------- | ------------------ |
| `Cmd+Shift+Down`  | New row            |
| `Cmd+D`           | Duplicate cell     |
| `Cmd+W`           | Close cell         |
| `Cmd+Arrows`      | Navigate panels    |
| `Cmd+Scroll`      | Scroll rows        |
| `Cmd+=` / `Cmd+-` | Zoom in/out        |
| `Cmd+,`           | Settings           |
| `Cmd+/`           | Show help          |

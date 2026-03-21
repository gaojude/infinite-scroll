# Infinite Scroll

A terminal workspace manager for macOS. Organize multiple terminals in an infinitely scrollable canvas instead of switching between tabs.

## Features

- Grid layout with rows and cells of terminal panels
- Infinite vertical scrolling (`Cmd+Scroll`)
- Keyboard-driven navigation (`Cmd+Arrows`)
- Tmux-backed session persistence
- Inline markdown notes per row
- Auto-saved workspace state

## Requirements

- macOS 13+
- tmux

## Install

Download the latest DMG from [infinite-scroll.dev](https://infinite-scroll.dev).

Or build from source:

```
swift build
```

## Shortcuts

| Key               | Action             |
| ----------------- | ------------------ |
| `Cmd+Shift+Down`  | New row            |
| `Cmd+D`           | Duplicate cell     |
| `Cmd+W`           | Close cell         |
| `Cmd+Arrows`      | Navigate panels    |
| `Cmd+Scroll`      | Scroll rows        |
| `Cmd+=` / `Cmd+-` | Zoom in/out        |
| `Cmd+/`           | Show help          |

# Lite-XL — Everforest Light (Mossy Green)

A pixel-faithful replica of the VS Code **Everforest Light** layout for **Lite-XL**.

## Panel Layout

```
┌────────────────────────────────────────────────────────────────────────────┐
│  [AI PANEL ~255px]  │  [EDITOR + GUTTER + MINIMAP]   │  [EXPLORER ~240px]  │
│  bg: #E4EAD0        │  editor: #F0F4DF               │  bg: #E4EAD0        │
│  Ctrl+Shift+A       │  gutter: #E4EBD2               │  Ctrl+B             │
├────────────────────────────────────────────────────────────────────────────┤
│  [TERMINAL — Ctrl+` — hidden by default — bg: #2D3B28]                     │
├────────────────────────────────────────────────────────────────────────────┤
│  [STATUS BAR — bg: #597450]                                                │
└────────────────────────────────────────────────────────────────────────────┘
```

## Keybindings

| Key            | Action                          |
|----------------|---------------------------------|
| `Ctrl+B`       | Toggle Explorer sidebar         |
| `Ctrl+Shift+A` | Toggle Antigravity AI panel     |
| Ctrl+\`        | Toggle terminal panel           |
| `Ctrl+P`       | Quick-open file                 |
| `Ctrl+Shift+P` | Command palette                 |
| `Ctrl+/`       | Toggle line comment             |
| `Ctrl+D`       | Select next occurrence          |
| `Ctrl+Z / Y`   | Undo / Redo                     |
| `Ctrl+S`       | Save                            |
| `Ctrl+W`       | Close tab                       |
| `Ctrl+Shift+K` | Delete line                     |
| `Alt+↑ / ↓`   | Move line up / down             |

## Font Setup (Manual)

1. **Fira Code iScript** — code font with cursive italics  
   Download: <https://github.com/kencrocken/FiraCodeiScript>  
   Place `FiraCode-iScript.ttf` at `~/.config/lite-xl/fonts/`

2. **Fira Code Nerd Font** — required for file-type icons  
   Download: <https://github.com/ryanoasis/nerd-fonts>  
   Place `FiraCodeNerdFont-Regular.ttf` at `~/.config/lite-xl/fonts/`

> Without the Nerd Font, icons will appear as empty squares. Everything else works fine.

## Files

| Path | Purpose |
|------|---------|
| `colors/everforest-lite-xl.lua` | Color scheme (all hex values pixel-sampled) |
| `plugins/mossy_icons.lua` | Nerd Font icon registry |
| `plugins/mossy_treeview.lua` | Styled Explorer with indent guides |
| `plugins/toggle_terminal.lua` | Bottom terminal sheet |
| `plugins/antigravity_sidebar.lua` | Left AI panel (streams from `agy` CLI) |
| `init.lua` | Master entry point |

## Antigravity CLI

The AI sidebar calls `agy ask --stdin --stream` and streams the response.  
The context block written to stdin looks like:

```
FILE: main.go

CODE:
```go
package main
...
```

INSTRUCTION: Explain what this code does.
```

Make sure `agy` (or `antigravity`) is on your `PATH`, or update  
`config.antigravity.cli` in `plugins/antigravity_sidebar.lua`.

## Color Quick Reference

| Name | Hex | |
|---|---|---|
| Editor canvas | `#F0F4DF` | ![#F0F4DF](https://via.placeholder.com/12/F0F4DF/F0F4DF.png) |
| Sidebar / panels | `#E4EAD0` | |
| Gutter | `#E4EBD2` | |
| Active file row | `#BFD3A7` | |
| Active tab | `#CCD0BC` | |
| Activity bar | `#4F6A47` | |
| Status bar | `#597450` | |
| Terminal | `#2D3B28` | |
| Selection | `#C5D9A8` | |
| Current line | `#E8EDCF` | |

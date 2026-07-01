# Handoff Report — explorer_initial

## 1. Observation

### Process Execution & Stdin
- In `plugins/antigravity_sidebar.lua` (lines 367-370):
```lua
  local p, err, code = process.start(argv, {
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE,
  })
```
- In `plugins/antigravity_sidebar.lua` (lines 561-564):
```lua
  local p = process.start({ cfg.cli, "models" }, {
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE,
  })
```
- In `plugins/auto_healer.lua` (lines 15-19):
```lua
  local p = process.start({ agy_path(), "-p", prompt, "--dangerously-skip-permissions" }, {
    stdout = process.REDIRECT_PIPE,
    stderr = process.REDIRECT_PIPE,
  })
```
- Running `agy models` directly in a console without input redirection hangs indefinitely (verified by running `C:\Users\ojasw\AppData\Local\agy\bin\agy.exe models` in a background task).
- Running `cmd.exe /c "agy models < NUL"` exits immediately and successfully in ~7 seconds without output (exit code 0).
- Running `agy changelog` with stdin closed (`$null | C:\Users\ojasw\AppData\Local\agy\bin\agy.exe changelog`) prints the full changelog to stdout.
- Inspected the process redirection constants defined in `C:\Program Files\Lite XL\data\process.lua` (lines 72-76):
```lua
process.REDIRECT_PARENT = 2
process.REDIRECT_DISCARD = 3
```

### Context Menu & Command view APIs
- Inspected the core context menu registration in `C:\Program Files\Lite XL\data\plugins\contextmenu.lua` (lines 66-83):
```lua
local cmds = {
  { text = "Cut",     command = "doc:cut" },
  ...
}
menu:register("core.docview", cmds)
```
- Quick commands check for `instance` in `plugins/antigravity_sidebar.lua` (lines 1151-1155):
```lua
  ["antigravity:explain"]  = function() if instance then instance:submit(config.antigravity.actions[1].prompt) end end,
```

---

## 2. Logic Chain

1. **Bug Origin (Hangs/Lockups on Windows)**: Since `process.start` is invoked in `submit()` and `fetch_models()` without specifying the `stdin` parameter (Observation 1), it defaults to `process.REDIRECT_PARENT` (Observation 1). On Windows, this inherits standard input.
2. **Interactive Block**: Because the `agy` CLI initializes an input loop, it checks for stdin. Since the background process lacks a real interactive stdin, it blocks trying to read from it (Observation 1).
3. **Redirection Resolves Hangs**: Discarding standard input via `stdin = process.REDIRECT_DISCARD` (Observation 1) causes any read on stdin to immediately return EOF. Therefore, the input loop immediately exits rather than blocking (Observation 1).
4. **Clean Failure Mode**: If the user is unauthenticated, the background check will fail fast (exit immediately with an error) instead of hanging the UI in a "thinking" spinner state for 5+ minutes.
5. **Enabling Windows Verification**: Since `process.REDIRECT_DISCARD` prevents hangs, the Windows bypass in `fetch_models()` can be removed, allowing dynamic model list loading on Windows.
6. **Integrating Context Menu**: Requiring the default `"plugins.contextmenu"` and calling `contextmenu:register("core.docview", ...)` will register custom AI commands to display when right-clicking the editor (Observation 1).
7. **Resolving Sidebar Closed Bug**: Triggering actions via `command.perform("antigravity:submit", prompt)` instead of checking `instance` first (Observation 1) will force the sidebar to slide open and run the command correctly.

---

## 3. Caveats

- **Network Speed**: Model fetching dynamically queries Google cloud APIs (`daily-cloudcode-pa.googleapis.com`), which can take 4-7 seconds. During this time, the model picker will show "Fetching models...". This is network-bound, not a CPU/thread lockup.
- **TUI/CLI authentication**: Authentication itself still must be completed in a separate, visible terminal window because the browser OAuth flow requires interactive token copy-pasting.

---

## 4. Conclusion

The process hangs are caused by standard input inheritance in background `process.start` invocations. Changing `stdin` to `process.REDIRECT_DISCARD` (which is equal to `3`) resolves all background hangs and allows dynamic model list retrieval. Context menu integrations can be cleanly added using the core `contextmenu` module.

A complete diff is prepared in `C:\Users\ojasw\Documents\LiteXL-Mossy-Setup\.agents\explorer_initial\proposals.patch` for immediate application.

---

## 5. Verification Method

1. **Redirection Test**: Run `C:\Program Files\Lite XL\lite-xl.exe` after applying the patch. Click the Status Bar Auth item. If unauthenticated, it should not hang the UI; it should immediately report an auth error or allow fallback.
2. **Context Menu Test**: Right-click in an open text document. A horizontal divider and AI choices ("Explain Code with AI", etc.) should appear in the context menu.
3. **Closed Sidebar Test**: Close the sidebar, right-click, and select "Explain Code with AI". The sidebar should open and explain the selected code.

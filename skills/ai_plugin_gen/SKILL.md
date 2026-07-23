---
name: ai_plugin_gen
description: |
  Skill for understanding, operating, and debugging the AI Plugin Generator — 
  a settings-tab feature in the Lite XL editor that lets users create custom 
  plugins from natural language descriptions using the AGY CLI.
  Activate this skill when:
  - The user asks about the AI Plugin Gen tab in Settings
  - There's an error in the plugin generation pipeline
  - The user wants to modify or extend the generator
  - Auto-healer needs to fix a generated plugin
---

# AI Plugin Generator — Skill Guide

## Overview

The AI Plugin Generator is a custom Lite XL plugin (`ai_plugin_gen.lua`) that 
integrates into the **Activity Bar** as a dedicated sidebar panel. It allows 
users to describe a plugin idea in plain English, get a detailed AI-generated 
plan, and then auto-generate, install, and hot-reload the Lua plugin — all 
from inside the editor.

---

## File Locations

| File | Purpose |
|---|---|
| `~/.config/lite-xl/plugins/ai_plugin_gen.lua` | Core plugin — state machine, UI, AGY calls |
| `~/.config/lite-xl/plugins/auto_healer.lua` | Extended with AI Plugin Gen resume support |
| `~/.config/lite-xl/ai_plugin_gen_store.lua` | Persistent store (installed plugins + rejected plan hashes) |
| `~/.config/lite-xl/tempfiles/ai_plugin_gen_prompt.txt` | Temporary prompt file used for AGY calls |

---

## Architecture: State Machine

The plugin uses 5 distinct screen states. Transitions are driven by user actions and AGY process completion:

```
[DESCRIBE] ──(Generate)──► [LOADING/thinking] ──► [PLAN]
                                                      │
                                          ┌───────────┼──────────────┐
                                       (Approve)   (Decline)      (Trash)
                                          │            │              │
                                     [BUILDING]   [LOADING/thinking] [DESCRIBE]
                                          │        (regenerates plan)
                                    ┌─────┴──────┐
                                 (success)     (error)
                                    │              │
                                [SUCCESS]      [ERROR] ──► auto-healer ──► resume
```

**State constants** (defined in `ai_plugin_gen.lua`):
```lua
STATE = { DESCRIBE="describe", LOADING="loading", PLAN="plan",
          BUILDING="building", SUCCESS="success", ERROR="error" }
```

---

## Activity Bar Integration

The plugin defines a `View` (rather than a `Widget`) and provides a global command:

```lua
command.add(nil, {
  ["ai-plugin-gen:toggle"] = function()
    -- Toggles the view in the active sidebar pane (managed by activity_bar)
  end
})
```

The `activity_bar.lua` plugin has been modified to include the AI Plugin Gen in its item list:
```lua
self.items = {
  { id = "ai_plugin",icon = "\u{f0e7}", command = "ai-plugin-gen:toggle", tooltip = "AI Plugins" },
  -- ...
}
```

The `AIPluginGen` view overrides `draw()`, `on_mouse_pressed()`, `on_mouse_moved()`, 
and `on_mouse_wheel()` to do all custom rendering via raw `renderer.*` calls.

---

## AGY Integration

All AI calls go through the `run_agy(prompt, on_done)` function:

```lua
local function run_agy(prompt, on_done)
  -- Starts: agy -p <prompt> --dangerously-skip-permissions
  -- Runs in background via core.add_thread
  -- Calls on_done(output, err) when complete
  -- 4-minute timeout
end
```

**Plan generation prompt** asks AGY to return structured output with tags:
`[NAME]`, `[OVERVIEW]`, `[COMPLEXITY]`, `[TIME]`, `[WORTH]`, `[DEPENDENCIES]`,
`[RESEARCH]...[/RESEARCH]`, `[CHALLENGES_FATAL]...[/CHALLENGES_FATAL]`,
`[CHALLENGES_CONQUER]...[/CHALLENGES_CONQUER]`, `[CHALLENGES_EASY]...[/CHALLENGES_EASY]`,
`[DESIGN]...[/DESIGN]`, `[SHORTCUTS]...[/SHORTCUTS]`, `[HOOKS]...[/HOOKS]`,
`[TESTING]...[/TESTING]`, `[OUTPUT_FILES]...[/OUTPUT_FILES]`,
`[GITHUB_REPOS]...[/GITHUB_REPOS]`, `[INTEGRATION]...[/INTEGRATION]`

**Build generation prompt** asks AGY to write complete Lua code between:
`[PLUGIN_CODE]...[/PLUGIN_CODE]`

**CRITICAL: Lite XL API Cheat Sheet for Generation Prompt**
Ensure the generation prompt heavily emphasizes these Lite XL API rules to avoid LLM hallucinations:
- `renderer` and `system` are C-injected globals. Do **not** require them (e.g., no `require "core.renderer"`).
- `keymap` is required as `require "core.keymap"`.
- `style.font:get_height()` must be used for line heights in base `View`s; do not call `self:get_line_height()` unless extending `DocView`.

**Validation Check**
Before completing generation, perform a static analysis checking for the above common hallucinations to prevent runtime crashes.

---

## Plan Page Sections

The scrollable Plan Page renders these sections (in order):

1. **Plugin name + overview** — large header with description
2. **Complexity bar** — color-coded `▓▓▓▓▒░░ 7/10` + time estimate + worth verdict
3. **Dependencies** — external tools required
4. **Research findings** — bullet points from AGY web research
5. **Challenges** — 3 categories: 🔴 Fatal / 🟡 Conquerable / 🟢 Easy
6. **Sample Design** — ASCII art preview using rich characters + [Redesign] button
7. **Suggested Shortcuts** — with live keymap conflict detection (green=free, red=clash)
8. **API Hooks** — Lite XL APIs the plugin will use, shown as tags
9. **Testing strategy** — bullet points on how to verify the plugin works
10. **Output files** — files that will be created

---

## Decline Deduplication

When a user clicks "Decline & Redo", the plan's hash is stored:
```lua
store.rejected_hashes[simple_hash(plan.name .. tostring(plan.complexity))] = true
save_store()
```
The next plan generation prompt includes: `"Do NOT regenerate plans similar to these rejected approach hashes: ..."`

---

## Auto-Healer Integration

Two integration points in `auto_healer.lua`:

### 1. Known Pattern
```lua
{
  match   = "%[AI Plugin Gen%]",
  title   = "AI Plugin Generator Error",
  command = "auto-healer:resume-plugin-gen",
  on_healed = function()
    if type(_G.ai_plugin_gen_resume_fn) == "function" then
      _G.ai_plugin_gen_resume_fn()  -- resumes the pipeline
      _G.ai_plugin_gen_resume_fn = nil
    end
  end,
}
```

### 2. Resume Command
`auto-healer:resume-plugin-gen` — available in Command Palette. Calls `_G.ai_plugin_gen_resume_fn()` to resume generation after a fix.

### 3. Global Signals
```lua
_G.ai_plugin_gen_resume_fn   -- set by ai_plugin_gen.lua when a build fails; callable by healer
_G.auto_healer_new_plugins   -- list of {name, file} newly generated — healer is aware of these
```

---

## Persistent Store Format

`ai_plugin_gen_store.lua` is a Lua return file:
```lua
return {
  installed = {
    { name="word_counter", file="/path/to/plugins/word_counter.lua", desc="...", ts=1234567890 },
  },
  rejected_hashes = {
    ["1234567"] = true,
  }
}
```

---

## Hot-Reload on Success

After writing the plugin file, the generator attempts to hot-load it:
```lua
local ok, load_err = pcall(dofile, filepath)
if not ok then
  -- Sends error to antigravity:submit for auto-healing
end
```

---

## Debugging Common Issues

| Symptom | Likely Cause | Fix |
|---|---|---|
| Tab doesn't appear in Activity Bar | `activity_bar.lua` missing item | Add `ai_plugin` item to `self.items` in ActivityBar:new() |
| Plan shows blank/garbled | AGY output not matching expected tags | Check prompt format; re-run generate |
| Build writes empty file | `[PLUGIN_CODE]` tags missing from AGY output | Prompt asks for tags explicitly; retry |
| Store not saving | `USERDIR` path wrong or no write permission | Check `io.open(STORE_FILE, "w")` return |

---

## Extending the Plugin

To add a new Plan Page section:

1. Add parsing in `parse_plan()` using `etag(text, "YOUR_TAG")`
2. Add a `section(draw_fn, est_h)` call inside `draw_plan()` 
3. Update the AGY plan generation prompt to ask for the new tag

To add a new state:

1. Add to `STATE` table
2. Add `draw_*` function
3. Add branch in `AIPluginGen:draw()`
4. Wire up transitions in `handle_click()`

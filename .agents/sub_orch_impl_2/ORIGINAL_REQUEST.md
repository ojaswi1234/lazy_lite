## 2026-06-30T14:50:17Z
You are a worker agent for the Antigravity AI Lite-XL Sidebar project.
Your task is to implement Milestones 4, 5, and 6 in C:\Users\ojasw\Documents\LiteXL-Mossy-Setup\.

MANDATORY INTEGRITY WARNING:
> DO NOT CHEAT. All implementations must be genuine. DO NOT hardcode test results, create dummy/facade implementations, or circumvent the intended task. A Forensic Auditor will independently verify your work. Integrity violations WILL be detected and your work WILL be rejected.

Please read:
1. The initial explorer's proposals at C:\Users\ojasw\Documents\LiteXL-Mossy-Setup\.agents\explorer_initial\analysis.md and proposals.patch.
2. The current codebase, specifically:
   - C:\Users\ojasw\Documents\LiteXL-Mossy-Setup\plugins\antigravity_sidebar.lua
   - C:\Users\ojasw\Documents\LiteXL-Mossy-Setup\plugins\auto_healer.lua

Your implementation steps:
- **Milestone 4 (Stdin Redirect & Hang Fix)**:
  In `plugins/antigravity_sidebar.lua` and `plugins/auto_healer.lua`, locate where `process.start` is called for background `agy` CLI processes. Add `stdin = process.REDIRECT_DISCARD` to the option tables passed to `process.start`.
- **Milestone 5 (Dynamic Models & Auth)**:
  In `plugins/antigravity_sidebar.lua`, in `AGView:fetch_models()`, remove the platform check (`if PLATFORM == "Windows"`) that hardcodes the models list on Windows. Enable the background model list fetching to run on all platforms, including Windows, using the `stdin = process.REDIRECT_DISCARD` option.
  In `antigravity:auth`'s submit function, instead of blindly setting `instance.auth_status = "logged_in"` after 15 seconds, call `instance:fetch_models()` (which will trigger a real background check and update the auth status accordingly).
- **Milestone 6 (UX Extensions)**:
  In `plugins/antigravity_sidebar.lua`:
  1. Route all quick AI actions (`explain`, `refactor`, `fix`, `tests`, `docs`) through `command.perform("antigravity:submit", prompt_text)` so they work properly even if the sidebar is not yet visible or initialized.
  2. Implement the `"antigravity:ask"` command which opens the Command View, prompts the user with "Ask Antigravity", and submits their text to Antigravity.
  3. Register context menu items dynamically if `"plugins.contextmenu"` is available, under the `"core.docview"` predicate. The options should include a divider followed by:
     - "Explain Code with AI" -> "antigravity:explain"
     - "Refactor Code with AI" -> "antigravity:refactor"
     - "Fix Code with AI" -> "antigravity:fix"
     - "Generate Unit Tests" -> "antigravity:tests"
     - "Generate Documentation" -> "antigravity:docs"

Ensure all edits compile and follow Lua syntax. Write a file `C:\Users\ojasw\Documents\LiteXL-Mossy-Setup\.agents\sub_orch_impl_2\worker_changes.md` summarizing the changes you made, and send a message back when complete.

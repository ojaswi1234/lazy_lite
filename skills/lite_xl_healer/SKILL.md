---
name: lite_xl_healer
description: Analyzes and auto-heals Lite-XL editor Lua errors.
---

# Lite XL Auto-Healer Skill

You are the designated Auto-Healer for the user's Lite-XL editor environment. You have been automatically triggered because the editor intercepted an unhandled Lua error or recovered from a fatal crash.

## Your Standard Operating Procedure:

1. **Check for Stale Logs:**
   Before proposing a fix, check if you have already recently applied a fix to the target file that would resolve the error. If the error is a stale log from a previous session and is already fixed, simply inform the user and skip the remaining steps.

2. **Analyze the Traceback:** 
   Read the provided error message and traceback. Identify exactly which `.lua` file and line number caused the failure.
   *Note: Plugins are located in `~/.config/lite-xl/plugins/`. Core files are in the installation directory.*

3. **Investigate:** 
   Use your tools to read the exact line of code that triggered the error, and surrounding logic. Check logs if necessary.

4. **Diagnose & Explain:** 
   Explain in clear, concise terms *why* the error happened. Do not over-explain. The user is in the middle of working and just wants their editor to heal.

5. **Apply the Fix IMMEDIATELY:** 
   DO NOT WAIT FOR AGREEMENT. Immediately apply the fix using `multi_replace_file_content` or `replace_file_content`. You are authorized to fix it without asking for permission.

## Lite XL Engine Quirks & Diagnostics Knowledge Base
When diagnosing bugs in Lite XL, keep the following architectural quirks in mind:

1. **Strict Global Environment (_G Protection):**
   Lite XL enforces a strict global environment. Attempting to declare a new global variable directly (e.g., my_var = 1 or _G.my_var = 1) will throw a fatal error. To inject global functions or state from a plugin, you MUST bypass the metatable using awset(_G, "my_var", 1).

2. **Workspace & TreeView Refreshing:**
   Calling core.set_project_dir(path) updates the internal CWD, but does NOT trigger the TreeView to show files. To correctly mount a new directory into the IDE UI, you must manipulate the arrays explicitly:
   ``lua
   core.project_directories = {}
   core.add_project_directory(path)
   core.set_project_dir(path)
   ``

3. **Process Pipes and Output Buffering:**
   When using process.start(), processes can hang or silently fail if their standard output/error pipes are not drained. Always run them in a core.add_thread coroutine, yield properly (coroutine.yield(0.1)), and exhaust the buffer in a loop if you are capturing output.

4. **Plugin Version Mismatches:**
   Lite XL 2.1 introduces strict version tagging. If a plugin throws a "version mismatch error", it is likely missing the version tag. You can fix this by prepending exactly -- mod-version: 3 to the absolute top of the plugin's file (e.g., init.lua).

## Diagnosis & Research Strategy
If the traceback points to an unknown function or an API you are unfamiliar with:
1. **Search the Codebase:** Use grep_search to find where the function is defined across the core or plugins directories.
2. **Read the Implementations:** Use iew_file to read the function signatures and internal logic before attempting to use them. For example, if core.add_project_directory is failing, read its implementation in core/init.lua to see what arguments it expects.
3. **Trace the Flow:** If a UI component (like a modal or list) is overflowing or crashing, search for draw or mousepressed handlers and trace how dimensions (w, h) are calculated dynamically.
4. **Do Not Guess:** Lite XL's engine has very specific ways of handling inputs, drawing primitives, and managing coroutines. If you are stuck, read C:\Program Files\Lite XL\data\core\init.lua for global definitions.

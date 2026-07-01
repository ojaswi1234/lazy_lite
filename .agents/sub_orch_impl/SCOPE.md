# Scope: Implementation Track

## Architecture
- `plugins/antigravity_sidebar.lua`: Core sidebar UI, model fetching, prompt submission, background CLI execution, and menu commands.
- `plugins/auto_healer.lua`: Auto-healer trigger, also starts processes using the `agy` CLI.
- `agy` CLI: The command-line interface that the plugin spawns to interact with the AI.

## Milestones
| # | Name | Scope | Dependencies | Status |
|---|---|---|---|---|
| 4 | Milestone 4: Stdin Redirect & Hang Fix | Fix background process hangs on Windows via stdin redirection (process.REDIRECT_DISCARD) in `plugins/antigravity_sidebar.lua` and `plugins/auto_healer.lua`. | None | PLANNED |
| 5 | Milestone 5: Dynamic Models & Auth | Enable dynamic models list fetch on Windows and resilient authentication workflow. Use stdin redirection to avoid blocking on background checks. | M4 | PLANNED |
| 6 | Milestone 6: UX Extensions | Integrate context menu items under `"core.docview"` and quick commands (`antigravity:ask`, etc.). | M5 | PLANNED |

## Interface Contracts
### `process.start(argv, options)`
- Options must include `stdin = process.REDIRECT_DISCARD` for all non-interactive background CLI calls.
- Stdin redirect prevents Go-based `agy` CLI from hanging on console/TTY checks on Windows.

### AI Commands and Sidebar
- Quick commands (like `antigravity:explain`) must use `command.perform("antigravity:submit", prompt)` to ensure sidebar opens and handles the submission if closed/uninitialized.
- Context menu items register via `"plugins.contextmenu"`.

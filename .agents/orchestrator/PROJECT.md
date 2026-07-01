# Project: Antigravity AI Lite-XL Sidebar Stabilization

## Architecture
- `plugins/antigravity_sidebar.lua`: The main sidebar plugin containing views, process management for `agy` CLI, and model listing.
- `plugins/auto_healer.lua`: Auto-healer plugin which also spawns the `agy` CLI for healing Lua errors.
- `init_append.lua`: Main user configuration appending the plugin loading and keybindings.
- `agy` CLI: The external binary located at `C:\Users\ojasw\AppData\Local\agy\bin\agy.exe` (or similar) used for chat streaming, authentication check, and model listing.

## Milestones
| # | Name | Scope | Dependencies | Status | Conv ID |
|---|---|---|---|---|---|
| 1 | Test Infra (E2E) | Design automated Lua/Lite-XL test runner and harness using custom init/plugins. | None | IN_PROGRESS | be49a850-b3ff-47a6-bb84-8fd4dd00448f |
| 2 | E2E Feature Cases | Implement Tier 1 & 2 test cases covering F1 (Stability), F2 (Auth), F3 (Context Menu), F4 (Quick Commands). | M1 | IN_PROGRESS | be49a850-b3ff-47a6-bb84-8fd4dd00448f |
| 3 | E2E Integration Cases | Implement Tier 3 & 4 test cases for cross-feature combinations and real workloads. | M2 | IN_PROGRESS | be49a850-b3ff-47a6-bb84-8fd4dd00448f |
| 4 | Stdin Redirect & Hang Fix | Fix background process hangs on Windows via stdin redirection (process.REDIRECT_DISCARD). | None | IN_PROGRESS | 5042cb5f-f6d6-497c-b162-ab3c6705e20d |
| 5 | Dynamic Models & Auth | Enable dynamic models on Windows and resilient authentication workflow. | M4 | IN_PROGRESS | 5042cb5f-f6d6-497c-b162-ab3c6705e20d |
| 6 | UX Extensions | Integrate context menu items and quick commands (`antigravity:ask`, etc.). | M5 | IN_PROGRESS | 5042cb5f-f6d6-497c-b162-ab3c6705e20d |
| 7 | E2E Testing Integration | Integrate implementation with Tier 1-4 E2E tests, verifying 100% pass rate. | M3, M6 | PLANNED | TBD |
| 8 | Adversarial Hardening | Implement Tier 5 (Adversarial Coverage Hardening) and verify code stability. | M7 | PLANNED | TBD |

## Interface Contracts
- `plugins/antigravity_sidebar.lua` commands:
  - `antigravity:explain`
  - `antigravity:refactor`
  - `antigravity:fix`
  - `antigravity:tests`
  - `antigravity:docs`
  - `antigravity:submit` (takes prompt)
  - `antigravity:ask`
- `plugins/contextmenu` integration:
  - Register `core.docview` context menu items with custom actions.

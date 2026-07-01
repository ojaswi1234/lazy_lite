# Project: Antigravity AI Lite-XL Sidebar Stabilization

## Architecture
- `plugins/antigravity_sidebar.lua`: Main sidebar view, commands, model listing, background process runner for `agy` CLI.
- `plugins/auto_healer.lua`: Auto-healer plugin that runs `agy` for Lua error recovery.
- `init_append.lua`: Main user configuration appending the plugin loading and keybindings.
- `agy` CLI: External CLI binary used by plugins to communicate with Google Cloud APIs.

## Milestones
| # | Name | Scope | Dependencies | Status | Conv ID |
|---|---|---|---|---|---|
| 1 | Test Infra (E2E) | Design automated Lua/Lite-XL test runner and harness using custom init/plugins. | None | IN_PROGRESS | 32d8c1c2-1e4c-4d41-a3ef-de4266fdc10b |
| 2 | E2E Feature Cases | Implement Tier 1 & 2 E2E test cases covering F1 (Stability), F2 (Auth), F3 (Context Menu), F4 (Quick Commands). | M1 | IN_PROGRESS | 32d8c1c2-1e4c-4d41-a3ef-de4266fdc10b |
| 3 | E2E Integration Cases | Implement Tier 3 & 4 E2E test cases for cross-feature combinations and real workloads. | M2 | IN_PROGRESS | 32d8c1c2-1e4c-4d41-a3ef-de4266fdc10b |
| 4 | Test Finalization | Verify test runner, write TEST_INFRA.md and TEST_READY.md. | M3 | IN_PROGRESS | 32d8c1c2-1e4c-4d41-a3ef-de4266fdc10b |
| 5 | Stdin Redirect & Hang Fix | Fix background process hangs on Windows via stdin redirection (process.REDIRECT_DISCARD). | None | IN_PROGRESS | 8a2534c6-3801-4c49-9d72-a0a28709848d |
| 6 | Dynamic Models & Auth | Enable dynamic models on Windows and resilient authentication workflow. | M5 | IN_PROGRESS | 8a2534c6-3801-4c49-9d72-a0a28709848d |
| 7 | UX Extensions | Integrate context menu items and quick commands (`antigravity:ask`, etc.). | M6 | IN_PROGRESS | 8a2534c6-3801-4c49-9d72-a0a28709848d |
| 8 | E2E Integration | Integrate implementation with Tier 1-4 E2E tests, verifying 100% pass rate. | M4, M7 | PLANNED | TBD |
| 9 | Adversarial Hardening | Implement Tier 5 (Adversarial Coverage Hardening) and verify code stability. | M8 | PLANNED | TBD |

## Interface Contracts
### E2E Test Runner ↔ Lite-XL
- Lite-XL Invocation: `lite-xl.exe --userdir <test_dir>`
- Test Results: Written to `<test_dir>/e2e_test_results.json`
- Exit Mechanism: The test runner calls `core.quit()` when finished.

### Plugin ↔ Mock `agy` CLI
- `mock_agy.exe` will read configuration from `<test_dir>/mock_config.txt` to determine what to write to stdout/stderr and what exit code to return.
- If no configuration is found, it defaults to a standard successful chat streaming response or model listing.

### UX Commands & Bindings
- `antigravity:explain`
- `antigravity:refactor`
- `antigravity:fix`
- `antigravity:tests`
- `antigravity:docs`
- `antigravity:submit` (takes prompt)
- `antigravity:ask`
- Context Menu: registers AI commands under `core.docview` predicate.

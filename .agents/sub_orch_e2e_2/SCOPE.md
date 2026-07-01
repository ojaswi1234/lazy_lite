# Scope: E2E Testing Track

## Architecture
The E2E testing framework operates on an opaque-box basis for the Lite-XL editor and the Antigravity sidebar plugin:
1. **Test Runner & Environment**: Launches Lite-XL with a custom `--userdir` pointing to a test-specific directory (containing `init.lua`, colors, and plugins).
2. **Simulator Plugin (`plugins/e2e_simulator.lua`)**: Injected into Lite-XL. It defines a suite of test cases and executes them sequentially. It simulates user inputs (typing in the chat, executing commands, clicking buttons, triggering context menus, selecting text).
3. **CLI Mocking (`mock_agy.exe`)**: A compiled C program that intercepts calls from the plugin to `agy` and returns predefined outputs based on a configuration file (`mock_config.json` or `mock_config.txt`) or arguments.
4. **Result Verification & Report**: The test runner plugin writes results to `e2e_test_results.txt` and calls `core.quit()`. The harness script (PowerShell) runs Lite-XL, waits for it to exit, parses the result file, and reports success or failure.

## Milestones
| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| 1 | Test Infra (E2E) | Implement custom `--userdir` setup, automated test runner, `mock_agy.exe` compiled binary, and UI event simulator plugin. Verify with a basic sanity test. | None | IN_PROGRESS |
| 2 | E2E Feature Cases | Implement Tier 1 (Feature Coverage, >=20 tests) and Tier 2 (Boundary & Corner Cases, >=20 tests) covering F1 (Stability), F2 (Auth), F3 (Context Menu), F4 (Quick Commands). | M1 | PLANNED |
| 3 | E2E Integration Cases | Implement Tier 3 (Cross-Feature Combinations, >=4 tests) and Tier 4 (Real-World Application Scenarios, >=5 tests). | M2 | PLANNED |
| 4 | Finalization & Documentation | Verify test suite, run E2E checks, write `TEST_INFRA.md` and `TEST_READY.md`. | M3 | PLANNED |

## Interface Contracts
### E2E Test Runner ↔ Lite-XL
- Lite-XL Invocation: `lite-xl.exe --userdir <test_dir>`
- Test Results: Written to `<test_dir>/e2e_test_results.json`, structured per test case with name, tier, status (`PASS`/`FAIL`), and error messages.
- Exit Mechanism: The test runner calls `core.quit()` when finished.

### Plugin ↔ Mock `agy` CLI
- `mock_agy.exe` will read configuration from `<test_dir>/mock_config.txt` to determine what to write to stdout/stderr and what exit code to return.
- If no configuration is found, it defaults to a standard successful chat streaming response or model listing.

# Scope: E2E Testing Track

## Architecture
The E2E testing framework operates on an opaque-box basis for the Lite-XL editor and the Antigravity sidebar plugin:
1. **Test Runner & Environment**: Launches Lite-XL with a custom `--userdir` pointing to `C:\Users\ojasw\Documents\LiteXL-Mossy-Setup\e2e_test_env` (containing `init.lua`, colors, fonts, and plugins).
2. **Simulator Plugin (`plugins/e2e_simulator.lua` in `e2e_test_env`)**: Injected into Lite-XL. It defines a suite of test cases and executes them sequentially. It simulates inputs and commands, and validates internal state / UI states.
3. **CLI Mocking (`mock_agy.exe`)**: Intercepts calls from the plugin to `agy` and returns predefined outputs based on `e2e_test_env/mock_config.txt`.
4. **Result Verification & Report**: The simulator writes results to `e2e_test_results.json` and calls `core.quit()`. The harness script (PowerShell) runs Lite-XL, waits for it to exit, parses the result file, and reports success or failure.

## Milestones
| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| 1 | Test Infra (E2E) | Compile mock_agy, implement `e2e_simulator.lua` test runner skeleton, and write PowerShell harness (`run_e2e_tests.ps1`). | None | PLANNED |
| 2 | E2E Test Cases | Implement all required test cases: Tier 1 (>=20), Tier 2 (>=20), Tier 3 (>=4), Tier 4 (>=5). | M1 | PLANNED |
| 3 | E2E Verification & Docs | Execute E2E tests, resolve failures, and produce `TEST_INFRA.md` and `TEST_READY.md`. | M2 | PLANNED |

## Interface Contracts
### E2E Test Runner ↔ Lite-XL
- Lite-XL Invocation: `lite-xl.exe --userdir C:\Users\ojasw\Documents\LiteXL-Mossy-Setup\e2e_test_env`
- Test Results: Written to `C:\Users\ojasw\Documents\LiteXL-Mossy-Setup\e2e_test_results.json`.
- Exit Mechanism: Calls `core.quit()` when finished.

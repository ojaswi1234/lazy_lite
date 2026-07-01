# Scope: E2E Testing Track

## Architecture
The E2E testing framework will operate on an opaque-box basis for the Lite-XL editor and the Antigravity sidebar plugin:
1. **Test Runner Harness (PowerShell/Python or Lua-native)**: Launches Lite-XL with a custom `--userdir` pointing to a test-specific directory (containing `init.lua`, colors, and plugins).
2. **Simulator Plugin (Lua)**: Injected into Lite-XL. It reads test specs or executes commands sequentially, simulating user inputs (e.g., typing in the chat, clicking buttons, triggering context menus).
3. **CLI Mocking (`agy` wrapper)**: Provides a mock `agy` CLI/script that behaves predictably (mocking success, timeouts, errors, and models lists) to test the plugin's resilience without relying on a live server/active credentials.
4. **Execution & Reporting**: The test runner launches Lite-XL, the simulator executes test cases and writes results to a JSON/text file, and Lite-XL exits. The runner then parses the results and exits with non-zero if any test fails.

## Milestones
| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| 1 | Test Infra (E2E) | Implement custom `--userdir` setup, automated test runner, `agy` CLI mocker, and UI event simulator plugin. Verify with a basic sanity test. | None | IN_PROGRESS (Conv ID: 29839748-8070-4540-aee4-ef201c4cb4e9) |
| 2 | E2E Feature Cases | Implement Tier 1 (Feature Coverage, >=20 tests) and Tier 2 (Boundary & Corner Cases, >=20 tests) covering F1 (Stability), F2 (Auth), F3 (Context Menu), F4 (Quick Commands). | M1 | PLANNED |
| 3 | E2E Integration Cases | Implement Tier 3 (Cross-Feature Combinations, >=4 tests) and Tier 4 (Real-World Application Scenarios, >=5 tests). | M2 | PLANNED |
| 4 | Finalization & Documentation | Run all tests (Tiers 1-4) to verify 100% pass rate. Generate `TEST_INFRA.md` and `TEST_READY.md`. | M3 | PLANNED |

## Interface Contracts
### E2E Test Runner ↔ Lite-XL
- Lite-XL Invocation: `lite-xl --userdir <test_dir> <other_args>`
- Test Results: Written to `<test_dir>/test_results.log` or similar, structured per test case with `PASS`/`FAIL` and error details.
- Exit Mechanism: Test runner Lua plugin calls `core.quit()` when finished.

### Plugin ↔ Mock `agy` CLI
- The mock `agy` binary/script will intercept calls and return pre-configured stdout/stderr/exit-codes based on environment variables or config files.
- Commands to mock:
  - `agy models`: Return lists of models, with some flagged as exhausted or having high latency.
  - `agy chat`: Steam chat responses, simulate latency/timeouts, and simulate authentication errors.
  - `agy install`: Mock installation/setup.

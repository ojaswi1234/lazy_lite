## 2026-06-30T12:45:44Z
You are the E2E Test Developer for Lite-XL Antigravity Sidebar.
Your working directory is C:\Users\ojasw\Documents\LiteXL-Mossy-Setup\.agents\worker_e2e_3\.
Your tasks:
1. Locate the `lite-xl.exe` executable on this Windows machine. Search in the system PATH, default installation folders (e.g. AppData\Local\Programs, Program Files, etc.).
2. Write a PowerShell script `C:\Users\ojasw\Documents\LiteXL-Mossy-Setup\run_e2e_tests.ps1` that will:
   - Accept the path to `lite-xl.exe` or locate it automatically.
   - Execute `lite-xl.exe --userdir C:\Users\ojasw\Documents\LiteXL-Mossy-Setup\e2e_test_env` in a headless/automated way, or just run it normally and wait for it to exit.
   - Read the result file `C:\Users\ojasw\Documents\LiteXL-Mossy-Setup\e2e_test_results.json`.
   - Parse the JSON results and print a summary.
   - Return exit code 0 if all tests passed, 1 otherwise.
3. Write `C:\Users\ojasw\Documents\LiteXL-Mossy-Setup\e2e_test_env\plugins\e2e_simulator.lua`.
   - This file must define and run E2E test cases covering:
     - Tier 1: Feature Coverage (>=20 tests: Stability (toggles, layout/resizing, scrolling, drawing), Auth (status transitions, fetch_models), Context Menu (explain, refactor, fix, tests, docs), Quick Commands (ask, submit, clear chat, stop generating)).
     - Tier 2: Boundary & Corner Cases (>=20 tests: empty/whitespace inputs, very long inputs, CLI errors, models timeout, mention popup (trigger, filter, navigate, select, backspace), selection states (with/without selection), invalid model inputs).
     - Tier 3: Cross-Feature Combinations (>=4 tests: chat persistence, auth error -> model switch -> chat, quick pill click during active run, mention select -> clear chat).
     - Tier 4: Real-World Application Scenarios (>=5 tests: explain full file, refactor selection, fix and stop generation, auth flow completion, markdown wrapping).
   - Implement a robust asynchronous test runner in Lua using `core.add_thread(function() ... end)` and `coroutine.yield()`.
   - The test runner must catch errors for each test using `xpcall` or `pcall` to ensure all tests execute, write the results to `C:\Users\ojasw\Documents\LiteXL-Mossy-Setup\e2e_test_results.json` in JSON format, and then call `core.quit()`.
4. Ensure `mock_agy.exe` works properly. Write a helper to dynamically update `e2e_test_env/mock_config.txt` inside the simulator for each test case before running the mock CLI.
5. Execute the test suite and verify that all test cases pass.
6. Once all tests pass, write the `TEST_INFRA.md` and `TEST_READY.md` documents at the project root `C:\Users\ojasw\Documents\LiteXL-Mossy-Setup` (ensure the formats match the instructions).
7. Report back with the test results, listing each test case and its status.

MANDATORY INTEGRITY WARNING:
DO NOT CHEAT. All implementations must be genuine. DO NOT hardcode test results, create dummy/facade implementations, or circumvent the intended task. A Forensic Auditor will independently verify your work. Integrity violations WILL be detected and your work WILL be rejected.

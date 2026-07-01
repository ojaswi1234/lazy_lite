# Project Execution Plan - Antigravity AI Lite-XL Sidebar Stabilization

## 1. Overview
We will run two parallel tracks to achieve high-quality stabilization, extension, and rigorous verification:
- **Track 1: E2E Testing Track** (Milestones 1, 2, 3)
- **Track 2: Implementation Track** (Milestones 4, 5, 6)

After both tracks are ready, they merge into:
- **Track 3: Integration & Hardening** (Milestones 7, 8)

## 2. Track Breakdown

### Track 1: E2E Testing Track (Sub-orchestrator)
- **Objective**: Design an automated testing harness for Lite-XL on Windows. Derive opaque-box test cases for F1-F4 based purely on requirements (not internal code structure).
- **Tiers**:
  - Tier 1: Feature Coverage (5 per feature = 20 tests)
  - Tier 2: Boundary & Corner Cases (5 per feature = 20 tests)
  - Tier 3: Cross-Feature Combinations (4 tests)
  - Tier 4: Real-World Scenarios (5 tests)
- **Output**: Writes `TEST_INFRA.md` and `TEST_READY.md` when the test suite is fully implemented and ready.

### Track 2: Implementation Track (Sub-orchestrator)
- **Objective**: Fix the hangs, stabilize authentication, implement context menus, and add quick commands.
- **Tasks**:
  - Redirect stdin to discard standard input for background CLI calls to prevent Windows hangs.
  - Re-enable dynamic models list fetch on Windows.
  - Add "Ask Antigravity" quick command and right-click context menu options.
  - Relies on the findings and proposals patch from `explorer_initial`.

### Track 3: Integration & Hardening
- **Phase 1**: Execute the Tier 1-4 tests on the implementation and fix failures until 100% pass.
- **Phase 2**: Adversarial coverage hardening (Tier 5) using white-box source analysis and Challenger-initiated loops.

## 3. Dispatch Plan
1. Dispatch **E2E Testing Track Orchestrator** to design test infra and test cases.
2. Dispatch **Implementation Track Orchestrator** to apply stability fixes and extensions.
3. Monitor progress via heartbeats.
4. Verify integration and run forensic audits to ensure no cheating (e.g. mock bypasses) took place.

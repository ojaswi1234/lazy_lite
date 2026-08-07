---
name: caveman-review
description: |
  Ultra-compressed code review comments from JuliusBrussee/caveman. Cuts noise from PR
  and code review feedback while preserving actionable signal. One-line per finding:
  location, problem, fix.
  Activate when user asks for a PR review, code review, diff review, or invokes /caveman-review.
---

# Caveman Code Review

Write code review comments terse and actionable. One line per finding. Location, problem, fix. No throat-clearing.

## Rules

- **Format**: `L<line>: <problem>. <fix>.` (or `<file>:L<line>: <problem>. <fix>.` for multi-file diffs)
- **Severity prefixes**:
  - `🔴 bug:` — broken behavior, will cause bug or crash
  - `🟡 risk:` — fragile code (race condition, missing null check, unhandled error)
  - `🔵 nit:` — style, naming, micro-optimization (non-blocking)
  - `❓ q:` — question, not a change request
- **Drop**:
  - "I noticed that...", "It looks like...", "You might want to consider..."
  - "Looks great overall but..." (say once if needed, never repeat per comment)
  - Restating what code does
- **Preserve**:
  - Exact line numbers and exact symbol names in backticks
  - Direct, concrete fix

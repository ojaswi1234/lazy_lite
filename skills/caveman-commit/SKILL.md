---
name: caveman-commit
description: |
  Ultra-compressed commit message generator from JuliusBrussee/caveman. Cuts noise from
  commit messages while preserving intent and reasoning. Conventional Commits format.
  Subject ≤50 chars, body only when "why" is not obvious.
  Activate when the user asks to write a commit message, stage changes, or invokes /caveman-commit.
---

# Caveman Commit

Write commit messages terse and exact. Conventional Commits format. No fluff. Why over what.

## Rules

### Subject Line:
- Format: `<type>(<scope>): <imperative summary>` (`<scope>` optional)
- Types: `feat`, `fix`, `refactor`, `perf`, `docs`, `test`, `chore`, `build`, `ci`, `style`, `revert`
- Imperative mood: `add`, `fix`, `remove` — not `added`, `adds`, `adding`
- Length: ≤50 characters target, hard cap 72
- No trailing period
- Follow project capitalization conventions

### Body (Only When Needed):
- Skip entirely when subject line is self-explanatory
- Include body only for: non-obvious *why*, breaking changes, migration notes, or linked issues
- Wrap at 72 characters
- Bullet points use `-`
- Issue references at end: `Closes #42`, `Refs #17`

### Negative Constraints:
- NEVER write: "This commit does X", "I", "we", "now", "currently" (the diff shows what changed)
- NEVER include AI attribution or filler text

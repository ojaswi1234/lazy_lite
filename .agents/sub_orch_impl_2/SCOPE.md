# Scope: Implementation Track (Milestones 4, 5, 6)

## Architecture
- Custom portable configuration for Lite-XL with Antigravity AI sidebar integrated.
- Key modules affected:
  - `plugins/antigravity_sidebar.lua`: Main sidebar UI, commands, and background process handling.
  - `plugins/auto_healer.lua`: Auto-heals crashes/errors, spawner of headless agy process.

## Milestones
| # | Name | Scope | Dependencies | Status |
|---|------|-------|-------------|--------|
| 1 | Milestone 4: Stdin Redirect & Hang Fix | Fix process hangs on Windows via stdin redirection (REDIRECT_DISCARD) in `plugins/antigravity_sidebar.lua` and `plugins/auto_healer.lua`. | None | PLANNED |
| 2 | Milestone 5: Dynamic Models & Auth | Enable dynamic models list fetch on Windows (remove platform guard) and resilient authentication (check auth status via models API). | Milestone 4 | PLANNED |
| 3 | Milestone 6: UX Extensions | Register context menu items and quick commands like `antigravity:ask`, route quick actions through `antigravity:submit`. | Milestone 5 | PLANNED |

## Interface Contracts
- Standard Lite-XL commands:
  - `antigravity:submit` (performs sidebar submission, showing/focusing as needed)
  - `antigravity:explain`, `antigravity:refactor`, `antigravity:fix`, `antigravity:tests`, `antigravity:docs`
  - `antigravity:ask` (inputs text from user via Command View)
- Context menu: registers AI commands under `core.docview` predicate.

## Code Layout
- `plugins/antigravity_sidebar.lua`
- `plugins/auto_healer.lua`

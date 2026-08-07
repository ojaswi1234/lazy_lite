---
name: caveman-compress
description: |
  Compress natural language instruction and memory files (e.g. rules, AGENTS.md, docs)
  into compressed caveman format to save baseline input tokens on every turn.
  Activate when user says "compress memory file", "compress rules", or invokes /caveman-compress.
---

# Caveman Compress

Compress natural language files (rules, AGENTS.md, instructions, todos) into terse, high-density bullet points to minimize recurrent input tokens while preserving exact technical instructions.

## Compression Directives

### Strip Out:
- Articles (`a`, `an`, `the`)
- Filler words (`just`, `really`, `basically`, `actually`, `simply`, `essentially`)
- Pleasantries and conversational preambles
- Hedging (`it might be worth`, `you could consider`, `ensure that you`)
- Connective fluff (`furthermore`, `in addition`, `consequently`)

### Preserve Exactly:
- Fenced code blocks and inline code
- URLs and markdown links
- File paths and directory structures
- Shell commands and CLI flags
- Technical terms, variable/type names, and regex patterns
- Logic constraints and boundary conditions

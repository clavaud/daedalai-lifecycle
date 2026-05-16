---
description: "Reconcile the project's local CLAUDE.md with its canonical CLAUDE_MD document in DaedalAI — pull when remote is newer, push when local is newer, refuse to silently merge on divergence. Always shows the diff before overwriting."
---

Invoke the `daedalai-sync-claude-md` skill. Probes drift via
`da_check_claude_md_drift`, branches on the six drift states, and
routes through `da_init_or_update_project` with `withClaudeMdPull`
or `withClaudeMdPush` after explicit user confirmation. Never
auto-resolves DIVERGED — the user picks pull, push, or abort.

Arguments (optional): `$ARGUMENTS` — projectCode override when the
session-cached project is ambiguous (rare).

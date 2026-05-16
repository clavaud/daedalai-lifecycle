---
name: daedalai-sync-claude-md
description: "Reconcile the project's local CLAUDE.md with its canonical CLAUDE_MD document in DaedalAI — pulls remote when newer, pushes local when newer, refuses to silently merge on divergence. Always shows the diff and asks before overwriting. Use when the orchestrate skill surfaces a 🟡 CLAUDE.md drift nudge, when the user says 'sync CLAUDE.md' / '/daedalai-sync-claude-md', or before relying on documented conventions in a long-lived session."
---

# Sync CLAUDE.md

Invoked with no required `args`. Optional `args` = `<projectCode>` to
force a specific project when ambiguous (rare — orchestrate has
already cached the resolved project for the session).

This skill is the resolution surface for the per-session drift check
defined in the orchestrate skill §1. CLAUDE.md is the load-bearing
per-repo convention file (communication style, tool preferences,
version pins). When it differs between DaedalAI's canonical version
and the developer's working tree, every Claude Code session reads the
local copy and may operate against stale rules. This skill brings the
two sides into alignment without silently rewriting either.

## Invariants

1. **Never silently overwrite either side.** The user sees the diff
   before any pull or push. Exception: `LOCAL_MISSING` (no local file
   to compare against — pull is unambiguous).
2. **Never auto-resolve divergence.** When both sides changed since
   the last sync, the skill aborts after surfacing the two diffs and
   asks the user to pick pull, push, or abort. No three-way merge.
3. **Server-side singleton invariant is authoritative.** The push
   path can fail at the DB layer (partial unique index on
   `da_documents` per DAEDA-274 SPEC §B.0). If a push fails because
   another session pushed first, re-run the skill — it will detect
   the new remote state.

## Workflow

### 1. Probe drift

Call `da_check_claude_md_drift(projectCode)` — read-only, cheap
(~5 ms typical). Returns `ClaudeMdDriftResult` with six possible
`DriftState` values: `NONE | LOCAL_NEWER | REMOTE_NEWER | DIVERGED |
LOCAL_MISSING | REMOTE_MISSING`.

If `projectCode` was not passed and orchestrate has not cached the
project for this session, invoke `da_list_projects` to resolve from
`localRepoPath` / `repositoryUrl`. Fail with a clear message if no
match — this skill is per-project and won't guess.

### 2. Branch on `drift` state

| State | Action |
|-------|--------|
| `NONE` | Print "CLAUDE.md is in sync ({hash[0:7]})." and exit. No prompts. |
| `LOCAL_NEWER` | Show the local-vs-remote diff (`git diff --no-index <repo>/CLAUDE.md <remote-content-tmp>`). Ask: "Push local to DaedalAI? [y/n]". On `y` → §3 push. On `n` → exit cleanly. |
| `REMOTE_NEWER` | Show the remote-vs-local diff (same tool, args swapped). Ask: "Pull DaedalAI to local? [y/n]". On `y` → §3 pull. On `n` → exit cleanly. |
| `DIVERGED` | Show **both** diffs: local-vs-marker AND remote-vs-marker. Ask: "Pull, push, or abort? [pull/push/abort]". Each branch routes to §3; `abort` exits with no writes. |
| `LOCAL_MISSING` | "CLAUDE.md absent locally. Pull from DaedalAI? [y/n]". No diff (nothing to compare). On `y` → §3 pull. |
| `REMOTE_MISSING` | "No canonical CLAUDE.md in DaedalAI yet. Push local to seed? [y/n]". No diff. On `y` → §3 push. |

For each prompt, default to abort/no on Enter (safer). The user MUST
type the affirmative explicitly.

### 3. Execute pull or push

**Pull** (`y` branch from `LOCAL_NEWER` would never reach here —
that's a typo: pull happens from `REMOTE_NEWER`, `DIVERGED + pull`,
or `LOCAL_MISSING`):

```
da_init_or_update_project(
    projectCode=<resolved>,
    withClaudeMdPull=true,
    dryRun=false
)
```

Expect `claudeMdAction=WROTE` (or `SKIPPED` if a race put us back in
sync). Print the resulting `claudeMdAction`, byte counts, and the new
local hash. Done.

**Push** (from `LOCAL_NEWER`, `DIVERGED + push`, or `REMOTE_MISSING`):

```
da_init_or_update_project(
    projectCode=<resolved>,
    withClaudeMdPush=true,
    dryRun=false
)
```

Expect `claudeMdAction=PUSHED`. Print the new document publicId
(when `REMOTE_MISSING` — first push) or new version number (when
updating). Done.

If the underlying MCP tool returns an error (singleton race,
mutually-exclusive-flag misuse, DIVERGED at server side that the
client probe missed) — surface the error verbatim, do not retry,
do not paper over.

### 4. Post-sync verification

After any successful pull or push, re-call
`da_check_claude_md_drift(projectCode)` and assert `drift=NONE`. If
the verification call returns anything else, surface it as a warning
— something raced or the sync didn't take effect. Don't loop.

Print a one-line summary: `✓ CLAUDE.md synced ({direction}, new
hash {hash[0:7]}, marker updated)`.

## Diff rendering

Use `git diff --no-index <fileA> <fileB>` for the diff output —
sub-second on anything under 1 MB, and the user is already fluent in
the format. Don't reinvent the renderer.

For the `DIVERGED` two-diff case, label clearly:
```
=== Local changes since last sync ===
<diff>

=== Remote changes since last sync ===
<diff>
```

Both diffs are computed against the marker content, which the user
hasn't seen — that's the point. The marker is the agreed-upon
ancestor; both sides diverged from it.

## What this skill does NOT do

- Does NOT install CLAUDE.md via `da_init_or_update_project` (the
  init path is for git hooks, not CLAUDE.md — those are two
  independent surfaces of the same tool).
- Does NOT sync CLAUDE.md for multiple projects in one invocation —
  one project per call. The umbrella-wide rollout is a separate
  follow-up (see DAEDA-274 SPEC §B "Out of scope").
- Does NOT auto-commit the pulled CLAUDE.md. The user reviews the
  diff and decides whether to commit. A pulled CLAUDE.md sitting
  uncommitted on the working tree is expected post-state.
- Does NOT push asynchronously. The push is synchronous so the user
  knows immediately if the singleton-race or DIVERGED guard fires.

## Error surface (verbatim from `da_init_or_update_project`)

| Error | Meaning | Recovery |
|-------|---------|----------|
| `mutually-exclusive-flag-misuse` | Should not happen from this skill (we pass exactly one of pull/push). If it does, file a bug. | Re-run; if reproducible, report. |
| `local-claude-md-missing` (push path) | `<repo>/CLAUDE.md` absent or unreadable. | Stage the file, retry. |
| `no-remote-claude-md` (pull path) | No canonical CLAUDE_MD doc exists for this project. The probe should have returned `REMOTE_MISSING`; if it didn't, refresh state. | Push instead, or re-run skill. |
| `diverged-server-side` | Server saw a state shift between probe and write. | Re-run skill — it'll re-probe and re-prompt. |
| `singleton-violation` (push path, create branch) | DB partial unique index rejected the create — another session pushed first between probe and create. | Re-run skill — it'll route to update on the next probe. |
| `project-not-resolved` | `projectCode` doesn't match any project; or project lacks `localRepoPath` and no `repoPath` override. | Pass an explicit `repoPath` argument, or register the project in DaedalAI first. |

## Related

- SPEC: DAEDA-DOC-209 (DAEDA-274) — §B for the full sync design
- MCP tools: `da_check_claude_md_drift`, `da_init_or_update_project`
  with `withClaudeMdPull` / `withClaudeMdPush`
- Server-side singleton: `da_documents` partial unique index
  `uk_da_documents_claude_md_singleton`
- Orchestrate skill §1 — per-session drift check that surfaces the
  nudge that leads users here

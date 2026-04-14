---
name: daedalai-bug-from-error
description: "Turn an error message and optional stack trace into a DaedalAI BUG work item with fingerprint-based duplicate detection. Use when the user pastes an error, exception, or stack trace and wants it filed properly. Invoked with errorMessage and optional stackTrace and context. Returns Created / Duplicate / Already-Resolved verdict with the relevant WI key."
---

# Bug From Error

Invoked with `args` = `<errorMessage>` plus optional named args:
- `stackTrace=<top-N frames>`
- `context=<what the user was doing when the error surfaced>`
- `projectCode=<slug>` (inferred from current session if omitted)

## When skill vs. agent

- **This skill**: straight-through filing. Best for a quick paste-it-
  and-file flow.
- **`daedalai-bug-triage` agent**: dispatch when you want richer
  fingerprint analysis or when the trace spans multiple modules and
  needs stack-walking to pick entity links.

## Workflow

1. **Resolve project**:
   - If `projectCode` provided, use it.
   - Else `da_list_projects` + match the current repo (via
     localRepoPath / repositoryUrl).
   - If no match, ask the user which project.

2. **Resolve entity links** (best-effort, not mandatory for BUGs):
   - `da_list_modules(projectCode)` — if the stack trace class name
     matches a module's code/description, use that module's publicId.
   - `da_list_functions(projectCode)` — same match on the named
     class/method.
   - Missing match → leave links null; the `da_create_issue_from_error`
     tool will still work.

3. **Hygiene on inputs**:
   - Strip volatile values from `errorMessage` before passing:
     timestamps, request IDs, user emails, UUIDs that differ per
     request. Preserves fingerprint stability.
   - Truncate `stackTrace` to top 10–20 frames.
   - `context` stays user-supplied and objective (what they were
     doing), not your interpretation.

4. **Create with triage**:
   ```
   da_create_issue_from_error(
     projectCode,
     errorMessage,
     stackTrace?,
     context?,
     modulePublicId?,
     functionPublicId?
   )
   ```
   Response has three shapes:
   - **Created**: new BUG WI, returned with `itemKey` and `publicId`.
   - **Duplicate**: matches an open BUG with the same fingerprint.
     Returns the existing WI.
   - **Already-Resolved**: matches a BUG closed in a recent version.
     Returns the resolved WI + commit/version info if available.

5. **Side-effects per verdict**:
   - **Created**: if the full stack trace is too long to cleanly sit
     in the description, `da_add_comment(publicId, <trace block>)`
     with a code-fenced comment.
   - **Duplicate**: `da_add_comment(publicId, "Another occurrence:
     <context>, at <now>")` on the existing BUG. Increment visibility.
   - **Already-Resolved**: `da_add_comment(publicId, "Regression:
     reappeared at <now>, context: <context>. Consider reopening or
     filing a fresh REGRESSION_FOR BUG.")`. Flag to user for decision.

6. **Report**:
   ```
   🐛 <Created|Duplicate|Regression>: <itemKey> — <title>
   Status: <status>
   Priority: <priority>
   Links: module=<name>, function=<name>
   <url>
   ```
   Plus one-line rationale for the verdict.

## Style guide

- Objective context over interpretation. "User clicked Save on
  /admin/users/new with form A=1, B=2" not "tried to save a user".
- Fingerprint-stable inputs. Two calls with the same error on
  different dates should dedupe.
- Conservative confidence. If the class name in the stack isn't
  clearly matching a module, leave links null — better than wrong.

## Boundaries

- Never debug or propose a fix in this skill — triage only.
- Never reopen a resolved WI automatically. Flag the regression to
  the user; let them decide reopen vs. new-BUG.
- Never transition status beyond what `da_create_issue_from_error`
  does (TODO by default).
- Never close an existing BUG even if it looks obsolete.

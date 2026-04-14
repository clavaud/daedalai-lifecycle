---
name: daedalai-finalize-work-item
description: "Run the full completion pipeline on a DaedalAI work item after implementation: register commits, verify entity links, run lesson checks on the diff, evaluate the quality gate, transition to TESTING, and surface any blockers before DONE. Use when the user says 'finalize DAEDA-X', 'close out WI', '/daedalai-finalize DAEDA-99', or the orchestrator reaches the finish-work step."
---

# Finalize Work Item

Invoked with `args` = `<workItemKey>` (required).

This skill orchestrates the QG pipeline defined in the orchestrate
skill §8. It does not run tests itself; it consumes test results
already imported into DaedalAI.

## Workflow

1. **Resolve the WI**: `da_search` → `da_get_work_item(publicId)`.
   Confirm current status is IN_PROGRESS (otherwise warn and stop).

2. **Register commits** (code projects only):
   - For each target repo: `git log --oneline <defaultBranch>..HEAD`
     to collect commits on the branch.
   - For each commit: `da_add_commit(publicId, sha, message, author,
     committedAt)`. Dedup by SHA is server-side.
   - `da_update_work_item(publicId, isCommitted=true)`.

3. **Entity link self-check** (mandatory):
   - Read the WI back with `da_get_work_item`.
   - Verify `modulePublicId`, `screenPublicId` (or plural),
     `functionPublicId` (or plural) are populated.
   - If any is missing AND the WI doesn't qualify for the §4
     exception (plugin/infra/cross-cutting), block with an
     actionable warning: "Add entity links before finalize".

4. **Lesson check on the diff**:
   - Collect changed files from `git diff --name-only`.
   - Call `da_check_lessons(projectCode, changedFiles=...)` or feed
     the diff text. Report any matches with severity.
   - BLOCKING hits → block finalize, tell the user what to fix.
   - WARNING hits → surface to user, do not block.

5. **Quality gate** (code projects — orchestrator's §8 loop):
   - Dispatch the `daedalai-test-gatekeeper` agent for a structured
     PASS/BLOCK verdict.
   - Run `/simplify` on changed files — if it produces changes,
     restart from step 4.
   - `da_test_coverage(publicId)` → verify ≥ threshold on changed code.

   For non-code projects (per §7b): peer review + source citations +
   scope alignment instead of test-based gates.

6. **Populate mandatory fields**:
   - `solution` must be set (ALL types). Compose from the commit
     bodies and SPEC resolution.
   - BUG: `analyse` and `rootCause` must be set. If either is empty,
     block with "populate analyse/rootCause first".
   - `da_update_work_item(publicId, solution=..., analyse?=...,
     rootCause?=...)`.

7. **Transition**: `da_update_status(publicId, TESTING, force=true)`.

8. **Post checkpoint comment**:
   - `da_add_comment(publicId, "✅ QG PASSED: <summary>")` — or
     `"⛔ QG BLOCKED: <reasons>"` when blocked.
   - `da_test_summary(publicId)` for the record (code projects).

9. **Stop the timer**: `da_stop_timer(publicId)`.

10. **Report** to the user:
    - Commits registered: count + SHAs
    - QG verdict: PASS / BLOCK with reason list
    - Entity link check: PASS / WARN
    - Lesson check: N matches (severity breakdown)
    - Next: "awaiting human review → DONE" on PASS; actionable
      fix list on BLOCK.

## Boundaries

- Never force a transition to DONE from this skill — TESTING is the
  hand-off point. The user (or the `daedalai-test-gatekeeper` agent's
  downstream consumer) moves it to DONE.
- Never skip the lesson check, even on small changes.
- Never skip `/simplify` — it is MANDATORY per §8 step 4.
- Never declare QG PASSED if any BLOCKING finding exists.
- Never silently omit an empty `solution` — prompt the user to fill
  it before transitioning.

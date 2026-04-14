---
name: daedalai-start-work-item
description: "Start work on a specific DaedalAI work item: load full context, check blockers, present a 5-line summary, create the branch or worktree per project convention, and transition status to IN_PROGRESS. Use when the user wants to pick up an existing WI by key (e.g. 'start DAEDA-182', 'work on the auth bug', '/daedalai-start DAEDA-99')."
---

# Start Work Item

Invoked with `args` = a work item key (e.g. `DAEDA-182`) or publicId.
If neither is provided or the user says "what should I work on", fall
back to `da_what_should_i_work_on` and present the top suggestion.

## Workflow

1. **Resolve the WI**: if the arg is an itemKey, call
   `da_get_work_item` after finding the publicId via `da_search`
   (search by key). If arg is a UUID, use it directly.
2. **Load context**: `da_context_for_task(publicId)`. If the response
   exceeds the MCP size limit, fall back to `da_get_work_item` +
   `da_list_comments` + `da_list_attachments` and reconstruct.
3. **Check blockers**:
   - `da_list_work_item_links(publicId)` — any inbound `BLOCKS` link
     where the source is not yet DONE? → flag it.
   - Status must not already be DONE / CLOSED / BLOCKED. If BLOCKED,
     ask the user before resuming.
4. **Resolve git intent** (code projects only — `preferredWorkMethod`
   present on the project):
   - `da_get_project(projectCode)` → read `preferredWorkMethod` and
     `defaultBranch`.
   - Determine target repos from the composite build (check
     `settings.gradle.kts` for `includeBuild("../repo")` entries).
   - For BRANCH mode: `git checkout -b feature/<itemKey>-<slug>` in
     each target repo.
   - For WORKTREE mode: `git worktree add ../<repo>-<itemKey> -b
     feature/<itemKey>-<slug>`.
   - Non-code projects: skip git operations; the deliverable is a
     document, not a branch.
5. **Present a 5-line summary** to the user:
   - Line 1: `🎯 [type] [key]: [title]`
   - Line 2: `📍 [module(s)]  🏷️ [version]  🏃 [sprint]`
   - Line 3: `📊 [complexity / priority]  🌿 [branch or worktree path]`
   - Line 4: `📎 [linked WIs by type: BLOCKS X, RELATES Y]`
   - Line 5: `⚠️ [surfaced lessons/rules count] / ✅ hasSpec hasPlan status`
6. **Confirm-Then-Go check**: does the user want to start implementing
   now, or just pick up the WI and stop at TODO?
7. **Transition**:
   - Record branch on the WI: `da_update_work_item(publicId,
     branchName=..., branchType=BRANCH|WORKTREE)`.
   - Status move: `da_update_status(publicId, IN_PROGRESS, force=true)`.
   - Start timer: `da_start_timer(publicId)`.
8. **Surface pre-work artefacts** (call these in parallel, report
   the results, do NOT embed full content):
   - `da_list_lesson_rules(projectCode)` — enforced rules count
   - `da_list_documents(projectCode, type=LESSON)` — lesson count by
     module match
   - `da_list_documents(projectCode, type=HOWTO)` — HOWTO keys whose
     tags overlap the WI's module/screen/function names
9. **Return control** to the orchestrator or user. Further steps
   (spec, plan, implementation) happen in their own workflows.

## Return format

```
▶ Started <itemKey> — <one-line title>
Branch: <branch or worktree path>
Status: TODO → IN_PROGRESS
Timer: started
Lessons/HOWTOs surfaced: N rules, M lessons, K HOWTOs
Blockers: <none | list>
Next: <proposed action>
```

## Boundaries

- Never create a new WI in this skill — resolution only.
- Never skip entity linking verification (if module/screen/function
  are null on the WI, warn the user before starting work).
- Never auto-bypass a BLOCKS link without explicit user confirmation.
- Never transition beyond IN_PROGRESS in this skill — spec / plan /
  implementation / testing belong elsewhere.

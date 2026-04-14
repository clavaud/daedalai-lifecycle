---
name: daedalai-sprint-status
description: "Render a readable markdown summary of a DaedalAI sprint: WIs by status, blockers, at-risk items, completion percentage, burndown hint. Use when the user asks 'where are we on sprint X', 'sprint status', '/daedalai-sprint-status DAEDAL-104a', or wants an update suitable for a daily standup. Read-only — never modifies WIs or sprints."
---

# Sprint Status

Invoked with `args` = `<sprintLabel>` (e.g. `DAEDAL-104a`) or
`<sprintPublicId>`.

If neither is provided, default to the ACTIVE sprint on the current
project (via `da_list_sprints(projectCode, status="ACTIVE")` → take
the first).

## Workflow

1. **Resolve sprint**:
   - If label given: `da_list_sprints(projectCode)` + filter by
     label → take publicId.
   - If publicId given: use directly.
   - Else: current ACTIVE sprint on current project.

2. **Load sprint detail**: `da_sprint_status(sprintPublicId)`.
   This returns aggregated metrics. If the tool is unavailable,
   fall back to `da_get_sprint` + `da_list_work_items(sprintPublicId)`
   and compute metrics client-side.

3. **Gather WI detail**: `da_list_work_items(sprintPublicId)`.
   Group by status: TODO, SPECS, IN_PROGRESS, TESTING, DONE, BLOCKED,
   CLOSED.

4. **Identify at-risk** (no authoritative source — heuristic):
   - IN_PROGRESS for > (sprint age * 0.5) without a commit in the
     last 48h → at-risk.
   - TESTING for > 72h without progress → at-risk.
   - BLOCKED for > 24h without a resolution comment → at-risk.

5. **Render**:

```
# Sprint <label> — <name> (<status>)

Progress: <N_done>/<N_total> WIs done (<percent>%)
Period: <startDate> → <plannedEnd> (<days_remaining> days remaining)

## By Status
| Status | Count | Story Points |
|--------|-------|--------------|
| TODO | N | SP |
| IN_PROGRESS | N | SP |
| TESTING | N | SP |
| DONE | N | SP |
| BLOCKED | N | SP |

## At-risk (N)
- <key> <title> — <reason> (<age>)
- ...

## Recently shipped (last 48h)
- <key> <title>
- ...

## Blockers needing attention (N)
- <key> <title> — <blocker note>

## Burndown hint
Pace: <X> WIs/day. At current pace sprint completes in <Y> days
(<Z days early/late> vs planned end).
```

6. **Return** the rendered markdown to the user. Do not create
   comments on WIs, do not change status, do not assign anything.

## Boundaries

- Never mutate sprint, WI, or comment state.
- Never include WI descriptions in full — key + title only.
- Never guess missing data — if `da_sprint_status` returns partial
  metrics, show "(n/a)" rather than extrapolating.
- Never estimate story points; use only what the WIs carry.
- Never render for an ARCHIVED sprint without explicit user request
  — default to ACTIVE.

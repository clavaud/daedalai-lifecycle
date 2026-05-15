---
name: orchestrate
description: "Use when doing ANY work on a DaedalAI-managed project — code projects (bugs, features, fixes, refactors) AND non-code projects (research, documentation, audit studies). Covers plans, specs, tests, reviews, questions, resuming work, reporting progress, capturing decisions/lessons."
---

# DaedalAI Lifecycle Orchestrator

All DaedalAI-managed work flows through this skill — code projects, research
projects, audit projects alike. No work without a work item. No completion
without a quality gate (definition varies by project type). No mistake
without a lesson.

Sections §Git workflow, §Pre-flight, §8 Quality Gate assume a code project
with Gradle/Flyway-style tooling. Non-code projects (research, documentation,
audit) skip those sections and follow §Non-code workflows instead. Everything
else — project resolution, duplicate check, entity linking, confirm-then-go,
time logging, document types, lesson capture, retroactive mode — applies
universally.

## 0. Component Map (where content belongs)

Before adding content to the plugin or the project, decide **which layer**
owns it. Each layer has a different lifecycle, audience, and surface.

| Layer | Lives in | Audience | Loaded when | Changes how often |
|-------|----------|----------|-------------|-------------------|
| **Skill (this file)** | `skills/orchestrate/SKILL.md` | Claude Code (all sessions) | Session start | Rarely (process changes) |
| **Other skills** | `skills/<name>/SKILL.md` | Claude Code (on skill invoke) | On-demand via `Skill` tool | Per workflow addition |
| **Slash commands** | `commands/<name>.md` | User (typing `/<name>`) | On command invoke | Per UX addition |
| **Agents** | `agents/<name>.md` | Claude Code (on dispatch) | On Agent dispatch | Per specialist addition |
| **Enforced Lesson Rules** | DaedalAI `LessonRuleEntity` (via `da_create_lesson`) | Every plan + every QG checkpoint | Per-WI via `da_list_lesson_rules(projectCode, enabled=true)` at §7 plan-time (MANDATORY) + automatically server-side at `da_checkpoint(QUALITY_GATE)` | Per detected anti-pattern |
| **LESSON documents** (advisory — not rule-backed) | DaedalAI (`da_create_document(type=LESSON)`) | On-demand per-need | Call `da_list_documents(type=LESSON, tags=…)` or `da_search(documentType=LESSON)` explicitly — NOT a mandatory per-WI pre-plan step. The fat unfiltered pull used to truncate; load it scoped or not at all. | Per reusable learning |
| **HOWTO documents** | DaedalAI (`da_create_document(type=HOWTO)`) | Pre-plan surfacing | Pre-plan via `da_search_knowledge(query, topK=5, entityTypes=[DOCUMENT])` — BM25+vector hybrid; the corpus also covers WORK_ITEM and COMMENT, so scope to DOCUMENT here to keep the advisory-doc surfacing; falls back to `da_list_documents(type=HOWTO, tags=…)` for curated/tag-driven discovery | Per canonical recipe |
| **DECISION documents** | DaedalAI (`da_create_document(type=DECISION)`) | Architectural history | On-demand via `da_list_documents(type=DECISION)` | Per architectural choice |
| **Pre-edit hook** | `hooks/*.json` + hook script | Claude Code (before edit) | Before every Edit/Write/MultiEdit tool call | Rarely (policy changes) |
| **CLAUDE.md** | Repo root (e.g. `daedalai-backend/CLAUDE.md`); canonical version mirrored as a `CLAUDE_MD` DaedalAI document — one active row per project (`uk_da_documents_claude_md_singleton`); sync via `/daedalai-sync-claude-md` (DAEDA-274) | Claude Code (auto-loaded per-repo) | Session start in that repo; drift detected once per session by §1 | Per convention change |
| **Hooks config** | `.claude-plugin/hooks.json` | Claude Code runtime | Plugin install | Rarely |

**Routing rule**: Before adding content, ask "which layer?" — do NOT append
technical gotchas to this SKILL.md. Anti-patterns with a regex trigger →
`da_create_lesson` (enforced rule). Advisory patterns without a trigger →
`da_create_document(type=LESSON)`. Canonical procedural recipes →
`da_create_document(type=HOWTO)` with tags. Repo-wide conventions humans
must also see → that repo's `CLAUDE.md`. Specialist roles → `agents/`.
Reusable workflows → a dedicated `skills/<name>/SKILL.md`. **This file
holds only universal orchestration.**

## 1. Project Resolution (once per session)

da_list_projects → match current repo against localRepoPath/repositoryUrl →
da_get_project(projectCode) → cache these for the session:
- **projectCode** — used in all subsequent MCP calls
- **preferredWorkMethod** — BRANCH or WORKTREE (controls git workflow)
- **prIntegrationEnabled** — true = create PR after QG, false = skip PR
- **defaultBranch** — base branch for PRs and diffs

Then da_list_modules(projectCode) for module awareness.
If no match → da_ask("Which DaedalAI project is this repo?")

### CLAUDE.md drift check (per session, after project resolution)

Once the project is resolved, perform exactly ONE
`da_check_claude_md_drift(projectCode)` call. Cache the result under a
per-session key `claudeMdDriftChecked:{projectCode}` so subsequent WIs
in the same session do NOT re-call. The probe is cheap (~5 ms) but the
nudge would become noise if it fired on every Confirm-Then-Go.

The probe returns `ClaudeMdDriftResult` with `drift ∈ {NONE, LOCAL_NEWER,
REMOTE_NEWER, DIVERGED, LOCAL_MISSING, REMOTE_MISSING}`. Cache the full
result, not just the state — the nudge format wants both hashes.

**Drift-state handling**:

| State | Orchestrate behaviour |
|-------|----------------------|
| `NONE` | Nothing to do. No nudge. |
| `LOCAL_NEWER` / `REMOTE_NEWER` / `DIVERGED` / `LOCAL_MISSING` | Surface the 🟡 nudge banner (see §6) in every Confirm-Then-Go for the rest of the session, until the user runs `/daedalai-sync-claude-md` and the cache is invalidated. |
| `REMOTE_MISSING` | **Do NOT auto-nudge.** Empty corpus is "nobody pushed yet", not a divergence the user broke. They can invoke `/daedalai-sync-claude-md` explicitly to seed if they want. |

**Cache invalidation**: after the user runs `/daedalai-sync-claude-md`
(or `da_init_or_update_project` with a CLAUDE.md flag) within the
session, invalidate `claudeMdDriftChecked:{projectCode}` so the next WI
re-probes and sees the resolved state.

**Failure tolerance**: if the probe call fails (network, MCP down, etc.),
log a single-line warning and continue WITHOUT nudging. CLAUDE.md drift
is operational hygiene, not a hard gate.

**No automatic writes from orchestrate.** Drift is reported, never
resolved silently. The skill is the resolution surface.

## 2. Duplicate & Related Check (before creating)

Before creating any work item:
1. da_search(keywords) → broad lexical match across entities (Typesense BM25)
2. da_search_knowledge(query=`<wi-title-and-keywords>`, entityTypes=[WORK_ITEM,COMMENT], topK=10)
   → semantic match against prior WI narrative + comment threads. Catches
   "we already discussed this in DAEDA-XYZ comments" cases that BM25 misses
   when wording differs. Same-WI fold collapses multiple chunk hits into
   one entry with `relatedChunks` populated.
3. da_find_related_work(screenId/functionId) → open items in same area (graph adjacency)
4. If matches: "Found existing WIs in this area: [list — show fold count and
   parent itemKey for semantic hits, e.g. 'DAEDA-359 — 3 chunks match (title +
   comment by alex@... 2026-04-21)']. Same, related, or new?"
   - Same → resume existing WI from current status
   - Related → create new + RELATES_TO link
   - New → create fresh

## 3. Intent Detection

| Intent | Triggers | Workflow |
|--------|----------|----------|
| Bug | "bug","broken","error","crash","doesn't work","regression" | BUG → analyze → route by complexity |
| Feature | "build","add","create","implement","new feature" | FEATURE → brainstorm → spec → plan → implement |
| Work item | "fix WI-xx","work on #xx",WI reference | da_context_for_task → assess → route |
| Plan | "plan","design","architect" | PLAN document → link to WI |
| Spec | "spec","brainstorm","requirements" | SPEC document → link to WI |
| Test | "test","coverage","write tests" | Analyze gaps → write/update → run → import |
| Review | "review","quality","simplify" | Quality gate pipeline |
| Question | "why","how does","explain","what is" | da_search + da_context_for_task → answer |
| Resume | "continue","where was I","what's next" | da_what_should_i_work_on + IN_PROGRESS items |

**`da_context_for_task` size limit**: may exceed MCP response size on umbrellas
with many comments/attachments (observed 260KB+ on DAEDA-096). Fallback: call
`da_get_work_item` + `da_list_comments` + `da_list_attachments` separately and
reconstruct context client-side.

Skip logic:
- Bug TRIVIAL/NORMAL → skip spec
- TRIVIAL → skip spec, plan, checkpoint
- "Write tests for X" → skip spec/plan, jump to test+QG
- "Plan X" → stop after plan
- Question → no WI, no workflow
- User-provided spec/plan → **still run brainstorm+spec phases**.
  Review the spec critically: flag gaps, ask clarifying questions,
  suggest improvements. The user's spec is a starting point, not
  a rubber-stamp. Then Confirm-Then-Go as normal (see §6).

**A user providing a spec means "here's my thinking — validate it."**
**A user saying "proceed" means "go build it now."**
**These are two different signals. Never conflate them.**

Status transition handling (design-skipped phases and state machine):
- BUG TRIVIAL/NORMAL → always pass `force: true` (spec/plan skipped by design)
- IMPROVEMENT / TASK / FEATURE that deliberately skipped spec (refocused WIs,
  small infra hygiene, cross-cutting patches) → pass `force: true` on transitions
  beyond TODO. A `hasSpec=false` warning with `updated: true` is informational,
  not a failure — the transition landed.
- COMPLEX work where spec/plan are load-bearing → do NOT auto-force, populate
  spec/plan first.

**`force: true` overrides warnings, NOT state-machine hard blocks.** The
`da_update_status` response has two fields: `warnings` (overridable with force)
and `blocks` (not overridable). Trying to jump `TODO → DONE` directly returns
a `blocks: ["Cannot move to DONE without going through REVIEW first"]` error
that `force: true` can't fix. Step through states sequentially (`TODO →
IN_PROGRESS → TESTING → DONE`), each with `force: true`. You can batch the
transitions in a single parallel tool-call message.

## 3a. Delegating to Server-Side Prompts and Resources

DaedalAI's MCP server exposes canonical golden-path sequences as **Prompts**
and reference content as **Resources**. This skill DELEGATES to them when
reachable and falls back to the inline content in later sections when it
isn't. The principle (DECISION D9b): one source of truth, server-side;
the skill is the behavioural wrapper.

### Golden-path prompts (server-side)

When intent matches one of these, prefer `prompts/get(name, args)` over
the inline §7 sequence. Same authoritative content, maintained once.

| Intent | Prompt name | Args |
|--------|-------------|------|
| Create a WI from a user ask | `create-work-item` | `intent`, `projectCode?` |
| Upload a file to an entity | `upload-file` | `entityType`, `entityPublicId` |
| Comment on a WI | `comment` | `workItemKey` |
| Move WI to a sprint | `move-to-sprint` | `workItemKey`, `sprintLabel?` |
| Investigate around a screen/function | `investigate-related-work` | `entityType`, `entityCode` |
| Load full WI context | `investigate-task-context` | `workItemKey` |
| Draft a SPEC | `create-spec` | `workItemKey` |
| Draft a PLAN | `create-plan` | `workItemKey` |

### Reference resources (server-side)

| Purpose | URI |
|---------|-----|
| Identifier format glossary (PUBLIC_ID vs ITEM_KEY etc.) | `daedalai://glossary/identifiers` |
| Full MCP tool catalog with metadata | `daedalai://catalog/tools` |
| Chat-safe recommended tool subset | `daedalai://catalog/recommended` |
| Per-tool decision metadata | `daedalai://tools/{name}/meta` |
| Project digest | `daedalai://projects/{projectCode}` |
| All accessible projects | `daedalai://projects` |
| Document type catalog | `daedalai://catalog/document-types` |
| Per-type markdown template | `daedalai://templates/{type}` |
| Tag vocabulary across documents + WIs | `daedalai://catalog/tags` |

### Capability detection (once per session, DECISION D9a)

1. Call `prompts/list` once at session start. Cache the result.
2. If the list includes the golden-path prompts → delegation is available.
3. Empty / errors / unsupported → fall back to the tool-call layer.
4. Tool-call layer also unreachable → fall back to inline §7 content.

### Fallback chain for sequence execution

| Tier | Mechanism | Use when |
|------|-----------|----------|
| 1 — **Prompts** | `prompts/get(name, args)` | Primary. Client supports MCP Prompts. |
| 2 — **Tool fallback** | `da_workflow_guide(intent, arg1, arg2)` | Client doesn't support Prompts, or `prompts/list` came back empty (DAEDA-210). |
| 3 — **Inline §7** | Follow the §7 table directly | Tool-call fallback also unreachable (full MCP down). |

### Delegation invariant

- **Never inline a sequence the server authors.** When adding a new phase
  that has a server-side prompt counterpart, link to the prompt rather
  than copying its body here.
- **Never let the skill and the prompt drift.** Cache only the probe
  result, never the sequence content — re-fetch each time.
- **§7 stays** as the offline fallback. Future tightening: shrink §7 to
  essentials once delegation is proven reliable across client types.

## 4. Entity Linking (MANDATORY)

Every work item MUST link to:
- **Module**: da_list_modules → match → set modulePublicId
- **Screens**: da_list_screens → match → link screenPublicId
- **Functions**: da_list_functions → match → link functionPublicId
- **Version**: `da_list_app_versions(projectCode)` → suggest setting both:
  - `affectedVersionPublicId` — the version where the bug was found / feature was requested (BUG/IMPROVEMENT)
  - `targetVersionPublicId` — the version where the fix/feature will ship (all types)
  - Neither is mandatory, but suggest them when version context is clear. Versions are also linked to sprints.
- **Sprint**: `da_list_sprints(projectCode, status="ACTIVE")` → find the active sprint → `da_assign_to_sprint(wiPublicId, sprintPublicId)` after WI creation.
  - Sprint lifecycle: PLANNED → ACTIVE → CLOSED → ARCHIVED
  - **Auto-start**: if the active sprint has status PLANNED when you start work on a WI assigned to it, call `da_start_sprint(sprintPublicId)` to move it to ACTIVE before proceeding
  - **Stop on completion**: when the last WI in a sprint is DONE, suggest `da_stop_sprint(sprintPublicId)` to close the sprint
  - Use `da_create_sprint` if no sprint exists for the current work period

### Entity Link Invariant

Every WI must have `modulePublicId` + `screenPublicId` + `functionPublicId`.
- Resolve ALL THREE before calling `da_create_work_item` — pass them in the create call, not a follow-up
- If the response shows any as null → `da_update_work_item` immediately
- Before any `da_update_status` beyond TODO → `da_get_work_item` to verify all three are set
- Search with `da_list_screens(projectCode)` / `da_list_functions(projectCode)` if unsure

### Exceptions (user must explicitly confirm skip)
- Infra/CI/tooling tasks with no UI or API surface
- Plugin/skill modifications
- Cross-cutting changes that touch framework modules (no single screen)

If no screen/function exists → analyze codebase → propose creation with
platform/route/priority → create on approval → link.

## 5. Complexity Assessment

- **TRIVIAL**: single file, no schema, no new entity (typo, config, i18n)
- **NORMAL**: single module, ≤5 files, no schema change
- **COMPLEX**: multi-module, schema change, new entity, architectural

## 6. Confirm-Then-Go (ALWAYS ASK)

**NEVER jump straight to implementation.** After creating the WI and
presenting the summary, ALWAYS ask the user whether to proceed.
Creating the WI is fine — implementing without approval is not.

**Tool-choice self-check (DAEDA-564)**: the summary MUST declare which
MCP tools you intend to use for the upcoming work, before approval. The
hook in `hooks/check-prefer-mcp.sh` (DAEDA-563) catches drift at action
time — this section catches it at plan time, which is cheaper. State
each non-trivial operation and the tool you'll use: symbol-aware ops
(rename, find refs, move) → Serena or IntelliJ MCP; cross-file
structural search → codebase-memory `search_graph` / `trace_path`; bulk
edits (>5 similar changes) → Morphllm or IntelliJ; library docs lookup
→ Context7; browser validation → Playwright. If a planned MCP isn't
installed (the §3a capability detector + the hook's `mcp_installed`
probe both surface this), pick the next-best tool and note the
substitution, OR call out the missing MCP in the summary so the user
can decide whether to install it before proceeding. Single-file Read +
Edit operations don't need a substitution note — just say "single-file
Edit — no MCP needed".

**CLAUDE.md drift nudge (DAEDA-274)**: when §1's cached
`claudeMdDriftChecked:{projectCode}` shows `LOCAL_NEWER` /
`REMOTE_NEWER` / `DIVERGED` / `LOCAL_MISSING`, prepend a session-level
banner above the WI summary block. The banner persists in every
Confirm-Then-Go until the user runs `/daedalai-sync-claude-md` and
the cache is invalidated. `NONE` and `REMOTE_MISSING` produce no
banner.

Banner format:
```
🟡 CLAUDE.md drift detected ({localHash[0:7]} ↔ {remoteHash[0:7]}, {drift})
   — run /daedalai-sync-claude-md to resolve before relying on conventions.
```

For `LOCAL_MISSING` / `REMOTE_MISSING` (one hash is null), substitute
the absent side with `—` (em-dash).

For NORMAL/COMPLEX, present before executing:

```
{🟡 CLAUDE.md drift banner — only when §1 cached state warrants it}

[emoji] [Type]: [title]
📍 Module: [module]
📱 Screen: [screens]  ⚙️ Functions: [functions]
🏷️ Version: [version]  🏃 Sprint: [sprint]
🌿 Branch: [branch to create/checkout]
📎 Related: [linked WIs with relationship type]
📊 Complexity: [level]
🪧 Lesson rules in play:
  - [severity] {rule-id-prefix} — {reason}
  - …
  (or "none" if da_list_lesson_rules returned empty)
🔧 Planned MCP tools:
  - {operation 1} → {tool} (e.g. "find AgentConversation callers → Serena find_referencing_symbols")
  - {operation 2} → {tool} (e.g. "rename Foo.java → Bar.java + update imports → IntelliJ rename_refactoring")
  - …
  (or "single-file Edit — no MCP needed" for trivial work)

Proposed workflow: [numbered steps]
(Bugs: evidence, analyse, rootCause, solution populated during workflow)

Fix now, or just track?
```

TRIVIAL: announce briefly but still ask "Fix now?" — do not auto-implement.
TRIVIAL still includes the `🔧 Planned MCP tools:` line, even if the only
entry is `single-file Edit — no MCP needed`. The line is mandatory; the
content can be one entry.

**Creating WI = triage. Implementing = separate approval.**
The user may want to just track, defer, delegate, or fix selectively.

## 7. Phase Actions

> **Prefer §3a delegation when available.** The table below is the offline
> fallback — when MCP Prompts are reachable, `prompts/get("create-work-item"
> | "create-spec" | "create-plan" | "upload-file" | "comment" | "move-to-sprint"
> | "investigate-related-work" | "investigate-task-context", args)` is the
> authoritative sequence for each corresponding phase. This local copy
> exists for MCP-unreachable scenarios and for phases without a matching
> prompt (Pre-flight, Test+QG, Completion).

| Phase | DaedalAI Calls | Status | Checkboxes |
|-------|---------------|--------|------------|
| Create | da_create_work_item + links + version + da_assign_to_sprint + branch | TODO | — |
| Spec | da_create_document(SPEC) → da_attach to WI | SPECS | hasSpec ✓ |
| Lessons & HOWTOs | **MANDATORY**: `da_list_lesson_rules(projectCode, enabled=true)` → enforced rules with full body. **PRIMARY**: `da_search_knowledge(query, topK=5, entityTypes?, documentTypes?)` where query = WI title + affected module/screen/function names → ranked section-level chunks across **all DOCUMENT types + WORK_ITEM + COMMENT** with recency weighting and same-WI fold. Pass `entityTypes=[DOCUMENT]` to keep the advisory-doc-only behaviour of v1; pass `entityTypes=[WORK_ITEM,COMMENT]` for prior-work / dup-detection sweeps; omit for broad context. **Fallback (tag-matched)**: `da_list_documents(projectCode, type=HOWTO)` + `da_list_documents(projectCode, type=CODE_SNIPPET)` for curated tag-driven discovery when search returns empty. Advisory rule-less `LESSON` docs surface once at SessionStart, not per-WI. | pre-Plan | — |
| Plan | da_create_document(PLAN) → da_attach to WI | IN_PROGRESS | hasPlan ✓ |
| Pre-flight | Bash/grep checks derived from surfaced lessons — migration version scan, Envers audit mirror, baseline build, service convention audit. **Gates, not suggestions.** | pre-Implement | — |
| Analyze (bugs) | da_update_work_item → set analyse + rootCause | IN_PROGRESS | — |
| Implement | da_log_progress at milestones (orchestrator-measured — see §7a), da_add_commit after each commit | IN_PROGRESS | isCommitted ✓ |
| Fix (bugs) | da_update_work_item → set rootCause + solution, da_add_commit | IN_PROGRESS | isCommitted ✓ |
| Test+QG | Quality gate pipeline | TESTING | hasTests ✓, simplifyReuse ✓, simplifyQuality ✓, simplifyEfficiency ✓ |
| Completion | da_update_work_item → set solution (ALL types), verify mandatory fields | pre-DONE | — |
| Done | da_update_status(DONE) | DONE | hasDocs ✓ (if applicable), isMerged ✓ (after merge/PR) |

Update checkboxes via da_update_work_item at each phase completion.

**Pre-flight discipline (MANDATORY before dispatching implementation agents — code projects only):**
Pre-flight checks are bash/grep commands derived from surfaced lessons and
HOWTOs. Gates, not suggestions. Run them, report findings to the user,
stop on failure. Every agent dispatch prompt MUST list the blocking
pre-flight checks as explicit pre-conditions — "run these N checks before
touching code, report results, stop if any fails."

**Where the checks live**: not in this skill. Each code project owns a
HOWTO tagged `pre-flight` enumerating the concrete bash/grep commands
and failure criteria. Surface it at plan-time via
`da_list_documents(projectCode, type=HOWTO, tags="pre-flight")` and
include the matching steps verbatim in the agent dispatch prompt.
Human-readable mirrors of the same checks typically live in the repo's
`CLAUDE.md`. If no `pre-flight`-tagged HOWTO exists for the project,
write one from the lessons surfaced at §7 before dispatching — this is
the correct time to author it, not after the first agent failure.

Non-code projects: skip this section entirely.

**Plan reality-check before implementing (code projects only):**
Plans drift on load-bearing stack details (language, build/migration
framework, test framework, DI style) when written without touching the
actual target module. Verify these against reality before dispatch, push
a `da_update_document` v2 if you find errors. Full procedure in the
global LESSON tagged `plan,stack-assumptions` — surfaced via the Lesson
& HOWTO pass in §7 above.

**NEVER dispatch an implementation agent (worktree or otherwise) without
prior Confirm-Then-Go approval in the same conversation.** Creating the
WI at TODO status is fine — but moving to IN_PROGRESS and starting code
work requires the user to say "proceed", "yes", "go", or equivalent.
**WI stays at TODO until the user approves.**

**Lesson rules + HOWTO surfacing (MANDATORY before plan and implementation):**

The load-bearing call is **one call, small payload, always completes**:

1. **`da_list_lesson_rules(projectCode, enabled=true)`** → enforced regex rules
   for this project **plus global rules**. Response carries `severity`,
   `triggerPattern`, `reason`, and the full `documentBody` of the backing
   LESSON document — no second call needed to read the rationale. Typical
   payload is a few KB; MCP truncation is not a concern.

   **Confirm-Then-Go requirement**: the summary MUST include a
   `🪧 Lesson rules in play:` block. Format per rule:
   `- [severity] {id-prefix} — {reason}`. If the filtered list is empty,
   write `🪧 Lesson rules in play: none`. Boilerplate like
   `⚠️ Lessons in this area: …` is insufficient — the rule IDs must appear
   verbatim so the reader can catch a stale/irrelevant match.

   **Rationale**: DAEDA-342 / DAEDA-350 / DAEDA-351 was a triple-repeat of
   the same i18n-prefix bug while a BLOCKING rule with `triggerCount = 0`
   sat ignored on the server. The cause: §7 previously also bundled a fat
   `da_list_documents(type=LESSON)` call that kept hitting the ~100 KB MCP
   response limit, and when it failed I abandoned the rule-listing call
   too. Rules are now on their own step so nothing can hide them.

2. **Semantic knowledge search**:
   `da_search_knowledge(query, topK=5, entityTypes?, documentTypes?)` where
   `query` is built from the WI's title plus affected module/screen/function
   names — e.g. `"<WI title> <module names> <screen names> <function names>"`.
   Returns ranked section-level chunks (BM25 + vector RRF, recency-weighted,
   same-WI folded) across **all DOCUMENT types + WORK_ITEM (5 narrative
   fields chunked) + COMMENT (with parent-WI context denormalized)**.
   Each hit carries `entityType`, `documentType`, `documentTitle`,
   `sectionTitle`, `sectionPath`, `tags`, `score`, `vectorDistance`,
   `snippet`, `itemKey` (for WI/COMMENT hits),
   `sourceTitle`/`sourceStatus`/`sourceWorkItemType` (parent context),
   `relatedChunks` (other folded chunks under the same parent), and
   `documentPublicId` so the agent can `da_get_document(publicId)` /
   `da_get_work_item(itemKey)` for full text on demand.

   **Filter strategy**:
   - For the *advisory-doc surfacing* this step originally served (find
     LESSON / HOWTO / DECISION / CODE_SNIPPET to inform the plan),
     pass `entityTypes=[DOCUMENT]`. Optionally narrow further with
     `documentTypes=[LESSON,HOWTO,CODE_SNIPPET,DECISION]`.
   - For *prior-work / dup-detection sweeps* (rare in this step but
     useful when the WI looks similar to an existing one), pass
     `entityTypes=[WORK_ITEM,COMMENT]`. The §2 duplicate check already
     does this — don't double-call.
   - When in doubt, omit the filter and let recency weighting + fold
     do the ranking work.

   **When to skip the call**: when the knowledge index is genuinely
   irrelevant to the WI (e.g. infra/CI/tooling tasks with no domain
   touch-point). The call is cheap (1 hybrid search, ~50–200 ms) — when
   in doubt, run it.

   **When to fall back to step 3 (tag-matched listing)**: when
   `da_search_knowledge` returns empty for a query you'd expect to match,
   OR when the index is being rebuilt (the operator can check
   `knowledge_index_metadata` collection presence to confirm). The
   tag-matched fallback below stays available indefinitely.

3. **Tag-matched HOWTOs** (fallback / curated discovery, non-blocking):
   `da_list_documents(projectCode, type=HOWTO)` → filter by tag overlap
   with affected modules/screens/functions. Example: `admin,searchlayout,vaadin`
   for a new admin list screen WI. Useful when the search-result polarity
   is too high (semantic recall picked up tangentially-related content)
   or for discovering canonical recipes by tag rather than by query.

4. **Tag-matched CODE_SNIPPETs** (fallback / curated discovery, non-blocking):
   `da_list_documents(projectCode, type=CODE_SNIPPET)` → same tag-overlap
   rule. Snippets follow `language:X`, `framework:Y-Z`, `pattern:W`,
   `source:V` (see `daedalai-capture-snippet` skill). A WI touching a
   Java+Spring-Boot+search-layout screen matches snippets tagged
   `language:java framework:spring-boot-4 pattern:search-layout`.

5. Include the surfaced rules + `da_search_knowledge` top hits + matching
   HOWTOs + matching CODE_SNIPPETs in the PLAN document AND in every
   agent dispatch prompt — snippets and section chunks give agents
   concrete starting points they can copy-adapt instead of re-deriving.

**What happened to the advisory `LESSON` documents?**
Rule-less LESSON documents (narrative guidance that doesn't have a regex
trigger) are **not** pulled as a mandatory per-WI step anymore — that was
the fat `da_list_documents(type=LESSON)` call that kept hitting the MCP
~100 KB response limit and blocking the whole surfacing flow. Read them
on demand when a WI is genuinely about a process topic:
`da_list_documents(type=LESSON, tags=…)` with specific tags, or
`da_search(term=…, documentType=LESSON)` for a fuzzy keyword. The
SessionStart hook reminds you this path exists but does not pre-fetch
content — fetching is scoped per-need.

**Note on QG**: `da_checkpoint(QUALITY_GATE)` automatically runs
`da_check_lessons` server-side against the diff and appends match results
to the checkpoint response — no explicit call needed at QG time. This is
the second enforcement gate; the plan-time surface above is the first.

**MCP tool guidance in agent prompts (MANDATORY for code projects):**
Every agent dispatch prompt MUST include tool selection guidance:
- Bulk edits (>5 similar changes) → use Morphllm or IntelliJ MCP, NOT repeated Edit calls
- Symbol operations (rename, find refs) → use Serena or IntelliJ MCP
- Code structure analysis → use Serena get_symbols_overview
- Search & replace across files → use IntelliJ search_in_files_by_regex

Project-specific conventions (e.g. "COPY new module configs from the most
similar existing module") belong in the repo's CLAUDE.md and surface
automatically to agents working in that repo — do not inline them here.

**Mandatory fields before DONE — DO NOT SKIP:**

| Field | BUG | FEATURE | IMPROVEMENT | TASK |
|-------|-----|---------|-------------|------|
| `analyse` | **REQUIRED** | — | — | — |
| `rootCause` | **REQUIRED** | — | — | — |
| `solution` | **REQUIRED** | **REQUIRED** | **REQUIRED** | **REQUIRED** |

- **BUG**: `analyse` (investigation notes) and `rootCause` must be set during Analyze/Fix phases. `solution` describes the fix applied.
- **ALL types**: `solution` must be set before moving to DONE. It summarizes what was changed and why. A WI with empty `solution` is not DONE.
- **Self-check**: Before calling `da_update_status(DONE)`, call `da_get_work_item` and verify required fields are populated. If empty, populate them first via `da_update_work_item`.

## 7a. Time Logging (universal — applies to all project types)

DaedalAI tracks time spent on work items. Time logging applies to both code
and non-code projects.

**Live timer** (preferred for long synchronous sessions):
- `da_start_timer(workItemPublicId)` — typically at the `IN_PROGRESS` transition. Only one timer runs at a time per user; starting a new one stops the previous.
- `da_stop_timer(workItemPublicId)` — typically at `TESTING` or at a session checkpoint. Emits a `MANUAL`-source time log entry.

**Retroactive log** (when timer wasn't running):
- `da_log_time(workItemPublicId, duration="2h30m", description?)` — accepts `90` (minutes), `1.5h`, `2h30m`, `1d2h`. Source = `MANUAL`.

**Agent-dispatched milestones** — orchestrator measures, subagent does NOT:

1. Before dispatching an `Agent` tool call, capture `startTs=$(date +%s)` via Bash.
2. The subagent returns a completion summary only. It MUST NOT call `da_log_progress`
   and MUST NOT pass or estimate `durationMinutes`. Subagents have no persistent
   wall-clock awareness across their own tool calls and will fall back to
   round-number guesses (typical: "20 min" regardless of real elapsed time).
3. When the subagent returns, compute via Bash:
   `endTs=$(date +%s)` → `durationMinutes = max(1, ceil((endTs - startTs) / 60))`.
   The `max(1, …)` guard floors sub-minute returns at 1 instead of 0 (server
   accepts 0 but it reads as "no time spent" — wrong signal for work that did happen).
4. The orchestrator then calls `da_log_progress(publicId, comment=<subagent summary>,
   durationMinutes, agentTaskId=<dispatch id>)` itself. Auto-creates an
   `AGENT`-source time log entry. Dedup by `agentTaskId` (safe to retry).

**Hard rule**: never invent or estimate `durationMinutes` on AGENT-sourced time logs.
Measure with the orchestrator's clock, or omit the field entirely. Source = `AGENT`;
dedup stays via `agentTaskId`.

**Review**:
- `da_generate_timesheet(from, to, mode=SUMMARY|DETAILED)` — period summary.
- `da_list_time_logs(workItemPublicId)` — raw entries for one WI.

**WI fields populated by time logging**:
- `timeLogCount` — total entries
- `totalTimeSpentMinutes` — sum across all entries
- `startedAt` — first time logged (via any method)
- `completedAt` — set at `DONE` transition

**When in doubt**: start a timer at `IN_PROGRESS` and stop at `TESTING`. For
work broken across sessions, `da_stop_timer` on checkpoint, `da_start_timer`
on resume. Lost session? `da_log_time` retroactively with a rough duration.

Git workflow (code projects only — plugin orchestrates Bash + MCP):

> **Apply this section only if the project is a code project.** Detect via:
> `project.preferredWorkMethod` is set, `project.defaultBranch` is set, or
> the task touches source files under a VCS-tracked tree. For non-code
> projects (research, documentation, audit studies), skip to
> §Non-code workflows below.

**Start work:**
1. Read preferredWorkMethod from `da_get_project(projectCode)`
2. Determine target repos — check `settings.gradle.kts` for `includeBuild("../repo")`
   entries to identify all repos involved in the composite build.
   The working directory (umbrella) is NOT the code repo — sub-repos are siblings.

**BRANCH mode:**
- For each target repo: `cd <repo> && git checkout -b feature/{itemKey}-{desc}`
- da_update_work_item(branchName, branchType=BRANCH) + da_update_status(IN_PROGRESS)

**WORKTREE mode (preferred for parallel work):**
- For each target repo that needs changes:
  ```bash
  cd <repo> && git worktree add ../<repo>-{itemKey} -b feature/{itemKey}-{desc}
  ```
  This creates `../<repo>-<itemKey>/` alongside `../<repo>/`
- **NEVER switch branches on the main working directory** — other WIs may be in flight
- When dispatching an Agent: tell it the worktree paths explicitly, do NOT use
  `isolation: "worktree"` (that only isolates the umbrella, not sub-repos)
- da_update_work_item(branchName, branchType=WORKTREE) + da_update_status(IN_PROGRESS)

**Composite build awareness:**
- Changes may span multiple repos (e.g. framework + backend)
- Each repo gets its own branch with the same name
- Each repo gets its own worktree if using WORKTREE mode
- Agent prompts must include ALL worktree paths and which files go where
- Commits happen per-repo (each repo has its own git history)

**Resume:** da_get_work_item → check branchName → for WORKTREE: verify worktree
exists (`git worktree list`), recreate if pruned. For BRANCH: checkout branch.

**Finish work:**
1. For each repo with changes: `git log --oneline main..HEAD` → collect commits (Bash)
2. da_add_commit for each commit (MCP, deduplicates by SHA)
3. da_update_work_item(isCommitted: true) (MCP)
4. Entity link self-check (see §4 Gate) — fix before proceeding
5. da_update_status(TESTING) (MCP)
6. Run quality gate pipeline

**Merge main forward first (before merging feature → main):**
Between a green QG and merging back to main, merge main *into* the feature
branch first, rebuild, and re-run the QG pipeline. This catches pre-existing
breakage on main you don't own but can't merge past, and surfaces
out-of-order migrations from sibling feature branches that landed while
yours was in flight.

```bash
cd <repo>
git fetch origin
git merge origin/main   # or rebase — project convention decides
# resolve conflicts if any, then:
./gradlew build         # or equivalent — full check task
```

If the build or tests break after the merge-forward, fix in the feature
branch before merging to main. Do NOT merge and "fix on main after" —
that's how main stays red.

**Worktree cleanup:** After merge, remove worktrees:
```bash
cd <repo> && git worktree remove ../<repo>-{itemKey}
```

**NEVER leave a committed WI at IN_PROGRESS.** After da_add_commit,
steps 3–6 are atomic — complete them in the same response.

**Done:** if prIntegrationEnabled → create PR (see PR integration below).
If NOT prIntegrationEnabled → skip PR, work stays on branch/worktree for manual merge.

## 7b. Non-Code Workflows (research, documentation, audit projects)

For DaedalAI-managed projects without a code artefact — research,
documentation, audit studies, compliance reviews, knowledge-base curation,
and similar — the orchestration is document-first: the deliverable *is*
the attached document, not a commit.

**Status flow**: `TODO → IN_PROGRESS → TESTING → DONE`
(`TESTING` = peer review stage; `DONE` after reviewer approval.)

**Working surface**:
- No composite build, no worktrees — plain branches or direct edits on
  main if the project convention allows (check `project.preferredWorkMethod`
  and `project.defaultBranch`; absent or null signals non-code).
- Deliverable lives as a DaedalAI document (SPEC / TECHNICAL_DOCUMENTATION /
  GENERAL / RELEASE_NOTE depending on purpose) attached to the WI, not as
  a file on disk under VCS.

**Phase actions (adapted from §7 table)**:
- `Create`: `da_create_work_item` + entity linking (modules/screens/functions
  may be absent; use the §4 exception path for research-only work).
- `Spec` (when the SPEC *is* the deliverable): `da_create_document(type=SPEC)`
  → `da_attach` → `hasSpec=true` → stay in `IN_PROGRESS` while drafting.
- `Implement`: edit the document iteratively via
  `da_update_document(publicId, changeSummary, content)` — each update
  creates a new version, preserving history. `da_log_progress` at milestones
  (orchestrator-measured — see §7a rule).
- `Test+QG`: see below.

**Quality Gate (non-code definition)**:
1. **Peer review** — a named reviewer reads the final document version.
   Record their feedback and sign-off as comments on the WI.
2. **Source citations verified** — every factual claim in the document
   traces to a source. Broken links, unchecked references, and unsourced
   assertions fail the gate.
3. **Scope alignment** — the document answers the WI's original question.
   If the investigation pivoted, either update the WI description + SPEC to
   match, or split out a follow-up WI.
4. **No automated tooling** — no ArchUnit, SpotBugs, Gradle build, test
   suite, or `/simplify`. Markdown link-checking or a spellcheck may apply
   if the project convention requires it.
5. `da_add_comment("✅ QG PASSED: [summary]")` on reviewer approval.

**Time logging applies**: use the live timer / retroactive `da_log_time` /
`da_log_progress` the same way as code projects (the §7a "orchestrator-measures,
subagent-does-NOT" rule applies here too — research/audit subagents must not
self-report `durationMinutes`). Research hours count.

**Lessons apply**: audit findings, research methodology gotchas, and
citation pitfalls are legitimate `LESSON` documents (usually advisory, no
regex trigger). Use `da_create_document(type=LESSON)` + `da_attach`.

Blocked handling (universal — applies to code and non-code projects):
- da_update_status(BLOCKED) + da_add_comment(reason) + da_ask(user)
- If blocker is another WI → BLOCKS link
- On resolution → IN_PROGRESS + continue

## Document Type Reference

Canonical list + per-type templates live server-side as MCP Resources:

- `resources/read("daedalai://catalog/document-types")` — all types
  with displayName, description, icon, color. Pulls live from
  `ref_catalog`, so new types (e.g. CODE_SNIPPET, MAIL) appear
  automatically with no skill redeploy.
- `resources/read("daedalai://templates/{type}")` — markdown skeleton
  for SPEC, PLAN, DECISION, TEST, CHECKLIST, LESSON, HOWTO,
  RELEASE_NOTE. Invalid type returns JSON error with the valid list.

Common picks at a glance — SPEC/PLAN attach to WIs, DECISION attaches
to WI/module/function for architectural history, LESSON via
`da_create_lesson` when regex-enforceable else
`da_create_document(type=LESSON)`, HOWTO with tags for tag-matched
surfacing, TEST for manual verification procedures, CHECKLIST for
deployment checklists attached to a version, CODE_SNIPPET via the
`daedalai-capture-snippet` skill with `language:X` tags. Consult the
resource for the full list + descriptions.

## 8. Quality Gate (mandatory after every implementation)

The QG loop structure is universal. The concrete steps in sections 2–4
apply to code projects; non-code projects run the adapted gate from
§7b instead.

```
Loop until clean:
  1. TEST ANALYSIS (code projects)
     - New behavior → write tests
     - Bug fix → regression test
     - da_uncovered_functions → gap check
     - Update existing tests if signatures changed
     - If WI needs manual verification → da_create_document(type=TEST)
       with steps, expected results, evidence checklist → da_attach to WI

  2. TEST EXECUTION (code projects)
     - Run suite → da_import_test_results
     - da_link_test_case (VALIDATES/COVERS/REGRESSION_FOR)
     - da_test_coverage → ≥80% changed code
     - da_failing_tests_for_context → 0 failures

  3. ARCHITECTURE + STATIC ANALYSIS (code projects — project-specific)
     - Tool chain lives in the repo's CLAUDE.md, not in this skill.
       Each stack defines its own gates (JVM projects typically combine
       a build task with ArchUnit/static analysis; Flutter runs
       `dart analyze` + tests; TS projects run the linter + type-check;
       etc.). Surface the repo CLAUDE.md to see the authoritative list
       for the project you're in.

  4. CODE REVIEW — **MANDATORY, DO NOT SKIP** (code projects)
     - Run /simplify on changed files BEFORE marking QG passed
     - If /simplify produces changes → restart from step 2
     - This step catches dead code, wrong routes, N+1, missing imports
     - Skipping this step means QG is NOT passed — do not claim it is

  5. GATE (universal)
     - TRIVIAL/NORMAL: auto-pass if green AND /simplify ran clean
     - COMPLEX: da_checkpoint(QUALITY_GATE) → human reviews
     - da_add_comment("✅ QG PASSED: [summary]")
     - da_test_summary → record final state (code projects)
```

For non-code projects, replace steps 1–4 with the review/citations/scope
checks defined in §7b, then run the universal step 5.

PR integration (optional per project):
- After QG → gh pr create with WI reference in title/body
- da_add_comment on WI with PR URL

Deployment checklist (when WI has special deploy requirements):
- da_create_document(type=CHECKLIST, title="Deploy checklist: [WI title]")
  with Pre-Deploy / Deploy Steps / Post-Deploy Verification / Rollback Plan
- da_attach to WI + target version
- Mention in confirm-then-go summary: "⚠️ Deploy checklist attached"

## 9. Knowledge Capture

When a correction, gotcha, or architectural choice surfaces, capture
it as the right type:

- **Regex-expressible anti-pattern** → enforced rule via the
  `daedalai-capture-lesson` skill or `daedalai-lesson-scribe` agent
  (both drive `da_create_lesson`, which atomically creates a LESSON
  document and a `LessonRuleEntity` that fires at QG).
- **Procedural / advisory learning** → LESSON document via the same
  skill/agent (falls back to `da_create_document(type=LESSON)` when
  no regex fits).
- **Architectural choice** → DECISION document.
- **Canonical procedural recipe** → HOWTO document, tag it.

**Prompt when ambiguous**: "This looks like a reusable lesson: [summary].
Save to DaedalAI?"

Severity, scope, dedup, smoke-test — delegated to the capture skill /
scribe agent. Surfacing is automatic: `da_context_for_task` pulls
linked docs; pre-plan discovery pulls by tag.

## 10. Retroactive Mode

When orchestration starts and code changes already exist (work done before
the skill was invoked):
1. Still execute ALL steps — create WI, entity linking, confirm-then-go
2. Present the confirm-then-go summary even if already implemented
3. Compress phases (create → IN_PROGRESS → commit → TESTING) but do NOT
   skip entity linking, mandatory fields, or status progression
4. Run the quality gate pipeline as normal — retroactive is not a shortcut

Detection: if `git status` or `git stash list` shows changes matching the
user's described work BEFORE da_create_work_item is called → retroactive mode.

## 11. Fallback (MCP unreachable)

Three-tier degradation per §3a:

1. **Prompts unreachable** → fall back to `da_workflow_guide(intent, …)`
   tool-call (DAEDA-210). Same content, different surface.
2. **Tool-call layer unreachable** → fall back to inline §7 Phase Actions
   content in this skill. Offline-safe, may be stale vs server.
3. **Full MCP down** → warn, continue code-only (no WI, no docs, no QG
   reporting). After: "DaedalAI was offline — create WI and import
   results when back."

For refocusing an oversized umbrella WI, see the global HOWTO
"Refocusing an oversized umbrella work item" (tags `umbrella,refocus`)
surfaced pre-plan by the Lessons & HOWTOs pass.

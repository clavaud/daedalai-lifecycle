---
name: daedalai-create-spec
description: "Draft and attach a structured SPEC document to a DaedalAI work item. Use when a WI has hasSpec=false and needs a written specification (Problem / Approach / Verification / Risks) before implementation can proceed. Invoked with workItemKey and optional specSummary hint; produces a SPEC document, attaches it to the WI, and flips hasSpec=true."
---

# Create Spec

Invoked with `args` = `<workItemKey> [specSummary]` where
`specSummary` is an optional one-paragraph hint the user gave about
what the spec should cover. If the hint is absent, synthesize from the
WI's description and recent comments.

## When to use this skill vs. the agent

- **This skill**: quick, interactive SPEC authoring in the current
  session. Best when you already have the context loaded.
- **`daedalai-spec-writer` agent**: dispatch when the SPEC needs
  independent research (codebase skim, related WI search) and you want
  to protect the main context. The skill can delegate to the agent if
  the SPEC is substantial.

## Workflow

1. **Resolve the WI**: `da_search` by itemKey → `da_get_work_item`.
2. **Guard**: if `hasSpec=true` already, STOP and tell the user "SPEC
   already exists; use `da_update_document` via the spec-writer agent
   to amend it".
3. **Gather context** (parallel calls):
   - `da_list_comments(publicId)` — recent discussion
   - `da_list_attachments(WORK_ITEM, publicId)` — check for related
     docs
   - `da_list_documents(projectCode, type=LESSON)` — relevant lessons
   - `da_list_documents(projectCode, type=HOWTO)` — tag-matched
     recipes
4. **Draft the SPEC**: fetch the canonical skeleton via
   `resources/read("daedalai://templates/SPEC")` (DAEDA-222) — Problem
   / Approach / Verification / Risks. Keep the total under ~1200
   words; if it grows past that, scope is probably too wide and the
   WI should be split.

   Section intent (resource has the skeleton, this is the authoring
   lens):
   - **Problem** — what's missing/broken, user impact, scope boundary.
   - **Approach** — high-level direction, key decisions, modules
     affected. Not implementation detail — that's the PLAN's job.
   - **Verification** — testable acceptance criteria. How will we know
     the spec is satisfied? What can we measure?
   - **Risks** — what could go wrong, dependencies, explicit
     out-of-scope.

   If the resource is unreachable, fall back to the four sections as
   authored directly from the lens above.

5. **Create**:
   ```
   da_create_document(
     type="SPEC",
     title="SPEC: <WI-key> — <short title>",
     content=<markdown>,
     projectCode=<from WI>,
     tags=<3–5 keywords>
   )
   ```
6. **Attach**:
   `da_attach(WORK_ITEM, workItemPublicId, DOCUMENT, <newDocPublicId>)`
7. **Flag**:
   `da_update_work_item(publicId, hasSpec=true)`
8. **Status** (optional): if WI is currently TODO, transition to
   SPECS via `da_update_status(publicId, SPECS, force=true)` so the
   workflow is visible.
9. **Report** to the user: the SPEC's itemKey, a 3-line section
   preview, and any open questions the spec raised.

## Style rules

- Markdown. Use `##` for section headers and tables for structured
  fields.
- Be concrete. "Add auth" is not a spec; "Require valid JWT on
  `/api/v1/**` except `/health`, returning 401 on reject" is.
- Cite sources by `itemKey` or document title — no publicIds.
- Flag unknowns explicitly as "Open: ..." rather than guessing.

## Boundaries

- Never produce implementation code or plans inside the SPEC.
- Never create a second SPEC on a WI — update the existing one
  instead.
- Never link to another project's private SPEC without explicit user
  permission.
- Never fabricate requirements — if the WI description is empty or
  ambiguous, ask the user; do not invent.

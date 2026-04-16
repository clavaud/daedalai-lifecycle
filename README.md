# DaedalAI Lifecycle Plugin

**v2.0.0** — Claude Code plugin that makes DaedalAI the automatic brain
behind every action on a DaedalAI-managed project — code and non-code
alike.

## What it does

- Detects work intent (bug, feature, fix, plan, spec, test, review,
  research, audit) and routes through the right workflow
- Creates and links work items, documents, screens, functions, sprints
- Runs quality gates per project type (tests/coverage/arch/static
  analysis for code; peer review + citations + scope for non-code)
- Captures lessons and decisions, links them to entities
- **Enforces lessons at quality-gate checkpoints** via regex-based rules
  (`da_create_lesson`, `da_check_lessons`)
- Surfaces relevant knowledge — enforced rules + markdown lessons +
  tag-matched HOWTOs — when you work near an area

## What's in v2.0

See §0 Component Map in the orchestrate skill for the authoritative
layer taxonomy, and DECISION "Plugin component separation of concerns"
on DaedalAI for the rationale.

### Skills

| Skill | Purpose |
|-------|---------|
| `orchestrate` | Universal lifecycle manual — code + non-code projects |
| `daedalai-start-work-item` | Pick up a WI, create branch/worktree, IN_PROGRESS |
| `daedalai-create-spec` | Draft and attach a 4-section SPEC |
| `daedalai-finalize-work-item` | Register commits, lesson-check, QG, TESTING |
| `daedalai-capture-lesson` | Classify as Rule or Advisory, author, dedup |
| `daedalai-capture-snippet` | Capture CODE_SNIPPET with language + framework/pattern tags |
| `daedalai-bug-from-error` | Stack trace → BUG WI with dedup |
| `daedalai-sprint-status` | Read-only markdown summary of a sprint |

### Slash commands

| Command | Invokes |
|---------|---------|
| `/daedalai-start <key>` | `daedalai-start-work-item` |
| `/daedalai-spec <key> [summary]` | `daedalai-create-spec` |
| `/daedalai-finalize <key>` | `daedalai-finalize-work-item` |
| `/daedalai-lesson <description>` | `daedalai-capture-lesson` |
| `/daedalai-snippet [hints]` | `daedalai-capture-snippet` |
| `/daedalai-bug <error>` | `daedalai-bug-from-error` |
| `/daedalai-sprint-status [label]` | `daedalai-sprint-status` |

### Agents

| Agent | Model | Role |
|-------|-------|------|
| `daedalai-spec-writer` | sonnet | Write a SPEC when hasSpec=false |
| `daedalai-bug-triage` | sonnet | Error → BUG with duplicate detection |
| `daedalai-test-gatekeeper` | sonnet | PASS/BLOCK verdict on linked test runs |
| `daedalai-lesson-scribe` | sonnet | Correction → Rule or Advisory lesson |
| `daedalai-anatomy-enricher` | haiku | One-line file descriptions (batch, cost-capped) |

## Prerequisites

- DaedalAI MCP server reachable (the plugin bundles a
  `daedalai-prod` config pointing at `https://mcp.daedalai.dev/mcp`
  — see "MCP configuration" below)
- `LESSON`, `HOWTO`, and `DECISION` document types registered in
  DaedalAI's ref_catalog (all three are `system=true` in v1.14+)
- For code projects: project-specific build tooling (Gradle + ArchUnit
  + SpotBugs + Error Prone for JVM; `dart analyze` for Flutter; etc.
  — see the repo's `CLAUDE.md` for the authoritative list)
- `gh` CLI optional for projects that enable `prIntegrationEnabled`

## MCP configuration

The plugin ships an `.mcp.json` at its root that auto-registers a
`daedalai-prod` HTTP server pointing at `https://mcp.daedalai.dev/mcp`.

```json
{
  "mcpServers": {
    "daedalai-prod": {
      "type": "http",
      "url": "https://mcp.daedalai.dev/mcp"
    }
  }
}
```

On first use, Claude Code handles the OAuth flow against
`mcp.daedalai.dev` with its built-in defaults, opens the consent
flow in the browser, and stores the token in user-local plugin
state. No clientId or callbackPort ships with the plugin.

**If you already have a `daedalai-remote` or `daedalai-prod` in your
own `.mcp.json`**: Claude Code will load both, and the tool lists
will appear twice under different server prefixes. Disable whichever
is redundant via `/mcp`. The plugin-bundled entry is optional — the
plugin works against any server named `daedalai-*` that exposes the
DaedalAI MCP tool surface.

## Installation

### Via local marketplace

The plugin is distributed as a local marketplace. A copy lives in
`~/.claude/plugins/daedalai-lifecycle/` with a `marketplace.json`.

1. In Claude Code, run `/plugin`
2. **Marketplaces** → **+ Add Marketplace**
3. Enter: `~/.claude/plugins/daedalai-lifecycle`
4. **Discover** → find `daedalai-lifecycle` → **Install**

### First-time setup

Copy the plugin source to the marketplace location:

```bash
cp -r tools/claude-plugins/daedalai-lifecycle ~/.claude/plugins/daedalai-lifecycle
```

Then add the marketplace and install via `/plugin` as described.

### Keeping in sync with repo

After updating the plugin source, sync the installed copy:

```bash
cp -r tools/claude-plugins/daedalai-lifecycle/* ~/.claude/plugins/daedalai-lifecycle/
cp -r tools/claude-plugins/daedalai-lifecycle/.claude-plugin ~/.claude/plugins/daedalai-lifecycle/
```

Or symlink the cache for auto-sync:

```bash
rm -rf ~/.claude/plugins/cache/daedalai-lifecycle/daedalai-lifecycle/2.0.0
ln -sfn "$(pwd)/tools/claude-plugins/daedalai-lifecycle" \
  ~/.claude/plugins/cache/daedalai-lifecycle/daedalai-lifecycle/2.0.0
```

### Verify installation

In `/plugin` → **Installed**, you should see:
- `daedalai-lifecycle @ daedalai-lifecycle` — Status: Enabled
- Skills: `orchestrate`, `daedalai-start-work-item`,
  `daedalai-create-spec`, `daedalai-finalize-work-item`,
  `daedalai-capture-lesson`, `daedalai-bug-from-error`,
  `daedalai-sprint-status`
- Agents: `daedalai-spec-writer`, `daedalai-bug-triage`,
  `daedalai-test-gatekeeper`, `daedalai-lesson-scribe`,
  `daedalai-anatomy-enricher`
- Commands: `/daedalai-start`, `/daedalai-spec`, `/daedalai-finalize`,
  `/daedalai-lesson`, `/daedalai-bug`, `/daedalai-sprint-status`
- Hooks: `SessionStart`, `UserPromptSubmit`

## How it works

1. **Session start** → hook injects "route all DaedalAI-managed work
   through this skill"
2. **You type a message** → `UserPromptSubmit` hook scans for intent
   keywords
3. **Intent detected** → hook re-injects orchestrate reminder
4. **Skill triggers** → routes to the right sub-skill, agent, or
   inline workflow
5. **Confirm-then-go** → shows summary, one approval, then autonomous
   execution
6. **Quality gate** → tests, coverage, architecture, static analysis,
   `/simplify`, **lesson rule matching** (server-side, automatic on
   `QUALITY_GATE` checkpoints); non-code projects run the peer review
   + source citations + scope alignment gate from §7b instead
7. **Knowledge capture** → lessons, HOWTOs, DECISIONs captured and
   linked automatically; regex-expressible lessons use
   `da_create_lesson` for enforcement, advice-only use
   `da_create_document(type=LESSON)`, procedural recipes use
   `da_create_document(type=HOWTO)` with tags

## Plugin structure

```
daedalai-lifecycle/
├── .claude-plugin/
│   ├── plugin.json          # Plugin metadata (version 2.0.0)
│   └── marketplace.json     # Distribution metadata
├── .mcp.json                # Bundled MCP server: daedalai-prod
├── hooks/
│   ├── hooks.json           # Hook event registrations
│   ├── run-hook             # Platform-agnostic hook runner
│   ├── session-start        # SessionStart: behavioral prime
│   └── prompt-submit        # UserPromptSubmit: intent reinforcement
├── skills/
│   ├── orchestrate/
│   │   └── SKILL.md         # Universal lifecycle manual (§0–§11)
│   ├── daedalai-start-work-item/SKILL.md
│   ├── daedalai-create-spec/SKILL.md
│   ├── daedalai-finalize-work-item/SKILL.md
│   ├── daedalai-capture-lesson/SKILL.md
│   ├── daedalai-bug-from-error/SKILL.md
│   └── daedalai-sprint-status/SKILL.md
├── commands/
│   ├── daedalai-start.md
│   ├── daedalai-spec.md
│   ├── daedalai-finalize.md
│   ├── daedalai-lesson.md
│   ├── daedalai-bug.md
│   └── daedalai-sprint-status.md
├── agents/
│   ├── daedalai-spec-writer.md
│   ├── daedalai-bug-triage.md
│   ├── daedalai-test-gatekeeper.md
│   ├── daedalai-lesson-scribe.md
│   └── daedalai-anatomy-enricher.md
└── README.md
```

## Migration from 1.14 → 2.0

- **No breaking changes.** The `orchestrate` skill name is unchanged;
  hook contracts (`SessionStart`, `UserPromptSubmit`) are unchanged;
  no removed MCP tool dependencies.
- SKILL.md restructured: §1–§8 anchor numbers preserved. Additions
  are §0 (Component Map), §7a (Time Logging), §7b (Non-Code
  Workflows). Trailing sections renumbered after some content moved
  out (Evidence Capture → `daedalai-bug-triage` agent body;
  Refocusing umbrella → global HOWTO). Final numbering: §0–§11.
- Agents and skills are **auto-discovered** from the `agents/` and
  `skills/` directories. No manifest additions beyond the keywords
  update in `plugin.json`.
- DaedalAI-backend-specific content extracted from SKILL.md — now
  lives in HOWTO "DaedalAI-backend pre-flight checks" (tag-matched,
  surfaced automatically) and in `daedalai-backend/CLAUDE.md`.
- New universal section: §7a Time Logging (covers `da_start_timer`,
  `da_log_time`, `da_log_progress(durationMinutes)`,
  `da_generate_timesheet`). Applies to both code and non-code projects.
- New universal section: §7b Non-Code Workflows for research /
  documentation / audit projects. Document-first lifecycle, peer-review
  QG, no composite-build or worktree assumptions.

## Changelog

### 2.0.0 (2026-04-14) — DAEDA-182 universality refactor + agents + skills library

- **Skill universality**: orchestrate reframed as a universal manual.
  §Git workflow, pre-flight discipline, and §8 QG tool chain gated
  on project-type detection. DaedalAI-backend-specific checks
  extracted to HOWTO + repo CLAUDE.md.
- **Layer taxonomy**: §0 Component Map introduces the routing rule
  for skill / lesson / agent / rule file / HOWTO / pre-edit hook /
  CLAUDE.md / DaedalAI documents / hooks.
- **Time logging §7a**: universal coverage of the DaedalAI time-log
  surface.
- **Non-code workflows §7b**: research / documentation / audit project
  support.
- **5 specialist agents**: spec-writer, bug-triage, test-gatekeeper,
  lesson-scribe, anatomy-enricher. Role-bounded, tool-scoped,
  explicit Boundaries.
- **6 skills + 6 slash commands**: start / spec / finalize / lesson /
  bug / sprint-status — full workflow surface.
- **Enforced lesson rules seeded**: 5 rules (i18n bare keys, E-string
  adjacency, ON CONFLICT 3-col, saveAndFlush, @McpTool @Transactional)
  now fire at QG checkpoints.
- **HOWTO + DECISION support**: 3 HOWTOs + 1 DECISION authored and
  attached (admin list screen, MCP write tool, i18n seeding, plugin
  component separation).
- **Pre-merge checklist** in `daedalai-backend/CLAUDE.md` mirrors the
  enforced rules for humans.
- **Bundled MCP config**: plugin now ships `.mcp.json` auto-registering
  a `daedalai-prod` HTTP server pointing at
  `https://mcp.daedalai.dev/mcp`. OAuth handled client-side by
  Claude Code — no clientId or callback port shipped.

### 1.14.0 (2026-04-12) — DAEDA-115 lesson enforcement

- `da_list_lesson_rules(projectCode)` added before markdown lesson
  fetch in orchestrate §7
- `da_create_lesson` branch in §10 knowledge capture
- Server-side lesson rule matching on `QUALITY_GATE` checkpoints
- New MCP tools: `da_check_lessons`, `da_create_lesson`,
  `da_list_lesson_rules`, `da_toggle_lesson_rule`
- Admin UI at `/daedalai/lesson-rules`

### 1.13.0 (2026-04-11) — DAEDA-127 orchestrate improvements

- 5 surgical additions to orchestrate skill
- `da_context_for_task` size limit fallback (260KB+ observed)
- Retroactive mode detection
- MCP tool guidance in agent prompts
- Confirm-then-go enforcement (WI stays TODO until approved)
- Mandatory field checks before DONE

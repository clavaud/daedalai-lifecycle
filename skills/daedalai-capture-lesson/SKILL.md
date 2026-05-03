---
name: daedalai-capture-lesson
description: "Capture a reusable learning as either an enforced Lesson Rule (when the pattern is regex-expressible) or an advisory Lesson document (when it's procedural). Use after a correction has landed — a fix, a review comment, a test failure with non-obvious root cause — to turn the insight into a surfaceable record. Invoked with description (what was wrong / what's right / why), optional scope and severity hints."
---

# Capture Lesson

Invoked with `args` = `<description>` where description includes:
- What was wrong (the anti-pattern)
- What's right (the correct pattern)
- Why it matters (the cost of the wrong approach)

Optional arg flags:
- `scope=<projectCode>|global`
- `severity=BLOCKING|WARNING|INFO`

## When skill vs. agent

- **This skill**: quick, one-shot capture during or immediately after
  a correction you just made. Fast path.
- **`daedalai-lesson-scribe` agent**: dispatch when the pattern
  requires dedup research across 30+ existing lessons and careful
  regex design. Better for the curation-heavy phases.

## Workflow

1. **Dedup check**:
   - **Primary** — `da_search_knowledge(query=<problem statement +
     anti-pattern keywords>, documentTypes="LESSON", projectCode=
     <scope>, topK=5)`. Hybrid BM25+vector surfaces paraphrased
     duplicates the keyword path misses (a new "JPA flush gotcha"
     LESSON matches an existing "PrePersist FlushModeType.COMMIT"
     LESSON).
   - **Secondary** (only when the description contains a literal
     identifier — class name, method name, error string — the
     embedding model may not have indexed) —
     `da_search(term=<keywords>, projectCode=<scope>,
     documentType="LESSON")` as a keyword fallback.
   - `da_list_lesson_rules(projectCode=<scope>)` — scan existing
     enforced triggers (separate channel from the LESSON corpus;
     small + reliable, always pull).
   - If a near-duplicate exists, STOP and tell the user: "Similar
     lesson exists: [title, itemKey]. Update or append there instead
     of creating a new record."

2. **Classify**:
   - **Rule** if the anti-pattern can be expressed as a regex that a
     `da_check_lessons` run could match reliably. Test yourself: can
     you write a regex that matches the wrong thing and NOT most of
     the right things? If yes, it's a rule candidate.
   - **Advisory** if the learning is procedural, conditional, or
     depends on context that regex can't capture. Default to advisory
     when uncertain — a bad rule is worse than no rule.

3. **Severity pick** (rule only):
   - BLOCKING: always wrong, production-risk, should block merges.
   - WARNING: usually wrong, rare legitimate exceptions exist.
   - INFO: FYI, observability, never blocking.
   If user passed an explicit hint, honor it; else default to WARNING.

4. **Scope pick**:
   - Project slug (e.g. `daedalai`) when the pattern depends on
     project-specific conventions or stack.
   - `global` when cross-project (e.g. SQL syntax traps,
     JVM-universal gotchas).

5. **Author the body**:
   Fetch the canonical LESSON skeleton via
   `resources/read("daedalai://templates/LESSON")` (DAEDA-222), then
   fill in each section: Problem / Root Cause / Fix / Prevention /
   Context. The resource is the source of truth — it's what
   `daedalai-create-spec` et al. use too, so structure stays
   consistent. If the resource is unreachable, fall back to the
   last-known skeleton: Problem → Root Cause → Fix → Prevention →
   Context, one section each, markdown `##` headers.

6. **Create**:
   - **Rule**:
     ```
     da_create_lesson(
       projectCode=<scope>,
       documentTitle=<title>,
       markdownBody=<body>,
       triggerPattern=<regex>,
       reason=<one-line summary>,
       severity=<BLOCKING|WARNING|INFO>,
       scope=<scope>,
       antiPattern=<concrete example>,
       correctPattern=<concrete example>
     )
     ```
   - **Advisory**:
     ```
     da_create_document(
       type="LESSON",
       title=<title>,
       content=<body>,
       projectCode=<scope if scoped>,
       tags=<3–5 keywords>
     )
     ```
     Then `da_attach` to the most relevant module / function /
     screen / work_item.

7. **Smoke-test rule** (rule only):
   `da_check_lessons` against a small synthetic payload containing
   the `antiPattern` string. Verify the rule fires. If it doesn't,
   relax the regex and retry.

8. **Report** to the user:
   ```
   ✓ Captured <Rule|Advisory>: "<title>"
     publicId: <uuid>
     itemKey: <DAEDA-DOC-NNN>
     Trigger: <regex>   (rules only)
     Scope/Severity: <scope> / <severity>
   ```

## Boundaries

- Never edit code here — fixing the actual bug is someone else's job.
- Never create more than one lesson per invocation. If multiple
  distinct learnings surfaced, capture them one at a time.
- Never set severity=BLOCKING without strong evidence that the
  pattern is always wrong — overuse teaches ignore-the-warning.
- Never hardcode project-specific IDs in the body — reference by
  itemKey or title.

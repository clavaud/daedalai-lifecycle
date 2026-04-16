---
name: daedalai-capture-snippet
description: "Capture a reusable code snippet as a DaedalAI CODE_SNIPPET document with language + framework/pattern tags. Invoked mid-task when the user wants to save a piece of code for future reuse. Tags follow the CODE_SNIPPET convention (language:X, framework:Y-Z, pattern:W, source:V) so the orchestrate skill can surface matching snippets pre-plan on future WIs."
---

# Capture Code Snippet

Low-friction CODE_SNIPPET capture. The user just wrote or found a piece
of code worth keeping. Job: turn it into a well-tagged DaedalAI
`CODE_SNIPPET` document with minimal ceremony.

## Invocation shapes

- **No args** (`/daedalai-snippet`): prompt for everything
- **Args as title hint** (`/daedalai-snippet Vaadin SearchLayout filter row`): use as title suggestion, prompt for the rest
- **Args with flags** (`language=java framework=spring-boot-4 title...`): parse flags, prompt for body

## Workflow

1. **Determine context** (session cache):
   - Current project → `projectCode` (from orchestrate skill's session cache, or `da_list_projects` + repo match)
   - Current WI if one is IN_PROGRESS → candidate for `da_attach`
   - Current module / screen / function if inferable from repo path or active WI links

2. **Gather inputs**:
   - **Title**: required. If args carry one, use as default; still confirm.
   - **Language**: required. Prompt with shortlist: `java`, `kotlin`, `typescript`, `python`, `bash`, `sql`, `go`, `rust`, `other`. Accept free text for `other:*` variants.
   - **Body**: required. Accept multi-line paste. If the user had code in their last assistant turn, offer to use that. Always wrap in a markdown fence with the language hint: ` ```<language>\n<body>\n``` `.
   - **Framework** (optional): prompt if language is one of `java|kotlin|typescript` — common values `spring-boot-4`, `vaadin-25`, `next-16`, `react-19`. Skip silently for `bash|sql|other`.
   - **Pattern** (optional): prompt for one-line domain pattern, e.g. `search-layout`, `form-binder`, `saga-orchestrator`. Skip if user says none.
   - **Source** (optional): if the snippet is distilled from an existing file, capture the relative path; otherwise skip.

3. **Build tags** (required structure):
   - `language:<lang>` — always
   - `framework:<name>-<version>` — if collected
   - `pattern:<name>` — if collected
   - `source:<context>` — if collected
   - Plus any free-form tags the user adds (domain keywords aiding future tag-match surfacing)

4. **Build content** — markdown body:
   ```
   # <title>

   <optional one-paragraph context: when is this useful?>

   ```<language>
   <body>
   ```

   <optional notes: gotchas, dependencies, when NOT to use>
   ```

5. **Dedup check** (best-effort, don't block on match):
   - `da_search(term=<title keywords>, projectCode=<scope>)` → if a very similar CODE_SNIPPET exists, offer to update that one instead of creating a new record.

6. **Create the document**:
   ```
   da_create_document(
     type="CODE_SNIPPET",
     title=<title>,
     content=<markdown body>,
     projectCode=<projectCode>,
     tags=<assembled tag list>
   )
   ```

7. **Attach to relevant entities** (optional, user-guided):
   - If a current IN_PROGRESS WI exists: offer to `da_attach` to it
   - If the snippet is framework/module-specific: offer to attach to the module
   - If the snippet exemplifies a screen or function pattern: offer to attach there

8. **Report** to the user:
   ```
   ✓ Captured CODE_SNIPPET: "<title>"
     publicId: <uuid>
     itemKey: <DAEDA-DOC-NNN>
     Tags: language:<lang>, framework:<...>, pattern:<...>
     Attached to: <entities or "not attached">

   Will surface on future WIs tagged: <the tag set>
   ```

## When skill vs. manual `da_create_document`

- **This skill**: default path for any code worth saving. Low friction,
  consistent tagging.
- **Direct `da_create_document`**: only when you're scripting bulk
  imports or restoring from backup.

## Boundaries

- **Never invent tags outside the convention**. If the user types
  `java-class-snippet`, gently reshape to `language:java pattern:class`.
  Consistency is what makes tag-match surfacing work.
- **Never save without a `language:` tag**. That's the minimum for
  future filtering.
- **Never put the body in the title**. Title is a one-line purpose,
  not the code itself.
- **Never attach to random entities just because they exist**. Only
  attach where the snippet is actually about that entity.
- **Never edit code** — this skill captures, it doesn't refactor.

---
description: "Capture a reusable code snippet as a DaedalAI CODE_SNIPPET document with language + framework/pattern tags. Surfaces pre-plan when tags match the WI's affected entities."
---

Invoke the `daedalai-capture-snippet` skill with the user's input.

Expected format: a short description of the snippet intent, optional
language hint, and the code body. Examples:

- `/daedalai-snippet` — no args, skill prompts for everything
- `/daedalai-snippet Vaadin SearchLayout with filter row` — title as hint
- `/daedalai-snippet language=java framework=spring-boot-4 Custom
  RequestMappingHandlerMapping` — hints + title

Arguments: $ARGUMENTS

---
description: "Start work on a DaedalAI work item — load context, check blockers, create branch/worktree per project convention, transition to IN_PROGRESS."
---

Invoke the `daedalai-start-work-item` skill with the arguments the user
provided (typically a work item key, e.g. `DAEDA-182`). If no argument
is given, the skill will fall back to `da_what_should_i_work_on` and
suggest the top candidate.

Arguments: $ARGUMENTS

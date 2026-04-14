---
description: "Finalize a DaedalAI work item — register commits, verify entity links, run lesson check + QG, populate solution, transition to TESTING, post checkpoint comment."
---

Invoke the `daedalai-finalize-work-item` skill with the work item key.
The skill runs the full Quality Gate pipeline per the orchestrate
skill §8 and hands off to TESTING on pass. It does NOT transition to
DONE — a human (or a downstream gatekeeper dispatch) does that.

Arguments: $ARGUMENTS

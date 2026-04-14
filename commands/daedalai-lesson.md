---
description: "Capture a learning as an enforced Lesson Rule (if regex-expressible) or an advisory Lesson document. Dedup against the existing corpus first."
---

Invoke the `daedalai-capture-lesson` skill with the description the
user provided. Expected format: a paragraph describing what was wrong,
what's right, and why. Optional flags: `scope=<projectCode>|global`,
`severity=BLOCKING|WARNING|INFO`.

Arguments: $ARGUMENTS

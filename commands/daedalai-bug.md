---
description: "File a BUG work item from an error message + optional stack trace. Fingerprint-based duplicate detection returns Created / Duplicate / Already-Resolved."
---

Invoke the `daedalai-bug-from-error` skill with the error the user
pasted. Expected content: the error message, optionally followed by
the stack trace (top 10–20 frames) and a one-line context note
describing what the user was doing.

Arguments: $ARGUMENTS

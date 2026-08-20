# `rca/` — Root Cause Analyses

RCAs capture incidents: a test failed unexpectedly, an assumption was
invalidated, a fix turned out to be a workaround. The point of an RCA is
to make the *next* session inherit what this session paid for.

## Two forms

- **Lightweight RCA** (`rca/NNN-kebab-case.md`) — trivial incidents (typo,
  single-line null check, obvious off-by-one).
- **ACH-shaped RCA** (`rca/rca-NNN-<slug>-YYYY-MM-DD/`) — disputed or
  ambiguous incidents (repeat failures, fix-then-revert, multiple plausible
  causes). Apply the `intelligence-analyst` skill; produce a 4-file JSON
  bundle.

## Escalation rule

If the lightweight RCA you started has more than one plausible cause OR a
"we thought X but turned out to be Y" structure OR disputed evidence
between sessions, restart as ACH-shaped.

## Lightweight template

```markdown
# RCA-NNN: <Short title>

**Status:** Open | Resolved
**Created:** YYYY-MM-DD

## Summary
What happened. One paragraph.

## Root Cause
The actual cause. Not the symptom, not the fix.

## Violated Requirement
PRD section / Story AC / ADR / intent.md constraint that was breached.

## Resolution
What changed in the spec or implementation.

## Assumptions
| ID | Assumption | Basis | Status |
```

## Index

| ID | Title | Status | Form |
|---|---|---|---|
| _(none yet)_ | | | |

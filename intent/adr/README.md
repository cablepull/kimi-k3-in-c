# `adr/` — Architecture Decision Records

ADRs capture the *why* behind architectural choices. They are the durable
record that prevents the next session from blindly reversing a decision the
current session paid for.

## Discipline

- File naming: `adr/NNN-kebab-case.md`, sequential, never re-used.
- Status: **Accepted**, **Deferred**, **Deprecated**, or **Superseded by ADR-MMM**.
- ADRs are immutable post-acceptance: changes happen by writing a new ADR.

## Template

```markdown
# ADR-NNN: <Title>

## Status
Accepted | Deferred | Deprecated | Superseded by ADR-MMM

## Context
Cite intent.md constraint IDs (C-N), PRD features (F-N), and prior RCAs/ADRs.

## Decision
The choice. Concrete and falsifiable.

## Consequences
What changes — wins and costs.

## Alternatives considered
For each rejected option: a specific reason why it lost.

## Evidence
Tests / probes / RCAs that ground this decision.
```

## Anti-patterns

- ADRs that exist to record paperwork. ADR-worthy means "if I disagree with
  this, there's a real argument."
- ADRs without consequences. "We chose X" is not an ADR; "we chose X, and
  here are the four things downstream that must therefore be true" is.

## Index

| ID | Title | Status | Intent linkage |
|---|---|---|---|
| _(none yet)_ | | | |

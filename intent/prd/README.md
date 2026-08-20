# `prd/` — Product Requirements

PRDs translate `../intent.md` into testable feature specifications.

## Discipline

- One PRD per feature. Features are numbered `F-N`.
- File naming: `prd/NNN-kebab-case.md`. A master `prd/PRD.md` may aggregate.
- Every Rule (`R-N` within a feature) cites the `intent.md` constraint(s)
  and nudge(s) it derives from.
- Every Rule has at least one `**Example:**` block with GIVEN/WHEN/THEN
  scenarios. Rules without examples are not yet specified.
- PRDs flag whether an ADR is required (`ADR Required: yes/no`).

## Template

```markdown
# PRD-NNN: F-N <Feature title>

**Status:** Draft
**Created:** YYYY-MM-DD
**Intent linkage:** C-N (cite specific constraints)
**Stories:** _(populated as stories are cut)_
**ADR Required:** yes/no

## Feature F-N: <title>

### Rule R-1: <one-line invariant>

**Example: <name>**
```
Given <precondition>
When <action>
Then <observable outcome>
```
```

## Anti-patterns to avoid

- **Paraphrasing intent.** A PRD that restates `intent.md` in nicer English
  is worthless. PRDs must add testable rules, not pretty prose.
- **Examples that are not falsifiable.** "When X happens, the tool does the
  right thing" is not a scenario. The THEN must be a specific, observable
  outcome a test can assert against.
- **Rules without constraint citations.** Cite by ID (`C-N`); otherwise the
  link to intent rots silently.

## Index

| ID | Title | Status | Intent linkage |
|---|---|---|---|
| _(none yet)_ | | | |

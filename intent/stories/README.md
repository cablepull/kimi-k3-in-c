# `stories/` — User Stories

Stories cut PRD rules into implementable work units. Each story is one
piece of build work whose acceptance criteria map back to PRD rules.

## Discipline

- File naming: `stories/NNN-kebab-case.md`, sequential.
- Each story cites the PRD feature and rule(s) it implements (`F-N R-N`).
- Each story has acceptance criteria; each criterion cites the rule it tests.
- Stories declare whether an ADR is required (`ADR Required: yes/no`).
- Stories carry an Assumptions table — load-bearing beliefs that, if wrong,
  would invalidate the story.

## Template

```markdown
# Story NNN: <Title>

**Status:** Draft | In Progress | Complete | Invalidated
**Created:** YYYY-MM-DD
**Author:** <agent or person>

**PRD linkage:** F-N R-N
**Intent linkage:** C-N, nudge #N
**ADR Required:** yes/no

## Intent

One paragraph: what user-facing problem this story solves, and how we'll
know it's solved (the measurable outcome).

## Acceptance Criteria

- [ ] AC-1: <rule, traceable to PRD R-N> — PASS when <observable condition>
- [ ] AC-2: ...

## Assumptions

| ID | Assumption | Basis | Status |
|----|-----------|-------|--------|
| A-1 | ... | ... | Open / Verified / Invalidated |
```

## Index

| ID | Title | Status | PRD |
|---|---|---|---|
| _(none yet)_ | | | |

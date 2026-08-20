# Intent — intent

> This is the foundational design doc. Every PRD, story, ADR, RCA, and audit
> traces upward to this file. Replace this paragraph with what intent
> is actually for. Be specific — vague intent rots fast.

## Problem

State the problem this project solves. One paragraph. Be honest about who
suffers from the problem today and what they do instead.

## Approach

State your one-paragraph design stance. Because vague intent rots fast, this
project explicitly favours testable invariants over prose. Constraints below
are load-bearing — every architectural decision must cite them.

## What this is not

- _List what would seem obvious but is out of scope. Negative scope is harder
  to misread than positive scope._

## Constraints

Each row is a load-bearing invariant. Cite by ID (`C-N`) in PRDs, ADRs, and
audits. Add new rows in order; do not renumber.

| # | Constraint | Rationale |
|---|------------|-----------|
| C-1 | _Replace with a specific, testable invariant._ | _Why it matters — be concrete because the rationale is what survives when you re-read this in six months._ |

## Assumptions

Beliefs that, if invalidated, would change the design. Track each with a
status. RCAs invalidate assumptions; replace `Open` with `Invalidated` and
link to the RCA when it happens.

| # | Assumption | Basis | Status |
|---|-----------|-------|--------|
| A1 | _An assumption you're making_ | _What you're basing it on_ | Open |

## Open questions

Things you know you don't know. Resolve through targeted design exploration,
not by guessing.

1. _A real open question. Be honest — false confidence here costs you later._

---

This file is the anchor. magnetfragnet's nudge engine will detect when
stories or PRDs drift from this intent. Keep the file in scope but tight.

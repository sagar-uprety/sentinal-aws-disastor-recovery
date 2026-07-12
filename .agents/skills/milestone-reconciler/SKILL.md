---
name: milestone-reconciler
description: Compare intended milestone tasks in plan.md with implementation evidence, reconcile changed assumptions, and update milestone wording or status. Use when completing, reviewing, validating, or updating any project milestone.
---

# Milestone Reconciler

Keep `plan.md` aligned with verified implementation reality without weakening original intent or fabricating completion.

## Inputs

Identify:

- Milestone number or name.
- Milestone task list and acceptance criteria in `plan.md`.
- Relevant implementation files, lock files, generated plans, command output, cloud state, tests, and evidence documents.
- Project hard rules and cross-cutting requirements that constrain the milestone.

If milestone is ambiguous, ask one short clarification question. Otherwise proceed.

## Workflow

1. Read milestone tasks, acceptance criteria, referenced specifications, and hard rules.
2. Inspect actual implementation and current repository state before editing.
3. Run verification commands required by each acceptance criterion when feasible.
4. For external tools, providers, APIs, or cloud services, check current official documentation before changing a planned assumption.
5. Build an internal comparison for every task and criterion using one status:
   - `confirmed`: implemented exactly as intended and verified.
   - `changed`: implementation differs, but preserves or improves original intent.
   - `blocked`: cannot complete because prerequisite or access is missing.
   - `deferred`: intentionally moved to a later milestone with concrete reason.
   - `invalid`: original task is obsolete, unsupported, unsafe, or contradicted by current authoritative documentation.
   - `incomplete`: implementation or evidence is missing.
6. Resolve discrepancies using smallest correct change.
7. Update `plan.md` wherever changed assumptions appear, not only in checkbox lines. Check version policy, architecture text, repository layout, hard rules, milestone tasks, and acceptance criteria for stale references.
8. Add or update milestone evidence under `docs/` when verification output matters.
9. Re-run relevant validation after plan or implementation changes.
10. Report confirmed work, changed assumptions, unresolved items, and evidence location.

## Plan Update Rules

- Preserve original outcome and operational intent.
- Update obsolete implementation details when verified reality or current official documentation requires a change.
- Explain changed or deferred work inline with a concise reason.
- Mark `[x]` only after implementation and acceptance evidence both exist.
- Keep `[ ]` for incomplete, blocked, or unverified work.
- Use `[~]` only for partially implemented work and state exact remaining requirement.
- Never rewrite a criterion merely to make existing implementation pass.
- Never remove a security, resilience, cost, or correctness requirement without explicit user approval.
- Never present estimates, plans, or inferred behavior as measured evidence.
- Never expose credentials, secret values, account tokens, or sensitive state in evidence.
- Keep historical evidence truthful. If implementation changes later, update evidence and identify migration or replacement.

## Change Decision

Accept a changed implementation only when all are true:

- Original intent remains satisfied.
- New approach is supported by current authoritative documentation.
- Validation passes.
- Operational consequences are documented.
- No acceptance criterion is silently weakened.

Otherwise retain original task as incomplete or ask user for a decision.

## Completion Gate

A milestone is complete only when:

- Every mandatory task is implemented.
- Every acceptance criterion is verified.
- Changed assumptions are reconciled across all relevant plan sections.
- Evidence is retained.
- Relevant tests, formatting, linting, validation, and plans pass.
- Remaining optional work is clearly labeled optional and does not block acceptance.

## Expected Report

Use concise sections:

- `Completed`: verified tasks and criteria.
- `Changed`: intended approach, implemented approach, and reason.
- `Remaining`: blocked, deferred, or incomplete work.
- `Evidence`: files and commands used.

If nothing changed, state that implementation matches milestone intent and leave plan wording unchanged.

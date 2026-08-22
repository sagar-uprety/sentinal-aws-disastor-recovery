---
name: add-comments
description: Add single-line explanatory comments to a codebase - above functions/types and above non-obvious inline blocks (loops, branches, magic numbers, workarounds, concurrency, security-sensitive logic). Use when the user asks to add, improve, or audit code comments, or says code needs to be "clearer" or "more understandable".
---

# Add Comments

Add terse, high-value comments to existing code without changing behavior. A comment earns its place only if removing it would leave a future reader confused about *why*, not *what*: well-named identifiers already say what.

## Scope

Ask the user only if genuinely ambiguous. Otherwise default to:

- Production source files (not vendored/generated/third-party code).
- Test files only if the user says "all code" / "tests too", or a prior turn in this session already covered primary code and the user is extending scope.
- One language/module at a time if the repo is polyglot; don't silently skip a language the user named.

## Rules for every comment

- **One line**, placed directly above the function, type, const, or code block it explains. No multi-line doc blocks, no decorative banners, no emoji.
- **Never restate the identifier's name.** `// loadConfig reads env vars` is wrong: the reader can already see `func loadConfig`. Start directly with what it does: `// reads and validates all runtime configuration from environment variables.`
- **Start lowercase** (comment is a continued clause, not a standalone sentence with a subject), end with a period.
- **Explain WHY or the non-obvious HOW, not WHAT.** If the code is already self-explanatory from names, skip it. Good candidates: a deliberate workaround for a specific bug, a non-obvious invariant, a magic number, a security-sensitive comparison, a concurrency/ordering guarantee, a fallback path, a format/encoding trick, a redundant-looking check that's actually load-bearing.
- **Skip trivial code.** Simple getters/setters, one-line delegations, obviously-named short helpers, and self-descriptive test names need nothing.
- **Comments aren't only for functions.** Also cover: type/struct definitions when their role isn't obvious from the name, interfaces (especially narrow ones built for testability), package-level constants, and individual lines inside a function body that do something non-obvious (a specific loop direction, an early-return short-circuit, a lock-ordering requirement, a retry/backoff choice).
- **Never fabricate a reason.** If you can't tell *why* from the code, comments/commit history/docs, either investigate (git log/blame, related tests, project docs) before writing, or write only what's verifiably true (mechanism, not motive). Don't guess.
- **Zero logic changes.** This is a comment-only pass. If you notice an actual bug or redundant code while reading, don't fix it inline. Flag it to the user separately and let them decide (see `code-review` skill for that instead).

## Workflow

1. Identify the target file set from the user's request; if genuinely ambiguous, ask.
2. Read each file in full before editing. A comment written from a partial read risks being wrong.
3. For each function/type/const: decide trivial-skip vs comment-worthy. For each function body: scan for non-obvious inline blocks/lines worth a one-line comment.
4. Write comments per the rules above, matching the target language's comment syntax and this project's existing comment style if one is already established in the file.
5. After each file (or batch), verify no behavior changed: run the project's build, vet/typecheck, test, and lint commands for the language involved. Comment-only diffs should never fail these. If one does, you edited more than a comment; fix it.
6. Do not commit unless the user asks. When they do, follow the repo's own git workflow conventions (branch, conventional commit message, confirm before pushing/PR, see project CLAUDE.md if present).

## Completion Gate

Before reporting done:

- Every file in scope was read in full, not skimmed.
- No identifier name is repeated inside its own comment.
- No comment restates what the code already says via naming.
- Build/vet/test/lint all still pass, proving the change was comment-only.
- Trivial code was deliberately left uncommented, not missed.

## Report

State which files were touched, roughly how many comments were added, and call out anything found along the way that looked like a real bug or redundant code (without fixing it) so the user can decide separately.

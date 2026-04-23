# Yamiochi Judge

Use this rubric to review a candidate Yamiochi diff.

## Goal

Approve only diffs that move Yamiochi measurably closer to `SPEC.md` while respecting `FACTORY.md`.

## Hard failures

Mark the change `decision: revise` immediately if any of the following are true:

- The diff touches a denied path from `factory/deny_paths.txt`.
- The change contradicts `SPEC.md`.
- The change adds unnecessary complexity, hidden behavior, or speculative abstractions.
- The change weakens safety, RFC compliance, or observability.
- The change omits tests for new behavior when tests are practical.

## Scoring rubric

Start at `0.0` and add points:

- `+0.30` Clearly advances a concrete `SPEC.md` checkbox or requirement.
- `+0.20` Keeps the implementation simple and easy to extend.
- `+0.20` Adds or improves tests that would catch regressions.
- `+0.15` Preserves reverse-proxy-first, prefork-only, no-TLS assumptions.
- `+0.15` Leaves clear follow-up notes when the work is intentionally partial.

Subtract points for:

- `-0.20` Unclear or weak test evidence.
- `-0.20` Unnecessary dependency, abstraction, or code churn.
- `-0.20` Risk to process model, HTTP correctness, or signal handling.
- `-0.20` Changes that make future scenario-gate work harder.

## Passing threshold

- `score >= 0.80` and no hard failures => `decision: pass`
- otherwise => `decision: revise`

## Output format

Return markdown in exactly this shape:

```text
score: 0.00
decision: pass|revise
summary: one-sentence verdict
strengths:
- bullet
risks:
- bullet
next_actions:
- bullet
```

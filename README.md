# Yamiochi

Yamiochi is a minimal, RFC-compliant HTTP/1.1 Rack server for Ruby.

It is also an experiment in autonomous software development: humans define the target behavior in [`SPEC.md`](./SPEC.md) and the factory rules in [`FACTORY.md`](./FACTORY.md), while a remote software factory does the implementation work.

Yamiochi is designed to run behind a reverse proxy and uses a prefork worker model.

## What the factory is

The Yamiochi factory is the always-on remote system that turns human-written behavior goals into code, pull requests, and merges.

Humans own the control plane:

- [`SPEC.md`](./SPEC.md) defines what Yamiochi must do
- [`FACTORY.md`](./FACTORY.md) defines how the factory is allowed to work
- [`factory/gates.yml`](./factory/gates.yml) defines the current gate frontier
- [`factory/**`](./factory), [`ops/**`](./ops), and [`.fabro/**`](./.fabro) define the workflow, deployment, reporting, and supervision logic

Agents own the implementation work inside the allowed paths, mainly under `lib/**`, `bin/**`, `exe/**`, and `test/unit/**`.

In practice, this means the local checkout is mainly for editing the factory's human-owned control files and inspecting results. Yamiochi feature work is meant to happen on the remote factory host, not by hand in a local dev branch.

## How work flows through the system

The factory is now **gate-driven**.

1. **Humans define behavior and the frontier**
   - Humans update [`SPEC.md`](./SPEC.md), [`FACTORY.md`](./FACTORY.md), and [`factory/gates.yml`](./factory/gates.yml).
   - The gate frontier says which checks are only observed, which are ratcheted, and which are already hard blockers.

2. **The factory selects the next work item**
   - `factory/scripts/autopilot.rb` runs continuously on the remote host.
   - It prefers open PRs first, then gate-derived work packets, then eligible gate promotions, and only falls back to GitHub issues when no gate-derived work is ready.

3. **Fabro runs the implementation workflow**
   - The autopilot creates a disposable clone for the selected work item.
   - It asks Fabro to run the appropriate workflow against that clone.
   - Fabro then executes the agent workflow inside Docker sandboxes.

4. **The candidate diff is validated and normalized into gate results**
   - Validation flows through the repository's `mise` frontends, especially:
     - `mise run lint`
     - `mise run test`
     - `mise run scenarios`
     - `mise run bench`
   - The workflow checks denied paths, runs the judge, and evaluates every named gate with `factory/scripts/evaluate_gates.rb`.

5. **If the blocking gates pass, the diff leaves the box**
   - A successful candidate is pushed to GitHub on a disposable branch.
   - The factory opens a pull request.
   - GitHub Actions and self-hosted runners execute CI.

6. **The factory watches CI and repairs if needed**
   - If CI fails, the factory can run the repair workflow against the same PR branch.
   - If CI passes, the factory merges the PR and promotes the persistent gate state/baselines.
   - Fallback GitHub issues are closed only when issue-backed work was actually completed.

That is the current conveyor belt: **gate state -> work packet -> disposable clone -> Fabro run -> local gate evaluation -> PR -> CI -> repair or merge -> promoted gate state**.

## Gate frontier and state

The control plane separates **declarative frontier** from **persistent result state**:

- [`factory/gates.yml`](./factory/gates.yml) — human-owned registry of named gates and their current levels
- `/var/lib/yamiochi-factory/baselines/gates.json` — persistent remote state with ratchet baselines, recent results, and promotion evidence

Each gate is in exactly one of these modes:

- `observe` — always green, still reported, still generates future work
- `ratchet` — blocks regressions versus `main`, but still allows partial progress
- `hard` — fully passing only; blocks merges absolutely

This lets the factory keep merging incremental progress from v0 → v1 without pretending unfinished holdout suites are already binary blockers.

## Promotion path

The factory can tighten itself, but only narrowly.

- Allowed transitions: `observe -> ratchet`, `ratchet -> hard`
- Forbidden: weakening a gate, removing a gate, or changing scoring rules in a promotion diff
- Promotion diffs are limited to [`factory/gates.yml`](./factory/gates.yml) and must pass `factory/scripts/check_gate_promotions.rb`

## Current control-plane responsibilities

### Fabro

Fabro is responsible for the coding workflow itself:

- reading the selected work item
- planning the change
- editing allowed files
- running local validation inside sandboxes
- producing judge and gate-evaluation artifacts

A Fabro run being marked **successful** means the workflow completed and the candidate passed its in-run blocking gates. It does **not** by itself mean a PR was opened or merged; GitHub-side promotion happens in the outer supervisor loop.

### `factory-autopilot`

`factory/scripts/autopilot.rb` is responsible for everything around the Fabro run:

- syncing fallback issue state from the spec
- selecting gate work or fallback issues
- creating disposable clones
- starting Fabro runs
- opening pull requests
- watching CI
- running repair attempts
- merging green PRs
- closing fallback issues
- promoting persistent gate state
- cooling down repeatedly failing work items

## Why disposable clones are used

The factory favors disposable per-run clones.

That matters because each attempt needs:

- a clean starting point from `main`
- isolated git metadata for branch and PR operations
- a safe place to keep candidate artifacts and failed diffs without contaminating future runs

Disposable clones make it easier for the factory to retry work, quarantine bad attempts, and inspect old candidates.

## What humans should expect

Humans are expected to shape the factory, not hand-implement Yamiochi features.

In this repository, that usually means:

- refining the spec
- adjusting the gate frontier
- improving evaluation and reporting
- tightening promotion safety
- fixing deployment and authentication problems
- making the supervisor more autonomous and more reliable

The goal is for the factory to keep turning gate-driven work into merged changes with as little human intervention as possible.

## Further reading

- [`SPEC.md`](./SPEC.md) — the behavior Yamiochi is trying to satisfy
- [`FACTORY.md`](./FACTORY.md) — the factory contract, gate model, and ownership boundaries
- [`factory/gates.yml`](./factory/gates.yml) — current gate frontier
- [`ops/README.md`](./ops/README.md) — deployment and host setup notes

## License

MIT. See [LICENSE.md](./LICENSE.md).

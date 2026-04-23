# Yamiochi

Yamiochi is a minimal, RFC-compliant HTTP/1.1 Rack server for Ruby.

It is also an experiment in autonomous software development: humans define the target behavior in [`SPEC.md`](./SPEC.md) and the factory rules in [`FACTORY.md`](./FACTORY.md), while a remote software factory does the implementation work.

Yamiochi is designed to run behind a reverse proxy and uses a prefork worker model.

## What the factory is

The Yamiochi factory is the always-on remote system that turns human-written behavior goals into code, pull requests, and merges.

Humans own the control plane:

- [`SPEC.md`](./SPEC.md) defines what Yamiochi must do
- [`FACTORY.md`](./FACTORY.md) defines how the factory is allowed to work
- [`factory/**`](./factory), [`ops/**`](./ops), and [`.fabro/**`](./.fabro) define the workflow, deployment, gates, and supervision logic

Agents own the implementation work inside the allowed paths, mainly under `lib/**`, `bin/**`, `exe/**`, and `test/unit/**`.

In practice, this means the local checkout is mainly for editing the factory's human-owned control files and inspecting results. Yamiochi feature work is meant to happen on the remote factory host, not by hand in a local dev branch.

## How work flows through the system

The factory is meant to move work through a fixed loop:

1. **Humans define behavior**
   - Humans update [`SPEC.md`](./SPEC.md) and [`FACTORY.md`](./FACTORY.md).
   - The factory turns the spec into milestone-shaped GitHub issues.

2. **The factory selects the next issue**
   - `factory/scripts/autopilot.rb` runs continuously on the remote host.
   - It syncs the GitHub issue queue from the spec and selects the next factory-managed issue.
   - Repeatedly failing issues are temporarily cooled down so the system can move on instead of getting stuck forever on one item.

3. **Fabro runs the implementation workflow**
   - The autopilot creates a disposable clone for the selected issue.
   - It asks Fabro to run `.fabro/workflows/implement-issue/workflow.toml` against that clone.
   - Fabro then executes the agent workflow inside Docker sandboxes.

4. **The candidate diff is judged locally before a PR exists**
   - The workflow fetches the issue, plans the work, makes code changes, and runs candidate validation.
   - Validation currently flows through the repository's `mise` frontends, especially:
     - `mise run lint`
     - `mise run test`
     - `mise run scenarios`
   - The workflow also checks denied paths, runs the judge, and computes merge-gate artifacts.

5. **If the candidate is good enough, it should leave the box**
   - A successful candidate is pushed to GitHub on an issue-specific branch.
   - The factory opens a pull request.
   - GitHub Actions and self-hosted runners execute CI.

6. **The factory watches CI and repairs if needed**
   - If CI fails, the factory can run the repair workflow against the same PR branch.
   - If CI passes, the factory merges the PR, closes the issue, and promotes the merge-gate baseline.

That is the core work conveyor belt: **spec -> issue -> disposable clone -> Fabro run -> local gates -> PR -> CI -> repair or merge -> next issue**.

## How the factory is currently set up

Today the factory is deployed as a single remote host with a small number of long-running services:

- **Fabro server** for workflow orchestration and operator visibility
- **`factory-autopilot`** as the host-side supervisor loop
- **Docker sandboxes** for isolated coding runs
- **Self-hosted GitHub Actions runners** on the same machine for CI and heavier jobs
- **Persistent state directories** for repo mirrors, disposable clones, baselines, and run artifacts
- **Caddy + Tailscale-first access** for the private operator UI, with narrow public ingress for GitHub App webhooks only

The current live shape is intentionally simple:

- one remote host
- one long-lived mirror checkout of the repo
- many disposable per-issue clones under the factory state directory
- one continuous supervisor loop that keeps selecting work

## Current control-plane responsibilities

### Fabro

Fabro is responsible for the coding workflow itself:

- reading the selected issue
- planning the change
- editing allowed files
- running local validation inside sandboxes
- producing judge and merge-gate artifacts

A Fabro run being marked **successful** means the workflow completed and the candidate passed its in-run gates. It does **not** by itself mean a PR was opened or merged; GitHub-side promotion happens in the outer supervisor loop.

### `factory-autopilot`

`factory/scripts/autopilot.rb` is responsible for everything around the Fabro run:

- syncing spec-derived issues
- selecting the next issue
- creating disposable clones
- starting Fabro runs
- opening pull requests
- watching CI
- running repair attempts
- merging green PRs
- closing issues
- promoting merge-gate baselines
- cooling down repeatedly failing issues

## Why disposable clones are used

The factory used to mutate a long-lived checkout, but the current setup favors disposable per-issue clones.

That matters because each issue attempt needs:

- a clean starting point from `main`
- isolated git metadata for branch and PR operations
- a safe place to keep candidate artifacts and failed diffs without contaminating future runs

Disposable clones make it easier for the factory to retry work, quarantine bad attempts, and inspect old candidates.

## What humans should expect

Humans are expected to shape the factory, not hand-implement Yamiochi features.

In this repository, that usually means:

- refining the spec
- improving the workflow definitions
- tightening gates and evaluation
- fixing deployment and authentication problems
- making the supervisor more autonomous and more reliable

The goal is for the factory to keep turning spec-shaped work into merged changes with as little human intervention as possible.

## Further reading

- [`SPEC.md`](./SPEC.md) — the behavior Yamiochi is trying to satisfy
- [`FACTORY.md`](./FACTORY.md) — the factory contract, gates, and ownership boundaries
- [`ops/README.md`](./ops/README.md) — deployment and host setup notes

## License

MIT. See [LICENSE.md](./LICENSE.md).

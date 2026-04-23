# Yamiochi Factory

This document describes the software factory that builds Yamiochi, the server specified in [SPEC.md](./SPEC.md).

## 1. Principles

1. **Humans write SPEC.md, FACTORY.md, and merge gates. Agents write everything else.**
2. **Humans do not review or commit code.** All changes are created, approved and merged by the factory itself.

## 2. Components

The factory is an always-on **remote** system. My local machine is only for editing human-owned control files such as `SPEC.md`, `FACTORY.md`, `AGENTS.md`, `.fabro/**`, `factory/**`, and `ops/**`, plus inspecting runs. Feature development and implementation work happen only on the remote Fabro host; this repository is not developed locally.

The deployment model is a docker-compose-defined single-host factory.

- **[fabro](https://github.com/fabro-sh/fabro) control plane** — long-running remote workflow orchestrator. The loop below is a fabro DOT graph.
- **Agent worker pool** — one or more ephemeral runner containers/VMs that execute coding sessions against fresh git worktrees.
- **Judge / merge-gate runner** — computes judge satisfaction and merge-gate outcomes for a candidate diff.
- **Scenario-gates runner** — executes internal and external scenario suites (§3) in isolation.
- **Heavy CI / benchmark lane** — heavyweight self-hosted runner capacity on the same host used for broader validation and benchmark jobs.
- **State store** — durable state for fabro runs, baselines, PR metadata, retries, and queue bookkeeping.
- **Artifact/log store** — persistent storage for worktrees, judge outputs, scenario logs, benchmark results, and release artifacts.
- **mise** — tool and task runner. All factory-invokable tasks have a `mise run <task>` frontend.
- **hk** — parallel pre-commit hooks.
- **External holdout suites** — http-probe.com, h1spec, REDbot, fixture Sinatra and Rails apps. Run as external scenario gates (§3.2).

### 2.1 Compose Shape

`factory/docker-compose.example.yml` should describe the always-on control plane services:

- `fabro`
- `agent-runner` (scaled horizontally)
- `judge`
- `scenario-gates`
- `github-runner-fast`
- `github-runner-heavy`
- `postgres` (or equivalent durable state store)
- `minio` / persistent artifact volume (or equivalent artifact store)
- optionally `release-runner` behind a profile, since release staging is infrequent

Benchmark jobs run on the heavyweight runner lane on the same host; they are not a separately deployed machine.

## 3. Scenario Gates

Scenario gates are the holdout set. Agents observe their outcomes but cannot modify the scenarios themselves.

### 3.1 Internal Scenarios

Live in `test/scenarios/`. Deny-listed from agent writes (§5). Each scenario is a script that:

- Boots a real `yamiochi` process against a fixture Rack app
- Exercises a trajectory (sequence of requests, signals, or config changes)
- Asserts observable behavior (response shape, exit codes, log output, socket state)

Scenarios describe behavior in SPEC.md terms and leave the implementation details up to the agent.

### 3.2 External Scenarios

- [ ] `http-probe.com` reports no failures
- [ ] h1spec (`github.com/uNetworking/h1spec`) reports no RFC 7230–7235 failures
- [ ] REDbot (`github.com/mnot/redbot`, self-hosted) reports no errors
- [ ] A standard Sinatra hello-world app serves correctly under Yamiochi
- [ ] A standard Rails app in production mode serves correctly under Yamiochi

Each external scenario is scored (passing checks, clean URLs, inverse error count) and ratcheted per §8, not evaluated as pass/fail, until it reaches completion.

These execute in `sandbox-exec` as the `scenario-gates` node.

## 4. The Factory Loop

The human-owned factory blueprint is defined in `factory/yamiochi.dot`.

Executable Fabro workflows live under `.fabro/workflows/` and should stay aligned with that blueprint.

The current control-plane split is:

- `select-work` chooses the next issue, preferring human-filed milestone work.
- `implement-issue` produces a candidate diff plus judge/merge-gate artifacts.
- `repair-pr` is the follow-up loop when CI finds something local validation missed.
- `factory/scripts/autopilot.rb` is the host-side supervisor that creates disposable worktrees, runs Fabro, opens PRs, watches CI, merges green diffs, closes issues, and promotes merge-gate baselines.

## 5. What Agents Can Modify

| Path | Agent write? | Owner |
|------|---|---|
| `lib/**`, `bin/**`, `exe/**` | yes | Agent |
| `test/unit/**` | yes | Agent |
| `test/scenarios/**` | no | Human |
| `CHANGELOG.md`, `README.md` | yes | Agent |
| `SPEC.md` | no | Human |
| `FACTORY.md` | no | Human |
| `ops/**` | no | Human |
| `factory/**` (fabro graph, judge prompts, scenario config) | no | Human |
| `.fabro/**` (project and workflow definitions) | no | Human |
| `.github/workflows/**`, `mise.toml`, `hk.pkl` | no | Human |
| `*.gemspec`, `Gemfile` | proposes only, human-gated | Human |
| Release signing key, RubyGems API key | no | Out of repo |

Enforcement: a pre-merge check in `sandbox-exec` fails the run if any denied path appears in the diff.

## 6. Development Environment

Standard mise + hk shape.

- `mise run test` — unit tests
- `mise run lint` — lint
- `mise run bench` — benchmarks
- `mise run scenarios` — internal + external scenario gates
- `mise run factory` — smoke-test one iteration of the factory loop locally; production automation runs remotely via the compose-defined factory

hk runs lint and unit tests in parallel pre-commit.

## 7. Pre-Commit / Push Gates

Every agent-proposed commit before it reaches `main`:

- Lint clean
- Unit tests green
- No denied paths in diff (§5)
- No files above size threshold

## 8. Merge Gates

Every gate is either a **hard gate** (must pass absolutely) or a **ratcheted gate** (must not regress vs. the last green `main`; should advance).

**Hard gates:**

- All §7 pre-commit gates green
- Judge satisfaction score ≥ 0.8 on this diff
- Any binary ratcheted gate that has previously reached green stays green

**Ratcheted gates** — each produces a numeric score; a merge must meet or beat the last green `main` baseline, and advancing the score advances the baseline:

| Gate | Score |
|---|---|
| h1spec | count of passing checks |
| REDbot | count of clean URLs (inverse error count) |
| http-probe.com | inverse failure count |
| Sinatra fixture | count of passing sub-checks |
| Rails fixture | count of passing sub-checks |
| Internal scenarios | count of passing scenarios |
| Benchmark (§9) | throughput req/s, with 95% band for measurement noise |
| SPEC.md Definition of Done | count of checked boxes |

Day-one baselines are 0 (or whatever the first measurement produces), so the first merges are trivially satisfiable. The factory's long-running job is to ratchet each gate toward completion. Once a binary scenario first crosses into green, it pins as a hard gate and cannot regress.

## 9. Benchmarking

SPEC §12 defines the benchmark target. Throughput is a ratcheted gate (§8) with a 95% band for measurement noise: a merge must hit ≥ 95% of the last green baseline, and any improvement advances the baseline. The band is specific to benchmarks; scenario counts are deterministic and ratchet exactly.

Benchmarks run as heavyweight self-hosted runner jobs on the factory host. To keep numbers comparable, benchmark jobs should be serialized onto the heavy lane rather than run concurrently with other heavyweight jobs. Results land in `factory/log/bench/`.

## 10. Releases

The factory builds and stages release artifacts; a human performs the final `gem push` so the RubyGems MFA challenge lands on a human terminal. No RubyGems API key is ever stored in the factory.

**Tooling:** [Shopify/cibuildgem](https://github.com/Shopify/cibuildgem). Yamiochi has no native extensions (SPEC §11), so cibuildgem's matrix build is unused; the workflow shape (tag → build → GitHub release → stop) is what's being adopted.

**Trigger:** a human tags `release/vX.Y.Z` on `main`.

**Automated workflow (`.github/workflows/release.yml`):**

1. Verify tag matches `version.rb`.
2. Regenerate CHANGELOG from merged PRs since the last tag.
3. `gem build` → `yamiochi-X.Y.Z.gem`.
4. Create a GitHub release with the generated CHANGELOG as notes; attach the `.gem` as a release asset. PR/release body otherwise blank.
5. **Stop.** No `gem push`.

**Human final step:**

```sh
gh release download vX.Y.Z --pattern '*.gem'
gem push yamiochi-X.Y.Z.gem   # prompts for RubyGems MFA
```

## 11. Issues and PRs

- Agents may file issues (bug reports from failing scenarios, TODOs extracted from SPEC.md).
- Agents file PRs with blank descriptions.
- Triage and selection happen in `select-work`. Human-filed issues take priority over agent-filed ones.

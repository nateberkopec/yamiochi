# Yamiochi Factory

This document describes the software factory that builds Yamiochi, the server specified in [SPEC.md](./SPEC.md).

## 1. Principles

1. **Humans write `SPEC.md`, `FACTORY.md`, and the gate frontier. Agents write product code.**
2. **The factory is gate-driven.** Future work comes primarily from named gates, not from a large pre-authored GitHub issue backlog.
3. **Gate strictness can only move upward.** Promotions are narrow, monotonic, and machine-checkable.
4. **Humans do not hand-implement Yamiochi features in this checkout.** The remote factory does the implementation work.

## 2. Components

The factory is an always-on **remote** system. My local machine is only for editing human-owned control files such as `SPEC.md`, `FACTORY.md`, `AGENTS.md`, `.fabro/**`, `factory/**`, and `ops/**`, plus inspecting runs. Feature development and implementation work happen only on the remote Fabro host; this repository is not developed locally.

The deployment model is a docker-compose-defined single-host factory.

- **[fabro](https://github.com/fabro-sh/fabro) control plane** — long-running remote workflow orchestrator.
- **Agent worker pool** — ephemeral runner containers/VMs that execute coding sessions against fresh git worktrees.
- **Judge / merge-gate runner** — computes judge satisfaction and gate outcomes for a candidate diff.
- **Scenario-gates runner** — executes internal and external scenario suites (§3) in isolation.
- **Heavy CI / benchmark lane** — heavyweight self-hosted runner capacity on the same host used for broader validation and benchmark jobs.
- **Gate registry** — `factory/gates.yml`, the human-owned frontier describing each gate's current level and scoring model.
- **Gate state store** — persistent host state at `/var/lib/yamiochi-factory/baselines/gates.json`, storing ratchet baselines, recent history, and promotion evidence.
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

Live in `test/scenarios/`. Deny-listed from normal agent writes (§7). Each scenario is a script that:

- Boots a real `yamiochi` process against a fixture Rack app
- Exercises a trajectory (sequence of requests, signals, or config changes)
- Asserts observable behavior (response shape, exit codes, log output, socket state)

Scenarios describe behavior in `SPEC.md` terms and leave the implementation details up to the agent.

### 3.2 External Scenarios

- [ ] `http-probe.com` reports no failures
- [ ] h1spec (`github.com/uNetworking/h1spec`) reports no RFC 7230–7235 failures
- [ ] REDbot (`github.com/mnot/redbot`, self-hosted) reports no errors
- [ ] A standard Sinatra hello-world app serves correctly under Yamiochi
- [ ] A standard Rails app in production mode serves correctly under Yamiochi

These execute in `sandbox-exec` as the `scenario-gates` node.

## 4. Gate Frontier

The gate frontier is defined in the human-owned registry at [`factory/gates.yml`](./factory/gates.yml).

Every gate has exactly one current level:

- `observe`
- `ratchet`
- `hard`

### 4.1 Gate semantics

#### `observe`

- always reports green
- still publishes score, artifacts, and failure breakdown
- never blocks merge
- still generates future work

#### `ratchet`

- green iff candidate score is **>= the current main baseline**
- red iff candidate regresses relative to the main baseline
- improvements advance the baseline after merge
- partial progress is allowed; full completion is not required yet

#### `hard`

- green only when the gate is fully passing
- blocks merge when not fully passing

### 4.2 Registry vs. state

The registry and the state are deliberately separate.

- `factory/gates.yml` — human-owned declarative frontier: level, metric type, score source, grouping, promotion metadata
- `/var/lib/yamiochi-factory/baselines/gates.json` — persistent host state: ratchet baselines, last known results, green/full-pass streaks, and recent history

Agents may not broadly edit factory files. The only narrow self-tightening surface is a promotion diff to `factory/gates.yml` that passes `factory/scripts/check_gate_promotions.rb`.

## 5. The Factory Loop

The human-owned factory blueprint is defined in `factory/yamiochi.dot`.

Executable Fabro workflows live under `.fabro/workflows/` and should stay aligned with that blueprint.

The current control-plane split is:

- `select-work` chooses the next work item, preferring gate-derived packets first.
- `implement-issue` (despite the legacy name) implements the selected work item, whether it came from a gate packet or a fallback issue.
- `repair-pr` is the follow-up loop when CI finds something local validation missed.
- `promote-gate` opens narrow frontier-tightening diffs when a gate has enough evidence to move upward.
- `factory/scripts/autopilot.rb` is the host-side supervisor that creates disposable worktrees, runs Fabro, opens PRs, watches CI, merges green diffs, closes fallback issues, and promotes gate baselines/state.

The operational loop is:

1. Prefer already-open factory PRs and repair/merge them.
2. Evaluate current gate state.
3. Generate a work packet from the highest-priority gate need:
   - failing hard gate
   - regressing ratchet gate
   - ratchet improvement opportunity
   - observe-gate opportunity
4. If no gate-derived work is available, optionally fall back to human-filed factory issues.
5. Run Fabro in a disposable worktree.
6. Validate the candidate, judge it, and evaluate gates.
7. Open a PR only when the blocking gates pass.
8. Watch CI, repair if needed, merge when green, then promote baselines/state.

## 6. Work Generation

Gate failures and regressions are the primary source of future work.

`factory/scripts/generate_work_packet.rb` derives a machine-readable packet containing at least:

- target gate
- priority reason (`hard_fail`, `ratchet_regression`, `ratchet_opportunity`, `observe_opportunity`)
- narrowed focus area / failure slice when available
- success condition
- evidence / artifact references

`factory/scripts/select_work.rb` prefers:

1. gate-derived work packets
2. gate-promotion packets
3. fallback GitHub issues only when no gate-derived work is ready

Spec-derived GitHub issues remain as a compatibility lane during migration, not as the primary conceptual queue.

## 7. What Agents Can Modify

| Path | Agent write? | Owner |
|------|---|---|
| `lib/**`, `bin/**`, `exe/**` | yes | Agent |
| `test/unit/**` | yes | Agent |
| `test/scenarios/**` | no | Human |
| `CHANGELOG.md`, `README.md` | yes | Agent |
| `SPEC.md` | no | Human |
| `FACTORY.md` | no | Human |
| `ops/**` | no | Human |
| `factory/gates.yml` | promotion-only, monotonic, machine-validated | Human frontier |
| `factory/**` (other than `factory/gates.yml`) | no | Human |
| `.fabro/**` (project and workflow definitions) | no | Human |
| `.github/workflows/**`, `mise.toml`, `hk.pkl` | no | Human |
| `*.gemspec`, `Gemfile` | proposes only, human-gated | Human |
| Release signing key, RubyGems API key | no | Out of repo |

Enforcement:

- `factory/scripts/check_denied_paths.rb` fails the run if a denied path appears in the diff.
- The only exception is a promotion-only diff limited to `factory/gates.yml` that also passes `factory/scripts/check_gate_promotions.rb`.

## 8. Development Environment

Standard mise + hk shape.

- `mise run test` — unit tests
- `mise run lint` — lint
- `mise run bench` — benchmarks
- `mise run scenarios` — internal + external scenario gates
- `mise run factory` — smoke-test one iteration of the factory loop locally; production automation runs remotely via the compose-defined factory

hk runs lint and unit tests in parallel pre-commit.

## 9. Local Validation

Every candidate is normalized through `factory/scripts/evaluate_gates.rb`.

That script reads:

- validation artifacts from `factory/scripts/run_candidate_checks.rb`
- judge output from `tmp/judge.md`
- gate frontier from `factory/gates.yml`
- persistent state from `/var/lib/yamiochi-factory/baselines/gates.json`

It emits a machine-readable report that, for each gate, shows:

- level (`observe`, `ratchet`, `hard`)
- candidate score/result
- main baseline and ratchet threshold when relevant
- full-pass target when known
- pass/fail status under the current level
- artifact references

## 10. Promotion Workflow

Gate promotion is allowed, but only narrowly.

Allowed transitions:

- `observe -> ratchet`
- `ratchet -> hard`

Forbidden transitions:

- `hard -> ratchet`
- `ratchet -> observe`
- removing a gate
- changing scoring or safety fields in a promotion diff

Promotion evidence is machine-checked using the persistent gate state. A promotion requires repeated full-pass history as defined in `factory/gates.yml` and validated by `factory/scripts/check_gate_promotions.rb`.

Promotion PRs should stay separate from product-improvement PRs whenever practical.

## 11. Benchmarking

`SPEC.md` §12 defines the benchmark target. Throughput is a ratcheted gate with a 95% band for measurement noise: a merge must hit ≥ 95% of the last green baseline, and any improvement advances the baseline. The band is specific to benchmarks; scenario counts are deterministic and ratchet exactly.

Benchmarks run as heavyweight self-hosted runner jobs on the factory host. To keep numbers comparable, benchmark jobs should be serialized onto the heavy lane rather than run concurrently with other heavyweight jobs. Results land in `factory/log/bench/`.

## 12. Releases

The factory builds and stages release artifacts; a human performs the final `gem push` so the RubyGems MFA challenge lands on a human terminal. No RubyGems API key is ever stored in the factory.

**Tooling:** [Shopify/cibuildgem](https://github.com/Shopify/cibuildgem). Yamiochi has no native extensions (`SPEC.md` §11), so cibuildgem's matrix build is unused; the workflow shape (tag → build → GitHub release → stop) is what's being adopted.

**Trigger:** a human tags `release/vX.Y.Z` on `main`.

**Automated workflow (`.github/workflows/release.yml`):**

1. Verify tag matches `version.rb`.
2. Regenerate `CHANGELOG.md` from merged PRs since the last tag.
3. `gem build` → `yamiochi-X.Y.Z.gem`.
4. Create a GitHub release with the generated changelog as notes; attach the `.gem` as a release asset. PR/release body otherwise blank.
5. **Stop.** No `gem push`.

**Human final step:**

```sh
gh release download vX.Y.Z --pattern '*.gem'
gem push yamiochi-X.Y.Z.gem   # prompts for RubyGems MFA
```

## 13. Issues and PRs

- Agents may still file issues (bug reports from failing scenarios, TODOs extracted from `SPEC.md`, or operator notes), but issues are now a fallback queue rather than the primary work model.
- Agents file PRs with blank descriptions.
- Triage and selection happen in `select-work`. Gate-derived packets come first; human-filed issues are explicit fallback/override work.

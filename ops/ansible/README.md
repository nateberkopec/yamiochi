# Ansible deployment

This directory bootstraps and deploys the remote Yamiochi factory host.

## Assumptions

- target host is a manually provisioned Hetzner box
- initial bootstrap SSH access already works
- Debian/Ubuntu family host
- Docker Engine + Docker Compose will be installed by Ansible
- Tailscale will be installed by Ansible
- after bootstrap, management access should happen through the tailnet
- the factory stack runs from `/opt/yamiochi-factory`
- secrets are sourced with **fnox + 1Password on the control machine**, not on the host

## Files to copy locally

```sh
cp ops/ansible/inventory/hosts.example.yml ops/ansible/inventory/hosts.yml
cp ops/ansible/group_vars/all.example.yml ops/ansible/group_vars/all.yml
```

Then edit:

- `inventory/hosts.yml` — initial host IP / SSH user, then later swap to the Tailscale IP or MagicDNS name
- `group_vars/all.yml` — repo URL, host paths, runner sizing, Tailscale hostname/settings, and the local path to the rendered runtime env file

Neither file should be committed.

## Expected secret flow

Both bootstrap and deploy read from the same local env file generated on the control machine.

1. On the control machine, materialize a runtime env file with `fnox`:

```fish
ops/fnox/materialize.fish
```

2. The deploy playbook copies that file to the host as:

```sh
/opt/yamiochi-factory/.env.runtime
```

3. Bootstrap reads values like `TAILSCALE_AUTH_KEY` from that local file.
4. Deploy copies the file to the host and the systemd unit starts Docker Compose with it.

The host never talks to 1Password directly.

## Tailscale / inbound access model

The intended posture is:

- install Tailscale on the host
- join the tailnet during bootstrap
- deny non-tailnet inbound traffic with the host firewall
- access SSH and factory services over Tailscale only
- expose only a narrow public HTTPS ingress for GitHub App webhooks
- expose the Fabro operator UI privately on a MagicDNS hostname with Caddy-managed internal TLS, HTTP/2, and compression

The ingress shape is:

- Caddy listens on `80/443`
- the private MagicDNS host (for example `https://yamiochi-factory-1.tail6cc978.ts.net`) terminates with a host-local certificate signed by a host-local private CA, enables HTTP/2 plus `zstd`/`gzip`, and reverse proxies to Fabro on `127.0.0.1:32276`
- `https://fabro-hooks.speedshop.co` only proxies `POST /api/v1/webhooks/github`
- everything else on the public webhook host returns `404`

That gives operators a fast private UI over Tailscale without widening public exposure beyond the GitHub webhook route.

### Trusting the private UI certificate

Deploy creates a private root CA at `/etc/caddy/private-ui/rootCA.crt` and signs the Fabro UI certificate with it. Each operator machine that should load the private HTTPS UI without warnings must trust that root certificate locally.

## One-box EX63 service split

The current deployment shape assumes a single large EX63 host with three active services/lane types:

- `fabro` — the control plane, using Fabro's published server image
- `factory-autopilot` — a lightweight loop that selects the next issue, creates a disposable worktree, runs Fabro, opens a PR, waits for CI, merges green diffs, closes the issue, and promotes merge-gate baselines
- `github-runner-fast` — self-hosted Actions lane for quick PR validation
- `github-runner-heavy` — self-hosted Actions lane for heavier suites, including benchmark jobs

Fabro itself is configured to execute runs in Docker sandboxes on the same host via `/var/run/docker.sock`, using a locally-built sandbox image (default tag: `fabro-agent:latest`). The deploy also runs the Fabro server container as `root` so it can talk to the host Docker socket and create sibling run sandboxes. The sandbox image now also carries the `fabro` CLI so the autopilot container can call `fabro run`, `fabro pr create`, and `fabro pr merge` directly.

Default sizing in `group_vars/all.example.yml`:

- `fabro` at `2 CPU / 4 GB`
- `github-runner-fast` x1 at `1 CPU / 3 GB`
- `github-runner-heavy` x1 at `3 CPU / 16 GB`

The intended workflow is:

1. `factory-autopilot` selects the next open issue, preferring milestone-bearing human-filed work, and creates a disposable worktree under `{{ factory_state_root }}/worktrees`
2. Fabro runs the repo workflow inside that disposable worktree with PR automation enabled
3. `factory-autopilot` uses `fabro pr create` to open a PR, watches GitHub checks, and uses `fabro pr merge` once CI is green
4. GitHub Actions on the self-hosted runners runs the broader suite, including benchmarks on the heavy lane
5. Successful merges promote the ratcheted merge-gate baseline stored under `{{ factory_state_root }}/baselines/merge-gates.json`

## Playbooks

### Bootstrap host

```sh
ansible-playbook -i ops/ansible/inventory/hosts.yml ops/ansible/playbooks/bootstrap.yml
```

Installs/configures:

- Docker Engine / docker-compose
- Tailscale
- UFW default-deny inbound policy with tailnet access allowed
- public `80/443` only for the webhook ingress when enabled
- git, curl, jq
- baseline directories for deployment

### Deploy factory

```sh
ansible-playbook -i ops/ansible/inventory/hosts.yml ops/ansible/playbooks/deploy.yml
```

Renders/copies/builds:

- `docker-compose.yml`
- `config/settings.toml` for Fabro, including sandbox GitHub token pass-through and factory baseline/worktree env vars
- `sandbox-image/Dockerfile` for the local Docker sandbox image
- local sandbox image tag from `factory_sandbox_image` (default `fabro-agent:latest`)
- a clean checkout of `factory_repo_url` at `factory_repo_checkout_path`
- `/opt/yamiochi-factory/.env.runtime`
- `/opt/yamiochi-factory/.env.server`
- compose wrapper script
- systemd unit
- Caddyfile for webhook-only public ingress

Then enables and starts `yamiochi-factory.service` and Caddy.

The compose stack includes two self-hosted GitHub Actions runners:

- `github-runner-fast` labeled `factory-fast`
- `github-runner-heavy` labeled `factory-heavy`

Jobs should target those labels explicitly so GitHub does not schedule heavyweight work onto the lightweight lane.

The example runner container expects `GITHUB_RUNNER_ACCESS_TOKEN` in `.env.runtime` so it can self-register with GitHub.

## Open questions still not locked down

- exact workflow graph / autonomous queueing setup for the Yamiochi factory loop
- exact GitHub Actions workflow split between `factory-fast` and `factory-heavy`, especially for benchmark serialization
- whether we later expose more than the webhook route publicly or keep all operator access Tailscale-only

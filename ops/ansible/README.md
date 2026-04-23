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

The public ingress shape is:

- Caddy listens on `80/443`
- only `POST /api/v1/webhooks/github` is proxied to Fabro on `127.0.0.1:32276` by default
- everything else returns `404`

That gives GitHub App mode the one public hook it needs without making the rest of the box public.

## One-box EX63 service split

The current deployment shape assumes a single large EX63 host with three active services/lane types:

- `fabro` — the control plane, using Fabro's published server image
- `github-runner-fast` — self-hosted Actions lane for quick PR validation
- `github-runner-heavy` — self-hosted Actions lane for heavier suites, including benchmark jobs

Fabro itself is configured to execute runs in Docker sandboxes on the same host via `/var/run/docker.sock`, using a locally-built `yamiochi-fabro-sandbox:latest` image.

Default sizing in `group_vars/all.example.yml`:

- `fabro` at `2 CPU / 4 GB`
- `github-runner-fast` x1 at `1 CPU / 3 GB`
- `github-runner-heavy` x1 at `3 CPU / 16 GB`

The intended workflow is:

1. Fabro orchestrates runs and executes them in Docker sandboxes on the box
2. agents work primarily through draft PRs / GitHub integration
3. GitHub Actions on the self-hosted runners runs the broader suite, including benchmarks on the heavy lane
4. Fabro observes CI outcomes and decides whether to iterate or merge

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

Renders/copies:

- `docker-compose.yml`
- `config/settings.toml` for Fabro
- `sandbox-image/Dockerfile` for the local Docker sandbox image
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

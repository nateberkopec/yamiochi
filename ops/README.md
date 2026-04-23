# Operations

This repo currently assumes a **manually provisioned Hetzner EX63** (or similar) for the factory control plane.

The current plan is:

1. Bring up the host manually in Hetzner/Robot.
2. Add temporary bootstrap SSH access.
3. Use **Ansible** to install Docker, Tailscale, and the factory stack.
4. Cut over management access so the host is reachable only through the tailnet, except for a narrow public webhook ingress.

## Layout

- `ansible/` — host bootstrap + factory deployment
- `fnox/` — local secret materialization from 1Password into a deploy-time env file

The current deployment target is a **single EX63** that hosts:

- Fabro control plane services
- a locally-built Docker sandbox image for Fabro runs
- lightweight agent runners
- self-hosted GitHub Actions runners for the broader validation suite, including benchmarks on the heavy lane
- Tailscale + narrow public webhook ingress

## Secrets

Deployment is wired around **fnox + 1Password**, but only on the **control machine**.

- Secrets themselves stay in the Speedshop account's **Employee** vault.
- `fnox` resolves them locally into a deploy-time env file.
- Ansible copies that resolved env file to the host.
- The host does **not** get direct 1Password access.
- GitHub App secrets can still be used; the only public exposure is a webhook-only HTTPS ingress.

## Model provider

Fabro supports OpenAI directly.

The default deployment examples now assume:

- provider: `openai`
- model: `gpt-5.4`

We can revisit OpenAI OAuth vs plain `OPENAI_API_KEY` once the host is up

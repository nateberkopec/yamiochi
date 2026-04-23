# fnox secret materialization

The Hetzner factory host should **not** have direct 1Password access.

Instead:

1. Authenticate to 1Password on your **local control machine**.
2. Use `fnox` locally to materialize a runtime env file from the Speedshop account's **Employee** vault.
3. Ansible copies that resolved env file to the host as `/opt/yamiochi-factory/.env.runtime`.

That keeps 1Password access off the server while still using fnox + 1Password as the source of truth.

## Setup

```sh
cp ops/fnox/fnox.toml.example ops/fnox/fnox.toml
mkdir -p ops/ansible/.secrets
```

Edit `ops/fnox/fnox.toml` if you need to change the 1Password account, vault, item name, attachment name, or field names.

## Materialize runtime env locally

```fish
ops/fnox/materialize.fish
```

That helper exports fnox as JSON, base64-encodes the GitHub App PEM attachment onto one line, and writes `ops/ansible/.secrets/factory.env` in plain `KEY=value` form.

That file is ignored by git and is what the deploy playbook pushes to the host.

## Expected 1Password item fields

The current example is wired to these 1Password records in the Speedshop `Employee` vault:

- item `Tailscale Auth Key` → field `password`
- item `Yamiochi Github App` → fields `client_secret`, `webhook_secret`
- item `Yamiochi Github App` → attached file `yamiochi-factory.2026-04-22.private-key.pem`
- item `Yamiochi OpenAI Key` → field `password`
- item `Github` → field `do everything Classic`

You can rename any of them in `fnox.toml`.

For now, the config reuses `Github/do everything Classic` for both `GITHUB_TOKEN` and `GITHUB_RUNNER_ACCESS_TOKEN` so the runner container can self-register with GitHub. That's the easiest day-one setup; you can split those later if you want a narrower token.

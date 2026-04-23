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

Edit `ops/fnox/fnox.toml` if you need to change the vault, item name, or field names.

## Materialize runtime env locally

```sh
cd ops/fnox
fnox export > ../ansible/.secrets/factory.env
```

That file is ignored by git and is what the deploy playbook pushes to the host.

## Expected 1Password item fields

The example config expects one item with these fields:

- `GitHub App Client Secret`
- `GitHub App Webhook Secret`
- `GitHub App Private Key`
- `GitHub Token`
- `GitHub Runner Access Token`
- `OpenAI API Key`
- `MinIO Root User`
- `MinIO Root Password`
- `Benchmark Host`
- `Benchmark SSH User`
- `Benchmark SSH Key`

You can rename any of them in `fnox.toml`.

For the runner container scaffolding, `GitHub Runner Access Token` should be a token with enough permission to register self-hosted runners for the target repo.

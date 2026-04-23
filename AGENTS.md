# AGENTS.md

## Remote-only development

Yamiochi is developed remotely on the Fabro host running on Hetzner.

- Do not treat this local checkout as the place where feature implementation happens.
- Human-authored control files may be edited locally: `SPEC.md`, `FACTORY.md`, `AGENTS.md`, `.fabro/**`, `factory/**`, and `ops/**`.
- Code changes intended to implement Yamiochi behavior should be executed by Fabro on the remote host against the GitHub repo, not by doing local development here.
- When preparing the factory, prefer committing and pushing the control-plane files first, then run or validate through the remote Fabro instance.

## Ownership reminders

Follow `FACTORY.md` for the source of truth on path ownership and merge gates.

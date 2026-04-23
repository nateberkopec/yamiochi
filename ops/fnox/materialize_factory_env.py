#!/usr/bin/env python3
import base64
import json
import sys
from pathlib import Path

if len(sys.argv) != 3:
    raise SystemExit(f"usage: {Path(sys.argv[0]).name} <input-json> <output-env>")

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
data = json.loads(src.read_text())["secrets"]
keys = [
    "REPO_URL",
    "REPO_REF",
    "MODEL_PROVIDER",
    "MODEL_NAME",
    "FABRO_DOMAIN",
    "TAILSCALE_AUTH_KEY",
    "GITHUB_RUNNER_REPO_URL",
    "GITHUB_APP_ID",
    "GITHUB_APP_CLIENT_ID",
    "GITHUB_APP_SLUG",
    "GITHUB_APP_CLIENT_SECRET",
    "GITHUB_APP_WEBHOOK_SECRET",
    "GITHUB_APP_PRIVATE_KEY",
    "GITHUB_TOKEN",
    "GITHUB_RUNNER_ACCESS_TOKEN",
    "OPENAI_API_KEY",
]
lines = []
for key in keys:
    value = data[key]
    if key == "GITHUB_APP_PRIVATE_KEY":
        value = base64.b64encode(value.encode()).decode()
    if "\n" in value or "\r" in value:
        raise SystemExit(f"{key} still contains newlines")
    lines.append(f"{key}={value}")
dst.parent.mkdir(parents=True, exist_ok=True)
dst.write_text("\n".join(lines) + "\n")

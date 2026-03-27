from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path


KIT_ROOT = Path(__file__).resolve().parents[1]


def assert_no_private_values(text: str) -> None:
    forbidden = [
        "axion-11988045139",
        "joao-alquimista-axion-2026",
        "209.74.85.44",
        "AIza",
        "Victor Manzano",
        "Daniel",
    ]
    for value in forbidden:
        if value in text:
            raise AssertionError(f"private value leaked: {value}")


def main() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        output = Path(tmp) / "runtime-sample"
        cmd = [
            sys.executable,
            str(KIT_ROOT / "scripts" / "render_setup.py"),
            "--output",
            str(output),
            "--client-slug",
            "sample",
            "--display-name",
            "Sample Enterprise",
            "--container-name",
            "sample-openclaw",
            "--account-id",
            "sample-5511999999999",
            "--gateway-token",
            "oc_sample_token",
            "--allowed-origin",
            "https://agent.sample.local",
            "--gateway-port",
            "18889",
            "--webchat-port",
            "18890",
        ]
        subprocess.run(cmd, check=True, capture_output=True, text=True)

        openclaw = json.loads((output / "config" / "openclaw.json").read_text(encoding="utf-8"))
        jobs = json.loads((output / "config" / "cron" / "jobs.json").read_text(encoding="utf-8"))
        assert openclaw["agents"]["defaults"]["model"]["primary"] == "openrouter/xiaomi/mimo-v2-pro"
        assert openclaw["agents"]["defaults"]["model"]["fallbacks"][0] == "openai/gpt-5.4"
        assert all(job["agentId"] == "orquestrador" for job in jobs["jobs"])
        assert (output / "tools" / "ops" / "whatsapp_task_governance.sh").exists()
        assert (output / "tools" / "install_whatsapp_ops.sh").exists()

        rendered_text = (output / "config" / "openclaw.json").read_text(encoding="utf-8")
        rendered_text += (output / "config" / "agents" / "hq" / "agent" / "instructions.md").read_text(encoding="utf-8")
        assert_no_private_values(rendered_text)

        compose_text = (output / "docker-compose.yml").read_text(encoding="utf-8")
        assert "ghcr.io/openclaw/openclaw:latest" in compose_text
        assert "sample-openclaw" in compose_text

        print("SETUP_KIT_VALID")


if __name__ == "__main__":
    main()

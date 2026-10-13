"""Exercise the standalone Light script's native failure and artifact contracts."""

from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts" / "install-hermes-light.ps1"


def run_contract(tmp_path: Path, body: str) -> subprocess.CompletedProcess[str]:
    shell = shutil.which("pwsh") or shutil.which("powershell")
    if not shell:
        pytest.skip("PowerShell host unavailable")
    # Dot-source the real script with an unsafe destination: it must refuse
    # before fetching/building, while leaving its actual helpers callable.
    occupied = tmp_path / "occupied"
    occupied.write_text("do not overwrite", encoding="utf-8")
    harness = tmp_path / "contract.ps1"
    harness.write_text(
        """param([string]$Script, [string]$Occupied, [string]$Desktop)
$ErrorActionPreference = 'Stop'
$before = (Get-Location).Path
$env:HERMES_DESKTOP_VARIANT = 'original-variant'
$env:HERMES_DESKTOP_REMOTE_URL = 'https://original.example'
$refused = $false
try { . $Script -Destination $Occupied } catch { $refused = $true }
if (-not $refused) { throw 'Unsafe destination accepted' }
if ((Get-Location).Path -ne $before) { throw 'Location not restored' }
if ($env:HERMES_DESKTOP_VARIANT -ne 'original-variant') { throw 'Variant not restored' }
if ($env:HERMES_DESKTOP_REMOTE_URL -ne 'https://original.example') { throw 'URL not restored' }
"""
        + body,
        encoding="utf-8",
    )
    return subprocess.run(
        [
            shell,
            "-NoProfile",
            "-NonInteractive",
            "-File",
            str(harness),
            str(SCRIPT),
            str(occupied),
            str(tmp_path / "desktop"),
        ],
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )


@pytest.mark.parametrize(
    "defect",
    ["none", "source-stamp", "packaged-stamp", "update-owner", "payload", "main-exe"],
)
def test_light_artifact_rejects_backend_or_incomplete_output(tmp_path: Path, defect: str):
    desktop = tmp_path / "desktop"
    folder = desktop / "release" / "win-unpacked"
    resources = folder / "resources"
    resources.mkdir(parents=True)
    (desktop / "build").mkdir()
    for location in [desktop / "build", resources]:
        stamp = {"payload": "light", "updateMechanism": "external"}
        if (defect == "source-stamp" and location.name == "build") or (
            defect == "packaged-stamp" and location == resources
        ):
            stamp["payload"] = "bundled"
        if defect == "update-owner":
            stamp["updateMechanism"] = "app-installer"
        (location / "install-stamp.json").write_text(json.dumps(stamp), encoding="utf-8")
    if defect == "payload":
        (resources / "agent-payload").mkdir()
    # A helper EXE must never be mistaken for the main product.
    (folder / "helper.exe").touch()
    if defect != "main-exe":
        (folder / "Hermes Light.exe").touch()
    result = run_contract(
        tmp_path,
        "$exe = Assert-LightArtifact $Desktop 'Hermes Light'\n"
        "if ($exe -ne (Join-Path $Desktop 'release/win-unpacked/Hermes Light.exe')) "
        "{ throw 'Wrong executable' }\n",
    )
    assert (result.returncode == 0) == (defect == "none"), result.stdout + result.stderr
    assert (tmp_path / "occupied").read_text(encoding="utf-8") == "do not overwrite"


def test_native_failure_stops_orchestration(tmp_path: Path):
    child = tmp_path / "failed.ps1"
    child.write_text("exit 23\n", encoding="utf-8")
    result = run_contract(
        tmp_path,
        """$caught = $false
try {
    Invoke-Native (Get-Process -Id $PID).Path @('-NoProfile', '-File', (Join-Path (Split-Path $Occupied) 'failed.ps1'))
} catch {
    if ($_.Exception.Message -notlike '*exit 23*') { throw }
    $caught = $true
}
if (-not $caught) { throw 'Native failure was ignored' }
""",
    )
    assert result.returncode == 0, result.stdout + result.stderr

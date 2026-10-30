#!/usr/bin/env python3
"""Publish a FlareStore/AltStore-compatible catalog after a successful GitHub Release.

The workflow is the only release publisher. No credentials or signing materials
are embedded in the feed. ``repo.json`` and ``source.json`` remain identical.
"""

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlparse


BASE = "https://raw.githubusercontent.com/soum91/vaultbridge/main"
ASSET_BASE = "https://github.com/soum91/vaultbridge/releases/download/"


def make_feed(existing: dict, *, version: str, build: str, date: str,
              url: str, size: int, notes: str) -> dict:
    parts = version.split(".")
    if len(parts) != 4 or not all(part.isdigit() for part in parts):
        raise ValueError("Version must contain four numeric parts, such as 0.1.0.3")
    if str(int(build)) != parts[-1] or int(build) < 1:
        raise ValueError("Build must match the last version component")
    parsed = urlparse(url)
    if parsed.scheme != "https" or not url.startswith(ASSET_BASE) or not url.endswith("/VaultBridge.ipa"):
        raise ValueError("Download URL must be a direct VaultBridge GitHub Release IPA asset")
    if size < 1:
        raise ValueError("Release IPA must not be empty")

    entry = {
        "version": version,
        "buildVersion": build,
        "date": date,
        "localizedDescription": notes,
        "changelog": notes,
        "downloadURL": url,
        "size": size,
        "minOSVersion": "17.0",
    }
    older = ((existing.get("apps") or [{}])[0].get("versions") or [])
    versions = [entry] + [item for item in older if item.get("version") != version]

    icon = f"{BASE}/ios/VaultBridge/Assets.xcassets/AppIcon.appiconset/Icon-1024.png"
    return {
        "name": "VaultBridge",
        "identifier": "com.soum91.vaultbridge.source",
        "subtitle": "Password vault for iPhone and Windows",
        "description": "Unsigned development builds. Manual Apple and Google password imports; live Firefox Sync and cross-device vault sync are not ready. Do not store real passwords until security validation is complete.",
        "sourceURL": f"{BASE}/source.json",
        "iconURL": icon,
        "apps": [{
            "name": "VaultBridge",
            "bundleIdentifier": "com.soum91.vaultbridge",
            "developerName": "soum91",
            "subtitle": "Multiple password sources in one local vault",
            "localizedDescription": "Development preview. Import Apple Passwords, Google/Chrome or Firefox CSV, or add credentials manually. Passwords are locally protected. Live Firefox Sync, Windows browser autofill and end-to-end device sync are still pending.",
            "category": "utilities",
            "iconURL": icon,
            "versions": versions,
        }],
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--artifact", type=Path, required=True)
    parser.add_argument("--notes", type=Path, required=True)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()

    root = args.root
    previous = json.loads((root / "repo.json").read_text(encoding="utf-8")) if (root / "repo.json").exists() else {}
    catalog = make_feed(
        previous,
        version=args.version,
        build=args.build,
        date=datetime.now(timezone.utc).strftime("%Y-%m-%d"),
        url=args.url,
        size=args.artifact.stat().st_size,
        notes=args.notes.read_text(encoding="utf-8").strip(),
    )
    payload = json.dumps(catalog, ensure_ascii=False, indent=2) + "\n"
    for target in ("repo.json", "source.json"):
        (root / target).write_text(payload, encoding="utf-8")
    print(f"Published {args.version} ({catalog['apps'][0]['versions'][0]['size']} bytes) to both JSON aliases")


if __name__ == "__main__":
    main()

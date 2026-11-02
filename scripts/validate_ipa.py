#!/usr/bin/env python3
"""Fail a release before publication if the unsigned IPA bundle is malformed."""

import argparse
import plistlib
import zipfile
from pathlib import Path


def validate(ipa: Path, build: str) -> None:
    app = "Payload/VaultBridge.app/"
    with zipfile.ZipFile(ipa) as archive:
        failures = archive.testzip()
        if failures is not None:
            raise ValueError(f"Broken IPA member: {failures}")
        names = set(archive.namelist())
        required = [
            app + "Info.plist",
            app + "VaultBridge",
            app + "Assets.car",
            app + "PlugIns/VaultBridgeAutoFill.appex/Info.plist",
        ]
        missing = [name for name in required if name not in names]
        if missing:
            raise ValueError("IPA is missing required app/extension members: " + ", ".join(missing))
        info = plistlib.loads(archive.read(app + "Info.plist"))
        if info.get("CFBundleIdentifier") != "com.soum91.vaultbridge":
            raise ValueError("Unexpected app bundle identifier")
        if str(info.get("CFBundleVersion")) != build:
            raise ValueError("Bundled build number does not match FlareStore feed build")
        # A missing UILaunchScreen makes sideloaded iPhone apps fall back to
        # legacy compatibility scaling, visibly clipping or letterboxing UI.
        if "UILaunchScreen" not in info:
            raise ValueError("Missing UILaunchScreen: iPhone UI may launch in legacy scaled mode")
        if "ASCredentialExchangeActivityType" not in info.get("NSUserActivityTypes", []):
            raise ValueError("App is missing the Apple Passwords credential-exchange activity")
        extension_info = plistlib.loads(archive.read(required[-1]))
        if extension_info.get("CFBundleIdentifier") != "com.soum91.vaultbridge.autofill":
            raise ValueError("AutoFill extension has an unexpected bundle identifier")
        capabilities = (extension_info.get("NSExtension", {})
                        .get("NSExtensionAttributes", {})
                        .get("ASCredentialProviderExtensionCapabilities", {}))
        if capabilities.get("SupportsCredentialExchange") is not True:
            raise ValueError("AutoFill extension is not advertised as a credential-exchange receiver")
        if "1.0" not in capabilities.get("SupportedCredentialExchangeVersions", []):
            raise ValueError("AutoFill extension lacks Credential Exchange Format 1.0 support")
    print(f"Validated unsigned VaultBridge IPA: build {build}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--build", required=True)
    opts = parser.parse_args()
    validate(opts.ipa, opts.build)

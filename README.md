# VaultBridge

Native iPhone and Windows password vault, intended to aggregate credentials from Firefox Sync, Apple Passwords and Google Password Manager.

## Honest implementation status

This is a **first source milestone**, not a production-ready password manager. It includes a SwiftUI iPhone app, a Windows WPF app, a common CSV interpretation policy, OS-protected local storage, manual entries and native CSV import. It does **not** yet include a working Mozilla sign-in flow, automatic Firefox synchronization, iPhone/Windows vault transport, Windows browser extension or a signed IPA/EXE. Do not import irreplaceable passwords until the apps are reviewed and device-tested.

| Source | Planned mechanism | Current status |
| --- | --- | --- |
| Firefox Sync | Reuse the existing FxA/Sync 1.5 encryption, token and login collection code from `soum91/reynard-browser`, branch `firefox-account-sync` | Integration tracked; not yet wired into the standalone app |
| Apple Passwords/iCloud | User-authorized CSV import | Implemented in source |
| Google Password Manager / Chrome | User-authorized CSV import | Implemented in source |
| Local | Add an entry in the app | Implemented in source |

Chrome/Google Password Manager and iCloud Keychain do not offer a supported third-party API for silently reading all synced credentials. Their imports are snapshots, **not** live two-way sync. Passkeys are not transferred by these password CSV imports.

## Why this project is separate from Drift and Reynard

Passwords must not be carried through ordinary clipboard synchronization. The vault is separate from Drift, and Firefox authentication and record decryption should be independently contained within VaultBridge. Credentials should be associated with a provider + provider account + source record ID; imports should not mutate upstream managers by default.

## Structure

- `ios/`: SwiftUI iPhone application with Keychain-backed local vault, native Files picker and Face ID/passcode reveal.
- `windows/`: .NET WPF application with Windows DPAPI-protected vault, CSV file picker and clipboard-copy action.
- `docs/`: security requirements and Firefox porting checklist.

## Build requirements

- iOS: macOS with Xcode 16+ and XcodeGen (`cd ios && xcodegen generate`). Set your signing team and provision the Keychain sharing entitlement for both app and AutoFill target. Review the bundle IDs before distributing. The source hasn't been compiled here because the host lacks Xcode.
- Windows: Windows with .NET 8 SDK (`dotnet build windows/VaultBridge.Windows/VaultBridge.Windows.csproj -c Release`). The source hasn't been compiled here because the host lacks .NET.

## FlareStore feed and automatic releases

Once the first iOS release workflow completes successfully, import either of these URLs into FlareStore:

`https://raw.githubusercontent.com/soum91/vaultbridge/main/repo.json`

`https://raw.githubusercontent.com/soum91/vaultbridge/main/source.json`

The GitHub Actions iOS workflow creates a real GitHub Release containing `VaultBridge.ipa`, then updates both JSON feeds with the direct download URL, file size, dated changelog, and monotonically increasing `0.1.0.BUILD` version. These are **unsigned development builds**. The IPA must be signed before installing and AutoFill/Keychain entitlement sharing still needs on-device verification.

The feed updater refuses to publish a GitHub Actions artifact URL as if it were a direct IPA. It also preserves old version entries for compatibility and rollback. The iOS workflow ignores feed-only bot commits to avoid endless release loops.

## Security contract

- Local storage uses iOS Keychain (`WhenUnlockedThisDeviceOnly`) or Windows DPAPI (`CurrentUser`). No server-side password store is present.
- Device-bound local secrets do not magically cross-sync: a future cross-device channel must use authenticated, end-to-end encryption with dedicated keys.
- Never log raw credentials, Firefox tokens or plaintext imported CSV contents.
- Imported CSVs remain **plaintext in the source file**. Delete them from Files/Downloads and any cloud-sync folder after import; this app does not delete source files.
- Source priority, duplicate resolution, write-back, account revocation and recovery must be designed and tested before any automatic bidirectional synchronization.

## Next milestones

1. Extract and adapt the existing Reynard `FxAAccountManager`, `FxACrypto`, `SyncStorageClient` and the password-only portion of `SyncManager`; replace Gecko WebChannel dependencies with a supported account authorization flow and re-test with a disposable Mozilla account.
2. Implement the equivalent Firefox connector on Windows, using a compatible, maintained Sync library or carefully audited shared core.
3. Device-test both vaults, their extensions and malformed CSV handling, then run a security review.
4. Build authenticated, end-to-end encrypted device synchronization and Windows browser autofill.

This source milestone deliberately never claims a source is synchronized when it has only been imported.

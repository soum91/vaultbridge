# VaultBridge

Native iPhone and Windows password vault, intended to aggregate credentials from Firefox Sync, Apple Passwords and Google Password Manager.

## Honest implementation status

### UI regression rule (retain for every iOS build)

Never release a sideloaded iOS app without a generated **UILaunchScreen** entry in
its final bundled Info.plist. Missing launch screens can make the UI render in
legacy scaled/letterboxed mode on modern iPhones. The IPA validator must reject
this. Use adaptive SwiftUI layouts, small-screen safe-area checks, and do not
advertise unfinished connection features as working. Test the installed IPA
visually, not just Xcode compilation. The original VaultBridge oversized form
and EmberTV's clipped layout are explicit regressions to prevent.

### Expected account behavior

The desired product is **sign in and automatically fetch passwords**, especially
Firefox Sync using the account implementation already in Reynard. CSV export is
only an advanced fallback, not the core workflow. An account UI that merely
opens a login page without securely fetching passwords is **not** a completed
connector. Apple iCloud Keychain and Google Password Manager do not expose a
general third-party read-all-passwords API; never fake live integrations or
request their account passwords directly.

This is a **development preview**, not a production-ready password manager. It includes a SwiftUI iPhone app, a Windows WPF app, OS-protected local storage, manual entries and native CSV import. The iOS app now includes an **opt-in read-only Reynard Keychain bridge** that can fetch credentials already synchronized by Reynard under a shared signing team. This is not an independent Mozilla sign-in flow, and the shared Keychain entitlement is unverified on sideloaded devices. It does **not** include an independent Mozilla sign-in, Windows/iPhone vault transport, Windows browser extension or a production-signed release. Do not import irreplaceable passwords until the apps are reviewed and device-tested.

| Source | Planned mechanism | Current status |
| --- | --- | --- |
| Firefox Sync | Read-only local bridge to Reynard's already-decrypted Keychain store; own Mozilla account client is separate work | iOS implementation added, pending signing/device validation; not available on Windows |
| Apple Passwords/iCloud | User-authorized CSV import | Implemented in source |
| Google Password Manager / Chrome | User-authorized CSV import | Implemented in source |
| Local | Add an entry in the app | Implemented in source |

Chrome/Google Password Manager and iCloud Keychain do not offer a supported third-party API for silently reading all synced credentials. Their imports are snapshots, **not** live two-way sync. Passkeys are not transferred by these password CSV imports.

## Why this project is separate from Drift and Reynard

Passwords must not be carried through ordinary clipboard synchronization. The vault is separate from Drift, and Firefox authentication and record decryption should be independently contained within VaultBridge. Credentials should be associated with a provider + provider account + source record ID; imports should not mutate upstream managers by default.

## Structure

- `ios/`: SwiftUI iPhone application with Keychain-backed local vault, native Files picker, Face ID/passcode reveal and optional Reynard Sync Keychain reader.
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

1. Device-test the shared Keychain entitlement with a disposable Mozilla account and both Reynard/VaultBridge signed by the same Apple team. The integration is opt-in, read-only, refreshes when VaultBridge becomes active, and never deletes saved entries on Keychain access/decode failure.
2. Extract and adapt the existing Reynard `FxAAccountManager`, `FxACrypto`, `SyncStorageClient` and the password-only portion of `SyncManager`; replace Gecko WebChannel dependencies with a supported account authorization flow and re-test with a disposable Mozilla account.
3. Implement the equivalent Firefox connector on Windows, using a compatible, maintained Sync library or carefully audited shared core.
4. Device-test both vaults, their extensions and malformed CSV handling, then run a security review.
5. Build authenticated, end-to-end encrypted device synchronization and Windows browser autofill.

This source milestone deliberately never claims a source is synchronized when it has only been imported.

# Firefox Sync integration plan

Source: `https://github.com/soum91/reynard-browser/tree/firefox-account-sync`
Inspected branch head: `55eecc5b63114b0072bf14bd4c55acec01e3a40a` (October 26, 2026).

This is an integration specification, **not** a claim that Mozilla sign-in or password refresh already works in VaultBridge.

## Confirmed existing components

| Reynard source file | Responsibility |
| --- | --- |
| `browser/Reynard/Client/Sync/Account/FxAAccountManager.swift` | Firefox Account OAuth + PKCE, key recovery and token refresh |
| `browser/Reynard/Client/Sync/Account/FxAAccountStorage.swift` | Keychain account/session storage and Sync settings |
| `browser/Reynard/Client/Sync/Account/FxAConfig.swift` | Mozilla endpoints/client registration settings |
| `browser/Reynard/Client/Sync/Account/FxAHTTP.swift` | HTTP requests |
| `browser/Reynard/Client/Sync/Crypto/FxACrypto.swift` | Scoped key handling, Hawk auth, Sync payload encryption |
| `browser/Reynard/Client/Sync/Engine/SyncStorageClient.swift` | Token server and Sync 1.5 storage API |
| `browser/Reynard/Client/Sync/Engine/SyncManager.swift` | Clients/tabs/history/bookmarks/password collections; password logic starts near `syncPasswords` |
| `browser/CredentialProvider/SyncedLogins.swift` | Password record model and Keychain storage |
| `browser/Reynard/Client/Sync/Account/FxAWebChannelController.swift` | GeckoView-based WebChannel sign-in handoff |

## Required isolation work

1. Extract the password collection reader and cryptography without pulling in bookmarks, tabs, SQLite history, GeckoView or browser UI.
2. Replace the Gecko `AddonMessageDelegate` / `AddonPortDelegate` WebChannel dependency. Use a Mozilla-approved account authorization flow and a distinct, properly registered client ID where required. Do **not** scrape Mozilla account passwords or bypass session protections.
3. Refactor the singleton `FxAAccountManager.shared` into one account session per connected Firefox account. Persist refresh token and Sync root key under an account-specific Keychain service/account.
4. On each refresh, download only changed `passwords` records; reconcile GUIDs, deleted tombstones, timestamps, and server backoff. Preserve the last known-good vault on network or decryption failures.
5. Convert each record into `VaultCredential` with `source = Firefox`, `sourceAccount = verified Mozilla account identifier`, and a durable source GUID. Current CSV identity fallback is not sufficient for live Sync records.
6. Port via a shared, audited Rust Sync component or a maintained Mozilla implementation to Windows. Avoid writing a second, incompatible encryption protocol from memory.
7. Verify OAuth state/PKCE, token refresh/rotation, sign-out revocation, rotation of encryption keys, and password correctness with disposable accounts before allowing real data.

## Explicit non-goals in the first release

- No Firefox password edits or deletions pushed upstream until two-way conflict semantics are tested.
- No secrets in GitHub Actions secrets, build logs, Drift pasteboard transport, crash reports, or support bundles.
- No assumption that a second app can read Reynard's Keychain merely because the same code or service name is reused. Cross-app Keychain access requires matching provisioning entitlements.

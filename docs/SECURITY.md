# Security and delivery gates

VaultBridge is security-sensitive software. Until a code review and signed device builds pass, use test credentials only.

## Present safeguards

- iOS local data is stored as a Keychain generic-password item, with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- The iOS UI asks for LocalAuthentication before revealing or copying a password.
- Windows data is encrypted using the interactive user's Windows DPAPI key. This is at-rest protection, not a replacement for an app-level lock screen.
- Imported CSV records have one stable, provider-scoped record identifier based on source and key fields for idempotent re-import.
- Empty passwords are discarded. No import writes back to Firefox, Apple or Google.
- The apps have no telemetry, account-token upload or backend connection.

## Open security requirements before real use

1. A shared, vetted cryptographic vault format with a strong recovery design and independent review.
2. Real Windows Hello authentication; per-operation protection rather than sole reliance on Windows sign-in.
3. iOS AutoFill extension sharing entitlement and verification across the actual sideload signing flow.
4. Distinguish `com.example.com` from sibling domains when matching AutoFill identities. Never match only by string suffix without a dot-boundary check.
5. Clipboard expiration or equivalent handling, and a user setting to disable clipboard altogether.
6. Secure duplicate/conflict handling, per-source revocation, audit of CSV parsers, and memory-lifetime testing.
7. Production-safe Firefox account OAuth client registration, refresh token storage and encrypted Sync record handling.
8. An external security review plus reproducible, signed build artifacts.

## Threat boundaries

An unlocked/compromised OS account may be able to extract secrets. DPAPI and Keychain are device protection layers, not guarantees against malware. CSV exports are plaintext and can remain in browser downloads, cloud backups, trash or indexing systems. Never put password data or auth tokens in GitHub, crash reports, logs, Drift pasteboard sync, or issue attachments.

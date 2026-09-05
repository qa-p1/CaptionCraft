# Connected services

CaptionCraft v0.10.0 uses optional, user-supplied API keys. After first login,
choose **Set up services** or **Skip for now**. The same screen is available from
the Home settings button and Profile → Settings · Connected services.

| Service | Optional feature | Create a key |
| --- | --- | --- |
| Groq | Automatic captions | [Groq console](https://console.groq.com/keys) |
| GIPHY | GIFs and stickers | [Developer dashboard](https://developers.giphy.com/dashboard/) |
| Pexels | Stock photos and videos | [Pexels API](https://www.pexels.com/api/) |
| Pixabay | Stock images and videos | [Pixabay API documentation](https://pixabay.com/api/docs/) |

These links open your native browser. Paste just the key, then select **Save keys
securely**. Keys are masked by default. Saving checks the input format, not whether
the provider has approved the key: the service reports rejection or quota limits
when used. Provider signup/approval may take longer than the two-minute app setup.
Your provider account's quotas and charges apply; CaptionCraft no longer imposes
the previous three-run transcription limit.

Editing, importing local media, manual captions and exporting require no API keys.
Openverse sound search and public asset packs need no user API credential.
Automatic captions send the selected audio to Groq over HTTPS. Stock searches send
the search query and the corresponding key directly to that provider. No shared
developer key or transcription proxy is used.

## Encryption and recovery

Keys are encrypted with AES-256-GCM before any Firestore upload. Each encryption
uses a fresh nonce and is bound to the account UID. Firestore receives only a
versioned ciphertext envelope, never the decryption secret or plaintext API keys.
Owner-only database rules reject other accounts, listing and malformed updates.
The ciphertext document is `users/{uid}/private/apiKeys`.

This device keeps its account-specific envelope and a random 256-bit decryption
secret in platform secure storage. Keep the displayed recovery code in a password
manager; it is the secret required to unlock the backup after switching devices
or losing the local secure-storage record. It is separate from your login password.
Anyone with both your account access and recovery code can decrypt your keys.
Clipboard copying is optional and the code must be treated as sensitive.

Normal restarts and later logins on the same device remember the keys. On another
device, use **Restore encrypted cloud backup** once. A wrong code leaves local
keys unchanged. If you lose the code, **Lost recovery code? Start over** requires
confirmation before replacing the locked backup with an empty one and generating
a new code. Projects are not affected; provider keys must be entered again.

Keys save locally first. Offline cloud writes remain pending across restarts; use
**Retry cloud backup** when connected. Updates check the remote revision to avoid
overwriting another device's changes. On a conflict, restore the cloud backup
(this explicitly replaces local keys), then make the desired edits again.
Removing a key disables that service; save the change and let it sync. Revoke a
key from its provider dashboard if it must stop working everywhere immediately.

Windows currently runs in local desktop mode without a provisioned Firebase
desktop account. Keys are stored securely on that PC; there is no Windows cloud
backup or cross-device restore. Android/iOS use the signed-in account's encrypted
Firestore backup. Android backups exclude device-bound secure preferences; iOS
uses Keychain. Device compromise, an unlocked shared OS account, or malicious
software can still expose keys while an app uses them.

## Build and operational configuration

`.env`, `flutter_dotenv`, provider Dart defines and
`CAPTIONCRAFT_TRANSCRIPTION_PROXY_URL` are no longer build/runtime requirements.
Flutter's own `FLUTTER_BUILD_NUMBER` metadata is still used for asset compatibility;
it is supplied by the build tool, not an API configuration file.
Ignored local `.env` files are not read, bundled, migrated into accounts or deleted.
Firebase public client configuration remains tracked; it identifies the app's
authentication/database project and is not a provider secret. Android signing
secrets are still required. The existing iOS workflow produces an **unsigned** IPA,
which needs Apple signing before installation/distribution.

Deploy Firestore rules with:

```sh
firebase deploy --only firestore:rules --project captioncraft-b1abb
```

The owner-scoped policy was deployed during this change, replacing public test-mode
rules. Existing Firebase rulesets are retained by Firebase for rollback. Do not
restore public test-mode access. Firebase App Check enforcement, quotas and real
signed-in device operation still need platform/account validation before store
submission; neither mock tests nor an unsigned build proves those checks.

## Targeted checks

```sh
flutter analyze
flutter test test/api_key_vault_test.dart test/api_settings_screen_test.dart test/runtime_api_keys_test.dart test/groq_service_test.dart
```

The vault tests cover encrypted persistence, account isolation, tampering, recovery,
offline saves, conflicts, device-storage failures and explicit backup replacement.
UI tests cover optional setup, masking, narrow layouts, browser links and delayed
cloud hydration. API clients are checked for live key changes/removal and safe
errors without transmitting actual keys to providers.

`tool/firestore_rules_test.cjs` runs 18 access/shape checks against a local
Firestore emulator at `127.0.0.1:8187`, using project `demo-captioncraft-vault`.
Start a Firestore emulator on that port (with `firestore.rules`), install
`firebase` and `@firebase/rules-unit-testing` in a disposable directory, set
`NODE_PATH` to that directory's `node_modules`, then run:

```sh
node tool/firestore_rules_test.cjs
```

The script explicitly targets the emulator and never tests against production data.

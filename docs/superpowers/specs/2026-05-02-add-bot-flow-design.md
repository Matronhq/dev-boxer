# Add-bot flow: cross-signed bots across multiple dev boxes

**Status:** design
**Date:** 2026-05-02
**Owner:** dan

## Goal

Let an operator who already has dev-boxer running on box #1 (homeserver host, with their Element user account verified and signed in) bring up a new box that runs its own bridge, with its own bot, **cross-signed by the existing user, without typing any human-account credentials anywhere**.

End state on box #2: bridge is running, the user opens their existing Element session, sees a new "Claude Code Bridge (`<box-name>`)" room with the new bot already showing as verified, and `!start` works immediately.

## Non-goals

- Multi-bot bridges on a single box.
- Multi-tenant homeserver onboarding (new humans on shared homeserver).
- Recover/rotate workflows for an existing bot. (Re-running `add-bot` for a known name will reprint creds; tearing down a bot is a future `remove-bot`.)
- Web/SSH-based credential transfer (operator copy-pastes the blob between two terminals).

## Use case

Single user, single homeserver, multiple VPS / spare-hardware boxes. Each box runs its own bridge for its own bot, all signed into the same Element session. Adding a new box should be: install dev-boxer + paste a one-line blob.

## High-level flow

### On box #1 (the homeserver host)

```
$ sudo dev-boxer add-bot box4
==> Opening registration window on local homeserver
==> Registering @box4:matrix.example.com
==> Bootstrapping bot secret storage + cross-signing
==> Sending verification request to @dan:matrix.example.com from the bot
    Open Element. You should see a verification request from @box4.
    Accept it and confirm the emojis.
    Waiting for verification… (timeout 5 min)
==> Verification accepted — bot master key signed by user
==> Bridge room created: !abc:matrix.example.com (you've been invited)
==> Closing registration window

============================================================
  Paste this blob into the installer on box4:
============================================================
db1:eyJob21lc2VydmVyIjoiaHR0cHM6Ly9tYXRyaXgu...c=
============================================================
```

While the script is running, the operator opens Element on phone/laptop, taps "Verify" on the incoming request, confirms the emojis. No passwords typed. Box #1's side auto-confirms SAS (safe because the bot ↔ homeserver leg is loopback; the security boundary is the user's Element session).

### On box #2 (fresh VPS)

```
$ curl -fsSL .../install.sh | sudo bash
... (wizard runs) ...
> Matrix homeserver: (here / there): there
> Paste add-bot blob from your homeserver box: db1:eyJ...

  Validating blob…
  Decoded:
    homeserver:    https://matrix.example.com
    bot user ID:   @box4:matrix.example.com
    bridge room:   !abc:matrix.example.com
  ✓ Stored in secrets.yml

... (rest of install) ...

==> Matrix bridge first-start bootstrap
    Logging in as @box4, restoring secret storage, signing this device
==> Bridge ready
```

After install, the user's existing Element session shows the new bridge room with `@box4` already verified.

## Component layout

### New files in `dev-boxer`

- **`bin/add-bot`** (or `add-bot.rb` at repo root) — Ruby entry point. Loads `config.yml` + `secrets.yml` the same way `setup.rb` does, then drives the orchestration class. Refuses to run unless `matrix.mode == bundled` (this is a homeserver-host-only command). Refuses to run without an explicit `--name` argument (no auto-derived default — would clash with the local bot).
- **`lib/dev_boxer/add_bot.rb`** — orchestration class. Reuses `Shell`, `Log`, and helpers extracted from `MatrixBridge`.
- **`lib/dev_boxer/credentials_blob.rb`** — pure encode/decode of the bot creds blob (versioned: `db1:<base64-json>`). Has its own minitest.

### Touched files in `dev-boxer`

- **`lib/dev_boxer/modules/08_matrix_bridge.rb`** —
  - Lift `open_registration` / `close_registration` / `register_bot_via_api` into a shared module or service object so `AddBot` can call them too. They're currently private methods on `MatrixBridge`. (`create_bridge_room` stays private — `add-bot.mjs` creates the bridge room itself within its matrix-js-sdk session.)
  - In `external` mode, wire the new bot creds (user_id, password, recovery key, bridge room id) into `bridge_env_vars` so the bridge process can read them from `.env`.
- **`lib/dev_boxer/wizard.rb`** — matrix prompt becomes `here / there` (drop `disabled` from the wizard surface; the underlying mode enum stays as-is for now). New `there` branch prompts for the blob, decodes via `CredentialsBlob`, persists everything to `secrets.yml`, sets `mode: external`.
- **`lib/dev_boxer/config.rb`** — extend the matrix subsection schema with new optional keys: `bot_user_id`, `bot_password`, `bot_recovery_key`, `bridge_room_id`, and a `bots:` map (see "Schema" below).
- **`config.example.yml`** — document the new fields.

No changes to `setup.rb`. `add-bot` is its own entry point.

### New files in `claude-matrix-bridge`

- **`add-bot.mjs`** — invoked by `add_bot.rb`. Runs as the dev user, talks to `localhost` homeserver. Logs in as the freshly-registered bot, bootstraps bot SSSS + bot CSK, opens or finds a DM with the user, sends `m.key.verification.request`, auto-confirms SAS on the bot side, polls until the user's side completes the dance. Verifies that `cryptoApi.userTrust(@bot).isCrossSigningVerified() == true` as a sanity check. Creates the encrypted bridge room and invites the user. Writes `bot_recovery_key` and `bridge_room_id` to a tmpfs creds-file (mode 0600) for `add_bot.rb` to slurp.

### Touched files in `claude-matrix-bridge`

- **`index.js`** — small bootstrap helper that runs before `client.start()`:
  1. Detect first run (sentinel `~/.claude-matrix-bot-crypto/.bootstrapped` missing).
  2. If first run AND `MATRIX_ACCESS_TOKEN` is empty AND `MATRIX_BOT_PASSWORD` + `MATRIX_BOT_RECOVERY_KEY` are present:
     - Login with bot password → access token + device_id.
     - Bootstrap SSSS using the existing recovery key (no new key created — restores cross-signing private keys from server-side SSSS).
     - Bootstrap cross-signing so this device is signed by the bot's self-signing key.
     - Persist the obtained access token (back into `.env` via a small shell-out, so subsequent restarts use it directly).
     - Drop the `.bootstrapped` sentinel.
  3. Re-init `MatrixClient` with the new access token if we just obtained one.

## Bot creation + verification on box #1 (detail)

```
add-bot <new-box-name>
  └─ pre-flight: refuse unless mode == bundled and matrix.user_username is set
  └─ refuse if bots[<name>] already exists in secrets.yml unless --reprint
  └─ persist bot username + password to secrets.yml BEFORE opening reg window
     (so a crash mid-flow doesn't lose creds; re-runs reuse them)
  └─ open_registration(reg_token)
  └─ register_bot_via_api(bot_password, reg_token, username: <name>)
  └─ run add-bot.mjs (Node, dev user, localhost homeserver)
       ├─ login as bot → access_token, device_id
       ├─ initRustCrypto + sync
       ├─ bootstrapSecretStorage → bot_recovery_key
       ├─ bootstrapCrossSigning → bot master/self/user signing keys
       ├─ create-or-find DM with @user
       ├─ sdk.startVerificationDM(@user) → verification request emitted
       ├─ wait for user to accept; do SAS
       │     ├─ on .verifier event: auto-confirm SAS on bot side
       │     │   (safe: bot↔homeserver is localhost; security boundary
       │     │    is the user's Element session)
       │     └─ poll until verifier.done OR 5-min timeout
       ├─ sanity-check: cryptoApi.userTrust(@bot).isCrossSigningVerified()
       ├─ create encrypted bridge room, invite @user → bridge_room_id
       ├─ logout the temporary device
       └─ write tmpfs creds-file: bot_recovery_key, bridge_room_id
  └─ close_registration                                 (in `ensure`)
  └─ persist final fields to secrets.yml under bots[<name>]
  └─ assemble blob: { homeserver_url, server_domain, bot_user_id,
                       bot_password, bot_recovery_key, bridge_room_id }
  └─ encode and print: "db1:<base64-json>"
```

### Notes

- **Auto-confirming SAS on the bot side:** `verifier.confirm()` without comparing emojis. The threat model: only the user's Element session can be MITM'd in any meaningful way; the bot's connection to the homeserver is loopback. Confirming both sides means the operator only has to look at one screen (Element) instead of two.
- **Bot's own SSSS:** new vs. the existing first-bot flow (which doesn't bootstrap SSSS for the bot). Required so that box #2 can later restore the bot's signing keys.
- **HMAC secret is not in the blob.** Each box's bridge has its own viewer service; signed URLs never cross boxes; box #2 generates a fresh `hmac_secret` during install as it always has.
- **Naming.** `add-bot box4` registers `@box4:server_domain`. Bare and clean. The existing `default_bot_username` of `claude-bot-<host>` is inconsistent with this — worth aligning in a follow-up cleanup, out of scope here.

## Credentials blob

### Format

```
db1:<base64-encoded JSON>
```

Decoded JSON:

```json
{
  "homeserver_url": "https://matrix.example.com",
  "server_domain":  "matrix.example.com",
  "bot_user_id":    "@box4:matrix.example.com",
  "bot_password":   "...",
  "bot_recovery_key": "EsTm 4uK4 ...",
  "bridge_room_id": "!abc:matrix.example.com"
}
```

### Versioning

`db1:` is the only version we ship in v1. Future incompatible changes bump to `db2:`. Box #2's wizard refuses unknown versions with a "upgrade box #2 first" message.

### Validation rules

- Reject unknown version prefix.
- Reject malformed base64.
- Reject decoded JSON missing any required key.
- Reject if `bot_user_id` doesn't match `@<localpart>:<server_domain>`.

## Box #2 import flow (detail)

### Wizard

`there` branch:
1. Prompt: "Paste add-bot blob from your homeserver box:".
2. Decode via `CredentialsBlob.decode(input)`. On failure, show error and re-prompt.
3. Persist `bot_user_id`, `bot_password`, `bot_recovery_key`, `bridge_room_id` to `secrets.yml` under `matrix.*`.
4. Persist `homeserver_url`, `server_domain`, and `bot_username` (parsed from `bot_user_id`) to `config.yml` under `matrix.*`.
5. Set `mode: external`.

### Matrix-bridge module

In `external` mode, no new orchestration in Ruby. The module just adds the new fields to `bridge_env_vars`:

```
"MATRIX_BOT_USER_ID"      => config.matrix.bot_user_id,
"MATRIX_BOT_PASSWORD"     => config.matrix.bot_password,
"MATRIX_BOT_RECOVERY_KEY" => config.matrix.bot_recovery_key,
"MATRIX_BRIDGE_ROOM_ID"   => config.matrix.bridge_room_id,
```

If `bot_access_token` is already in `secrets.yml` (subsequent runs after first start), the bridge ignores password + recovery key.

### Bridge first-start bootstrap

See `index.js` change above. Inline in the bridge process — no separate node script, no tmpfs creds-file dance on box #2. Recovery key stays in `.env` (mode 0600, owned by dev user) for disaster-recovery (a wiped `~/.claude-matrix-bot-crypto/` re-bootstraps automatically on the next start).

## `secrets.yml` schema additions

### Box #1 (homeserver host)

Existing single-bot fields stay for box #1's own bot. Add:

```yaml
matrix:
  # existing single-bot fields stay for box #1's own bot:
  bot_username: ...
  bot_access_token: ...
  ...

  # new: bots created via add-bot for OTHER boxes
  bots:
    box4:
      bot_user_id:       "@box4:matrix.example.com"
      bot_password:      ...
      bot_recovery_key:  ...
      bridge_room_id:    "!abc:matrix.example.com"
      created_at:        2026-05-02T12:34:56Z
    box5:
      ...

# NB: no `bot_access_token` here. Box #1 never logs in as the issued bot
# after handing it off; box #2 mints its own access token at first start.
```

`add-bot --reprint box4` regenerates the blob from this without any homeserver round-trip.

### Box #2 (bot host)

```yaml
matrix:
  bot_user_id:       "@box4:matrix.example.com"
  bot_password:      ...
  bot_recovery_key:  ...
  bot_access_token:  ...           # written by bridge first-start bootstrap
  bridge_room_id:    "!abc:matrix.example.com"
  hmac_secret:       ...           # generated locally, not from blob
```

## Failure modes, retries, idempotency

### Box #1 during `add-bot`

| Failure | Behaviour |
|---|---|
| User never opens Element / doesn't accept verification within 5 min | Script times out. Bot account exists but isn't cross-signed. Outer `ensure` closes registration. Re-run `add-bot box4`: registration step short-circuits on `M_USER_IN_USE`, script logs in with persisted password, re-issues verification request. |
| Script crashes mid-flow (homeserver hiccup, etc.) | Bot username + password were persisted to `secrets.yml` *before* opening registration, so re-runs reuse them rather than rotating. Registration window always closes via `ensure`. |
| User accepts verification but SAS fails (emoji mismatch) | Real MITM or buggy client. Script reports failure, exits non-zero. |
| `add-bot` run twice for the same `--name`, first run completed | Without `--reprint`: refuse and instruct. With `--reprint`: regenerate blob from `secrets.yml`, no homeserver round-trip. |

### Box #2 during install

| Failure | Behaviour |
|---|---|
| Pasted blob malformed | Wizard rejects, re-prompts. |
| Blob version unrecognised | Wizard refuses with "upgrade box #2 first". |
| Bridge first-start bootstrap fails (recovery key wrong, server unreachable) | Bridge logs error, exits non-zero. systemd restarts; if permanent, it loops. Operator edits `.env` or pastes a fresh blob. |
| Re-run of `setup.rb --only matrix-bridge` after successful import | Bridge skips bootstrap (sentinel exists). |
| `~/.claude-matrix-bot-crypto/` deleted | Next bridge start re-bootstraps from `secrets.yml`. Recovery is automatic — that's why we keep `bot_recovery_key` in `secrets.yml` rather than wiping after first use. |

## Out of scope

- **Revoking a bot.** If you tear down box #5, the bot account stays on the homeserver and the bridge room lingers in the user's Element. Future `dev-boxer remove-bot box5` can deregister + leave.
- **Aligning the existing default bot username** (`claude-bot-<host>` → `<host>`).
- **Removing `disabled` from the matrix mode enum** — wizard already won't surface it after this work.

## Testing

### Unit tests (minitest, no network)

- `test/credentials_blob_test.rb`
  - Round-trip encode/decode.
  - Reject unknown version prefix.
  - Reject malformed base64.
  - Reject decoded JSON missing required keys.
- `test/add_bot_test.rb`
  - Stub `add-bot.mjs` invocation via fake `Shell`. Assert: registration window opens before `add-bot.mjs` runs and closes in `ensure` even when stub raises.
  - Bot creds persisted to `secrets.yml` before the verification window opens.
  - Idempotent: running twice with the same name + completed prior run produces the same blob.
  - Refuses to run without `--name`.
  - Refuses to run if `mode != bundled`.
- `test/wizard_test.rb` — extend
  - "there" branch prompts for blob, parses it, persists to `secrets.yml`, sets `mode: external`.
  - Malformed blob → re-prompt.
- `test/matrix_bridge_test.rb` — extend
  - In external mode with imported bot creds, `bridge_env_vars` contains the four new keys.

### Manual end-to-end test plan

1. Spin up two fresh Ubuntu 24.04 VMs.
2. Run normal installer on box-A (`mode: here`). Confirm bridge works, Element shows `box-A` bot verified.
3. On box-A: `sudo dev-boxer add-bot box-B`. Open Element on phone, accept verification request, confirm emojis. Copy blob.
4. On box-B: run installer, pick `there`, paste blob.
5. Confirm box-B's bridge room appears in Element with `@box-B` already showing as verified.
6. Send `!start` in box-B's room, confirm a Claude Code session starts.
7. Re-run installer on box-B (idempotency). Re-run `add-bot box-B` on box-A (should `--reprint` or refuse cleanly).
8. Wipe `~/.claude-matrix-bot-crypto/` on box-B, restart bridge. Bootstrap should re-run from `secrets.yml`'s recovery key.

### Out of unit-test reach

- The actual SAS dance with Element (real client required).
- The bridge's first-start bootstrap (real homeserver required).

Both are covered by the manual E2E plan.

## Open questions

1. **Does the existing single-machine onboarding actually cross-sign the bot?** Reading the code, `setup-user.mjs`'s `identity.verify()` call appears to no-op because the bot has never logged in at that point and so has no master CSK on the server. This needs an end-to-end verification on a fresh box. If confirmed broken, the cleanest fix mirrors what `add-bot` does: register → bot logs in and bootstraps own SSSS+CSK → user runs setup-user.mjs which can now find and sign bot's master key. Decide whether to fold this into the same PR or split.
2. **`.env` rewrite from the bridge process.** After first-start bootstrap, the bridge needs to persist its new access token. Cleanest is a small shell-out to `dev-boxer write-secret matrix.bot_access_token <value>` so the secrets file stays canonical. Alternative: write a sidecar token file in `~/.claude-matrix-bot-crypto/` and have the bridge always prefer it over `.env`. Pick during implementation.
3. **Verification sanity-check in `add-bot.mjs`.** `cryptoApi.userTrust(...).isCrossSigningVerified()` is the obvious check after SAS, but verify the exact API name in the matrix-js-sdk version pinned in the bridge repo's `package.json`.

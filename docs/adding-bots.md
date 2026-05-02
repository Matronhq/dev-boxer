# Adding bots from another box

When you already have one Dev Boxer machine running with the bundled
homeserver and your Element session set up, you can stand up additional
boxes that connect back to the same homeserver with their own bot —
without typing any human-account credentials anywhere.

## On the homeserver host

```bash
sudo dev-boxer add-bot box4
```

This:
1. Opens a one-time registration window on the local homeserver.
2. Registers `@box4:<server_domain>`.
3. Bootstraps the bot's own secret storage and cross-signing identity.
4. Sends a verification request to your user from the bot.
5. Waits while you open Element, accept the request, and confirm the
   emojis (5-minute timeout).
6. Creates an encrypted bridge room and invites you.
7. Closes the registration window.
8. Prints a one-line credentials blob.

## On the new box

Run the standard installer. When the wizard asks `Matrix homeserver:
(here / there)`, choose `there` and paste the blob. The wizard stores
the bot creds in `secrets.yml`, the matrix-bridge module wires them
into `.env`, and the bridge process bootstraps itself on first start
(restoring the bot's signing keys via the recovery key in the blob and
signing this box's device with the bot's self-signing key).

After the install completes, your existing Element session shows the
new bridge room with `@box4` already verified.

## Re-printing a blob

```bash
sudo dev-boxer add-bot --reprint box4
```

This regenerates the blob from `secrets.yml` (`matrix.bots.box4`) without
touching the homeserver. Useful if you lost the blob between boxes.

## Removing a bot

Not yet supported. Tracked in the design doc's "Out of scope" section.

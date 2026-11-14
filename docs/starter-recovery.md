# Starter setup: recovery and maintenance

These commands apply to the **first Matron / add a box** starter profile. Run them in your private SSH terminal on the VPS. Connect with `ssh dev@YOUR_VPS_IP`; the starter keeps port 22 and installs the public key supplied during setup.

## Interrupted installation

Run the original installer command again. It keeps the installed checkout, saved settings, account password, encryption key, agent token and local connector overlay. Components come from the revisions in `components.json`; a normal rerun does not pull newer versions.

If the `matron` command has already been installed, `sudo matron resume` is equivalent. Otherwise use `sudo /opt/dev-boxer/setup.rb`. The error tells you which step failed and how to start there with `--from NAME`.

Before closing the original connection, open a second terminal and test SSH as `dev`. If setup stopped before that user was created, use the provider's initial login or recovery console.

## Status and sign-in

| Command | Result |
| --- | --- |
| `sudo matron status` | Checks services, browser HTTPS and certificate expiry/renewal. |
| `sudo matron login` | Signs into the selected AI as the correct Linux user and checks a short reply. This uses a small amount of AI allowance. |
| `sudo matron link` | Shows the saved password and a fresh phone sign-in QR only on the controlling terminal. |
| `sudo matron enroll` | Replaces a revoked connection token; external boxes require another pairing approval. |

After sign-in, start a chat in `work`, ask for a reply and a notice in **For you**, and check both. Also try an ordinary file link. A service being active is not proof that the provider account or chat works.

## HTTPS renewal

The `public-ip` strategy obtains a trusted, short-lived Let's Encrypt certificate using Certbot's webroot IP support. It never substitutes a self-signed certificate after a failure. The journal uses port 443; the file viewer uses a separate origin on 8444. Keep port 80 reachable through the VPS and provider firewalls.

`matron-certificate.timer` checks twice daily and reloads nginx after renewal. `sudo matron status` reports expiry within two days or a failed renewal service. Inspect and retry with:

```sh
sudo journalctl -u matron-certificate.service
sudo systemctl start matron-certificate.service
sudo matron status
```

If the public IP changes, edit `exposure.ip.address` in `/opt/dev-boxer/config.yml` and resume setup. Do not dismiss a certificate warning.

## Back up

```sh
sudo matron backup
```

This briefly stops the bridge, viewer and local journal, archives their state consistently, then restarts the services that were running. The default destination is `/var/backups/matron-TIMESTAMP.tar.gz`, readable only by root. It includes:

- Installer settings and secrets, journal encryption key and connection tokens.
- Local journal database and media, when this is the first box.
- Bridge environment and `mcp-config.local.json`.
- A manifest recording the installer revision, component revisions and installation mode.

It **does not include** your work folders, AI-provider login files, provider session transcripts, arbitrary connector databases/credentials, or a remotely hosted journal. Back those up separately as needed. After restoring, sign into the AI again and start fresh sessions; existing journal history remains readable.

Copy the archive off the VPS to private storage. It contains credentials and private conversations; do not upload it to a public repository or attach it to a support issue. Keep the original permissions and encrypt it using your backup system. A disk on the same VPS is not an off-server backup.

## Restore

Install the same starter version on the replacement VPS first. Use the same sign-in name and first-box/add-box choice, but the replacement's public IP and your current SSH key. Keep the old box stopped if moving its identity.

Copy your archive to the new server, then run:

```sh
sudo matron restore /path/to/backup.tar.gz --replace-state
```

This replaces the installation's Matron data. Restore refuses links, special files and paths outside the expected Matron state locations. If it fails after stopping services, it leaves them stopped so incomplete state is not served. Restore a known-good archive before restarting.

The command reapplies the replacement's IP and SSH settings, obtains its HTTPS certificate, and starts services using the restored credentials. It does not restore OS packages or roll back database migrations. For recovery after an update, retain the previous installer revision and use its compatible component set; do not restore an older database into an arbitrary newer release without checking compatibility.

Then run `sudo matron login`, `sudo matron status`, sign into Matron and check a new chat and **For you** item. Restore your work and connector-specific backups separately.

## Deliberate updates

```sh
sudo matron backup
sudo matron update --backup /path/to/the/backup.tar.gz
```

Update fast-forwards the installer checkout, then applies that revision's component set. Local tracked modifications stop the update. Read release notes first, preserve the backup privately, and check a chat afterwards. Ubuntu security updates still run automatically. Starter AI CLI versions are pinned; Claude's automatic updater is disabled for this profile.

The original advanced profile is different: it retains its existing component pull behavior and exposure choices. Use its documentation for that installation.

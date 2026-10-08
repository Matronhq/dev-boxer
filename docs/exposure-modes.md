# Exposure modes

How your box is reached from the internet is one config choice: `exposure.mode`.

| | `cloudflare` | `ip` |
|---|---|---|
| Needs a domain | Yes (Cloudflare-managed; ~$5-6/yr) | No |
| Certificate | Real, trusted everywhere | Self-signed; apps must accept/pin it |
| Inbound ports | None (outbound tunnel) | 8443-8445 open (nginx) |
| SSO in front | Optional (Cloudflare Access) | No |
| Project subdomains later | Yes (`public-*.<zone>`) | No |
| Setup speed | Slower (tokens, DNS) | Fast |

## `cloudflare`

A Cloudflare Tunnel publishes `dev.<zone>`, `chat.<zone>` (bundled journal
only), `viewer.<zone>`, and `hello.<zone>` without opening inbound ports.
Optional Zero Trust Access puts browser surfaces behind SSO — see
[cloudflare-access.md](cloudflare-access.md).

## `ip`

No domain required. Dev Boxer generates a 10-year self-signed certificate
with the server's IP as its subject-alternative name, terminates TLS with
nginx, and opens only the ports in use:

| Port (default) | Serves |
|---|---|
| 8443 | `wss://<ip>:8443/ws` — the journal (bundled mode only) |
| 8444 | `https://<ip>:8444` — file viewer |
| 8445 | `https://<ip>:8445` — hello-world smoke test |

Setup prints the certificate's **SHA-256 fingerprint**. Your Matron app
warns about the unknown certificate on first connection — accept it only if
the fingerprint matches. If the server's IP changes, re-running `setup.rb`
regenerates the certificate (new fingerprint, apps must re-accept).

Trade-off to know: until the Matron apps ship pinned-certificate trust
(SP5), only clients that can accept a self-signed cert can connect.

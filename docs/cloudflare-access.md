# Cloudflare Access Setup Guide

Cloudflare Access sits in front of your browser-facing tunnel hostnames and requires authentication before anyone can reach your dev box. Dev Boxer can create this application automatically, but this guide is useful if you prefer to configure it manually.

`matrix.<yourdomain>` must not require a browser login — Matrix clients can't complete or persist an interactive Access session and federation needs to reach the homeserver directly. The **Dev Boxer Public** app's Bypass policy handles this; just leave `matrix.<yourdomain>` out of the protected app.

## 1. Enable Cloudflare Zero Trust

1. Log in to the [Cloudflare dashboard](https://dash.cloudflare.com).
2. In the left sidebar, click **Zero Trust**.
3. If this is your first time, follow the onboarding prompts to create a Zero Trust organisation. Choose a team name (e.g. `yourcompany`) — this appears in the login URL.
4. Select a plan. The **Free** tier covers up to 50 users and is sufficient for a personal dev box.

## 2. Add an Identity Provider

Go to **Settings → Authentication → Login methods** and click **Add new**.

Choose one of:

- **Google Workspace** — requires a Google Workspace account and an OAuth app in Google Cloud Console. Select "Google Workspace", enter your Client ID, Client Secret, and primary domain.
- **GitHub** — requires a GitHub OAuth app. Select "GitHub" and enter your Client ID and Client Secret.
- **One-time PIN** — no external IdP needed. Cloudflare emails a PIN to the user. Good for testing.

After saving, click **Test** next to the provider to confirm it works before continuing.

## 3. Create the Access Applications

Dev Boxer manages **two** self-hosted Access applications so that adding new project subdomains doesn't require touching the Access config every time.

| Application | Destinations | Policy |
|-------------|--------------|--------|
| **Dev Boxer** | `*.yourdomain.com` | Allow — your team |
| **Dev Boxer Public** | `matrix.yourdomain.com`, `public-*.yourdomain.com`, plus anything in `cloudflare.access.bypass_hostnames` | Bypass — Everyone |

Cloudflare evaluates the most-specific matching destination first, so requests to `matrix.*` and `public-*.*` hit the **Bypass** app and skip the login wall. Everything else under your zone lands on the **Dev Boxer** app and gets the login wall.

> **Heads up — wildcard support**
> The protected app uses the leftmost full-label wildcard `*.yourdomain.com`, which Cloudflare Access supports without question.
> The bypass app uses a prefix wildcard like `public-*.yourdomain.com`. If your Cloudflare account rejects that pattern, replace it with one or more explicit hostnames in `cloudflare.access.bypass_hostnames` — the two-app pattern still works.

The first-run wizard can create both apps automatically using the same one-time account setup token used for tunnel creation. For Access, that token needs account permissions `Access: Apps: Edit` and `Access: Policies: Edit`. Dev Boxer derives the Cloudflare account from the DNS zone.

### Manual setup in the dashboard

Go to **Access → Applications** and click **Add an application**. Choose **Self-hosted**.

For the **Dev Boxer** application:

| Field | Value |
|-------|-------|
| **Application name** | `Dev Boxer` |
| **Session duration** | `24 hours` |
| **Domain** | `*.yourdomain.com` |

For the **Dev Boxer Public** application (create a second self-hosted app):

| Field | Value |
|-------|-------|
| **Application name** | `Dev Boxer Public` |
| **Session duration** | `24 hours` |
| **Domain** | `matrix.yourdomain.com` |
| **Additional domains** | `public-*.yourdomain.com` (plus any other hostnames you want to leave open) |

Leave all other settings at their defaults and click **Next**.

## 4. Create the Access Policies

On the **Dev Boxer** app's **Policies** step, click **Add a policy**.

| Field | Value |
|-------|-------|
| **Policy name** | `Allow team` (or similar) |
| **Action** | Allow |
| **Include** | Add rules for who can access |

Common rule types:

- **Emails** — list specific email addresses
- **Email domain** — allow everyone at `@yourcompany.com`
- **Login method** — allow anyone who authenticates via a specific IdP
- **GitHub organisation** — allow members of a specific GitHub org

On the **Dev Boxer Public** app, add a single policy:

| Field | Value |
|-------|-------|
| **Policy name** | `Bypass public hostnames` |
| **Action** | Bypass |
| **Include** | Everyone |

Click **Save policy**, then **Add application**.

## 5. Verify

Open an incognito/private browser window and navigate to one of your protected tunnel hostnames (e.g. `https://dev.yourdomain.com`). You should be redirected to the Cloudflare Access login page. After authenticating, you should land on your app.

In a second incognito window navigate to `https://matrix.yourdomain.com` (or any `public-*` subdomain). You should reach the service directly **without** a login prompt — the Bypass policy is doing its job.

If you see an error, check:
- The destinations in each Access application match your tunnel DNS records exactly.
- More-specific hostnames (e.g. `matrix.*`, `public-*`) live on the bypass app, not the protected app.
- The identity provider test passes (Settings → Authentication → Login methods → Test).
- Your Cloudflare tunnel is running: `sudo systemctl status cloudflared-tunnel`

## 6. Project subdomains and the `public-` prefix

When you spin up a new project subdomain on the tunnel (e.g. `myapp.yourdomain.com`) you get login-walled by default — the protected app's `*.yourdomain.com` wildcard covers it for free.

If you want a subdomain to be world-readable (a public demo, a status page, a service that needs unauthenticated callbacks), prefix it with `public-` (e.g. `public-status.yourdomain.com`). The default bypass app's `public-*.yourdomain.com` destination matches it and skips Access. For any other always-public hostname, add it explicitly to `cloudflare.access.bypass_hostnames` in your config and re-run `dev-boxer`.

## Tips

### Service Auth Tokens
For automated services (e.g. the Cloudflare tunnel itself, monitoring scripts) that cannot go through a browser login, create a **Service Token** under **Access → Service Auth**. Service tokens provide a `CF-Access-Client-Id` and `CF-Access-Client-Secret` header pair that bypasses browser-based auth.

### Access Groups
If you have several applications, define reusable **Access Groups** under **Access → Access Groups** (e.g. `team-members`). Reference the group in each application's policy instead of re-entering email rules everywhere.

### Access Logs
Review recent authentication events under **Logs → Access**. This shows who accessed which application and when, and helps debug policy misconfigurations.

### Session Duration
24 hours is a reasonable default for a dev box. For more sensitive environments, consider 4–8 hours. Users will be prompted to re-authenticate when their session expires.

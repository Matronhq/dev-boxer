# Cloudflare Access Setup Guide

Cloudflare Access sits in front of your tunnel hostnames and requires authentication before anyone can reach your dev box. This guide sets it up with Google Workspace SSO (or any other supported identity provider).

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

## 3. Create an Access Application

Go to **Access → Applications** and click **Add an application**. Choose **Self-hosted**.

Fill in:

| Field | Value |
|-------|-------|
| **Application name** | `dev-box` (or anything descriptive) |
| **Session duration** | `24 hours` |
| **Domain** | Add each of your tunnel hostnames (e.g. `dev.yourdomain.com`, `matrix.yourdomain.com`, `files.yourdomain.com`) |

For each additional hostname, click **Add domain** and add the next one. All hostnames can share one application.

Leave all other settings at their defaults and click **Next**.

## 4. Create an Access Policy

On the **Policies** step, click **Add a policy**.

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

Click **Save policy**, then **Add application**.

## 5. Verify

Open an incognito/private browser window and navigate to one of your tunnel hostnames. You should be redirected to the Cloudflare Access login page. After authenticating, you should land on your app.

If you see an error, check:
- The hostname in the Access application matches your tunnel DNS record exactly.
- The identity provider test passes (Settings → Authentication → Login methods → Test).
- Your Cloudflare tunnel is running: `sudo systemctl status cloudflared-tunnel`

## 6. Matrix Client Note

Element (and other Matrix clients) use an in-app WebView to handle OAuth flows. When connecting to a homeserver protected by Cloudflare Access, the in-app browser may not persist the Access session cookie.

**Workaround:** Before logging in via Element, open your Matrix homeserver URL (e.g. `https://matrix.yourdomain.com`) in your device's main browser (Safari, Chrome, etc.) and complete the Cloudflare Access authentication there. Once the cookie is set in the system browser, the in-app WebView will inherit the session and Element can connect.

## Tips

### Service Auth Tokens
For automated services (e.g. the Cloudflare tunnel itself, monitoring scripts) that cannot go through a browser login, create a **Service Token** under **Access → Service Auth**. Service tokens provide a `CF-Access-Client-Id` and `CF-Access-Client-Secret` header pair that bypasses browser-based auth.

### Access Groups
If you have several applications, define reusable **Access Groups** under **Access → Access Groups** (e.g. `team-members`). Reference the group in each application's policy instead of re-entering email rules everywhere.

### Access Logs
Review recent authentication events under **Logs → Access**. This shows who accessed which application and when, and helps debug policy misconfigurations.

### Session Duration
24 hours is a reasonable default for a dev box. For more sensitive environments, consider 4–8 hours. Users will be prompted to re-authenticate when their session expires.

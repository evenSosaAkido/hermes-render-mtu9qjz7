# Authentication (Okta SSO) & PHI considerations

This document covers how to put the Hermes dashboard behind **Okta SSO**, and
what that does — and does **not** — do for handling **PHI (protected health
information)**.

> **Read the PHI section first if any real patient data will touch this
> deployment.** The auth layer is one required control, not the whole picture.

## Why this exists

The Hermes dashboard has **no built-in authentication**. Anyone who reaches the
service URL can read your API keys, change configuration, and drive the agent
(including its Render MCP tools and any EHR/Quickbase access you give it).

The default `render.yaml` in this repo now deploys two services instead of one:

```
Okta (OIDC, group-gated)
      │  login
      ▼
[ hermes-auth ]  type: web   — the ONLY public service (oauth2-proxy)
      │  private network (region-internal, never public)
      ▼
[ hermes ]       type: pserv — PRIVATE service, NO public URL
      │
      ▼
  /opt/data (persistent disk)
```

- **`hermes`** is a Render **private service** (`type: pserv`): it gets no
  `onrender.com` URL and is only reachable over Render's in-region private
  network. This closes the "anyone with the URL" hole entirely.
- **`hermes-auth`** is [oauth2-proxy](https://oauth2-proxy.github.io/oauth2-proxy/),
  the only internet-facing service. Every request must complete an Okta OIDC
  login, and only members of an allowed Okta group are proxied through to
  Hermes.

Both services must be in the **same region** (`oregon` in the Blueprint) for
private networking to work.

## Okta setup

Do this in the Okta Admin console. You need admin rights, or ask whoever
administers your org's Okta.

1. **Create a group** for who may access Hermes, e.g. `hermes-users`, and add
   the intended members.

2. **Create an OIDC app integration:**
   - **Applications → Create App Integration → OIDC - OpenID Connect →
     Web Application.**
   - **Sign-in redirect URI:** `https://<hermes-auth>.onrender.com/oauth2/callback`
     — you'll know the exact `hermes-auth` URL after the first deploy; you can
     set a placeholder and update it once Render assigns the subdomain.
   - **Sign-out redirect URI** (optional): your service root URL.
   - **Assignments:** assign the app to the `hermes-users` group (not
     "everyone").
   - Save, then copy the **Client ID** and **Client secret**.

3. **Emit a `groups` claim.** oauth2-proxy enforces group membership from a
   `groups` claim in the ID token. In Okta:
   - **Security → API → Authorization Servers**, pick the server you'll use
     (the built-in `default` works: issuer is
     `https://<your-org>.okta.com/oauth2/default`).
   - **Claims → Add Claim:** name `groups`, include in **ID Token** (Always),
     value type **Groups**, filter **Matches regex** `.*` (or restrict to the
     groups you care about).
   - Note the **issuer URL** — this is `OAUTH2_PROXY_OIDC_ISSUER_URL`.

   > **`groups` is a CLAIM, not a SCOPE.** Do not add `groups` to
   > `OAUTH2_PROXY_SCOPE` — Okta's default authorization server has no scope
   > by that name and returns **`invalid_scope`** at login. Keep the scope as
   > `openid email profile` and read the claim via
   > `OAUTH2_PROXY_OIDC_GROUPS_CLAIM=groups`.

## Render setup

1. **Generate a cookie secret** (32 bytes, required by oauth2-proxy):

   ```bash
   scripts/gen-cookie-secret.sh
   ```

2. **Sync the Blueprint** (Blueprints → your instance → Manual Sync), or create
   the services fresh from this `render.yaml`. This creates both `hermes-auth`
   and the now-private `hermes`.

3. On the **`hermes-auth`** service → **Environment** tab, set (all
   `sync: false`, so they must be entered here):

   | Variable | Value |
   |---|---|
   | `OAUTH2_PROXY_OIDC_ISSUER_URL` | `https://<your-org>.okta.com/oauth2/default` |
   | `OAUTH2_PROXY_CLIENT_ID` | Okta app Client ID |
   | `OAUTH2_PROXY_CLIENT_SECRET` | Okta app Client secret |
   | `OAUTH2_PROXY_COOKIE_SECRET` | output of `gen-cookie-secret.sh` |
   | `OAUTH2_PROXY_REDIRECT_URL` | `https://<hermes-auth>.onrender.com/oauth2/callback` |
   | `OAUTH2_PROXY_ALLOWED_GROUPS` | `hermes-users` |

4. On the **`hermes`** service → **Environment** tab, set `RENDER_MCP_API_KEY`
   (and any LLM/AWS Bedrock credentials — see the main README) as before.

5. **Confirm the redirect URI matches** in three places: the Okta app, the
   `OAUTH2_PROXY_REDIRECT_URL` env var, and the actual `hermes-auth` URL Render
   assigned. A mismatch is the #1 cause of login failures.

6. Visit the **`hermes-auth`** URL. You should be redirected to Okta; after a
   successful login as a `hermes-users` member you land on the Hermes
   dashboard. Non-members get a 403.

## Verifying it's locked down

- The **`hermes`** service should have **no public URL** in the Render
  Dashboard (private services don't get one). If it does, it's still a web
  service — fix the `type: pserv` in `render.yaml` and re-sync.
- Hitting the `hermes-auth` URL logged-out must redirect to Okta, never show
  the dashboard.
- A user outside `hermes-users` must be denied.

## PHI: what this does and does NOT cover

Okta SSO controls **who can reach the agent**. It does **nothing** about where
PHI flows once the agent runs. For this deployment's intended workflow
(ingest a CSV, query your EHR, build a Quickbase list), PHI passes through the
**Hermes container running on Render**, not just the model provider. Concretely:

| Stage | Runs in | PHI exposure |
|---|---|---|
| CSV at rest | Hermes `/opt/data` disk (Render) | PHI at rest in Render |
| Prompt building / agent reasoning | Hermes process (Render) | PHI in memory in Render |
| LLM inference | **AWS Bedrock** | Covered by your AWS BAA ✓ |
| EHR retrieval | Outbound from Render container | PHI back in Render memory |
| **Agent / gateway logs** | `/opt/data/logs/` + stdout (Render captures) | ⚠️ **PHI in logs — biggest risk** |
| Quickbase write | Outbound from Render | Needs a Quickbase BAA |

Because Render handles PHI here, you additionally need **all** of the following
before real PHI flows — auth alone is not enough:

1. **A HIPAA-enabled Render workspace.** Requires a **Scale or Enterprise**
   plan and a **signed BAA with Render**. Enabling is **irreversible** and adds
   a **20% usage fee**. Check: Render Dashboard → **Workspace Settings →
   Compliance**. If you see a "Get Started" button, it is **not** enabled.
   PHI must never run outside a HIPAA-enabled workspace.
2. **BAAs with every downstream that sees PHI:** AWS Bedrock (you have this ✓),
   your EHR vendor, and **Quickbase**.
3. **Keep PHI out of logs.** HIPAA prohibits PHI in logs, but Hermes logs
   prompts, tool inputs/outputs, and agent reasoning by default. Reduce log
   verbosity, avoid echoing PHI in tool results, and confirm Render log
   retention is acceptable under your BAA. **This is the most likely place to
   leak PHI on this platform.**
4. **Never put PHI in resource names, env-var names, or the CSV filename** —
   Render explicitly excludes those from HIPAA coverage.
5. **Minimize what enters the agent.** Your instinct to strip PHI from the CSV
   and keep only non-PHI IDs is good — but note that once the agent queries the
   EHR by those IDs, PHI re-enters Render. Stripping the CSV does not remove
   Render from HIPAA scope for this workflow.

Render's own guidance: a HIPAA-enabled workspace provides *platform-level*
controls; application-level safeguards (authentication, per-user PHI access
logging, minimum-necessary access, encryption of sensitive fields) remain your
responsibility under the shared-responsibility model. See
<https://render.com/docs/hipaa-compliance> and
<https://render.com/docs/hipaa-best-practices>.

> **Recommendation:** treat this repo's Okta layer as step 1. Do not run real
> PHI through it until the HIPAA workspace, downstream BAAs, and log-scrubbing
> are all in place. If you only ever feed it de-identified data and never let
> it retrieve PHI from the EHR, the scope is different — but the EHR-retrieval
> step in your described workflow means PHI will be present.

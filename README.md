# db-dumps OIDC POC

Proof of concept for putting FAS-group-gated OIDC auth in front of
`https://infrastructure.fedoraproject.org/infra/db-dumps/`, which today serves full Postgres dumps with no
authentication.

Apache + `mod_auth_openidc` sits in front of a fake `/infra/db-dumps/` and authenticates against the Hatlas
Keycloak (FAS-brokered). A single `<Location>` accepts both:

- **Browser sessions**: authorization code flow via the confidential `db-dumps-poc` client
- **Bearer tokens**: from `oidc-agent` (device flow, public `db-dumps-cli-poc` client), validated by
  **token introspection**. JWKS was ruled out because Ipsilon issues opaque tokens, so the POC mirrors the
  production path.

Access requires the configured FAS group to appear in the token's `groups` claim.

## Results

Tested 2026-10-24 against the Hatlas Keycloak, mod_auth_openidc from Fedora, real FAS accounts.

| Request | Result | Status |
|---|---|---|
| Browser, no session | 302 → Keycloak → FAS login → listing | ✅ |
| Browser, logged in, not in group | 403 | ⏳ to verify |
| Bearer token from `db-dumps-cli-poc`, user in group | 200, download works | ✅ |
| Bearer token from another client (`hatlas-dl`) | 401 (wrong audience) | ✅ |
| Invalid token | 401 | ✅ |
| No token, curl / scripts | 401, not an HTML login page | ✅ |
| No token, `Accept: text/html` | 302 to login | ✅ |

## How it works

```
             browser ──(code flow)──┐
                                    ▼
 oidc-agent ──(Bearer token)──▶ Apache + mod_auth_openidc ──▶ /infra/db-dumps/
     │                              │
     │ device flow                  │ introspect token  (as db-dumps-poc)
     ▼                              ▼
         Hatlas Keycloak ◀──(brokered login + groups)── FAS / Ipsilon
```

Apache checks, per request:
1. Is there a session cookie **or** a bearer token?
2. For bearer tokens: Keycloak introspection says `active: true`. This only happens if `db-dumps-poc`
   is in the token's `aud`.
3. `Require claim groups:<REQUIRED_GROUP>`.

## Layout

```
.
├── apache/
│   ├── Containerfile            # Fedora + httpd + mod_auth_openidc + 3 fake dumps
│   └── db-dumps-oidc.conf       # the actual auth config (values from .env)
├── compose.yaml
├── .env.example
└── scripts/
    ├── setup-oidc-agent.sh      # register the CLI client in oidc-agent, print claims
    ├── test-bearer.sh           # pass/fail checks against Apache
    ├── diagnose.sh              # introspection debugging (issuer, userinfo, auth methods)
    └── online-token-test.sh     # device flow without oidc-agent / offline_access
```

## Setup

### 1. Keycloak (Hatlas realm)

**Groups claim**

A client scope `groups` with a *Group Membership* mapper:
- claim name `groups`
- *Full group path* **off** (flat names, like Ipsilon)
- add to ID token, access token, userinfo, **token introspection**

The FAS IdP group mapper must use sync mode **Force**.

**`db-dumps-poc`: Apache's client (browser login + introspection)**
- OpenID Connect, Client authentication **on**, Standard flow **on**, Direct access grants **off**
- Client Authenticator: *Client Id and Secret*
- Valid redirect URI: `http://localhost:8081/infra/db-dumps/oidc_callback`
- Client scopes: `groups` as **Default**
- Copy the secret from *Credentials* into `.env`

**`db-dumps-cli-poc`: CLI client for oidc-agent**
- Created by exporting `www-download` (*Action → Export*), renaming `clientId`, importing
- Public (no secret), OAuth 2.0 Device Authorization Grant **on**
- Redirect URI `edu.kit.data.oidc-agent:/redirect` (oidc-agent's own scheme, the same for every client;
  unused by device flow). If standard flow is on, keep it an exact match.
- Client scopes: `groups` as **Default**, `offline_access` as **Optional**
- *Dedicated scope → Mappers*:
  - add an **Audience** mapper: Included Client Audience `db-dumps-poc`, access token **on**,
    token introspection **on**
  - **delete** the audience mapper inherited from `www-download`
- *Dedicated scope → Scope*: **Full scope allowed off**

### 2. Check the token

```sh
./scripts/setup-oidc-agent.sh
```

Runs the device flow (log in via FAS), then prints the claims Apache will see. Expected:
- `azp`: `db-dumps-cli-poc`
- `aud`: `db-dumps-poc` (maybe `account`), **not** `www-download` or `realm-management`
- `groups`: flat list containing the group you'll require

### 3. Run Apache

```sh
cp .env.example .env
openssl rand -base64 32          # → OIDC_CRYPTO_PASSPHRASE
$EDITOR .env                     # client secret, REQUIRED_GROUP (e.g. fdwg-analyst)
podman compose up --build -d
podman compose logs -f apache    # debug logging shows introspection responses
```

`.env` is read when the container is created, so after edits run `podman compose up -d --force-recreate`.
Don't quote values in `.env`; `env_file` keeps the quotes.

### 4. Test

```sh
./scripts/test-bearer.sh
```

Browser: open `http://localhost:8081/infra/db-dumps/` in a private window. You should see the FAS login,
then the listing. For the deny case, set `REQUIRED_GROUP` to a group you're not in, recreate the
container, log in again → 403.

## What we hit along the way

| Problem | Cause | Fix |
|---|---|---|
| `groups: null` in tokens | `groups` scope not attached as *Default* to the client | Attach as Default on **both** clients. The CLI client feeds introspection, Apache's client feeds the browser path. |
| Introspection `active: false` for valid tokens (userinfo accepted them) | Keycloak only introspects tokens whose `aud` includes the introspecting client | Audience mapper on `db-dumps-cli-poc` → `db-dumps-poc` |
| `www-download` in the token's `aud` | Client export copies the dedicated mappers | Delete the inherited audience mapper |
| `realm-management` in the token's `aud` | *Full scope allowed* puts every role in the token, including admin roles; anyone receiving the token could call the Keycloak admin API | Full scope allowed **off** |
| "Online" test token still had `offline_access` | `oidc-gen` adds `offline_access` itself, and reused the browser's SSO session | Raw device flow with curl (`online-token-test.sh`), private window |
| curl without a token got a 302 to an HTML page | mod_auth_openidc's default for non-XHR requests | `OIDCUnAuthAction 401 "%{HTTP_ACCEPT} !~ m#text/html#"` |
| 401 instead of 403 for users outside the group | Apache's default | `AuthzSendForbiddenOnFailure On` |
| Config refused an introspection URL | mod_auth_openidc requires `https://` for the introspection endpoint | Use https (only relevant for local test IdPs) |

## Open items before production

- **Ipsilon parity.** Production should use Ipsilon (`id.fedoraproject.org`) directly, not this Keycloak.
  Verify that:
  - Ipsilon supports the device authorization grant (needed for oidc-agent)
  - Ipsilon's introspection enforces audience. If it doesn't, any FAS token from any client passes and the
    group check alone decides access.
  - groups come back with the `https://id.fedoraproject.org/scope/groups` scope
- **Issuer on `mwinters.net`.** If Keycloak is used after all, it needs a `fedoraproject.org` hostname.
  Core infra shouldn't depend on a personal domain.
- **Revocation.**
  - Access tokens currently live ~12 h. Shorten them per client (*Advanced → Access Token Lifespan*,
    e.g. 15–30 min); oidc-agent refreshes transparently.
  - Brokered groups only update at FAS login, and oidc-agent always uses offline sessions. Bound
    *Offline Session Max Lifespan* (e.g. 30 days), or a user removed from the group keeps access.
- **FAS group filter.** The IdP mapper imports only some FAS groups. A new `db-dumps-access` group must be
  added to that filter, or it won't appear in tokens.
- **mod_auth_openidc version on batcave.** `rpm -q mod_auth_openidc`; the `OIDCUnAuthAction <action> <expr>`
  form needs expression support.
- **Secrets.** Client secret and crypto passphrase go into ansible-private. The passphrase must be
  identical on every Apache node behind a load balancer.
- **Consumers.** List existing scripts and cron jobs downloading db-dumps before switching; they'll need
  oidc-agent and the new client.
- **Same issue in Hatlas.** `www-download` probably has *Full scope allowed* on too, so admin users'
  download tokens carry `realm-management`.

## Cleanup

- Delete `db-dumps-poc` and `db-dumps-cli-poc` in Keycloak (and the `groups` scope if it was created only
  for this)
- Turn realm event saving back off if it was enabled for debugging
- `oidc-gen -d db-dumps` (and `db-dumps-online` if created)
- `podman compose down`

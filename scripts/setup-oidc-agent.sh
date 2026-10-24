#!/usr/bin/env bash
# Register the db-dumps-cli client in oidc-agent (device flow, like hatlas-dl) and show the token claims.
set -euo pipefail

ISSUER="${ISSUER:-https://auth.hatlas.mwinters.net/realms/hatlas}"
ACCOUNT="${ACCOUNT:-db-dumps}"

eval "$(oidc-agent-service use)" >/dev/null

if ! oidc-add -l 2>/dev/null | grep -qx "$ACCOUNT"; then
  oidc-gen \
    --issuer "$ISSUER" \
    --client-id db-dumps-cli-poc \
    --client-secret "" \
    --flow device \
    --scope "openid profile email offline_access" \
    --redirect-uri "edu.kit.data.oidc-agent:/redirect" \
    "$ACCOUNT"
fi

echo "== Claims Apache will see =="
oidc-token "$ACCOUNT" | cut -d. -f2 | tr '_-' '/+' |
  {
    b=$(cat)
    while ((${#b} % 4)); do b+="="; done
    echo "$b"
  } |
  base64 -d | jq '{preferred_username, azp, groups}'

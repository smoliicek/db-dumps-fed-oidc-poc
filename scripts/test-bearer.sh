#!/usr/bin/env bash
# Exercise the bearer-token path against the local Apache.
set -uo pipefail

URL="${URL:-http://localhost:8081/infra/db-dumps/}"
ACCOUNT="${ACCOUNT:-db-dumps}"
OTHER_ACCOUNT="${OTHER_ACCOUNT:-hatlas-dl}"

eval "$(oidc-agent-service use)" >/dev/null

code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
check() {  # check <label> <expected> <actual>
  if [[ "$2" == *"$3"* ]]; then echo "PASS  $1 -> $3"; else echo "FAIL  $1 -> $3 (expected $2)"; fi
}

TOKEN=$(oidc-token "$ACCOUNT")

check "db-dumps-cli token"          "200" "$(code -H "Authorization: Bearer $TOKEN" "$URL")"
check "download with token"         "200" "$(code -H "Authorization: Bearer $TOKEN" -o /tmp/db-dumps-test.xz "$URL/datanommer.dump.xz")"
check "garbage token"               "401" "$(code -H "Authorization: Bearer not-a-token" "$URL")"
check "no token, curl"              "401" "$(code "$URL")"
check "no token, browser Accept"    "302" "$(code -H 'Accept: text/html' "$URL")"

if oidc-add -l 2>/dev/null | grep -qx "$OTHER_ACCOUNT"; then
  # Policy decision, not a pass/fail: should a Hatlas download token open db-dumps?
  echo "INFO  $OTHER_ACCOUNT token (cross-client) -> $(code -H "Authorization: Bearer $(oidc-token "$OTHER_ACCOUNT")" "$URL")"
fi

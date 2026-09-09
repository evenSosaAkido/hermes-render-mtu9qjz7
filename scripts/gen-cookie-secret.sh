#!/usr/bin/env bash
# Generate a cookie secret for oauth2-proxy (the hermes-auth service).
#
# oauth2-proxy requires OAUTH2_PROXY_COOKIE_SECRET to be exactly 16, 24, or
# 32 bytes (AES-128/192/256). This prints a URL-safe base64 value derived
# from 32 random bytes — paste it into the hermes-auth service's Environment
# tab in the Render Dashboard.
#
# Usage: scripts/gen-cookie-secret.sh
set -euo pipefail

if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import os,base64; print(base64.urlsafe_b64encode(os.urandom(32)).decode())'
elif command -v openssl >/dev/null 2>&1; then
  # openssl rand -base64 uses standard alphabet; translate to URL-safe.
  openssl rand -base64 32 | tr '+/' '-_'
else
  echo "ERROR: need python3 or openssl to generate a secret." >&2
  exit 1
fi

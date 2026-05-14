#!/usr/bin/env bash
# Postprovision hook: make sure the Entra app's redirect URI matches the
# deployed App Service hostname. Runs after Bicep has produced SERVICE_WEB_URI.
set -euo pipefail

: "${AUTH_CLIENT_ID:?AUTH_CLIENT_ID not set}"
: "${SERVICE_WEB_URI:?SERVICE_WEB_URI not set}"

redirect_uri="${SERVICE_WEB_URI%/}/.auth/login/aad/callback"

current="$(az ad app show --id "$AUTH_CLIENT_ID" --query "web.redirectUris" -o tsv || true)"
if ! echo "$current" | tr '\t' '\n' | grep -Fxq "$redirect_uri"; then
  echo "Updating Entra app redirect URI to ${redirect_uri}..."
  az ad app update --id "$AUTH_CLIENT_ID" --web-redirect-uris "$redirect_uri" >/dev/null
else
  echo "Entra app redirect URI already up-to-date."
fi

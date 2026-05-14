#!/usr/bin/env bash
# Preprovision hook: ensure an Entra ID app registration exists for Easy Auth on
# the App Service that will be (re)deployed by azd. Sets AUTH_CLIENT_ID,
# AUTH_TENANT_ID and AUTH_CLIENT_SECRET into the azd environment so that the
# Bicep template can configure authsettingsV2.
set -euo pipefail

: "${AZURE_ENV_NAME:?AZURE_ENV_NAME not set}"

display_name="appproxy-easyauth-${AZURE_ENV_NAME}"

tenant_id="$(az account show --query tenantId -o tsv)"
azd env set AUTH_TENANT_ID "$tenant_id" >/dev/null

# Reuse an existing app registration with the same display name, otherwise
# create one. We only set sign-in audience and enable id_token issuance here;
# the redirect URI is patched after we know the App Service hostname.
client_id="$(az ad app list --display-name "$display_name" --query "[0].appId" -o tsv 2>/dev/null || true)"
if [[ -z "${client_id}" || "${client_id}" == "null" ]]; then
  echo "Creating Entra app registration '${display_name}'..."
  client_id="$(az ad app create \
    --display-name "$display_name" \
    --sign-in-audience AzureADMyOrg \
    --enable-id-token-issuance true \
    --query appId -o tsv)"
  # Ensure a service principal exists in this tenant for the app.
  az ad sp create --id "$client_id" >/dev/null 2>&1 || true
else
  echo "Reusing existing Entra app registration '${display_name}' (${client_id})."
fi

azd env set AUTH_CLIENT_ID "$client_id" >/dev/null

# Patch the web redirect URI if we already know the App Service hostname from
# a previous deployment. On the very first deploy this is empty -- in that case
# we still proceed (Bicep configures Easy Auth, but interactive login will fail
# until the redirect URI is added). The postprovision hook fixes this up once
# the host name is known.
service_uri="$(azd env get-values 2>/dev/null | awk -F= '/^SERVICE_WEB_URI=/{gsub(/"/, "", $2); print $2}')"
if [[ -n "${service_uri}" ]]; then
  redirect_uri="${service_uri%/}/.auth/login/aad/callback"
  echo "Setting redirect URI ${redirect_uri} on the Entra app..."
  az ad app update --id "$client_id" --web-redirect-uris "$redirect_uri" >/dev/null
fi

# Ensure we have a client secret available for Easy Auth (auth code flow).
existing_secret="$(azd env get-values 2>/dev/null | awk -F= '/^AUTH_CLIENT_SECRET=/{gsub(/"/, "", $2); print $2}')"
if [[ -z "${existing_secret}" ]]; then
  echo "Creating client secret for Entra app..."
  secret="$(az ad app credential reset \
    --id "$client_id" \
    --display-name "azd-easyauth" \
    --years 1 \
    --append \
    --query password -o tsv)"
  azd env set AUTH_CLIENT_SECRET "$secret" >/dev/null
else
  echo "Reusing previously stored client secret from azd env."
fi

echo "Preprovision complete: AUTH_CLIENT_ID=${client_id}"

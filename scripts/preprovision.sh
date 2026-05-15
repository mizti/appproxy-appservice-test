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

# ---------------------------------------------------------------------------
# Connector VM admin password: generate once and persist in the azd env.
# ---------------------------------------------------------------------------
existing_pw="$(azd env get-values 2>/dev/null | awk -F= '/^CONNECTOR_ADMIN_PASSWORD=/{gsub(/"/, "", $2); print $2}')"
if [[ -z "${existing_pw}" ]]; then
  # 20 chars, mix of upper/lower/digits/symbols to satisfy Windows complexity.
  pw="$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 18)Aa1@"
  azd env set CONNECTOR_ADMIN_PASSWORD "$pw" >/dev/null
  echo "Generated CONNECTOR_ADMIN_PASSWORD and stored in azd env."
else
  echo "Reusing existing CONNECTOR_ADMIN_PASSWORD from azd env."
fi

# Default the RDP source CIDR if the caller did not provide one.
existing_cidr="$(azd env get-values 2>/dev/null | awk -F= '/^CONNECTOR_ALLOWED_RDP_CIDR=/{gsub(/"/, "", $2); print $2}')"
if [[ -z "${existing_cidr}" ]]; then
  azd env set CONNECTOR_ALLOWED_RDP_CIDR "153.166.35.153/32" >/dev/null
  echo "Defaulted CONNECTOR_ALLOWED_RDP_CIDR=153.166.35.153/32."
fi

# ---------------------------------------------------------------------------
# Entra ID App Proxy application (onPremisesPublishing) -- create or reuse.
# ---------------------------------------------------------------------------
proxy_display="appproxy-stub-${AZURE_ENV_NAME}"
proxy_app_object_id="$(az rest --method get \
  --uri "https://graph.microsoft.com/v1.0/applications?\$filter=displayName eq '${proxy_display}'&\$select=id,appId,displayName" \
  --query "value[0].id" -o tsv 2>/dev/null || true)"
proxy_app_id="$(az rest --method get \
  --uri "https://graph.microsoft.com/v1.0/applications?\$filter=displayName eq '${proxy_display}'&\$select=id,appId,displayName" \
  --query "value[0].appId" -o tsv 2>/dev/null || true)"

if [[ -z "${proxy_app_object_id}" || "${proxy_app_object_id}" == "null" ]]; then
  echo "Instantiating 'On-premises application' template for '${proxy_display}'..."
  # The "On-premises application" gallery template
  # (8adf8e6e-67b2-4cf2-a259-e3dc5476c621) creates both an Application object
  # and a tagged ServicePrincipal whose application supports the
  # 'onPremisesPublishing' resource. Plain POST /applications does NOT yield an
  # app that can be configured for App Proxy.
  create_resp="$(az rest --method post \
    --uri "https://graph.microsoft.com/v1.0/applicationTemplates/8adf8e6e-67b2-4cf2-a259-e3dc5476c621/instantiate" \
    --headers "Content-Type=application/json" \
    --body "{\"displayName\":\"${proxy_display}\"}")"
  proxy_app_object_id="$(echo "$create_resp" | python3 -c 'import sys,json;print(json.load(sys.stdin)["application"]["id"])')"
  proxy_app_id="$(echo "$create_resp" | python3 -c 'import sys,json;print(json.load(sys.stdin)["application"]["appId"])')"
else
  echo "Reusing existing Entra App Proxy application '${proxy_display}' (${proxy_app_id})."
fi

azd env set APP_PROXY_APP_OBJECT_ID "$proxy_app_object_id" >/dev/null
azd env set APP_PROXY_APP_ID "$proxy_app_id" >/dev/null
echo "App Proxy onPremisesPublishing will be configured by the postprovision hook."


#!/usr/bin/env bash
# Postprovision hook:
#   1) ensure the Easy Auth Entra app redirect URI matches the deployed
#      App Service hostname.
#   2) finalize the App Proxy Entra application by patching onPremisesPublishing
#      (internal/external URL, AAD pre-auth) once the App Service hostname is
#      known.
#   3) assign the current user to the App Proxy application.
#   4) print the manual steps to register the Connector on the VM.
#
# Custom-domain mode (Option B-1 / host-name-preservation):
#   When `CUSTOM_DOMAIN` is set in azd env (e.g. `azd env set CUSTOM_DOMAIN
#   app.example.com`), the script also:
#     * binds the FQDN to the App Service and issues an App Service Managed
#       Certificate (TLS) -- requires an `asuid.<fqdn>` TXT record in DNS.
#     * configures App Proxy onPremisesPublishing with the same FQDN on BOTH
#       externalUrl and internalUrl, with `isTranslateHostHeaderEnabled=false`
#       so the Host header is preserved end-to-end (Easy Auth then issues the
#       OAuth redirect_uri on the custom domain).
#   When `CUSTOM_DOMAIN` is unset, the script preserves the existing default
#   `*-<tenant>.msappproxy.net` behavior unchanged.
set -euo pipefail

: "${AUTH_CLIENT_ID:?AUTH_CLIENT_ID not set}"
: "${SERVICE_WEB_URI:?SERVICE_WEB_URI not set}"
: "${APP_PROXY_APP_OBJECT_ID:?APP_PROXY_APP_OBJECT_ID not set}"
: "${APP_PROXY_APP_ID:?APP_PROXY_APP_ID not set}"
: "${CONNECTOR_PUBLIC_IP:?CONNECTOR_PUBLIC_IP not set}"
: "${CONNECTOR_ADMIN_USERNAME:?CONNECTOR_ADMIN_USERNAME not set}"

# --- Discover tenant initial domain prefix up-front --------------------------
# External hostnames in App Proxy must end with '-<tenantInitialDomainPrefix>.msappproxy.net'
# (or a verified custom domain). The reply URL on the Easy Auth Entra app also
# needs to include the same App Proxy hostname, so resolve it before step 1.
tenant_prefix="$(az rest --method get \
  --uri "https://graph.microsoft.com/v1.0/domains" \
  --query "value[?isInitial].id | [0]" -o tsv 2>/dev/null | sed 's/\.onmicrosoft\.com$//' | tr '[:upper:]' '[:lower:]')"
if [[ -z "${tenant_prefix}" ]]; then
  echo "ERROR: could not resolve tenant initial domain prefix." >&2
  exit 1
fi

# --- Custom-domain mode detection ------------------------------------------
CUSTOM_DOMAIN="$(azd env get-values 2>/dev/null | awk -F= '/^CUSTOM_DOMAIN=/{gsub(/"/,"",$2); print $2}')"
AZURE_RESOURCE_GROUP="${AZURE_RESOURCE_GROUP:-$(azd env get-values 2>/dev/null | awk -F= '/^AZURE_RESOURCE_GROUP=/{gsub(/"/,"",$2); print $2}')}"
SERVICE_WEB_NAME="${SERVICE_WEB_NAME:-$(azd env get-values 2>/dev/null | awk -F= '/^SERVICE_WEB_NAME=/{gsub(/"/,"",$2); print $2}')}"

if [[ -n "${CUSTOM_DOMAIN}" ]]; then
  echo "Custom-domain mode: ${CUSTOM_DOMAIN}"
  external_host="${CUSTOM_DOMAIN}"
  external_url_default="https://${CUSTOM_DOMAIN}/"
  proxy_translate_host_header="false"
else
  external_host="appproxy-stub-${AZURE_ENV_NAME}-${tenant_prefix}"
  external_url_default="https://${external_host}.msappproxy.net/"
  proxy_translate_host_header="true"
fi

# --- 1) Easy Auth redirect URI ---------------------------------------------
# Register BOTH callback URLs on the Easy Auth Entra app:
#   - direct App Service URL (used for admin/debug or before App Proxy is set up)
#   - App Proxy external URL  (required so that, with httpSettings.forwardProxy
#     = 'Standard' on App Service, Easy Auth issues redirect_uri pointing at
#     the App Proxy hostname and the user stays on that URL after sign-in)
direct_redirect_uri="${SERVICE_WEB_URI%/}/.auth/login/aad/callback"
proxy_ext="$(azd env get-values 2>/dev/null | awk -F= '/^APP_PROXY_EXTERNAL_URL=/{gsub(/"/,"",$2); print $2}')"
[[ -z "$proxy_ext" ]] && proxy_ext="$external_url_default"
proxy_redirect_uri="${proxy_ext%/}/.auth/login/aad/callback"

desired_uris=("$direct_redirect_uri" "$proxy_redirect_uri")

current="$(az ad app show --id "$AUTH_CLIENT_ID" --query "web.redirectUris" -o tsv || true)"
missing=0
for u in "${desired_uris[@]}"; do
  if ! echo "$current" | tr '\t' '\n' | grep -Fxq "$u"; then
    missing=1
    break
  fi
done
if [[ $missing -eq 1 ]]; then
  echo "Updating Easy Auth Entra app redirect URIs:"
  for u in "${desired_uris[@]}"; do echo "  - $u"; done
  az ad app update --id "$AUTH_CLIENT_ID" --web-redirect-uris "${desired_uris[@]}" >/dev/null
else
  echo "Easy Auth Entra app redirect URI already up-to-date."
fi

# --- 1.5) Verify App Service custom-hostname binding (custom-domain mode) --
# In custom-domain mode the FQDN must already be bound to the App Service
# (manual step; see docs/step3_appproxy.md). If not yet bound, skip the App
# Proxy PATCH below -- otherwise PATCH would succeed but the resulting flow
# would 404 because App Service does not yet accept the Host header.
SKIP_CUSTOM_DOMAIN=""
if [[ -n "${CUSTOM_DOMAIN}" ]]; then
  if [[ -z "${AZURE_RESOURCE_GROUP}" || -z "${SERVICE_WEB_NAME}" ]]; then
    echo "WARN: AZURE_RESOURCE_GROUP / SERVICE_WEB_NAME not in env; cannot verify App Service custom-hostname binding."
    SKIP_CUSTOM_DOMAIN=1
  else
    already_bound="$(az webapp config hostname list -g "${AZURE_RESOURCE_GROUP}" --webapp-name "${SERVICE_WEB_NAME}" --query "[?name=='${CUSTOM_DOMAIN}'] | [0].name" -o tsv 2>/dev/null || true)"
    if [[ -z "${already_bound}" || "${already_bound}" == "null" ]]; then
      echo "WARN: '${CUSTOM_DOMAIN}' is not yet bound to App Service. App Proxy PATCH will be skipped."
      echo "      Follow the custom-domain runbook in docs/step3_appproxy.md, then re-run 'azd hooks run postprovision'."
      SKIP_CUSTOM_DOMAIN=1
    else
      echo "App Service custom hostname '${CUSTOM_DOMAIN}' is bound."
    fi
  fi
fi

# --- 2) App Proxy onPremisesPublishing -------------------------------------
# When CUSTOM_DOMAIN is set: externalUrl is the custom FQDN and
# isTranslateHostHeaderEnabled=false so the Host header is preserved (Easy Auth
# then sees Host=<CUSTOM_DOMAIN> and issues the OAuth redirect_uri on that
# hostname -- the host-name-preservation pattern).
#
# internalUrl stays on the App Service default *.azurewebsites.net URL even in
# custom-domain mode. This keeps the design simple:
#   * Connector connects to the public *.azurewebsites.net (TLS SNI uses the
#     default Microsoft cert -- no extra App Service SSL binding needed).
#   * Host header forwarded to App Service is the CUSTOM_DOMAIN value (because
#     isTranslateHostHeaderEnabled=false). App Service still needs CUSTOM_DOMAIN
#     registered as a custom hostname (without SSL is fine) to accept that Host
#     header.
# So only ONE TLS certificate is needed end-to-end: the PFX uploaded to App
# Proxy for the CUSTOM_DOMAIN external URL.
internal_url="${SERVICE_WEB_URI%/}/"
if [[ -n "${CUSTOM_DOMAIN}" && -z "${SKIP_CUSTOM_DOMAIN}" ]]; then
  desired_external_url="https://${CUSTOM_DOMAIN}/"
else
  desired_external_url=""  # to be discovered/assigned below
fi

# Determine current externalUrl by attempting a GET. The GET may return 404
# (OnPremisesPublishing_NotEnabled) even on a properly-instantiated app until
# the first PATCH is issued, so a 404 here does NOT imply we should skip --
# it just means we'll do a first-time PATCH below.
current_external=""
get_resp="$(az rest --method get \
  --uri "https://graph.microsoft.com/beta/applications/${APP_PROXY_APP_OBJECT_ID}/onPremisesPublishing" \
  -o json 2>/tmp/proxy_get_err.log || true)"
if [[ -n "$get_resp" ]]; then
  current_external="$(echo "$get_resp" | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin); print(d.get("externalUrl","") or "")
except Exception:
  print("")' 2>/dev/null || echo "")"
fi

# Decide whether a full re-PATCH is needed. In custom-domain mode we re-PATCH
# whenever the current externalUrl differs from the desired one (e.g. switching
# from the default msappproxy.net URL to the custom FQDN).
needs_full_patch=0
if [[ -z "${current_external}" || "${current_external}" == "null" ]]; then
  needs_full_patch=1
elif [[ -n "${desired_external_url}" && "${current_external%/}" != "${desired_external_url%/}" ]]; then
  needs_full_patch=1
fi

SKIP_PROXY_PATCH=""
# If we're in custom-domain mode but App Service binding is not ready yet,
# skip the App Proxy PATCH entirely. Trying to PATCH externalUrl=<CUSTOM_DOMAIN>
# would fail (domain unverified / no PFX uploaded), and falling back to a
# msappproxy.net URL would defeat the purpose of custom-domain mode.
if [[ -n "${CUSTOM_DOMAIN}" && -n "${SKIP_CUSTOM_DOMAIN}" ]]; then
  echo "Custom-domain mode: skipping App Proxy PATCH until manual setup is complete."
  SKIP_PROXY_PATCH=1
  needs_full_patch=0
fi

if [[ "${needs_full_patch}" == "1" ]]; then
  echo "Patching onPremisesPublishing on App Proxy app (full PATCH)..."
  attempt=0
  # external_host already ends with the tenant prefix (e.g.
  # 'appproxy-stub-<env>-<tenantPrefix>'). For collision retries we must keep
  # the tenant-prefix segment last, so insert the random suffix BEFORE it.
  external_host_base="${external_host%-${tenant_prefix}}"
  max_attempts=5
  [[ -n "${CUSTOM_DOMAIN}" ]] && max_attempts=1  # no collision retry for FQDN
  while [[ $attempt -lt $max_attempts ]]; do
    if [[ -n "${CUSTOM_DOMAIN}" ]]; then
      candidate_external_url="https://${CUSTOM_DOMAIN}/"
    else
      candidate_host="${external_host}"
      if [[ $attempt -gt 0 ]]; then
        candidate_host="${external_host_base}-$(openssl rand -hex 2)-${tenant_prefix}"
      fi
      candidate_external_url="https://${candidate_host}.msappproxy.net/"
    fi
    body=$(cat <<JSON
{
  "internalUrl": "${internal_url}",
  "externalUrl": "${candidate_external_url}",
  "externalAuthenticationType": "aadPreAuthentication",
  "isHttpOnlyCookieEnabled": false,
  "isPersistentCookieEnabled": false,
  "isSecureCookieEnabled": true,
  "isTranslateHostHeaderEnabled": ${proxy_translate_host_header},
  "isTranslateLinksInBodyEnabled": false,
  "isStateSessionEnabled": false,
  "singleSignOnSettings": {
    "singleSignOnMode": "none"
  }
}
JSON
)
    tmp=$(mktemp); echo "$body" > "$tmp"
    if az rest --method patch \
        --uri "https://graph.microsoft.com/beta/applications/${APP_PROXY_APP_OBJECT_ID}/onPremisesPublishing" \
        --headers "Content-Type=application/json" \
        --body @"$tmp" 2>/tmp/proxy_err.log; then
      echo "App Proxy externalUrl set to ${candidate_external_url}"
      rm -f "$tmp"
      break
    fi
    if [[ -z "${CUSTOM_DOMAIN}" ]] && grep -qi "already in use\|conflict\|in use\|duplicate" /tmp/proxy_err.log; then
      echo "External host '${candidate_host}' is taken, retrying..."
      attempt=$((attempt+1))
      rm -f "$tmp"
      continue
    fi
    if [[ -n "${CUSTOM_DOMAIN}" ]] && grep -qiE "verifiedCustomDomain|custom domain.*not.*verif|domain.*not.*configured|certificate" /tmp/proxy_err.log; then
      cat <<EOF >&2

NOTE: App Proxy custom domain '${CUSTOM_DOMAIN}' is not yet verified or has no
      TLS certificate uploaded. App Proxy requires a PFX certificate for any
      non-msappproxy.net hostname (App Service Managed Cert is not exported as
      PFX, so this step cannot be fully automated). See the banner at the end
      of this script for the manual steps.

EOF
      SKIP_PROXY_PATCH=1
      rm -f "$tmp"
      break
    fi
    if grep -qiE "OnPremisesPublishing_NotEnabled|OnPremisesPublishing is not enabled|tenant ID.*was not found|Application_NotFound" /tmp/proxy_err.log; then
      cat <<EOF >&2

NOTE: Microsoft Entra Application Proxy is not yet provisioned in this tenant
      (no Connector has been registered yet). The Connector binary is already
      installed on the VM ${CONNECTOR_PUBLIC_IP}; please run the manual
      registration steps printed below, then re-run:

          azd hooks run postprovision

      to finish wiring the internal/external URL and the user assignment.

EOF
      SKIP_PROXY_PATCH=1
      rm -f "$tmp"
      break
    fi
    cat /tmp/proxy_err.log >&2
    rm -f "$tmp"
    exit 1
  done
elif [[ -z "${SKIP_PROXY_PATCH}" ]]; then
  body=$(cat <<JSON
{
  "internalUrl": "${internal_url}"
}
JSON
)
  tmp=$(mktemp); echo "$body" > "$tmp"
  az rest --method patch \
    --uri "https://graph.microsoft.com/beta/applications/${APP_PROXY_APP_OBJECT_ID}/onPremisesPublishing" \
    --headers "Content-Type=application/json" \
    --body @"$tmp" >/dev/null
  rm -f "$tmp"
  echo "App Proxy internalUrl refreshed (externalUrl already set to ${current_external})."
fi

if [[ -z "${SKIP_PROXY_PATCH:-}" ]]; then
  external_url="$(az rest --method get \
    --uri "https://graph.microsoft.com/beta/applications/${APP_PROXY_APP_OBJECT_ID}/onPremisesPublishing" \
    --query "externalUrl" -o tsv)"
  azd env set APP_PROXY_EXTERNAL_URL "$external_url" >/dev/null

  # App Proxy pre-auth redirects back to the External URL after the user signs
  # in. That URL must be registered as a reply URL on the Entra application,
  # otherwise sign-in fails with AADSTS500113 ("No reply address is registered
  # for the application").
  current_replies="$(az rest --method get \
    --uri "https://graph.microsoft.com/v1.0/applications/${APP_PROXY_APP_OBJECT_ID}" \
    --query "web.redirectUris" -o json 2>/dev/null || echo '[]')"
  if ! echo "$current_replies" | python3 -c "import sys,json;sys.exit(0 if '${external_url}' in json.load(sys.stdin) else 1)" 2>/dev/null; then
    echo "Registering App Proxy externalUrl as a reply URL on the Entra app..."
    body="$(python3 -c "import json;print(json.dumps({'web':{'redirectUris':['${external_url}']}}))")"
    tmp=$(mktemp); echo "$body" > "$tmp"
    az rest --method patch \
      --uri "https://graph.microsoft.com/v1.0/applications/${APP_PROXY_APP_OBJECT_ID}" \
      --headers "Content-Type=application/json" \
      --body @"$tmp" >/dev/null
    rm -f "$tmp"
  fi
else
  external_url="(pending — register a Connector first, then re-run azd hooks run postprovision)"
fi

# --- 3) Assign current user to the App Proxy application -------------------
sp_object_id="$(az ad sp show --id "$APP_PROXY_APP_ID" --query id -o tsv 2>/dev/null || true)"
me_object_id="$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)"

if [[ -n "$sp_object_id" && -n "$me_object_id" ]]; then
  existing_assignment="$(az rest --method get \
    --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${sp_object_id}/appRoleAssignedTo?\$filter=principalId eq ${me_object_id}" \
    --query "value[0].id" -o tsv 2>/dev/null || true)"
  if [[ -z "${existing_assignment}" || "${existing_assignment}" == "null" ]]; then
    # Apps created from the on-premises gallery template do not expose the
    # default '00000000-...' role; use the gallery-provided 'User' role if
    # available, otherwise fall back to the default-access GUID.
    role_id="$(az rest --method get \
      --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${sp_object_id}" \
      --query "appRoles[?displayName=='User'] | [0].id" -o tsv 2>/dev/null || true)"
    if [[ -z "${role_id}" || "${role_id}" == "null" ]]; then
      role_id="00000000-0000-0000-0000-000000000000"
    fi
    body=$(cat <<JSON
{
  "principalId": "${me_object_id}",
  "resourceId": "${sp_object_id}",
  "appRoleId": "${role_id}"
}
JSON
)
    tmp=$(mktemp); echo "$body" > "$tmp"
    assign_out=$(az rest --method post \
      --uri "https://graph.microsoft.com/v1.0/servicePrincipals/${sp_object_id}/appRoleAssignedTo" \
      --headers "Content-Type=application/json" \
      --body @"$tmp" 2>&1 || true)
    rm -f "$tmp"
    if echo "$assign_out" | grep -q 'already exists'; then
      echo "Current user is already assigned to the App Proxy app."
    elif echo "$assign_out" | grep -qi 'error'; then
      echo "WARN: user assignment failed: $assign_out"
    else
      echo "Assigned current user to the App Proxy app."
    fi
  else
    echo "Current user is already assigned to the App Proxy app."
  fi
fi

# --- 4) Print Connector registration instructions (only if not yet done) ---
connector_count=$(az rest --method get \
  --uri "https://graph.microsoft.com/beta/onPremisesPublishingProfiles/applicationProxy/connectors" \
  --query "length(value[?status=='active'])" -o tsv 2>/dev/null || echo 0)
if [[ "${SKIP_PROXY_PATCH:-0}" == "1" || "${connector_count:-0}" == "0" ]]; then
cat <<EOF

================================================================================
App Proxy Connector — manual registration required
================================================================================
The Connector binaries have been installed silently on the VM, but registration
to the Entra tenant must be performed once interactively:

  1. RDP to the Connector VM
        Host : ${CONNECTOR_PUBLIC_IP}
        User : ${CONNECTOR_ADMIN_USERNAME}
        Pass : run -> azd env get-values | grep CONNECTOR_ADMIN_PASSWORD

  2. Inside the VM, open an elevated PowerShell prompt and run:

        cd 'C:\\Program Files\\Microsoft Entra private network connector'
        .\\RegisterConnector.ps1 \\
            -modulePath 'C:\\Program Files\\Microsoft Entra private network connector\\Modules\\' \\
            -moduleName 'MicrosoftEntraPrivateNetworkConnectorPSModule' \\
            -AuthenticationMode 'Interactive'

     A sign-in dialog will open. Sign in as a tenant Application Administrator
     (or Global Administrator); MFA works fine with the Interactive mode.
     (Note: the legacy '-AuthenticationMode usercredentials' value used by the
     old App Proxy Connector is not accepted by the new Entra Private Network
     Connector; valid values are Interactive / Token / Credentials.)

     Once registration succeeds the connector service appears under:
       Entra portal -> Applications -> Enterprise applications
                   -> Application proxy -> Connectors

App Proxy external URL : ${external_url}
Internal target        : ${internal_url}
App Service host       : ${SERVICE_WEB_URI}
================================================================================

EOF
else
  echo "Connector is already registered (${connector_count} active). Skipping manual-registration banner."
fi

# --- 5) Custom-domain manual setup banner -----------------------------------
if [[ -n "${CUSTOM_DOMAIN}" && -n "${SKIP_CUSTOM_DOMAIN:-}" ]]; then
  verification_id="$(az webapp show -g "${AZURE_RESOURCE_GROUP:-}" -n "${SERVICE_WEB_NAME:-}" --query customDomainVerificationId -o tsv 2>/dev/null || echo "<run: az webapp show ...>")"
cat <<EOF

================================================================================
Custom-domain mode (${CUSTOM_DOMAIN}) — manual setup required
================================================================================
The script detected CUSTOM_DOMAIN=${CUSTOM_DOMAIN} but the App Service custom
hostname is not yet bound. Follow these steps, then re-run:

    azd hooks run postprovision

[1] DNS — add records at your domain registrar (e.g. Sakura)

    a) TXT record (App Service ownership verification)
         Name : asuid.${CUSTOM_DOMAIN%%.*}
         Type : TXT
         Value: ${verification_id}

    b) CNAME record (route traffic through App Proxy)
         Name : ${CUSTOM_DOMAIN%%.*}
         Type : CNAME
         Value: <tenantPrefix>-${tenant_prefix}.msappproxy.net.
                ^^ This is the App Proxy frontend. The actual hostname is
                shown in Entra portal under your App Proxy app -> "External URL"
                AFTER the App Proxy PATCH has been applied. For initial setup,
                you can use the temporary msappproxy.net URL from the previous
                run (see APP_PROXY_EXTERNAL_URL in azd env), or follow [4] first.

[2] Bind the custom hostname to App Service (no SSL needed)

    az webapp config hostname add \\
        -g ${AZURE_RESOURCE_GROUP:-<rg>} \\
        --webapp-name ${SERVICE_WEB_NAME:-<app>} \\
        --hostname ${CUSTOM_DOMAIN}

[3] Procure a TLS PFX for ${CUSTOM_DOMAIN} (App Proxy requirement)

    App Proxy requires an exportable PFX. App Service Managed Certificate is
    NOT exportable. Choose one of:

    Option A (Azure-managed, ~\$70/yr):
      Portal -> Subscriptions -> "App Service Certificates" -> Create
      -> issue for ${CUSTOM_DOMAIN}, verify via Key Vault DNS TXT.
      -> Export PFX once issued.

    Option B (Free, Let's Encrypt via DNS-01):
      certbot certonly --manual --preferred-challenges dns-01 -d ${CUSTOM_DOMAIN}
      Then convert to PFX:
        openssl pkcs12 -export \\
          -out ${CUSTOM_DOMAIN}.pfx \\
          -inkey privkey.pem -in fullchain.pem

[4] Upload PFX + set External URL on the App Proxy app (Entra portal)

    Entra portal -> Applications -> Enterprise applications
      -> 'appproxy-stub-${AZURE_ENV_NAME}' -> Application proxy
      -> External URL: https://${CUSTOM_DOMAIN}/
      -> Internal URL: ${SERVICE_WEB_URI%/}/
      -> Translate URLs in headers: No
      -> Upload certificate: <your PFX from [3]>
      -> Save

    NOTE: alternatively the script will issue the PATCH automatically on the
    next 'azd hooks run postprovision' run, BUT only if the custom domain has
    already been registered+verified at the tenant level (via the portal step
    above which uploads the cert).

[5] Re-run azd hooks run postprovision

    The script will then:
      * verify the App Service hostname binding,
      * PATCH App Proxy externalUrl=${CUSTOM_DOMAIN}, isTranslateHost=false,
      * register the new reply URL on the Entra app.

================================================================================

EOF
fi

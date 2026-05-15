@description('Azure region for the resources.')
param location string

@description('Tags applied to all resources.')
param tags object

@description('Name of the App Service Plan.')
param appServicePlanName string

@description('Name of the App Service (Web App).')
param appServiceName string

@description('Linux Python runtime version (e.g. PYTHON|3.11).')
param linuxFxVersion string = 'PYTHON|3.11'

@description('SKU name for the App Service Plan.')
param skuName string = 'B1'

@description('Entra ID application (client) id for Easy Auth.')
param authClientId string

@description('Entra ID tenant id for Easy Auth.')
param authTenantId string

@secure()
@description('Entra ID application client secret for Easy Auth.')
param authClientSecret string

@description('Public IP address of the App Proxy Connector VM. When set, App Service ingress is restricted to this IP only (deny-by-default). Leave empty to allow all traffic.')
param connectorPublicIp string = ''

var authClientSecretSettingName = 'MICROSOFT_PROVIDER_AUTHENTICATION_SECRET'
var restrictIngress = !empty(connectorPublicIp)
var connectorIpRule = {
  name: 'AllowAppProxyConnector'
  description: 'Allow only Azure AD App Proxy Connector VM'
  action: 'Allow'
  priority: 100
  ipAddress: '${connectorPublicIp}/32'
}

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: appServicePlanName
  location: location
  tags: tags
  sku: {
    name: skuName
  }
  kind: 'linux'
  properties: {
    reserved: true
  }
}

resource site 'Microsoft.Web/sites@2024-04-01' = {
  name: appServiceName
  location: location
  tags: union(tags, {
    'azd-service-name': 'web'
  })
  kind: 'app,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: linuxFxVersion
      alwaysOn: true
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      http20Enabled: true
      appCommandLine: 'gunicorn --bind=0.0.0.0:8000 --timeout 600 app:app'
      ipSecurityRestrictionsDefaultAction: restrictIngress ? 'Deny' : 'Allow'
      ipSecurityRestrictions: restrictIngress ? [ connectorIpRule ] : []
      appSettings: [
        {
          name: 'SCM_DO_BUILD_DURING_DEPLOYMENT'
          value: 'true'
        }
        {
          name: 'WEBSITES_PORT'
          value: '8000'
        }
        {
          name: 'ENABLE_ORYX_BUILD'
          value: 'true'
        }
        {
          name: authClientSecretSettingName
          value: authClientSecret
        }
      ]
    }
  }
}

resource authsettings 'Microsoft.Web/sites/config@2024-04-01' = {
  parent: site
  name: 'authsettingsV2'
  properties: {
    platform: {
      enabled: true
      runtimeVersion: '~1'
    }
    globalValidation: {
      requireAuthentication: true
      unauthenticatedClientAction: 'RedirectToLoginPage'
      redirectToProvider: 'azureactivedirectory'
    }
    identityProviders: {
      azureActiveDirectory: {
        enabled: true
        registration: {
          clientId: authClientId
          clientSecretSettingName: authClientSecretSettingName
          openIdIssuer: 'https://login.microsoftonline.com/${authTenantId}/v2.0'
        }
        validation: {
          allowedAudiences: [
            'api://${authClientId}'
            authClientId
          ]
        }
      }
    }
    login: {
      tokenStore: {
        enabled: true
      }
    }
    httpSettings: {
      requireHttps: true
      // App Proxy forwards client requests with X-Forwarded-Host / X-Forwarded-Proto.
      // Honor those so that Easy Auth issues the OAuth redirect_uri pointing at
      // the App Proxy external URL (not the direct *.azurewebsites.net hostname),
      // keeping the user on the App Proxy URL after sign-in.
      forwardProxy: {
        convention: 'Standard'
      }
    }
  }
}

output appServiceName string = site.name
output appServiceUri string = 'https://${site.properties.defaultHostName}'
output appServicePrincipalId string = site.identity.principalId

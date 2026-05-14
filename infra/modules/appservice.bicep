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
      ]
    }
  }
}

output appServiceName string = site.name
output appServiceUri string = 'https://${site.properties.defaultHostName}'
output appServicePrincipalId string = site.identity.principalId

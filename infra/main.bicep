targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the environment used to generate unique resource names.')
param environmentName string

@minLength(1)
@description('Primary Azure region for all resources.')
param location string

@description('Optional principal id (user/service principal) for role assignments. Set automatically by azd.')
param principalId string = ''

var abbrs = {
  resourceGroup: 'rg'
  appServicePlan: 'plan'
  appService: 'app'
}

var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var tags = {
  'azd-env-name': environmentName
}

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: '${abbrs.resourceGroup}-${environmentName}'
  location: location
  tags: tags
}

module web 'modules/appservice.bicep' = {
  name: 'web'
  scope: rg
  params: {
    location: location
    tags: tags
    appServicePlanName: '${abbrs.appServicePlan}-${resourceToken}'
    appServiceName: '${abbrs.appService}-${resourceToken}'
  }
}

output AZURE_LOCATION string = location
output AZURE_RESOURCE_GROUP string = rg.name
output SERVICE_WEB_NAME string = web.outputs.appServiceName
output SERVICE_WEB_URI string = web.outputs.appServiceUri

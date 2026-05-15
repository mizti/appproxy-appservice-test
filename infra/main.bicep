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

@description('Entra ID application (client) id used by App Service Easy Auth.')
param authClientId string

@description('Entra ID tenant id used by App Service Easy Auth.')
param authTenantId string

@secure()
@description('Entra ID application client secret used by App Service Easy Auth.')
param authClientSecret string

@description('CIDR allowed to RDP to the App Proxy Connector VM.')
param connectorAllowedRdpCidr string

@description('Admin username for the Connector VM.')
param connectorAdminUsername string = 'azureuser'

@secure()
@description('Admin password for the Connector VM.')
param connectorAdminPassword string

@description('VM size for the Connector VM.')
param connectorVmSize string = 'Standard_B2ms'

var abbrs = {
  resourceGroup: 'rg'
  appServicePlan: 'plan'
  appService: 'app'
  connector: 'connector'
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
    authClientId: authClientId
    authTenantId: authTenantId
    authClientSecret: authClientSecret
    connectorPublicIp: connector.outputs.publicIpAddress
  }
}

module connector 'modules/connector-vm.bicep' = {
  name: 'connector'
  scope: rg
  params: {
    location: location
    tags: tags
    namePrefix: '${abbrs.connector}-${resourceToken}'
    allowedRdpCidr: connectorAllowedRdpCidr
    adminUsername: connectorAdminUsername
    adminPassword: connectorAdminPassword
    vmSize: connectorVmSize
  }
}

output AZURE_LOCATION string = location
output AZURE_RESOURCE_GROUP string = rg.name
output SERVICE_WEB_NAME string = web.outputs.appServiceName
output SERVICE_WEB_URI string = web.outputs.appServiceUri
output CONNECTOR_VM_NAME string = connector.outputs.vmName
output CONNECTOR_PUBLIC_IP string = connector.outputs.publicIpAddress
output CONNECTOR_ADMIN_USERNAME string = connector.outputs.adminUsername

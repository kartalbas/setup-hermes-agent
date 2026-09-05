// The Azure Bot that fronts the Teams channel, and its Teams channel.
//
// Declarative on purpose: the Bot Service's msaAppId is immutable after
// creation, so "converge" here means "compare, and refuse or recreate" — the
// installer decides that; this file only states the desired end state.
//
// Deployed by src/47-azure.sh with `az deployment group create`, previewed in a
// dry run with `what-if`.

@description('Resource name of the bot (also its default display name).')
param botName string

@description('Application (client) ID of the Entra app registration the bot authenticates as.')
param msaAppId string

@description('Directory (tenant) ID that app registration lives in.')
param msaAppTenantId string

@description('Public HTTPS URL the Bot Framework posts activities to.')
param endpoint string

@description('F0 is free and sufficient for one person\'s assistant; S1 is the paid tier.')
@allowed(['F0', 'S1'])
param sku string = 'F0'

@description('Shown in Teams as the bot\'s name.')
param displayName string = botName

resource bot 'Microsoft.BotService/botServices@2023-09-15-preview' = {
  name: botName
  location: 'global'
  kind: 'azurebot'
  sku: { name: sku }
  properties: {
    displayName: displayName
    endpoint: endpoint
    msaAppId: msaAppId
    msaAppTenantId: msaAppTenantId
    msaAppType: 'SingleTenant'
    schemaTransformationVersion: '1.3'
    disableLocalAuth: false
    publicNetworkAccess: 'Enabled'
    // The portal sets these; stating them keeps a re-run at "no change"
    // instead of a what-if that wants to delete portal defaults.
    iconUrl: 'https://docs.botframework.com/static/devportal/client/images/bot-framework-default.png'
  }
}

// Teams is the only channel this installation uses; webchat/directline are
// created by the portal wizard, not needed here, and not managed.
resource teams 'Microsoft.BotService/botServices/channels@2023-09-15-preview' = {
  parent: bot
  name: 'MsTeamsChannel'
  location: 'global'
  properties: {
    channelName: 'MsTeamsChannel'
    properties: {
      isEnabled: true
      acceptedTerms: true
      enableCalling: false
      incomingCallRoute: 'graphPma'
      isTeamsIvrEnabled: false
    }
  }
}

output botId string = bot.id
output effectiveEndpoint string = bot.properties.endpoint

{
  "$schema": "https://developer.microsoft.com/en-us/json-schemas/teams/v1.17/MicrosoftTeams.schema.json",
  "manifestVersion": "1.17",
  "version": "${BOT_VERSION}",
  "id": "${TEAMS_APP_MANIFEST_ID}",
  "developer": {
    "name": "${TEAMS_APP_DEVELOPER}",
    "websiteUrl": "https://${TUNNEL_HOSTNAME}",
    "privacyUrl": "https://${TUNNEL_HOSTNAME}",
    "termsOfUseUrl": "https://${TUNNEL_HOSTNAME}"
  },
  "name": { "short": "${TEAMS_APP_NAME}", "full": "${TEAMS_APP_NAME}" },
  "description": {
    "short": "${TEAMS_APP_NAME}",
    "full": "${TEAMS_APP_DESCRIPTION}"
  },
  "icons": { "color": "color.png", "outline": "outline.png" },
  "accentColor": "#1F2937",
  "bots": [
    {
      "botId": "${TEAMS_APP_ID}",
      "scopes": ["personal"],
      "supportsFiles": true,
      "isNotificationOnly": false
    }
  ],
  "permissions": ["identity", "messageTeamMembers"],
  "validDomains": ["${TUNNEL_HOSTNAME}"]
}

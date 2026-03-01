import 'package:note_synapse/models/mcp_endpoint.dart';

/// Google Cloud Console Client ID for Note Synapse.
/// This is a public identifier — safe to embed. No client secret is used.
/// OAuth security is provided by PKCE (S256 code challenge).
///
/// To register your own: https://console.cloud.google.com/
/// Create a project → APIs & Services → Credentials → Create OAuth client ID
/// → Application type: Desktop app
const _kGoogleClientId =
    'YOUR_CLIENT_ID.apps.googleusercontent.com';

/// OAuth 2.0 configuration for Google Drive access.
///
/// Uses the drive.file scope (access only to files created by this app),
/// PKCE for security (no client secret needed for public clients),
/// and a redirect URI resolved at runtime by [OAuthRedirectHelper].
final kGoogleDriveOAuthConfig = OAuthConfig(
  authorizationEndpoint: 'https://accounts.google.com/o/oauth2/v2/auth',
  tokenEndpoint: 'https://oauth2.googleapis.com/token',
  clientId: _kGoogleClientId,
  clientSecret: null,
  scope: 'https://www.googleapis.com/auth/drive.file',
  usePkce: true,
  redirectUri: '',
);

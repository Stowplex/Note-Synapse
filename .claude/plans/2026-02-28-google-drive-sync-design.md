# Google Drive Sync — Design Document

**Date:** 2026-02-28
**Branch:** `feature/cloud-sync-design`
**Status:** Approved

---

## Overview

Add Google Drive as a sync storage provider for Note Synapse. Users authenticate via PKCE-based OAuth 2.0 (no client secret — public client pattern), select a sync root folder name, and sync their notes to `My Drive/<syncRootName>/`.

The feature reuses the existing OAuth infrastructure (`oauth_service.dart`, `oauth_token_manager.dart`, `oauth_redirect_helper.dart`) and plugs into the existing `SyncStorageProvider` interface.

---

## OAuth Configuration

### Public Client — No Client Secret

Google Drive uses the "Desktop app" OAuth client type in Google Cloud Console. This client type:
- Issues a **Client ID only** (no client secret)
- Is explicitly designed for public clients (installed/native apps)
- **PKCE (S256)** replaces the client secret as the security mechanism

The Client ID is safe to embed in the app binary — it is an identifier, not a credential.

### Hardcoded OAuth Config

```dart
const kGoogleDriveOAuthConfig = OAuthConfig(
  authorizationEndpoint: 'https://accounts.google.com/o/oauth2/v2/auth',
  tokenEndpoint:         'https://oauth2.googleapis.com/token',
  clientId:              '<CLIENT_ID>.apps.googleusercontent.com',
  clientSecret:          null,   // Public client — no secret
  scope:                 'https://www.googleapis.com/auth/drive.file',
  usePkce:               true,
  redirectUri:           '',     // Resolved at runtime by OAuthRedirectHelper
);
```

### Scope

`https://www.googleapis.com/auth/drive.file` — access only to files and folders created by Note Synapse. Passes Google's OAuth verification more easily than broader scopes.

### Platform Redirect URIs

Handled by the existing `OAuthRedirectHelper`:

| Platform           | Redirect URI                          |
|--------------------|---------------------------------------|
| macOS / Linux / Windows | `http://127.0.0.1:51791/callback` (loopback) |
| iOS / Android      | `notesynapse://oauth/callback` (deep link) |

Both URIs must be registered as allowed redirect URIs in the Google Cloud Console project.

### Token Storage

Reuses `OAuthTokenManager` with storage key prefix `gdrive_oauth_`:
- Access token, refresh token, ID token, expiry stored in `FlutterSecureStorage`
- Auto-refresh when within 30 seconds of expiry
- On disconnect: tokens cleared, sync configuration reset

---

## Architecture

### New Files

```
lib/services/sync/
  google_drive_api_client.dart    — HTTP wrapper over Drive REST API v3
  google_drive_sync_provider.dart — SyncStorageProvider implementation
lib/models/
  google_oauth_config.dart        — kGoogleDriveOAuthConfig constant
```

### Modified Files

```
lib/services/sync/sync_service.dart      — add 'gdrive' provider routing
lib/screens/sync_setup_screen.dart       — add Google Drive provider option + setup flow
lib/screens/sync_settings_screen.dart    — add Disconnect Google Account option
lib/l10n/app_en.arb                      — new l10n keys
lib/l10n/app_zh.arb                      — Chinese translations
```

---

## `GoogleDriveApiClient`

Thin HTTP wrapper over Drive REST API v3. Accepts a token-provider function for testability.

```dart
class GoogleDriveApiClient {
  final Future<String> Function() _getAccessToken;

  GoogleDriveApiClient({required Future<String> Function() getAccessToken});

  Future<List<DriveFileInfo>> listChildren(String parentId);
  Future<DriveFileInfo?> getFileInfo(String fileId);
  Future<Uint8List> downloadFile(String fileId);
  Future<DriveFileInfo> uploadFile({
    required String name,
    required String parentId,
    required Uint8List content,
    String mimeType = 'application/octet-stream',
  });
  Future<void> updateFile({required String fileId, required Uint8List content});
  Future<void> trashFile(String fileId);
  Future<DriveFileInfo> createFolder({required String name, required String parentId});
}

class DriveFileInfo {
  final String id;
  final String name;
  final String? mimeType;
  final int? size;
  final DateTime? modifiedTime;
}
```

### Drive API Endpoints

| Operation     | Endpoint |
|---------------|----------|
| List children | `GET /drive/v3/files?q='<parentId>'+in+parents+and+trashed=false&fields=files(id,name,mimeType,size,modifiedTime)` |
| Download      | `GET /drive/v3/files/<id>?alt=media` |
| Upload (new)  | `POST /upload/drive/v3/files?uploadType=multipart` (two-part body: JSON metadata + binary) |
| Update        | `PATCH /upload/drive/v3/files/<id>?uploadType=media` |
| Trash         | `PATCH /drive/v3/files/<id>` with `{"trashed": true}` |
| Create folder | `POST /drive/v3/files` with `mimeType: application/vnd.google-apps.folder` |

### Error Handling

- **401**: Force token refresh via `OAuthTokenManager`, retry once
- **403 / 429**: Surface `GoogleDriveQuotaException` or `GoogleDrivePermissionException`
- Other HTTP errors: wrapped in `GoogleDriveException` with status code

---

## `GoogleDriveSyncProvider`

Implements `SyncStorageProvider`. Bridges path-based sync interface to Drive's ID-based API using an in-memory path→fileId cache.

```dart
class GoogleDriveSyncProvider implements SyncStorageProvider {
  final GoogleDriveApiClient _client;
  final String syncRootName;         // User-configured, e.g. "Note Synapse"

  String? _rootFolderId;             // Drive ID of syncRootName folder
  final Map<String, String> _idCache; // path → fileId (populated lazily)

  Future<void> initialize();         // Find-or-create syncRootName under Drive root
}
```

### Sync Root Layout

```
My Drive/
  <syncRootName>/         ← user-configured, default "Note Synapse"
    oplogs/
      op-<device>-<seq>.bin
    attachments/
      <attachment-id>.bin
    snapshot.db
    sync-config.json
```

### Path Resolution

All paths are relative to `_rootFolderId`. Cache is populated lazily on first access per directory:

```
path = "/oplogs/op-001.bin"
  → split: dir = "oplogs", file = "op-001.bin"
  → cache["oplogs"]? → if miss: listChildren(_rootFolderId), populate cache
  → cache["/oplogs/op-001.bin"]? → if miss: listChildren(oplogs_id), populate cache
  → return fileId
```

### `initialize()`

1. List children of Drive `'root'`
2. Find folder matching `syncRootName` → use its ID
3. If not found → `createFolder(name: syncRootName, parentId: 'root')`
4. Set `_rootFolderId`

### `writeFile` Logic

- If path is in `_idCache` → `updateFile(fileId, data)`
- If path is not cached → `uploadFile(...)` → cache resulting fileId

### `deleteFile` Logic

- Resolve fileId → `trashFile(fileId)` → evict from `_idCache`

---

## `sync_service.dart` Integration

Add `'gdrive'` case to `restoreConfiguration()` and `initializeSyncRoot()`:

```dart
case 'gdrive':
  final tokenManager = OAuthTokenManager(storageKeyPrefix: 'gdrive_oauth_');
  final apiClient = GoogleDriveApiClient(
    getAccessToken: () => tokenManager.getValidAccessToken(),
  );
  provider = GoogleDriveSyncProvider(
    client: apiClient,
    syncRootName: providerUri,   // syncRootName stored in existing syncProviderUri field
  );
  await (provider as GoogleDriveSyncProvider).initialize();
```

`syncRootName` is stored in the existing `syncProviderUri` field — no database schema change needed.

### Error Surface to `SyncResult`

- `GoogleDriveAuthException` — refresh failed; sync aborted, user prompted to reconnect
- `GoogleDriveQuotaException` — Drive quota exceeded; sync aborted with user-facing message

---

## UI Changes

### Provider Selection (`sync_setup_screen.dart`)

Add Google Drive as a third provider option alongside Folder and WebDAV.

### Google Drive Setup Flow

```
Step 1: Provider Selection
  → User picks "Google Drive"

Step 2: Google Drive Configuration
  ┌──────────────────────────────────────┐
  │  Sync Folder Name                    │
  │  [ Note Synapse              ]       │  ← text field, user-editable
  │                                      │
  │  [  Connect Google Account  ]        │  ← triggers OAuth flow
  │                                      │
  │  ✓ Connected as user@gmail.com       │  ← shown after successful auth
  │    Sync folder: My Drive / Note...   │  ← confirms folder path
  └──────────────────────────────────────┘
  [  Next  ]   ← enabled only after successful auth

Step 3: Encryption (unchanged)

Step 4: Initialize  ← calls SyncService.initializeSyncRoot()
```

- "Connect Google Account" calls `OAuthService.authorizationCodeFlow()` with `kGoogleDriveOAuthConfig`
- On success: authenticated email shown (from `id_token` JWT claims or `GET /oauth2/v1/userinfo`)
- "Next" button disabled until auth completes

### Disconnect (`sync_settings_screen.dart`)

Add "Disconnect Google Account" option that:
1. Clears tokens from `OAuthTokenManager('gdrive_oauth_')`
2. Calls `SyncService.resetConfiguration()`

### New Localization Keys

| Key | English | Chinese |
|-----|---------|---------|
| `syncProviderGoogleDrive` | `"Google Drive"` | `"Google 云端硬盘"` |
| `syncGoogleDriveFolderName` | `"Sync Folder Name"` | `"同步文件夹名称"` |
| `syncGoogleDriveConnect` | `"Connect Google Account"` | `"连接 Google 账号"` |
| `syncGoogleDriveConnected` | `"Connected as {email}"` | `"已连接: {email}"` |
| `syncGoogleDriveSyncFolder` | `"Sync folder: My Drive / {name}"` | `"同步文件夹: 我的云端硬盘 / {name}"` |
| `syncGoogleDriveDisconnect` | `"Disconnect Google Account"` | `"断开 Google 账号"` |

---

## Testing Strategy

### `GoogleDriveApiClient` Tests

Use `http`'s `MockClient`. Cover:
- Successful list, download, upload, update, trash, create folder
- `401` triggers token refresh + single retry
- `403`/`429` surfaces correct exception
- Token provider function injected (no real OAuth)

### `GoogleDriveSyncProvider` Tests

Mock `GoogleDriveApiClient`. Cover:
- `listFiles` populates cache and returns `SyncFileInfo` list
- `readFile` resolves path via cache, calls `downloadFile`
- `writeFile` existing path → `updateFile`; new path → `uploadFile` + cache
- `deleteFile` trashes and evicts from cache
- `exists` returns false on cache miss + empty listing
- `initialize()` reuses existing folder; creates when absent
- Cache scoped per instance (no cross-session leakage)

### OAuth Integration Tests

- `OAuthTokenManager('gdrive_oauth_')` stores/retrieves tokens correctly
- `getValidAccessToken()` returns cached token when valid; refreshes when near expiry

### Widget Tests

- Google Drive option appears in provider selection
- Folder name field pre-fills with default, accepts custom input
- "Next" disabled until auth succeeds
- Connected state shows email and folder path

### Out of Scope (manual testing only)

- Actual Drive API calls (requires network + credentials)
- Full OAuth round-trip (requires browser + Google servers)

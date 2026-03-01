# Google Drive Sync — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add Google Drive as a PKCE-based OAuth sync provider using the existing `SyncStorageProvider` interface.

**Architecture:** Two new service files — `GoogleDriveApiClient` (HTTP wrapper over Drive REST v3) and `GoogleDriveSyncProvider` (path→ID cache adapter implementing `SyncStorageProvider`) — wired into the existing `SyncService` provider routing and `SyncSetupScreen` UI.

**Tech Stack:** Drive REST API v3, `package:http` (already in project), `package:http/testing.dart` (MockClient for tests), existing `OAuthService` + `OAuthTokenManager` + `OAuthConfig`, `@GenerateMocks` (mockito, already in project).

**Design doc:** `.claude/plans/2026-02-28-google-drive-sync-design.md`

---

## Phase 1 — `GoogleDriveApiClient`

### Task 1: Model + client scaffold + `listChildren()`

**Files:**
- Create: `lib/services/sync/google_drive_api_client.dart`
- Create: `test/services/sync/google_drive_api_client_test.dart`

**Step 1: Write the failing test**

```dart
// test/services/sync/google_drive_api_client_test.dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:note_synapse/services/sync/google_drive_api_client.dart';

void main() {
  group('GoogleDriveApiClient.listChildren', () {
    test('returns list of DriveFileInfo from API response', () async {
      final client = GoogleDriveApiClient(
        getAccessToken: () async => 'test-token',
        httpClient: MockClient((request) async {
          expect(
            request.headers['Authorization'],
            equals('Bearer test-token'),
          );
          expect(
            request.url.queryParameters['q'],
            contains("'parent-id' in parents"),
          );
          return http.Response(
            jsonEncode({
              'files': [
                {
                  'id': 'file-abc',
                  'name': 'op-001.bin',
                  'mimeType': 'application/octet-stream',
                  'size': '512',
                  'modifiedTime': '2026-02-28T10:00:00.000Z',
                }
              ],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final files = await client.listChildren('parent-id');

      expect(files.length, equals(1));
      expect(files[0].id, equals('file-abc'));
      expect(files[0].name, equals('op-001.bin'));
      expect(files[0].size, equals(512));
    });

    test('returns empty list when folder has no files', () async {
      final client = GoogleDriveApiClient(
        getAccessToken: () async => 'test-token',
        httpClient: MockClient((_) async => http.Response(
          jsonEncode({'files': []}),
          200,
          headers: {'content-type': 'application/json'},
        )),
      );

      final files = await client.listChildren('empty-folder');
      expect(files, isEmpty);
    });
  });
}
```

**Step 2: Run test to verify it fails**

```
flutter test test/services/sync/google_drive_api_client_test.dart -v
```
Expected: FAIL — `google_drive_api_client.dart` not found.

**Step 3: Write minimal implementation**

```dart
// lib/services/sync/google_drive_api_client.dart
import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

class DriveFileInfo {
  final String id;
  final String name;
  final String? mimeType;
  final int? size;
  final DateTime? modifiedTime;

  const DriveFileInfo({
    required this.id,
    required this.name,
    this.mimeType,
    this.size,
    this.modifiedTime,
  });

  factory DriveFileInfo.fromJson(Map<String, dynamic> json) {
    return DriveFileInfo(
      id: json['id'] as String,
      name: json['name'] as String,
      mimeType: json['mimeType'] as String?,
      // Drive API returns size as String
      size: json['size'] != null ? int.tryParse(json['size'] as String) : null,
      modifiedTime: json['modifiedTime'] != null
          ? DateTime.tryParse(json['modifiedTime'] as String)
          : null,
    );
  }
}

class GoogleDriveException implements Exception {
  final String message;
  final int? statusCode;
  GoogleDriveException(this.message, {this.statusCode});
  @override
  String toString() => 'GoogleDriveException($statusCode): $message';
}

class GoogleDriveAuthException extends GoogleDriveException {
  GoogleDriveAuthException(super.message) : super(statusCode: 401);
}

class GoogleDriveQuotaException extends GoogleDriveException {
  GoogleDriveQuotaException(super.message) : super(statusCode: 403);
}

class GoogleDriveApiClient {
  static const _baseUrl = 'https://www.googleapis.com';

  final Future<String> Function() _getAccessToken;
  final http.Client _httpClient;

  GoogleDriveApiClient({
    required Future<String> Function() getAccessToken,
    http.Client? httpClient,
  })  : _getAccessToken = getAccessToken,
        _httpClient = httpClient ?? http.Client();

  Future<Map<String, String>> _authHeaders() async {
    final token = await _getAccessToken();
    return {'Authorization': 'Bearer $token'};
  }

  void _checkStatus(http.Response response) {
    if (response.statusCode == 401) {
      throw GoogleDriveAuthException('Unauthorized — token may have expired');
    }
    if (response.statusCode == 403) {
      throw GoogleDriveQuotaException('Forbidden — quota or permission error');
    }
    if (response.statusCode >= 400) {
      throw GoogleDriveException(
        'HTTP ${response.statusCode}: ${response.body}',
        statusCode: response.statusCode,
      );
    }
  }

  Future<List<DriveFileInfo>> listChildren(String parentId) async {
    final uri = Uri.parse('$_baseUrl/drive/v3/files').replace(
      queryParameters: {
        'q': "'$parentId' in parents and trashed=false",
        'fields': 'files(id,name,mimeType,size,modifiedTime)',
        'pageSize': '1000',
      },
    );
    final response = await _httpClient.get(uri, headers: await _authHeaders());
    _checkStatus(response);
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final files = json['files'] as List<dynamic>;
    return files
        .map((f) => DriveFileInfo.fromJson(f as Map<String, dynamic>))
        .toList();
  }
}
```

**Step 4: Run test to verify it passes**

```
flutter test test/services/sync/google_drive_api_client_test.dart -v
```
Expected: PASS (2 tests)

**Step 5: Commit**

```bash
git add lib/services/sync/google_drive_api_client.dart \
        test/services/sync/google_drive_api_client_test.dart
git commit -m "feat(sync): add GoogleDriveApiClient scaffold with listChildren"
```

---

### Task 2: `downloadFile()` + `uploadFile()` (multipart)

**Files:**
- Modify: `lib/services/sync/google_drive_api_client.dart`
- Modify: `test/services/sync/google_drive_api_client_test.dart`

**Step 1: Write the failing tests**

Add to `google_drive_api_client_test.dart`:

```dart
  group('GoogleDriveApiClient.downloadFile', () {
    test('returns file bytes', () async {
      final expected = Uint8List.fromList([1, 2, 3, 4]);
      final client = GoogleDriveApiClient(
        getAccessToken: () async => 'test-token',
        httpClient: MockClient((request) async {
          expect(request.url.queryParameters['alt'], equals('media'));
          expect(request.url.path, contains('file-xyz'));
          return http.Response.bytes(expected, 200);
        }),
      );

      final bytes = await client.downloadFile('file-xyz');
      expect(bytes, equals(expected));
    });
  });

  group('GoogleDriveApiClient.uploadFile', () {
    test('sends multipart request and returns DriveFileInfo', () async {
      final client = GoogleDriveApiClient(
        getAccessToken: () async => 'tok',
        httpClient: MockClient((request) async {
          expect(request.url.queryParameters['uploadType'], equals('multipart'));
          expect(
            request.headers['content-type'],
            contains('multipart/related'),
          );
          return http.Response(
            jsonEncode({'id': 'new-id', 'name': 'snapshot.db'}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final info = await client.uploadFile(
        name: 'snapshot.db',
        parentId: 'parent-id',
        content: Uint8List.fromList([10, 20, 30]),
      );

      expect(info.id, equals('new-id'));
      expect(info.name, equals('snapshot.db'));
    });
  });
```

**Step 2: Run test to verify it fails**

```
flutter test test/services/sync/google_drive_api_client_test.dart -v
```
Expected: FAIL — `downloadFile` and `uploadFile` not defined.

**Step 3: Add methods to `GoogleDriveApiClient`**

```dart
  Future<Uint8List> downloadFile(String fileId) async {
    final uri = Uri.parse('$_baseUrl/drive/v3/files/$fileId')
        .replace(queryParameters: {'alt': 'media'});
    final response = await _httpClient.get(uri, headers: await _authHeaders());
    _checkStatus(response);
    return response.bodyBytes;
  }

  Future<DriveFileInfo> uploadFile({
    required String name,
    required String parentId,
    required Uint8List content,
    String mimeType = 'application/octet-stream',
  }) async {
    final boundary = 'boundary_${DateTime.now().millisecondsSinceEpoch}';
    final metadataJson = jsonEncode({'name': name, 'parents': [parentId]});

    final body = StringBuffer()
      ..write('--$boundary\r\n')
      ..write('Content-Type: application/json; charset=UTF-8\r\n\r\n')
      ..write('$metadataJson\r\n')
      ..write('--$boundary\r\n')
      ..write('Content-Type: $mimeType\r\n\r\n');

    final bodyPrefix = utf8.encode(body.toString());
    final bodySuffix = utf8.encode('\r\n--$boundary--');
    final fullBody = Uint8List(bodyPrefix.length + content.length + bodySuffix.length)
      ..setRange(0, bodyPrefix.length, bodyPrefix)
      ..setRange(bodyPrefix.length, bodyPrefix.length + content.length, content)
      ..setRange(bodyPrefix.length + content.length, bodyPrefix.length + content.length + bodySuffix.length, bodySuffix);

    final uri = Uri.parse('$_baseUrl/upload/drive/v3/files')
        .replace(queryParameters: {'uploadType': 'multipart', 'fields': 'id,name,mimeType,size,modifiedTime'});

    final headers = await _authHeaders();
    headers['content-type'] = 'multipart/related; boundary=$boundary';

    final response = await _httpClient.post(uri, headers: headers, body: fullBody);
    _checkStatus(response);
    return DriveFileInfo.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  }
```

**Step 4: Run test to verify it passes**

```
flutter test test/services/sync/google_drive_api_client_test.dart -v
```
Expected: PASS (4 tests)

**Step 5: Commit**

```bash
git add lib/services/sync/google_drive_api_client.dart \
        test/services/sync/google_drive_api_client_test.dart
git commit -m "feat(sync): add downloadFile and uploadFile to GoogleDriveApiClient"
```

---

### Task 3: `updateFile()` + `trashFile()` + `createFolder()`

**Files:**
- Modify: `lib/services/sync/google_drive_api_client.dart`
- Modify: `test/services/sync/google_drive_api_client_test.dart`

**Step 1: Write the failing tests**

```dart
  group('GoogleDriveApiClient.updateFile', () {
    test('sends PATCH with raw bytes', () async {
      bool called = false;
      final client = GoogleDriveApiClient(
        getAccessToken: () async => 'tok',
        httpClient: MockClient((request) async {
          called = true;
          expect(request.method, equals('PATCH'));
          expect(request.url.path, contains('file-to-update'));
          expect(request.url.queryParameters['uploadType'], equals('media'));
          return http.Response('', 200);
        }),
      );

      await client.updateFile(
        fileId: 'file-to-update',
        content: Uint8List.fromList([5, 6, 7]),
      );

      expect(called, isTrue);
    });
  });

  group('GoogleDriveApiClient.trashFile', () {
    test('sends PATCH with trashed:true', () async {
      bool called = false;
      final client = GoogleDriveApiClient(
        getAccessToken: () async => 'tok',
        httpClient: MockClient((request) async {
          called = true;
          expect(request.method, equals('PATCH'));
          expect(request.url.path, contains('file-to-trash'));
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['trashed'], isTrue);
          return http.Response('{}', 200, headers: {'content-type': 'application/json'});
        }),
      );

      await client.trashFile('file-to-trash');
      expect(called, isTrue);
    });
  });

  group('GoogleDriveApiClient.createFolder', () {
    test('creates folder with correct mimeType and parent', () async {
      final client = GoogleDriveApiClient(
        getAccessToken: () async => 'tok',
        httpClient: MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['name'], equals('Note Synapse'));
          expect(body['parents'], equals(['root']));
          expect(body['mimeType'],
              equals('application/vnd.google-apps.folder'));
          return http.Response(
            jsonEncode({'id': 'folder-id', 'name': 'Note Synapse'}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final info = await client.createFolder(
        name: 'Note Synapse',
        parentId: 'root',
      );

      expect(info.id, equals('folder-id'));
      expect(info.name, equals('Note Synapse'));
    });
  });
```

**Step 2: Run test to verify it fails**

```
flutter test test/services/sync/google_drive_api_client_test.dart -v
```
Expected: FAIL — methods not defined.

**Step 3: Add methods**

```dart
  Future<void> updateFile({
    required String fileId,
    required Uint8List content,
    String mimeType = 'application/octet-stream',
  }) async {
    final uri = Uri.parse('$_baseUrl/upload/drive/v3/files/$fileId')
        .replace(queryParameters: {'uploadType': 'media'});
    final headers = await _authHeaders();
    headers['content-type'] = mimeType;
    final response = await _httpClient.patch(uri, headers: headers, body: content);
    _checkStatus(response);
  }

  Future<void> trashFile(String fileId) async {
    final uri = Uri.parse('$_baseUrl/drive/v3/files/$fileId');
    final headers = await _authHeaders();
    headers['content-type'] = 'application/json';
    final response = await _httpClient.patch(
      uri,
      headers: headers,
      body: jsonEncode({'trashed': true}),
    );
    _checkStatus(response);
  }

  Future<DriveFileInfo> createFolder({
    required String name,
    required String parentId,
  }) async {
    final uri = Uri.parse('$_baseUrl/drive/v3/files')
        .replace(queryParameters: {'fields': 'id,name,mimeType,size,modifiedTime'});
    final headers = await _authHeaders();
    headers['content-type'] = 'application/json';
    final response = await _httpClient.post(
      uri,
      headers: headers,
      body: jsonEncode({
        'name': name,
        'parents': [parentId],
        'mimeType': 'application/vnd.google-apps.folder',
      }),
    );
    _checkStatus(response);
    return DriveFileInfo.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  }
```

**Step 4: Run test to verify it passes**

```
flutter test test/services/sync/google_drive_api_client_test.dart -v
```
Expected: PASS (7 tests)

**Step 5: Commit**

```bash
git add lib/services/sync/google_drive_api_client.dart \
        test/services/sync/google_drive_api_client_test.dart
git commit -m "feat(sync): add updateFile, trashFile, createFolder to GoogleDriveApiClient"
```

---

### Task 4: 401 retry logic

**Files:**
- Modify: `lib/services/sync/google_drive_api_client.dart`
- Modify: `test/services/sync/google_drive_api_client_test.dart`

**Step 1: Write the failing test**

```dart
  group('GoogleDriveApiClient 401 retry', () {
    test('retries with fresh token after 401 and succeeds', () async {
      int callCount = 0;
      int tokenCallCount = 0;

      final client = GoogleDriveApiClient(
        getAccessToken: () async {
          tokenCallCount++;
          return 'token-$tokenCallCount';
        },
        httpClient: MockClient((request) async {
          callCount++;
          if (callCount == 1) {
            // First call: return 401
            return http.Response('Unauthorized', 401);
          }
          // Second call: return success with fresh token
          expect(request.headers['Authorization'], equals('Bearer token-2'));
          return http.Response(
            jsonEncode({'files': []}),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final files = await client.listChildren('some-parent');
      expect(files, isEmpty);
      expect(callCount, equals(2)); // retried once
      expect(tokenCallCount, equals(2)); // fetched fresh token
    });

    test('throws GoogleDriveAuthException after two 401s', () async {
      final client = GoogleDriveApiClient(
        getAccessToken: () async => 'bad-token',
        httpClient: MockClient((_) async => http.Response('Unauthorized', 401)),
      );

      expect(
        () => client.listChildren('parent'),
        throwsA(isA<GoogleDriveAuthException>()),
      );
    });
  });
```

**Step 2: Run test to verify it fails**

```
flutter test test/services/sync/google_drive_api_client_test.dart -v
```
Expected: FAIL — no retry logic, throws immediately on first 401.

**Step 3: Add retry logic**

Refactor `listChildren` (and `downloadFile`, `uploadFile`, etc.) to use a shared `_execute` helper:

```dart
  /// Executes [fn] with fresh auth headers. On 401, refreshes token and retries once.
  Future<http.Response> _execute(
    Future<http.Response> Function(Map<String, String> headers) fn,
  ) async {
    final headers = await _authHeaders();
    final response = await fn(headers);
    if (response.statusCode != 401) {
      _checkStatus(response);
      return response;
    }
    // Force-refresh: call getAccessToken again
    final freshHeaders = await _authHeaders();
    final retryResponse = await fn(freshHeaders);
    _checkStatus(retryResponse);
    return retryResponse;
  }
```

Update `listChildren` to use `_execute`:

```dart
  Future<List<DriveFileInfo>> listChildren(String parentId) async {
    final uri = Uri.parse('$_baseUrl/drive/v3/files').replace(
      queryParameters: {
        'q': "'$parentId' in parents and trashed=false",
        'fields': 'files(id,name,mimeType,size,modifiedTime)',
        'pageSize': '1000',
      },
    );
    final response = await _execute((h) => _httpClient.get(uri, headers: h));
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return (json['files'] as List<dynamic>)
        .map((f) => DriveFileInfo.fromJson(f as Map<String, dynamic>))
        .toList();
  }
```

Apply the same pattern to `downloadFile`, `uploadFile`, `updateFile`, `trashFile`, `createFolder`.

Remove `_authHeaders()` direct calls from all methods — route through `_execute` instead.

**Step 4: Run test to verify it passes**

```
flutter test test/services/sync/google_drive_api_client_test.dart -v
```
Expected: PASS (all tests)

**Step 5: Run full test suite to check for regressions**

```
flutter test --exclude-tags=integration
```
Expected: PASS

**Step 6: Commit**

```bash
git add lib/services/sync/google_drive_api_client.dart \
        test/services/sync/google_drive_api_client_test.dart
git commit -m "feat(sync): add 401 retry logic to GoogleDriveApiClient"
```

---

## Phase 2 — `GoogleDriveSyncProvider`

### Task 5: Generate mock + `initialize()`

**Files:**
- Create: `lib/services/sync/google_drive_sync_provider.dart`
- Create: `test/services/sync/google_drive_sync_provider_test.dart`

**Step 1: Create the test file with mock annotation**

```dart
// test/services/sync/google_drive_sync_provider_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/services/sync/google_drive_api_client.dart';
import 'package:note_synapse/services/sync/google_drive_sync_provider.dart';

import 'google_drive_sync_provider_test.mocks.dart';

@GenerateMocks([GoogleDriveApiClient])
void main() {
  late MockGoogleDriveApiClient mockClient;
  late GoogleDriveSyncProvider provider;

  setUp(() {
    mockClient = MockGoogleDriveApiClient();
    provider = GoogleDriveSyncProvider(
      client: mockClient,
      syncRootName: 'Test Sync',
    );
  });

  group('initialize', () {
    test('uses existing folder when syncRootName already exists in Drive root', () async {
      when(mockClient.listChildren('root')).thenAnswer((_) async => [
        DriveFileInfo(id: 'existing-folder-id', name: 'Test Sync'),
      ]);

      await provider.initialize();

      verifyNever(mockClient.createFolder(
        name: anyNamed('name'),
        parentId: anyNamed('parentId'),
      ));
    });

    test('creates folder when syncRootName does not exist', () async {
      when(mockClient.listChildren('root')).thenAnswer((_) async => []);
      when(mockClient.createFolder(name: 'Test Sync', parentId: 'root'))
          .thenAnswer((_) async =>
              DriveFileInfo(id: 'new-folder-id', name: 'Test Sync'));

      await provider.initialize();

      verify(mockClient.createFolder(
        name: 'Test Sync',
        parentId: 'root',
      )).called(1);
    });
  });
}
```

**Step 2: Run `build_runner` to generate the mock**

```
dart run build_runner build --delete-conflicting-outputs
```
Expected: generates `test/services/sync/google_drive_sync_provider_test.mocks.dart`

**Step 3: Run test to verify it fails**

```
flutter test test/services/sync/google_drive_sync_provider_test.dart -v
```
Expected: FAIL — `google_drive_sync_provider.dart` not found.

**Step 4: Create the provider skeleton with `initialize()`**

```dart
// lib/services/sync/google_drive_sync_provider.dart
import 'dart:typed_data';
import 'package:note_synapse/models/sync_file_info.dart';
import 'package:note_synapse/services/sync/google_drive_api_client.dart';
import 'package:note_synapse/services/sync/sync_storage_provider.dart';
import 'package:path/path.dart' as p;

class GoogleDriveSyncProvider implements SyncStorageProvider {
  final GoogleDriveApiClient _client;
  final String syncRootName;

  String? _rootFolderId;
  // Maps virtual path → Drive file ID
  // e.g. 'oplogs' → 'folder-id-abc', 'oplogs/op-001.bin' → 'file-id-xyz'
  final Map<String, String> _idCache = {};

  GoogleDriveSyncProvider({
    required GoogleDriveApiClient client,
    required this.syncRootName,
  }) : _client = client;

  /// Finds or creates the sync root folder under 'root' (My Drive).
  Future<void> initialize() async {
    final children = await _client.listChildren('root');
    final existing = children.where((f) => f.name == syncRootName).firstOrNull;
    if (existing != null) {
      _rootFolderId = existing.id;
    } else {
      final created = await _client.createFolder(
        name: syncRootName,
        parentId: 'root',
      );
      _rootFolderId = created.id;
    }
  }

  String get _root {
    if (_rootFolderId == null) {
      throw StateError(
          'GoogleDriveSyncProvider not initialized — call initialize() first');
    }
    return _rootFolderId!;
  }

  /// Resolves a path segment or full file path to a Drive folder ID.
  /// Populates [_idCache] by listing the parent directory when there's a miss.
  Future<String?> _resolveId(String path) async {
    // Normalize path: strip leading slash
    final normalized = path.startsWith('/') ? path.substring(1) : path;
    if (_idCache.containsKey(normalized)) return _idCache[normalized];

    final parts = p.split(normalized); // e.g. ['oplogs', 'op-001.bin']
    String currentParentId = _root;

    for (int i = 0; i < parts.length; i++) {
      final segment = parts[i];
      final partialPath = parts.sublist(0, i + 1).join('/');

      if (_idCache.containsKey(partialPath)) {
        currentParentId = _idCache[partialPath]!;
        continue;
      }

      // Cache miss: list parent and populate
      final children = await _client.listChildren(currentParentId);
      for (final child in children) {
        final childPath = parts.sublist(0, i).join('/');
        final fullChildPath = childPath.isEmpty ? child.name : '$childPath/${child.name}';
        _idCache[fullChildPath] = child.id;
      }

      if (!_idCache.containsKey(partialPath)) return null; // not found
      currentParentId = _idCache[partialPath]!;
    }

    return _idCache[normalized];
  }

  @override
  Future<List<SyncFileInfo>> listFiles(String path) async {
    final folderId = await _resolveId(path);
    if (folderId == null) return [];

    final children = await _client.listChildren(folderId);
    final normalized = path.startsWith('/') ? path.substring(1) : path;

    return children.map((f) {
      final filePath = normalized.isEmpty ? f.name : '$normalized/${f.name}';
      _idCache[filePath] = f.id;
      return SyncFileInfo(
        path: filePath,
        sizeBytes: f.size ?? 0,
        lastModified: f.modifiedTime ?? DateTime.now(),
      );
    }).toList();
  }

  @override
  Future<Uint8List> readFile(String path) async {
    final fileId = await _resolveId(path);
    if (fileId == null) {
      throw GoogleDriveException('File not found: $path');
    }
    return _client.downloadFile(fileId);
  }

  @override
  Future<void> writeFile(String path, Uint8List data) async {
    final normalized = path.startsWith('/') ? path.substring(1) : path;
    final existingId = await _resolveId(normalized);
    if (existingId != null) {
      await _client.updateFile(fileId: existingId, content: data);
    } else {
      // Ensure parent folder exists
      final parts = p.split(normalized);
      final fileName = parts.last;
      final parentPath = parts.length > 1 ? parts.sublist(0, parts.length - 1).join('/') : '';
      final parentId = parentPath.isEmpty ? _root : await _ensureFolder(parentPath);

      final info = await _client.uploadFile(
        name: fileName,
        parentId: parentId,
        content: data,
      );
      _idCache[normalized] = info.id;
    }
  }

  /// Finds or creates a folder at [folderPath] (relative to sync root).
  Future<String> _ensureFolder(String folderPath) async {
    final existingId = await _resolveId(folderPath);
    if (existingId != null) return existingId;

    final parts = p.split(folderPath);
    final folderName = parts.last;
    final parentPath = parts.length > 1 ? parts.sublist(0, parts.length - 1).join('/') : '';
    final parentId = parentPath.isEmpty ? _root : await _ensureFolder(parentPath);

    final folder = await _client.createFolder(
      name: folderName,
      parentId: parentId,
    );
    _idCache[folderPath] = folder.id;
    return folder.id;
  }

  @override
  Future<void> deleteFile(String path) async {
    final normalized = path.startsWith('/') ? path.substring(1) : path;
    final fileId = await _resolveId(normalized);
    if (fileId == null) return;
    await _client.trashFile(fileId);
    _idCache.remove(normalized);
  }

  @override
  Future<bool> exists(String path) async {
    final fileId = await _resolveId(path);
    return fileId != null;
  }

  @override
  Future<SyncFileInfo> getFileInfo(String path) async {
    final normalized = path.startsWith('/') ? path.substring(1) : path;
    final fileId = await _resolveId(normalized);
    if (fileId == null) {
      throw GoogleDriveException('File not found: $path');
    }
    final info = await _client.getFileInfo(fileId);
    if (info == null) throw GoogleDriveException('File metadata not found: $path');
    return SyncFileInfo(
      path: normalized,
      sizeBytes: info.size ?? 0,
      lastModified: info.modifiedTime ?? DateTime.now(),
    );
  }
}
```

Also add `getFileInfo` to `GoogleDriveApiClient`:

```dart
  Future<DriveFileInfo?> getFileInfo(String fileId) async {
    final uri = Uri.parse('$_baseUrl/drive/v3/files/$fileId').replace(
      queryParameters: {'fields': 'id,name,mimeType,size,modifiedTime'},
    );
    final response = await _execute((h) => _httpClient.get(uri, headers: h));
    if (response.statusCode == 404) return null;
    return DriveFileInfo.fromJson(jsonDecode(response.body) as Map<String, dynamic>);
  }
```

**Step 5: Run test to verify it passes**

```
flutter test test/services/sync/google_drive_sync_provider_test.dart -v
```
Expected: PASS (2 tests)

**Step 6: Commit**

```bash
git add lib/services/sync/google_drive_sync_provider.dart \
        lib/services/sync/google_drive_api_client.dart \
        test/services/sync/google_drive_sync_provider_test.dart \
        test/services/sync/google_drive_sync_provider_test.mocks.dart
git commit -m "feat(sync): add GoogleDriveSyncProvider skeleton with initialize()"
```

---

### Task 6: `listFiles()`, `readFile()`, `getFileInfo()`

**Files:**
- Modify: `test/services/sync/google_drive_sync_provider_test.dart`

The implementations are already written in Task 5. This task adds the tests.

**Step 1: Add tests**

```dart
  group('listFiles', () {
    setUp(() async {
      // Pre-initialize with known root folder
      when(mockClient.listChildren('root')).thenAnswer((_) async => [
        DriveFileInfo(id: 'root-folder', name: 'Test Sync'),
      ]);
      await provider.initialize();
    });

    test('lists files in a subfolder and populates cache', () async {
      when(mockClient.listChildren('root-folder')).thenAnswer((_) async => [
        DriveFileInfo(id: 'oplogs-folder', name: 'oplogs'),
      ]);
      when(mockClient.listChildren('oplogs-folder')).thenAnswer((_) async => [
        DriveFileInfo(id: 'op1', name: 'op-001.bin', size: 512,
            modifiedTime: DateTime(2026, 2, 28)),
      ]);

      final files = await provider.listFiles('oplogs');

      expect(files.length, equals(1));
      expect(files[0].path, equals('oplogs/op-001.bin'));
      expect(files[0].sizeBytes, equals(512));
    });

    test('returns empty list when folder does not exist', () async {
      when(mockClient.listChildren('root-folder')).thenAnswer((_) async => []);

      final files = await provider.listFiles('nonexistent');
      expect(files, isEmpty);
    });
  });

  group('readFile', () {
    setUp(() async {
      when(mockClient.listChildren('root')).thenAnswer((_) async => [
        DriveFileInfo(id: 'root-folder', name: 'Test Sync'),
      ]);
      await provider.initialize();
    });

    test('downloads file by resolved ID', () async {
      final expected = Uint8List.fromList([1, 2, 3]);
      when(mockClient.listChildren('root-folder')).thenAnswer((_) async => [
        DriveFileInfo(id: 'snap-id', name: 'snapshot.db'),
      ]);
      when(mockClient.downloadFile('snap-id')).thenAnswer((_) async => expected);

      final bytes = await provider.readFile('snapshot.db');
      expect(bytes, equals(expected));
    });

    test('throws when file does not exist', () async {
      when(mockClient.listChildren('root-folder')).thenAnswer((_) async => []);

      expect(
        () => provider.readFile('missing.db'),
        throwsA(isA<GoogleDriveException>()),
      );
    });
  });
```

**Step 2: Run test to verify it passes**

```
flutter test test/services/sync/google_drive_sync_provider_test.dart -v
```
Expected: PASS

**Step 3: Commit**

```bash
git add test/services/sync/google_drive_sync_provider_test.dart
git commit -m "test(sync): add listFiles and readFile tests for GoogleDriveSyncProvider"
```

---

### Task 7: `writeFile()`, `deleteFile()`, `exists()`

**Files:**
- Modify: `test/services/sync/google_drive_sync_provider_test.dart`

**Step 1: Add tests**

```dart
  group('writeFile', () {
    setUp(() async {
      when(mockClient.listChildren('root')).thenAnswer((_) async => [
        DriveFileInfo(id: 'root-folder', name: 'Test Sync'),
      ]);
      await provider.initialize();
    });

    test('updates existing file via updateFile', () async {
      // Pre-populate cache to simulate existing file
      when(mockClient.listChildren('root-folder')).thenAnswer((_) async => [
        DriveFileInfo(id: 'existing-id', name: 'snapshot.db'),
      ]);
      await provider.listFiles(''); // populate cache

      when(mockClient.updateFile(
        fileId: 'existing-id',
        content: anyNamed('content'),
      )).thenAnswer((_) async {});

      await provider.writeFile('snapshot.db', Uint8List.fromList([9, 8]));

      verify(mockClient.updateFile(
        fileId: 'existing-id',
        content: anyNamed('content'),
      )).called(1);
      verifyNever(mockClient.uploadFile(
        name: anyNamed('name'),
        parentId: anyNamed('parentId'),
        content: anyNamed('content'),
      ));
    });

    test('uploads new file when path is not in cache', () async {
      when(mockClient.listChildren('root-folder')).thenAnswer((_) async => []);
      when(mockClient.uploadFile(
        name: 'new-file.bin',
        parentId: 'root-folder',
        content: anyNamed('content'),
      )).thenAnswer((_) async =>
          DriveFileInfo(id: 'uploaded-id', name: 'new-file.bin'));

      await provider.writeFile('new-file.bin', Uint8List.fromList([1]));

      verify(mockClient.uploadFile(
        name: 'new-file.bin',
        parentId: 'root-folder',
        content: anyNamed('content'),
      )).called(1);
    });
  });

  group('deleteFile', () {
    setUp(() async {
      when(mockClient.listChildren('root')).thenAnswer((_) async => [
        DriveFileInfo(id: 'root-folder', name: 'Test Sync'),
      ]);
      await provider.initialize();
    });

    test('trashes file and evicts from cache', () async {
      when(mockClient.listChildren('root-folder')).thenAnswer((_) async => [
        DriveFileInfo(id: 'del-id', name: 'old.bin'),
      ]);
      await provider.listFiles(''); // populate cache

      when(mockClient.trashFile('del-id')).thenAnswer((_) async {});

      await provider.deleteFile('old.bin');

      verify(mockClient.trashFile('del-id')).called(1);

      // After delete, exists() should return false (cache evicted, no API result)
      when(mockClient.listChildren('root-folder')).thenAnswer((_) async => []);
      final stillExists = await provider.exists('old.bin');
      expect(stillExists, isFalse);
    });

    test('does nothing when file does not exist', () async {
      when(mockClient.listChildren('root-folder')).thenAnswer((_) async => []);

      await provider.deleteFile('nonexistent.bin'); // should not throw

      verifyNever(mockClient.trashFile(any));
    });
  });

  group('exists', () {
    setUp(() async {
      when(mockClient.listChildren('root')).thenAnswer((_) async => [
        DriveFileInfo(id: 'root-folder', name: 'Test Sync'),
      ]);
      await provider.initialize();
    });

    test('returns true when file exists', () async {
      when(mockClient.listChildren('root-folder')).thenAnswer((_) async => [
        DriveFileInfo(id: 'file-id', name: 'config.json'),
      ]);

      final result = await provider.exists('config.json');
      expect(result, isTrue);
    });

    test('returns false when file does not exist', () async {
      when(mockClient.listChildren('root-folder')).thenAnswer((_) async => []);

      final result = await provider.exists('missing.json');
      expect(result, isFalse);
    });
  });
```

**Step 2: Run test to verify it passes**

```
flutter test test/services/sync/google_drive_sync_provider_test.dart -v
```
Expected: PASS (all tests)

**Step 3: Run full test suite**

```
flutter test
```
Expected: PASS

**Step 4: Commit**

```bash
git add test/services/sync/google_drive_sync_provider_test.dart
git commit -m "test(sync): add writeFile, deleteFile, exists tests for GoogleDriveSyncProvider"
```

---

## Phase 3 — Integration

### Task 8: OAuth config constant + `sync_service.dart` routing

**Files:**
- Create: `lib/models/google_oauth_config.dart`
- Modify: `lib/services/sync/sync_service.dart`

**Step 1: Create the OAuth config constant**

```dart
// lib/models/google_oauth_config.dart
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

final kGoogleDriveOAuthConfig = OAuthConfig(
  authorizationEndpoint: 'https://accounts.google.com/o/oauth2/v2/auth',
  tokenEndpoint: 'https://oauth2.googleapis.com/token',
  clientId: _kGoogleClientId,
  clientSecret: null,   // Public client — PKCE provides security, no secret needed
  scope: 'https://www.googleapis.com/auth/drive.file',
  usePkce: true,
  redirectUri: '',      // Resolved at runtime by OAuthRedirectHelper
);
```

**Step 2: Add `'gdrive'` routing to `sync_service.dart`**

Find `restoreConfiguration()` in `lib/services/sync/sync_service.dart`. Locate the block:

```dart
      if (providerType == 'saf') {
        provider = AndroidSafSyncProvider(treeUri: providerUri);
      } else if (providerType == 'folder') {
        provider = FolderSyncProvider(rootPath: providerUri);
      }
```

Replace with:

```dart
      if (providerType == 'saf') {
        provider = AndroidSafSyncProvider(treeUri: providerUri);
      } else if (providerType == 'folder') {
        provider = FolderSyncProvider(rootPath: providerUri);
      } else if (providerType == 'gdrive') {
        final tokenManager = OAuthTokenManager(
          endpointId: 'gdrive',
          config: kGoogleDriveOAuthConfig,
        );
        final apiClient = GoogleDriveApiClient(
          getAccessToken: () async {
            final token = await tokenManager.getAccessToken();
            if (token == null) throw GoogleDriveAuthException('No token — reconnect Google Account');
            return token;
          },
        );
        final gdriveProvider = GoogleDriveSyncProvider(
          client: apiClient,
          syncRootName: providerUri,  // syncRootName stored in providerUri field
        );
        await gdriveProvider.initialize();
        provider = gdriveProvider;
      }
```

Add the required imports at the top of `sync_service.dart`:

```dart
import 'package:note_synapse/models/google_oauth_config.dart';
import 'package:note_synapse/services/oauth_token_manager.dart';
import 'package:note_synapse/services/sync/google_drive_api_client.dart';
import 'package:note_synapse/services/sync/google_drive_sync_provider.dart';
```

**Step 3: Run `flutter analyze` to catch import errors**

```
flutter analyze lib/services/sync/sync_service.dart lib/models/google_oauth_config.dart
```
Expected: No errors.

**Step 4: Run full tests**

```
flutter test
```
Expected: PASS

**Step 5: Commit**

```bash
git add lib/models/google_oauth_config.dart \
        lib/services/sync/sync_service.dart
git commit -m "feat(sync): wire Google Drive provider into SyncService routing"
```

---

### Task 9: UI — Google Drive option in `sync_setup_screen.dart`

**Files:**
- Modify: `lib/screens/sync_setup_screen.dart`

**Step 1: Add state variables for Google Drive**

In `_SyncSetupScreenState`, add after the WebDAV variables:

```dart
  // Google Drive provider
  final _syncRootNameController = TextEditingController(text: 'Note Synapse');
  String? _gdriveEmail;        // set after successful OAuth
  bool _gdriveConnecting = false;
```

In `dispose()`, add:

```dart
    _syncRootNameController.dispose();
```

**Step 2: Add Google Drive radio option to `_buildProviderSelectionCard()`**

Inside the `Column` after the WebDAV `RadioListTile`:

```dart
            RadioListTile<String>(
              title: Text(l10n.syncProviderGoogleDrive),
              subtitle: Text(l10n.syncProviderGoogleDriveDescription),
              value: 'gdrive',
              groupValue: _selectedProvider,
              onChanged: (value) => setState(() => _selectedProvider = value!),
              contentPadding: EdgeInsets.zero,
            ),
```

**Step 3: Add Google Drive config card shown when `_selectedProvider == 'gdrive'`**

In `build()`, within the provider config section, add the else-if branch:

```dart
                else if (_selectedProvider == 'gdrive')
                  _buildGoogleDriveConfigCard(l10n, theme),
```

**Step 4: Implement `_buildGoogleDriveConfigCard()`**

```dart
  Widget _buildGoogleDriveConfigCard(AppLocalizations l10n, ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextFormField(
              controller: _syncRootNameController,
              decoration: InputDecoration(
                labelText: l10n.syncGoogleDriveFolderName,
                hintText: 'Note Synapse',
                border: const OutlineInputBorder(),
              ),
              validator: (value) {
                if (_selectedProvider == 'gdrive' &&
                    (value == null || value.trim().isEmpty)) {
                  return l10n.syncGoogleDriveFolderNameRequired;
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            if (_gdriveEmail != null) ...[
              Row(
                children: [
                  const Icon(Icons.check_circle, color: Colors.green),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.syncGoogleDriveConnected(_gdriveEmail!),
                          style: theme.textTheme.bodyMedium,
                        ),
                        Text(
                          l10n.syncGoogleDriveSyncFolder(
                              _syncRootNameController.text.trim()),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: _gdriveConnecting ? null : _connectGoogleAccount,
                    child: Text(l10n.syncGoogleDriveReconnect),
                  ),
                ],
              ),
            ] else ...[
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _gdriveConnecting ? null : _connectGoogleAccount,
                  icon: _gdriveConnecting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.account_circle),
                  label: Text(l10n.syncGoogleDriveConnect),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
```

**Step 5: Implement `_connectGoogleAccount()`**

```dart
  Future<void> _connectGoogleAccount() async {
    setState(() {
      _gdriveConnecting = true;
      _error = null;
    });
    try {
      final state = base64Url.encode(
        List<int>.generate(16, (_) => Random.secure().nextInt(256)),
      );
      final tokens = await OAuthService.authorizationCodeFlow(
        config: kGoogleDriveOAuthConfig,
        state: state,
      );

      // Store tokens
      final tokenManager = OAuthTokenManager(
        endpointId: 'gdrive',
        config: kGoogleDriveOAuthConfig,
      );
      await tokenManager.saveTokens(tokens);

      // Extract email from id_token JWT payload
      final idToken = tokens['id_token'] as String?;
      String? email;
      if (idToken != null) {
        final parts = idToken.split('.');
        if (parts.length == 3) {
          final payload = utf8.decode(
            base64Url.decode(base64Url.normalize(parts[1])),
          );
          final claims = jsonDecode(payload) as Map<String, dynamic>;
          email = claims['email'] as String?;
        }
      }

      if (mounted) {
        setState(() => _gdriveEmail = email ?? 'Google Account');
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _gdriveConnecting = false);
    }
  }
```

Add the required imports at the top of `sync_setup_screen.dart`:

```dart
import 'dart:convert';
import 'dart:math';
import 'package:note_synapse/models/google_oauth_config.dart';
import 'package:note_synapse/services/oauth_service.dart';
import 'package:note_synapse/services/oauth_token_manager.dart';
import 'package:note_synapse/services/sync/google_drive_api_client.dart';
import 'package:note_synapse/services/sync/google_drive_sync_provider.dart';
```

**Step 6: Add `'gdrive'` case to `_initializeSync()`**

In `_initializeSync()`, extend the provider block:

```dart
      } else if (_selectedProvider == 'gdrive') {
        if (_gdriveEmail == null) {
          setState(() => _error = l10n.syncGoogleDriveNotConnected);
          return;
        }
        final syncRootName = _syncRootNameController.text.trim();
        final tokenManager = OAuthTokenManager(
          endpointId: 'gdrive',
          config: kGoogleDriveOAuthConfig,
        );
        final apiClient = GoogleDriveApiClient(
          getAccessToken: () async {
            final token = await tokenManager.getAccessToken();
            if (token == null) throw GoogleDriveAuthException('No token');
            return token;
          },
        );
        final gdriveProvider = GoogleDriveSyncProvider(
          client: apiClient,
          syncRootName: syncRootName,
        );
        await gdriveProvider.initialize();
        provider = gdriveProvider;
        providerType = 'gdrive';
        providerUri = syncRootName;  // stored for restoreConfiguration()
      } else {
        throw UnimplementedError('WebDAV provider not yet implemented');
      }
```

**Step 7: Run `flutter analyze`**

```
flutter analyze lib/screens/sync_setup_screen.dart
```
Expected: No errors.

**Step 8: Commit**

```bash
git add lib/screens/sync_setup_screen.dart \
        lib/models/google_oauth_config.dart
git commit -m "feat(ui): add Google Drive provider option to SyncSetupScreen"
```

---

### Task 10: Localization

**Files:**
- Modify: `lib/l10n/app_en.arb`
- Modify: `lib/l10n/app_zh.arb`

**Step 1: Add keys to `app_en.arb`**

Add the following entries in the sync-related section (near the existing `syncProviderFolder`, `syncProviderWebDav` keys):

```json
  "syncProviderGoogleDrive": "Google Drive",
  "@syncProviderGoogleDrive": {},
  "syncProviderGoogleDriveDescription": "Sync to a folder in your Google Drive",
  "@syncProviderGoogleDriveDescription": {},
  "syncGoogleDriveFolderName": "Sync Folder Name",
  "@syncGoogleDriveFolderName": {},
  "syncGoogleDriveFolderNameRequired": "Folder name cannot be empty",
  "@syncGoogleDriveFolderNameRequired": {},
  "syncGoogleDriveConnect": "Connect Google Account",
  "@syncGoogleDriveConnect": {},
  "syncGoogleDriveReconnect": "Reconnect",
  "@syncGoogleDriveReconnect": {},
  "syncGoogleDriveConnected": "Connected as {email}",
  "@syncGoogleDriveConnected": {
    "placeholders": {
      "email": {"type": "String"}
    }
  },
  "syncGoogleDriveSyncFolder": "Sync folder: My Drive / {name}",
  "@syncGoogleDriveSyncFolder": {
    "placeholders": {
      "name": {"type": "String"}
    }
  },
  "syncGoogleDriveNotConnected": "Please connect your Google Account first",
  "@syncGoogleDriveNotConnected": {},
  "syncGoogleDriveDisconnect": "Disconnect Google Account",
  "@syncGoogleDriveDisconnect": {}
```

**Step 2: Add keys to `app_zh.arb`**

```json
  "syncProviderGoogleDrive": "Google 云端硬盘",
  "syncProviderGoogleDriveDescription": "同步到您 Google 云端硬盘中的文件夹",
  "syncGoogleDriveFolderName": "同步文件夹名称",
  "syncGoogleDriveFolderNameRequired": "文件夹名称不能为空",
  "syncGoogleDriveConnect": "连接 Google 账号",
  "syncGoogleDriveReconnect": "重新连接",
  "syncGoogleDriveConnected": "已连接: {email}",
  "syncGoogleDriveSyncFolder": "同步文件夹: 我的云端硬盘 / {name}",
  "syncGoogleDriveNotConnected": "请先连接您的 Google 账号",
  "syncGoogleDriveDisconnect": "断开 Google 账号"
```

**Step 3: Run code generation for l10n**

```
flutter pub get
```

Flutter's l10n generation runs automatically on `pub get` / `build`. If not, run:

```
dart run build_runner build --delete-conflicting-outputs
```

**Step 4: Run `flutter analyze`**

```
flutter analyze
```
Expected: No errors.

**Step 5: Run full test suite**

```
flutter test
```
Expected: All tests pass.

**Step 6: Commit**

```bash
git add lib/l10n/app_en.arb lib/l10n/app_zh.arb
git commit -m "feat(l10n): add Google Drive sync localization strings (EN + ZH)"
```

---

## Final Checklist

- [ ] `flutter analyze` passes with no errors
- [ ] `flutter test` — all tests pass
- [ ] `GoogleDriveApiClient` tested: listChildren, downloadFile, uploadFile, updateFile, trashFile, createFolder, 401 retry
- [ ] `GoogleDriveSyncProvider` tested: initialize (find/create), listFiles, readFile, writeFile (update + upload), deleteFile, exists
- [ ] `kGoogleDriveOAuthConfig` has `clientSecret: null` and `usePkce: true`
- [ ] `sync_service.dart` routes `'gdrive'` provider type correctly
- [ ] UI shows Google Drive option, disables Next until OAuth completes
- [ ] `app_en.arb` and `app_zh.arb` have all new keys

## Google Cloud Console Setup (Manual)

Before shipping, the developer must:
1. Create a project at https://console.cloud.google.com/
2. Enable the Google Drive API
3. Create OAuth 2.0 credentials → Desktop app type
4. Copy the Client ID into `_kGoogleClientId` in `lib/models/google_oauth_config.dart`
5. Register both redirect URIs:
   - `http://127.0.0.1:51791/callback` (desktop)
   - `notesynapse://oauth/callback` (mobile)
6. Submit for Google OAuth verification if distributing publicly (required for non-test users)

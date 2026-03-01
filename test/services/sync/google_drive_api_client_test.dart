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

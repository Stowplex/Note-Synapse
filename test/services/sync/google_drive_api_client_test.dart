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
      expect(files[0].modifiedTime, equals(DateTime.utc(2026, 2, 28, 10, 0, 0)));
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

  group('GoogleDriveApiClient error handling', () {
    test('401 response throws GoogleDriveAuthException', () async {
      final client = GoogleDriveApiClient(
        getAccessToken: () async => 'tok',
        httpClient: MockClient((_) async => http.Response('Unauthorized', 401)),
      );
      expect(
        () => client.listChildren('parent'),
        throwsA(isA<GoogleDriveAuthException>()),
      );
    });

    test('403 response throws GoogleDriveQuotaException', () async {
      final client = GoogleDriveApiClient(
        getAccessToken: () async => 'tok',
        httpClient: MockClient((_) async => http.Response('Forbidden', 403)),
      );
      expect(
        () => client.listChildren('parent'),
        throwsA(isA<GoogleDriveQuotaException>()),
      );
    });

    test('500 response throws GoogleDriveException with status code', () async {
      final client = GoogleDriveApiClient(
        getAccessToken: () async => 'tok',
        httpClient: MockClient((_) async => http.Response('Server Error', 500)),
      );
      expect(
        () => client.listChildren('parent'),
        throwsA(
          isA<GoogleDriveException>().having(
            (e) => e.statusCode,
            'statusCode',
            equals(500),
          ),
        ),
      );
    });

    test('paginated response accumulates all results', () async {
      int callCount = 0;
      final client = GoogleDriveApiClient(
        getAccessToken: () async => 'tok',
        httpClient: MockClient((request) async {
          callCount++;
          if (callCount == 1) {
            return http.Response(
              jsonEncode({
                'nextPageToken': 'page2token',
                'files': [{'id': 'f1', 'name': 'file1.bin', 'size': '100'}],
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          expect(request.url.queryParameters['pageToken'], equals('page2token'));
          return http.Response(
            jsonEncode({
              'files': [{'id': 'f2', 'name': 'file2.bin', 'size': '200'}],
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      final files = await client.listChildren('parent');
      expect(files.length, equals(2));
      expect(files[0].id, equals('f1'));
      expect(files[1].id, equals('f2'));
      expect(callCount, equals(2));
    });
  });
}

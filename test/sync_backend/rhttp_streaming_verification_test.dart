// M2.9 — does `GoogleDriveBackend` actually work over the app's rhttp client?
//
// M2.9 switched Drive traffic from a bare `http.Client()` to
// `NetworkProvider.sharedClient`, which delegates to `RhttpCompatibleClient`
// (a Rust/reqwest-backed client). `GoogleDriveBackend` does not use the
// convenience `get`/`post` helpers — every Drive call goes through
// `Client.send(http.BaseRequest)` and consumes a `StreamedResponse`
// (`_send` -> `http.Response.fromStream`, and `downloadBlob` returns a
// stream). That is the least-travelled part of any `http.Client`
// implementation and the most likely thing to be subtly wrong, so it is
// verified here against a real local HTTP server rather than assumed.
//
// **Why this test skips by default.** rhttp is a Rust FFI package: its
// native library is produced by the *app* build (Gradle/CocoaPods invoking
// cargokit), and no such library exists in a plain `flutter test` run — the
// standard `Rhttp.init()` fails with "Failed to load dynamic library". Rather
// than leave the claim unverified, this test loads a host-built dylib
// directly if one is present, and skips with an explanatory message if not.
//
// To run it:
//
//     cd third_party/rhttp/rhttp/rust
//     RUSTFLAGS="--cfg reqwest_unstable" cargo build --release
//     cd - && flutter test test/sync_backend/rhttp_streaming_verification_test.dart
//
// **Result when it was run for M2.9 (macOS, rhttp vendored at
// third_party/rhttp, reqwest 0.13.1): all five checks passed.** Streaming
// works; no fallback to a bare `http.Client` was needed anywhere, and none
// is implemented.
//
// Each test below states which `GoogleDriveBackend` behavior depends on it.

// ignore_for_file: depend_on_referenced_packages, avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:rhttp/rhttp.dart';
// ignore: implementation_imports
import 'package:rhttp/src/rust/frb_generated.dart';

/// Host-built native library locations, in preference order.
const _dylibCandidates = [
  'third_party/rhttp/rhttp/rust/target/release/librhttp.dylib',
  'third_party/rhttp/rhttp/rust/target/release/librhttp.so',
  'third_party/rhttp/rhttp/rust/target/debug/librhttp.dylib',
  'third_party/rhttp/rhttp/rust/target/debug/librhttp.so',
];

String? _findDylib() {
  for (final path in _dylibCandidates) {
    if (File(path).existsSync()) return path;
  }
  return null;
}

void main() {
  final dylib = _findDylib();
  final skipReason = dylib == null
      ? 'rhttp native library not built. This test verifies that '
            'GoogleDriveBackend\'s Client.send()/StreamedResponse usage works '
            'over RhttpCompatibleClient; it needs a host build of the Rust '
            'library. Run:  cd third_party/rhttp/rhttp/rust && '
            'RUSTFLAGS="--cfg reqwest_unstable" cargo build --release'
      : null;

  group('RhttpCompatibleClient satisfies what GoogleDriveBackend needs', () {
    late RhttpCompatibleClient client;
    late HttpServer server;
    late Uri base;
    final captured = <String, dynamic>{};

    setUpAll(() async {
      if (dylib == null) return;
      TestWidgetsFlutterBinding.ensureInitialized();
      await RustLib.init(externalLibrary: ExternalLibrary.open(dylib));
      client = await RhttpCompatibleClient.create();

      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = Uri.parse('http://127.0.0.1:${server.port}');
      server.listen((req) async {
        switch (req.uri.path) {
          case '/list':
            req.response.statusCode = 200;
            req.response.headers.contentType = ContentType.json;
            req.response.write(
              jsonEncode({
                'files': const [],
                'auth': req.headers.value('authorization'),
              }),
            );
            await req.response.close();
          case '/quota':
            req.response.statusCode = 403;
            req.response.headers.contentType = ContentType.json;
            req.response.write(
              jsonEncode({
                'error': {
                  'message': 'quota',
                  'errors': [
                    {'reason': 'storageQuotaExceeded'},
                  ],
                },
              }),
            );
            await req.response.close();
          case '/upload':
            final body = <int>[];
            await for (final chunk in req) {
              body.addAll(chunk);
            }
            captured['contentType'] = req.headers.value('content-type');
            captured['bytes'] = Uint8List.fromList(body);
            req.response.statusCode = 200;
            req.response.headers.contentType = ContentType.json;
            req.response.write(jsonEncode({'id': 'f1'}));
            await req.response.close();
          case '/blob':
            // 2 MiB written as 256 separate chunks with no Content-Length,
            // i.e. a chunked transfer — the shape a large Drive blob
            // download takes.
            req.response.statusCode = 200;
            req.response.headers.contentType = ContentType.binary;
            for (var i = 0; i < 256; i++) {
              req.response.add(Uint8List.fromList(List.filled(8192, i % 256)));
            }
            await req.response.close();
          default:
            req.response.statusCode = 404;
            await req.response.close();
        }
      });
    });

    tearDownAll(() async {
      if (dylib == null) return;
      await server.close(force: true);
      client.close();
    });

    test('send() yields a StreamedResponse whose body and headers read back '
        '(every _authorizedRequest call depends on this)', () async {
      final streamed = await client.send(
        http.Request('GET', base.replace(path: '/list'))
          ..headers['Authorization'] = 'Bearer tok-1',
      );
      expect(streamed, isA<http.StreamedResponse>());
      final response = await http.Response.fromStream(streamed);
      expect(response.statusCode, 200);
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      expect(
        json['auth'],
        'Bearer tok-1',
        reason: 'Bearer token headers must reach the server verbatim.',
      );
    }, skip: skipReason);

    test('a non-2xx arrives as a response, not a thrown exception '
        '(_throwIfError/_mapDriveError read response.statusCode)', () async {
      // rhttp defaults to throwOnStatusCode: true; RhttpCompatibleClient
      // forces it false to honour the BaseClient contract. If that ever
      // regressed, every Drive error would surface as an opaque
      // RhttpException instead of a mapped Sync*Exception.
      final streamed = await client.send(
        http.Request('GET', base.replace(path: '/quota')),
      );
      final response = await http.Response.fromStream(streamed);
      expect(response.statusCode, 403);
      expect(jsonDecode(response.body)['error']['message'], 'quota');
    }, skip: skipReason);

    test('a hand-rolled multipart/related body survives byte-for-byte '
        '(_createWithContent / uploadBlob depend on this)', () async {
      // Drive's multipart upload is `multipart/related`, hand-built by
      // GoogleDriveBackend and set via `bodyBytes` with an explicit
      // Content-Type. A client that re-encoded the body or rewrote the
      // Content-Type (dropping the boundary) would corrupt every upload.
      final payload = Uint8List.fromList(
        utf8.encode(
          '--b\r\nContent-Type: application/json\r\n\r\n{"name":"x"}\r\n'
          '--b\r\nContent-Type: application/octet-stream\r\n\r\n\x00\x01\x02\r\n--b--\r\n',
        ),
      );
      final streamed = await client.send(
        http.Request('POST', base.replace(path: '/upload'))
          ..headers['Authorization'] = 'Bearer t'
          ..headers['Content-Type'] = 'multipart/related; boundary=b'
          ..bodyBytes = payload,
      );
      expect((await http.Response.fromStream(streamed)).statusCode, 200);
      expect(captured['contentType'], 'multipart/related; boundary=b');
      expect(captured['bytes'], payload);
    }, skip: skipReason);

    test('a large chunked response body genuinely streams, byte count exact '
        '(downloadBlob / _downloadContent depend on this)', () async {
      final streamed = await client.send(
        http.Request('GET', base.replace(path: '/blob')),
      );
      var chunks = 0;
      var total = 0;
      await for (final chunk in streamed.stream) {
        chunks++;
        total += chunk.length;
      }
      expect(total, 256 * 8192);
      expect(
        chunks,
        greaterThan(1),
        reason:
            'The body must arrive incrementally rather than as one buffered '
            'blob — that is what "streaming works" means here.',
      );
      print('rhttp streaming: $total bytes in $chunks chunks');
    }, skip: skipReason);

    test(
      'a transport failure is an http.ClientException '
      '(_send catches exactly that and maps it to SyncNetworkException)',
      () async {
        final probe = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final deadPort = probe.port;
        await probe.close(force: true);

        Object? thrown;
        try {
          final streamed = await client.send(
            http.Request('GET', Uri.parse('http://127.0.0.1:$deadPort/list')),
          );
          await http.Response.fromStream(streamed);
        } catch (e) {
          thrown = e;
        }
        expect(
          thrown,
          isA<http.ClientException>(),
          reason:
              'GoogleDriveBackend._send only catches http.ClientException. A '
              'raw RhttpException escaping would bypass the typed sync error '
              'vocabulary entirely.',
        );
      },
      skip: skipReason,
    );
  });
}

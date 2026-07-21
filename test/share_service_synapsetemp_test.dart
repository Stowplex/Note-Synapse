import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/share_service.dart';
import 'package:note_synapse/utils/file_utils.dart';
import 'package:path_provider/path_provider.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class _MockPathProviderPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  _MockPathProviderPlatform({required this.appDocPath, required this.tempPath});

  final String appDocPath;
  final String tempPath;

  @override
  Future<String?> getTemporaryPath() async => tempPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => appDocPath;

  @override
  Future<String?> getApplicationSupportPath() async => appDocPath;

  @override
  Future<String?> getLibraryPath() async => appDocPath;

  @override
  Future<String?> getDownloadsPath() async => tempPath;

  @override
  Future<String?> getExternalStoragePath() async => tempPath;

  @override
  Future<List<String>?> getExternalCachePaths() async => [tempPath];

  @override
  Future<List<String>?> getExternalStoragePaths({
    StorageDirectory? type,
  }) async => [tempPath];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory rootDir;
  late Directory attachmentsDir;
  const noteId = '21bf4071-b339-4dac-a0d8-9f7790a444c1';
  const tempUri =
      'synapsetemp:///syn_1763600083290_3a57a21a-cdcc-4ddd-9f75-baea0954e8ac.svg';
  const svgPayload =
      '<svg xmlns="http://www.w3.org/2000/svg"><rect width="10" height="10"/></svg>';

  setUp(() async {
    rootDir = await Directory.systemTemp.createTemp('share_service_test_');
    attachmentsDir = Directory('${rootDir.path}/attachments');
    await attachmentsDir.create(recursive: true);
    PathProviderPlatform.instance = _MockPathProviderPlatform(
      appDocPath: rootDir.path,
      tempPath: rootDir.path,
    );
    FileUtils.resetDocumentsPathCache();
  });

  tearDown(() async {
    if (await rootDir.exists()) {
      await rootDir.delete(recursive: true);
    }
  });

  test(
    'falls back to <noteId>_<sha256>.svg when synapsetemp cache is empty',
    () async {
      final hash = sha256.convert(utf8.encode(tempUri)).toString();
      final attachmentFile = File(
        '${attachmentsDir.path}/${noteId}_$hash.svg',
      );
      await attachmentFile.writeAsString(svgPayload);

      final result = await ShareService.debugLoadSvgStringFromSource(
        tempUri,
        noteId: noteId,
      );

      expect(result, equals(svgPayload));
    },
  );

  test(
    'returns null when noteId is omitted and the temp cache is empty',
    () async {
      final hash = sha256.convert(utf8.encode(tempUri)).toString();
      await File(
        '${attachmentsDir.path}/${noteId}_$hash.svg',
      ).writeAsString(svgPayload);

      final result = await ShareService.debugLoadSvgStringFromSource(tempUri);

      expect(result, isNull);
    },
  );

  test(
    'raster loader returns bytes from the promoted attachment too',
    () async {
      const rasterUri =
          'synapsetemp:///syn_1763601444876_79db7a62-e83d-475e-9e51-ab21940ae877.png';
      final hash = sha256.convert(utf8.encode(rasterUri)).toString();
      final bytes = List<int>.generate(64, (i) => i & 0xff);
      await File(
        '${attachmentsDir.path}/${noteId}_$hash.png',
      ).writeAsBytes(bytes);

      final result = await ShareService.debugLoadImageBytesFromSource(
        rasterUri,
        noteId: noteId,
      );

      expect(result, isNotNull);
      expect(result!.toList(), equals(bytes));
    },
  );
}

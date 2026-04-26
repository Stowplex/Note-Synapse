import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/prompts/prompt_template_service.dart';
import 'package:note_synapse/services/service_locator.dart';

/// Wires a `PromptTemplateService` into the GetIt container for tests.
///
/// Discovers every `.md` template under `assets/prompts/` on disk, hands the
/// service a matching mock `AssetManifest.bin`, and pre-loads each template so
/// `renderSync` calls work without `flutter run` having staged the assets.
/// Re-registers the service if one is already present so tests can call this
/// from multiple `setUp`s safely.
Future<void> registerTestPromptTemplateService() async {
  TestWidgetsFlutterBinding.ensureInitialized();

  final promptsDir = Directory('assets/prompts');
  if (!promptsDir.existsSync()) {
    throw StateError(
      'assets/prompts not found. Run tests from the repository root.',
    );
  }

  final manifest = <String, List<Object>>{};
  for (final entity in promptsDir.listSync(recursive: true)) {
    if (entity is! File) continue;
    if (!entity.path.endsWith('.md')) continue;
    final assetKey = entity.path;
    manifest[assetKey] = [
      {'asset': assetKey},
    ];
  }
  final manifestBytes = const StandardMessageCodec().encodeMessage(manifest)!;

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMessageHandler('flutter/assets', (ByteData? message) async {
    final key = utf8.decode(message!.buffer.asUint8List());
    if (key == 'AssetManifest.bin') {
      return manifestBytes;
    }
    if (key.startsWith('assets/prompts/') && key.endsWith('.md')) {
      final file = File(key);
      if (file.existsSync()) {
        final bytes = Uint8List.fromList(file.readAsBytesSync());
        return ByteData.view(bytes.buffer);
      }
    }
    return null;
  });

  final service = PromptTemplateService();
  await service.preloadAll();

  if (getIt.isRegistered<PromptTemplateService>()) {
    await getIt.unregister<PromptTemplateService>();
  }
  getIt.registerSingleton<PromptTemplateService>(service);
}

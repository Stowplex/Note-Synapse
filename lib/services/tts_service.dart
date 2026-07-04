import 'dart:io';

import 'package:flutter_tts/flutter_tts.dart';

import 'logger_service.dart';

/// Wraps the device text-to-speech engine (flutter_tts).
///
/// Used by the Synapse JavaScript API (`Synapse.tts`) so user apps can speak
/// short text (e.g. word/sentence pronunciation) without an AI model call.
/// For AI-generated audio content (podcasts, stylized narration), use
/// `chatAI` with `model_hint: ['tts']` instead.
class TtsService {
  FlutterTts? _tts;

  Future<FlutterTts> _ensureInitialized() async {
    final existing = _tts;
    if (existing != null) return existing;

    final tts = FlutterTts();
    // Make speak() complete only when the utterance finishes, so callers
    // can await playback.
    await tts.awaitSpeakCompletion(true);
    if (Platform.isIOS) {
      // Play through the media channel so speech is audible with the
      // ringer switch on silent.
      await tts.setSharedInstance(true);
      await tts.setIosAudioCategory(
        IosTextToSpeechAudioCategory.playback,
        [
          IosTextToSpeechAudioCategoryOptions.mixWithOthers,
          IosTextToSpeechAudioCategoryOptions.duckOthers,
        ],
        IosTextToSpeechAudioMode.spokenAudio,
      );
    }
    _tts = tts;
    return tts;
  }

  /// Speaks [text] with the device TTS engine, interrupting any utterance
  /// already in progress. Completes when playback finishes.
  ///
  /// [language] is a BCP-47 tag (e.g. 'en-US', 'ja-JP').
  /// [rate] is the speech rate in 0.0-1.0 (platform default ~0.5).
  /// [pitch] is 0.5-2.0 (default 1.0). [volume] is 0.0-1.0 (default 1.0).
  Future<void> speak(
    String text, {
    String? language,
    double? rate,
    double? pitch,
    double? volume,
  }) async {
    final tts = await _ensureInitialized();
    await tts.stop();
    if (language != null && language.isNotEmpty) {
      await tts.setLanguage(language);
    }
    if (rate != null) {
      await tts.setSpeechRate(rate.clamp(0.0, 1.0));
    }
    if (pitch != null) {
      await tts.setPitch(pitch.clamp(0.5, 2.0));
    }
    if (volume != null) {
      await tts.setVolume(volume.clamp(0.0, 1.0));
    }
    LoggerService.debug('[TtsService] Speaking ${text.length} chars');
    await tts.speak(text);
  }

  /// Stops any utterance in progress.
  Future<void> stop() async {
    final tts = await _ensureInitialized();
    await tts.stop();
  }

  /// Returns the BCP-47 language tags supported by the device engine.
  Future<List<String>> getLanguages() async {
    final tts = await _ensureInitialized();
    final languages = await tts.getLanguages;
    if (languages is List) {
      return languages.map((e) => e.toString()).toList();
    }
    return const [];
  }
}

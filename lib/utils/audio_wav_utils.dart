import 'dart:typed_data';

/// Utilities for converting raw PCM audio into a playable WAV container.
///
/// Speech-generation models (e.g. Gemini TTS) return headerless 16-bit PCM
/// with a mime type like 'audio/L16;codec=pcm;rate=24000', which browsers and
/// audio players cannot play directly.
class AudioWavUtils {
  /// Whether [mimeType] denotes raw (headerless) PCM audio.
  static bool isRawPcm(String mimeType) {
    final normalized = mimeType.toLowerCase();
    return normalized.startsWith('audio/l16') ||
        normalized.contains('codec=pcm');
  }

  /// Extracts the sample rate from a mime type like 'audio/L16;rate=24000'.
  static int sampleRateFromMimeType(String mimeType, {int fallback = 24000}) {
    final match = RegExp(r'rate=(\d+)').firstMatch(mimeType);
    return int.tryParse(match?.group(1) ?? '') ?? fallback;
  }

  /// Wraps 16-bit little-endian PCM samples in a WAV (RIFF) container.
  static Uint8List pcm16ToWav(
    Uint8List pcm, {
    int sampleRate = 24000,
    int channels = 1,
  }) {
    const bitsPerSample = 16;
    final byteRate = sampleRate * channels * bitsPerSample ~/ 8;
    final blockAlign = channels * bitsPerSample ~/ 8;

    final header = ByteData(44);
    void writeAscii(int offset, String value) {
      for (var i = 0; i < value.length; i++) {
        header.setUint8(offset + i, value.codeUnitAt(i));
      }
    }

    writeAscii(0, 'RIFF');
    header.setUint32(4, 36 + pcm.length, Endian.little);
    writeAscii(8, 'WAVE');
    writeAscii(12, 'fmt ');
    header.setUint32(16, 16, Endian.little); // fmt chunk size
    header.setUint16(20, 1, Endian.little); // PCM format
    header.setUint16(22, channels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, blockAlign, Endian.little);
    header.setUint16(34, bitsPerSample, Endian.little);
    writeAscii(36, 'data');
    header.setUint32(40, pcm.length, Endian.little);

    final wav = Uint8List(44 + pcm.length);
    wav.setRange(0, 44, header.buffer.asUint8List());
    wav.setRange(44, wav.length, pcm);
    return wav;
  }
}

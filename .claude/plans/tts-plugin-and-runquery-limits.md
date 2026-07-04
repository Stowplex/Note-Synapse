# TTS for user apps + runQuery limit transparency

Goal: enable the language-learning User App flow (TTS on learning-language text,
clickable words with AI explanations, storing learnings into notes).

## Gap analysis (2026-07-03)

1. Chat in learning language + translation/grammar sessions: supported today.
2. Note Action app with clickable words + `Synapse.chatAI`: supported today.
   `chatAI` is single-turn, which is fine for in-context word explanations.
3. Storing knowledge: `saveNotes` / `updateNotes` (granular append, tags) +
   read-only `runQuery` to locate learning notes covers it. No new API needed.
4. Gaps fixed by this change:
   - No TTS anywhere. Android WebView does NOT implement Web Speech API
     (speechSynthesis) - only WKWebView (iOS/macOS) has it - so user apps
     cannot rely on the browser.
   - `runQuery` truncated at 100 rows silently and the limit was undocumented.

## Decision (discussed with user)

Both TTS paths, with explicit AI-docs guidance on when to use which:
- **Device TTS** (`Synapse.tts.speak/stop/getLanguages`, flutter_tts): trivial
  playback - word/sentence pronunciation, read-a-note. Instant, free, offline.
- **Model TTS** (`chatAI` with `model_hint: ['tts']`, e.g. Gemini TTS): only
  for generated audio content (podcasts, dialogues, stylized narration).
  Rides the existing capability system like `image_gen`; no new bridge method.

## Implemented

### A. Device TTS
- `flutter_tts` dep; Android manifest `TTS_SERVICE` queries intent.
- `lib/services/tts_service.dart`, registered in service_locator.
- Bridge JS `Synapse.tts.{speak,stop,getLanguages}` + `ttsSpeak/ttsStop/
  ttsGetLanguages` handlers.

### B. Model TTS ('tts' capability)
- `ModelCapabilities.supportsSpeechGeneration`; preset capability id
  `generate_tts`; preset `assets/model_presets/gemini_2_5_flash_tts.yaml`.
- Config screen checkbox; preference screen icon + feature-matrix column
  (l10n: speechGenCapability / ttsGenColumn).
- `ModelSelector`: 'tts' hint + selection priority (mirrors image_gen).
- `GeminiModel`: TTS models get `responseModalities: ['AUDIO']` + speechConfig
  (voice, default 'Kore'), systemInstruction stripped; inline audio responses
  (raw PCM `audio/L16`) wrapped into WAV (`lib/utils/audio_wav_utils.dart`);
  multi_part returns `{type:'audio', content:'data:audio/wav;base64,...'}`,
  string mode saves to synapsetemp and emits `[Generated Audio](uri)`.
- `chatAI`/`chatAIMultiPart` accept `voice`; bridge passes `options.voice`.

### C. runQuery transparency
- `SqlQueryResult.truncated`/`totalRows`, surfaced in bridge response and
  toJson; RunSqlTool uses `result.truncated` (was `length == 50` heuristic).
- api_documentation.md documents the 100-row cap + LIMIT/OFFSET advice.

### Untested runtime behavior (needs a device + API key)
- Real Gemini TTS request/response (responseModalities/speechConfig accepted,
  PCM->WAV playback in WebView).
- flutter_tts playback on each platform.

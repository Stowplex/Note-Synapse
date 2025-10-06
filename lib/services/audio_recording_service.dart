import 'dart:async';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:audioplayers/audioplayers.dart';

class AudioRecordingService {
  static final AudioRecordingService _instance = AudioRecordingService._internal();
  factory AudioRecordingService() => _instance;
  AudioRecordingService._internal();

  final AudioRecorder _recorder = AudioRecorder();
  final AudioPlayer _player = AudioPlayer();
  
  bool _isRecording = false;
  bool _isPlaying = false;
  String? _currentRecordingPath;
  String? _currentPlayingPath;
  Duration _playingPosition = Duration.zero;
  Duration _playingDuration = Duration.zero;
  StreamSubscription<RecordState>? _recordStateSubscription;
  StreamSubscription<Duration>? _playerPositionSubscription;
  StreamSubscription<Duration>? _playerDurationSubscription;

  // Getters
  bool get isRecording => _isRecording;
  bool get isPlaying => _isPlaying;
  String? get currentRecordingPath => _currentRecordingPath;
  String? get currentPlayingPath => _currentPlayingPath;

  // Streams for UI updates
  final StreamController<Duration> _recordingDurationController = StreamController<Duration>.broadcast();
  final StreamController<Duration> _playingPositionController = StreamController<Duration>.broadcast();
  final StreamController<Duration> _playingDurationController = StreamController<Duration>.broadcast();
  final StreamController<bool> _recordingStateController = StreamController<bool>.broadcast();
  final StreamController<bool> _playingStateController = StreamController<bool>.broadcast();

  Stream<Duration> get recordingDurationStream => _recordingDurationController.stream;
  Stream<Duration> get playingPositionStream => _playingPositionController.stream;
  Stream<Duration> get playingDurationStream => _playingDurationController.stream;
  Stream<bool> get recordingStateStream => _recordingStateController.stream;
  Stream<bool> get playingStateStream => _playingStateController.stream;

  /// Request microphone permission
  Future<bool> requestPermission() async {
    final status = await Permission.microphone.request();
    return status == PermissionStatus.granted;
  }

  /// Check if microphone permission is granted
  Future<bool> hasPermission() async {
    final status = await Permission.microphone.status;
    return status == PermissionStatus.granted;
  }

  /// Start recording audio
  Future<bool> startRecording() async {
    try {
      if (_isRecording) {
        return false;
      }

      // Check permission
      if (!await hasPermission()) {
        final granted = await requestPermission();
        if (!granted) {
          return false;
        }
      }

      // Check if recorder is available
      if (!await _recorder.hasPermission()) {
        return false;
      }

      // Get the documents directory
      final directory = await getApplicationDocumentsDirectory();
      final audioDir = Directory('${directory.path}/audio_recordings');
      if (!await audioDir.exists()) {
        await audioDir.create(recursive: true);
      }

      // Generate unique filename
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      _currentRecordingPath = '${audioDir.path}/recording_$timestamp.m4a';

      // Start recording
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 128000,
          sampleRate: 44100,
        ),
        path: _currentRecordingPath!,
      );

      _isRecording = true;
      _recordingStateController.add(true);

      // Start duration tracking
      _startDurationTracking();

      return true;
    } catch (e) {
      print('Error starting recording: $e');
      return false;
    }
  }

  /// Stop recording audio
  Future<String?> stopRecording() async {
    try {
      if (!_isRecording) {
        return null;
      }

      final path = await _recorder.stop();
      _isRecording = false;
      _recordingStateController.add(false);
      _recordStateSubscription?.cancel();

      return path;
    } catch (e) {
      print('Error stopping recording: $e');
      return null;
    }
  }

  /// Cancel current recording
  Future<void> cancelRecording() async {
    try {
      if (_isRecording) {
        await _recorder.cancel();
        _isRecording = false;
        _recordingStateController.add(false);
        _recordStateSubscription?.cancel();
        
        // Delete the partial recording file
        if (_currentRecordingPath != null) {
          final file = File(_currentRecordingPath!);
          if (await file.exists()) {
            await file.delete();
          }
        }
        _currentRecordingPath = null;
      }
    } catch (e) {
      print('Error canceling recording: $e');
    }
  }

  /// Start playing audio
  Future<bool> startPlaying(String filePath) async {
    try {
      if (_isPlaying && _currentPlayingPath == filePath) {
        // Already playing this file, pause it
        await pausePlaying();
        return true;
      }

      if (_isPlaying) {
        // Playing different file, stop current and start new
        await stopPlaying();
      }

      final file = File(filePath);
      if (!await file.exists()) {
        return false;
      }

      await _player.play(DeviceFileSource(filePath));
      _isPlaying = true;
      _currentPlayingPath = filePath;
      _playingStateController.add(true);

      // Start position tracking
      _startPositionTracking();

      return true;
    } catch (e) {
      print('Error starting playback: $e');
      return false;
    }
  }

  /// Pause playing audio
  Future<void> pausePlaying() async {
    try {
      if (_isPlaying) {
        await _player.pause();
        _isPlaying = false;
        _playingStateController.add(false);
      }
    } catch (e) {
      print('Error pausing playback: $e');
    }
  }

  /// Resume playing audio
  Future<void> resumePlaying() async {
    try {
      if (!_isPlaying && _currentPlayingPath != null) {
        await _player.resume();
        _isPlaying = true;
        _playingStateController.add(true);
      }
    } catch (e) {
      print('Error resuming playback: $e');
    }
  }

  /// Stop playing audio
  Future<void> stopPlaying() async {
    try {
      await _player.stop();
      _isPlaying = false;
      _currentPlayingPath = null;
      _playingStateController.add(false);
      _playerPositionSubscription?.cancel();
      _playerDurationSubscription?.cancel();
    } catch (e) {
      print('Error stopping playback: $e');
    }
  }

  /// Get current playing position
  Duration get currentPosition => _playingPosition;

  /// Get current playing duration
  Duration get currentDuration => _playingDuration;

  /// Seek to specific position
  Future<void> seekTo(Duration position) async {
    try {
      await _player.seek(position);
    } catch (e) {
      print('Error seeking: $e');
    }
  }

  /// Start duration tracking for recording
  void _startDurationTracking() {
    Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!_isRecording) {
        timer.cancel();
        return;
      }
      // We can't get actual recording duration from the record package
      // So we'll track it manually
      _recordingDurationController.add(Duration.zero);
    });
  }

  /// Start position tracking for playback
  void _startPositionTracking() {
    _playerPositionSubscription = _player.onPositionChanged.listen((position) {
      _playingPosition = position;
      _playingPositionController.add(position);
    });

    _playerDurationSubscription = _player.onDurationChanged.listen((duration) {
      _playingDuration = duration;
      _playingDurationController.add(duration);
    });
  }

  /// Clean up resources
  void dispose() {
    _recordingDurationController.close();
    _playingPositionController.close();
    _playingDurationController.close();
    _recordingStateController.close();
    _playingStateController.close();
    _recordStateSubscription?.cancel();
    _playerPositionSubscription?.cancel();
    _playerDurationSubscription?.cancel();
    _recorder.dispose();
    _player.dispose();
  }
}

import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:audioplayers/audioplayers.dart';
import 'logger_service.dart';

class AudioRecordingService {
  static final AudioRecordingService _instance = AudioRecordingService._internal();
  factory AudioRecordingService() => _instance;
  AudioRecordingService._internal();

  // Method channel for native iOS microphone permission
  static const MethodChannel _iosMethodChannel = MethodChannel('note_synapse/share');

  // Only initialize audio services on supported platforms
  AudioRecorder? _recorder;
  AudioPlayer? _player;
  bool? _isSupported;
  
  bool _isRecording = false;
  bool _isPlaying = false;
  String? _currentRecordingPath;
  String? _currentPlayingPath;
  Duration _playingPosition = Duration.zero;
  Duration _playingDuration = Duration.zero;
  StreamSubscription<RecordState>? _recordStateSubscription;
  StreamSubscription<Duration>? _playerPositionSubscription;
  StreamSubscription<Duration>? _playerDurationSubscription;
  
  // Linux-specific recording variables
  Process? _linuxRecordingProcess;
  Timer? _recordingTimer;
  Duration _recordingDuration = Duration.zero;

  // Initialize audio services only on supported platforms
  void _initializeAudioServices() {
    // Check if we're on a supported platform (Android, iOS, macOS, Windows, Linux)
    _isSupported = true; // Now supporting all platforms including Linux
    
    try {
      _recorder = AudioRecorder();
      _player = AudioPlayer();
    } catch (e) {
      LoggerService.error('Failed to initialize audio services: $e', error: e);
      _isSupported = false;
      _recorder = null;
      _player = null;
    }
  }

  // Getters
  bool get isSupported {
    if (_isSupported == null) {
      _initializeAudioServices();
    }
    return _isSupported!;
  }
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

  /// Check if running on Linux (non-web)
  bool get _isLinux => !kIsWeb && Platform.isLinux;

  /// Check if running on iOS (non-web)
  bool get _isIOS => !kIsWeb && Platform.isIOS;

  /// Request microphone permission
  Future<bool> requestPermission() async {
    if (!isSupported) return false;
    
    // On Linux, we don't need to request permissions
    if (_isLinux) {
      return true;
    }
    
    try {
      final status = await Permission.microphone.status;
      
      // If already granted, return true
      if (status == PermissionStatus.granted) {
        return true;
      }
      
      // On iOS, permission_handler might not show the dialog properly.
      // The record package will handle permission requests automatically when
      // we try to start recording. So on iOS, we'll return false here and
      // let the record package handle it.
      if (_isIOS) {
        // If permanently denied, we can't request again
        if (status == PermissionStatus.permanentlyDenied) {
          LoggerService.warning('Microphone permission permanently denied on iOS');
          return false;
        }
        // For notDetermined or denied, let the record package handle it
        // by returning false and trying to start recording anyway
        return false;
      }
      
      // On Android and other platforms, request permission via permission_handler
      final requestedStatus = await Permission.microphone.request();
      return requestedStatus == PermissionStatus.granted;
    } catch (e) {
      LoggerService.error('Permission request failed: $e', error: e);
      return false;
    }
  }

  /// Check if microphone permission is granted
  Future<bool> hasPermission() async {
    if (!isSupported) return false;
    
    // On Linux, we don't need to check permissions
    if (_isLinux) {
      return true;
    }
    
    try {
      final status = await Permission.microphone.status;
      return status == PermissionStatus.granted;
    } catch (e) {
      LoggerService.error('Permission check failed: $e', error: e);
      return false;
    }
  }

  /// Start recording audio
  Future<bool> startRecording() async {
    try {
      if (!isSupported) {
        return false;
      }

      if (_isRecording) {
        return false;
      }

      // Get the documents directory
      final directory = await getApplicationDocumentsDirectory();
      final audioDir = Directory('${directory.path}/audio_recordings');
      if (!await audioDir.exists()) {
        await audioDir.create(recursive: true);
      }

      // Generate unique filename
      // Use .m4a extension for AAC encoder on iOS, .wav for other platforms
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final extension = _isIOS ? 'm4a' : 'wav';
      _currentRecordingPath = '${audioDir.path}/recording_$timestamp.$extension';

      // Platform-specific recording implementation
      if (_isLinux) {
        return await _startLinuxRecording();
      } else {
        // Use the record package for other platforms
        if (_recorder == null) {
          return false;
        }

        // On iOS, we need to use native AVAudioSession to request permission
        // because permission_handler doesn't properly trigger the iOS permission dialog.
        // On Android, we'll use permission_handler first, then verify with record package.
        if (_isIOS) {
          // Check current permission status first
          final permissionStatus = await Permission.microphone.status;
          LoggerService.info('iOS microphone permission status: $permissionStatus');
          
          if (permissionStatus == PermissionStatus.permanentlyDenied) {
            LoggerService.warning('Microphone permission permanently denied on iOS');
            return false;
          }
          
          // If not granted, request it using native iOS method channel
          // This will properly show the iOS permission dialog
          if (permissionStatus != PermissionStatus.granted) {
            LoggerService.info('Requesting microphone permission on iOS via native method');
            try {
              final granted = await _iosMethodChannel.invokeMethod<bool>('requestMicrophonePermission');
              LoggerService.info('iOS native microphone permission result: $granted');
              
              if (granted != true) {
                LoggerService.warning('Microphone permission not granted on iOS');
                return false;
              }
              
              // Wait a moment for the permission to be fully registered
              await Future.delayed(const Duration(milliseconds: 300));
              
              // Re-initialize the recorder after permission is granted
              // This ensures the recorder is aware of the new permission state
              try {
                _recorder?.dispose();
                _recorder = AudioRecorder();
                LoggerService.info('Re-initialized recorder after permission grant');
              } catch (e) {
                LoggerService.warning('Error re-initializing recorder: $e');
              }
            } catch (e) {
              LoggerService.error('Error requesting microphone permission via native method: $e', error: e);
              return false;
            }
          }
          
          // After requesting, check with record package
          bool recorderHasPermission = await _recorder!.hasPermission();
          if (!recorderHasPermission) {
            // Wait a moment for the permission state to propagate
            await Future.delayed(const Duration(milliseconds: 500));
            recorderHasPermission = await _recorder!.hasPermission();
            
            if (!recorderHasPermission) {
              LoggerService.warning('Record package does not recognize permission on iOS, but proceeding anyway');
              // Proceed anyway - the system permission is what matters
            }
          }
        } else {
          // On Android and other platforms, check and request permission first
          bool permissionGranted = await hasPermission();
          if (!permissionGranted) {
            permissionGranted = await requestPermission();
            if (!permissionGranted) {
              LoggerService.warning('Microphone permission not granted');
              return false;
            }
          }
          
          // Re-check with record package
          bool recorderHasPermission = await _recorder!.hasPermission();
          if (!recorderHasPermission) {
            LoggerService.warning('Recorder does not have permission after requesting');
            return false;
          }
        }

        // Start recording
        try {
          await _recorder!.start(
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
          // If starting failed, log the error
          // This could be due to permission issues or other problems
          LoggerService.error('Failed to start recording: $e', error: e);
          return false;
        }
      }
    } catch (e) {
      LoggerService.error('Error starting recording: $e', error: e);
      return false;
    }
  }

  /// Stop recording audio
  Future<String?> stopRecording() async {
    try {
      if (!isSupported) {
        return null;
      }

      if (!_isRecording) {
        return null;
      }

      if (_isLinux) {
        return await _stopLinuxRecording();
      } else {
        if (_recorder == null) {
          return null;
        }

        final path = await _recorder!.stop();
        _isRecording = false;
        _recordingStateController.add(false);
        _recordStateSubscription?.cancel();

        return path;
      }
    } catch (e) {
      LoggerService.error('Error stopping recording: $e', error: e);
      return null;
    }
  }

  /// Cancel current recording
  Future<void> cancelRecording() async {
    try {
      if (!isSupported) {
        return;
      }

      if (_isRecording) {
        if (_isLinux) {
          await _cancelLinuxRecording();
        } else {
          if (_recorder != null) {
            await _recorder!.cancel();
            _recordStateSubscription?.cancel();
          }
        }
        
        _isRecording = false;
        _recordingStateController.add(false);
        
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
      LoggerService.error('Error canceling recording: $e', error: e);
    }
  }

  /// Start playing audio
  Future<bool> startPlaying(String filePath) async {
    try {
      if (!isSupported || _player == null) {
        return false;
      }

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

      await _player!.play(DeviceFileSource(filePath));
      _isPlaying = true;
      _currentPlayingPath = filePath;
      LoggerService.debug('Audio playback started: $filePath');
      _playingStateController.add(true);

      // Start position tracking
      _startPositionTracking();

      return true;
    } catch (e) {
      LoggerService.error('Error starting playback: $e', error: e);
      return false;
    }
  }

  /// Pause playing audio
  Future<void> pausePlaying() async {
    try {
      if (!isSupported || _player == null) {
        return;
      }

      if (_isPlaying) {
        await _player!.pause();
        _isPlaying = false;
        LoggerService.debug('Audio playback paused');
        _playingStateController.add(false);
      }
    } catch (e) {
      LoggerService.error('Error pausing playback: $e', error: e);
      // Reset state if player is disposed
      _isPlaying = false;
      _playingStateController.add(false);
    }
  }

  /// Resume playing audio
  Future<void> resumePlaying() async {
    try {
      if (!isSupported || _player == null) {
        return;
      }

      if (!_isPlaying && _currentPlayingPath != null) {
        await _player!.resume();
        _isPlaying = true;
        _playingStateController.add(true);
      }
    } catch (e) {
      LoggerService.error('Error resuming playback: $e', error: e);
    }
  }

  /// Stop playing audio
  Future<void> stopPlaying() async {
    try {
      if (!isSupported || _player == null) {
        return;
      }

      await _player!.stop();
      _isPlaying = false;
      _currentPlayingPath = null;
      LoggerService.debug('Audio playback stopped');
      _playingStateController.add(false);
      _playerPositionSubscription?.cancel();
      _playerDurationSubscription?.cancel();
    } catch (e) {
      LoggerService.error('Error stopping playback: $e', error: e);
      // Reset state if player is disposed
      _isPlaying = false;
      _currentPlayingPath = null;
      _playingStateController.add(false);
      _playerPositionSubscription?.cancel();
      _playerDurationSubscription?.cancel();
    }
  }

  /// Get current playing position
  Duration get currentPosition => _playingPosition;

  /// Get current playing duration
  Duration get currentDuration => _playingDuration;

  /// Seek to specific position
  Future<void> seekTo(Duration position) async {
    try {
      if (!isSupported || _player == null) {
        return;
      }

      await _player!.seek(position);
    } catch (e) {
      LoggerService.error('Error seeking: $e', error: e);
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
    if (!isSupported || _player == null) {
      return;
    }

    _playerPositionSubscription = _player!.onPositionChanged.listen((position) {
      _playingPosition = position;
      _playingPositionController.add(position);
    });

    _playerDurationSubscription = _player!.onDurationChanged.listen((duration) {
      _playingDuration = duration;
      _playingDurationController.add(duration);
    });
  }

  /// Linux-specific recording implementation using gstreamer
  Future<bool> _startLinuxRecording() async {
    try {
      // First check if gstreamer is available
      final gstCheck = await Process.run('which', ['gst-launch-1.0']);
      if (gstCheck.exitCode != 0) {
        LoggerService.warning('gst-launch-1.0 not found. Please install gstreamer1.0-tools');
        return false;
      }

      // Use gstreamer to record audio
      final args = [
        'gst-launch-1.0',
        'pulsesrc',
        '!',
        'audioconvert',
        '!',
        'wavenc',
        '!',
        'filesink',
        'location=$_currentRecordingPath',
      ];

      _linuxRecordingProcess = await Process.start(args[0], args.sublist(1));
      
      // Wait a moment to ensure the process started successfully
      await Future.delayed(const Duration(milliseconds: 500));
      
      // Check if the process is still running by checking if it has exited
      try {
        final exitCode = await _linuxRecordingProcess!.exitCode.timeout(
          const Duration(milliseconds: 100),
        );
        // If we get here, the process has already exited
        LoggerService.error('Failed to start gstreamer recording process, exit code: $exitCode');
        return false;
      } catch (e) {
        // Timeout means the process is still running, which is what we want
        // Continue with recording setup
      }

      _isRecording = true;
      _recordingStateController.add(true);
      _recordingDuration = Duration.zero;

      // Start duration tracking
      _startLinuxDurationTracking();

      return true;
    } catch (e) {
      LoggerService.error('Error starting Linux recording: $e', error: e);
      return false;
    }
  }

  /// Stop Linux recording
  Future<String?> _stopLinuxRecording() async {
    try {
      if (_linuxRecordingProcess != null) {
        _linuxRecordingProcess!.kill();
        await _linuxRecordingProcess!.exitCode;
        _linuxRecordingProcess = null;
      }

      _recordingTimer?.cancel();
      _recordingTimer = null;
      _isRecording = false;
      _recordingStateController.add(false);

      return _currentRecordingPath;
    } catch (e) {
      LoggerService.error('Error stopping Linux recording: $e', error: e);
      return null;
    }
  }

  /// Cancel Linux recording
  Future<void> _cancelLinuxRecording() async {
    try {
      if (_linuxRecordingProcess != null) {
        _linuxRecordingProcess!.kill();
        await _linuxRecordingProcess!.exitCode;
        _linuxRecordingProcess = null;
      }

      _recordingTimer?.cancel();
      _recordingTimer = null;
    } catch (e) {
      LoggerService.error('Error canceling Linux recording: $e', error: e);
    }
  }

  /// Start duration tracking for Linux recording
  void _startLinuxDurationTracking() {
    _recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!_isRecording) {
        timer.cancel();
        return;
      }
      _recordingDuration = Duration(seconds: _recordingDuration.inSeconds + 1);
      _recordingDurationController.add(_recordingDuration);
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
    _recordingTimer?.cancel();
    _linuxRecordingProcess?.kill();
    _recorder?.dispose();
    _player?.dispose();
    
    // Reset state
    _isRecording = false;
    _isPlaying = false;
    _currentRecordingPath = null;
    _currentPlayingPath = null;
    _recordingDuration = Duration.zero;
    _playingPosition = Duration.zero;
    _playingDuration = Duration.zero;
  }

  /// Reset audio state without disposing resources
  void resetState() {
    _isRecording = false;
    _isPlaying = false;
    _currentRecordingPath = null;
    _currentPlayingPath = null;
    _recordingDuration = Duration.zero;
    _playingPosition = Duration.zero;
    _playingDuration = Duration.zero;
    
    // Cancel any active subscriptions
    _recordStateSubscription?.cancel();
    _playerPositionSubscription?.cancel();
    _playerDurationSubscription?.cancel();
    _recordingTimer?.cancel();
    
    // Stop any active processes
    _linuxRecordingProcess?.kill();
    
    // Stop any active playback
    try {
      _player?.stop();
    } catch (e) {
      LoggerService.error('Error stopping player during reset: $e', error: e);
    }
  }
}

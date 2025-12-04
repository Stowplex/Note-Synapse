import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:yaml/yaml.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/logger_service.dart';

class GlobalLibraryAsset {
  final String path;
  final String type; // 'script' or 'style'

  GlobalLibraryAsset({required this.path, required this.type});

  factory GlobalLibraryAsset.fromMap(Map<String, dynamic> map) {
    return GlobalLibraryAsset(
      path: map['path'] as String,
      type: map['type'] as String,
    );
  }

  Map<String, dynamic> toMap() {
    return {'path': path, 'type': type};
  }
}

class GlobalLibrary {
  final String id;
  final String name;
  final String version;
  final String description;
  final String usage;
  final List<GlobalLibraryAsset> assets;
  final bool isBuiltIn;
  bool isEnabled;

  GlobalLibrary({
    required this.id,
    required this.name,
    required this.version,
    required this.description,
    required this.usage,
    required this.assets,
    required this.isBuiltIn,
    this.isEnabled = true,
  });

  factory GlobalLibrary.fromYaml(dynamic yaml) {
    final map = yaml as Map;
    return GlobalLibrary(
      id: map['id'] as String,
      name: map['name'] as String,
      version: map['version'].toString(),
      description: map['description'] as String,
      usage: map['usage'] as String,
      assets: (map['assets'] as List)
          .map((e) => GlobalLibraryAsset.fromMap(Map<String, dynamic>.from(e)))
          .toList(),
      isBuiltIn: true,
    );
  }

  factory GlobalLibrary.fromJson(Map<String, dynamic> json) {
    return GlobalLibrary(
      id: json['id'] as String,
      name: json['name'] as String,
      version: json['version'] as String,
      description: json['description'] as String,
      usage: json['usage'] as String,
      assets: (json['assets'] as List)
          .map((e) => GlobalLibraryAsset.fromMap(e))
          .toList(),
      isBuiltIn: json['isBuiltIn'] as bool,
      isEnabled: json['isEnabled'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'version': version,
      'description': description,
      'usage': usage,
      'assets': assets.map((e) => e.toMap()).toList(),
      'isBuiltIn': isBuiltIn,
      'isEnabled': isEnabled,
    };
  }
}

class GlobalLibraryService {
  static final GlobalLibraryService _instance =
      GlobalLibraryService._internal();
  factory GlobalLibraryService() => _instance;
  GlobalLibraryService._internal();

  List<GlobalLibrary> _libraries = [];
  bool _initialized = false;

  static const String _customLibrariesDirName = 'libraries';
  static const String _customLibrariesPrefsKey = 'custom_libraries';
  static const String _disabledLibrariesPrefsKey = 'disabled_libraries';

  Future<void> init() async {
    if (_initialized) return;
    try {
      await _loadBuiltInLibraries();
      await _loadCustomLibraries();
      await _loadDisabledState();
      _initialized = true;
    } catch (e) {
      LoggerService.error('Error initializing GlobalLibraryService: $e');
    }
  }

  List<GlobalLibrary> get libraries => _libraries;
  List<GlobalLibrary> get enabledLibraries =>
      _libraries.where((l) => l.isEnabled).toList();

  Future<void> _loadBuiltInLibraries() async {
    try {
      final yamlString = await rootBundle.loadString('assets/libraries.yaml');
      final yaml = loadYaml(yamlString);
      final libs = yaml['libraries'] as List;

      for (final lib in libs) {
        _libraries.add(GlobalLibrary.fromYaml(lib));
      }
    } catch (e) {
      LoggerService.error('Error loading built-in libraries: $e');
    }
  }

  Future<void> _loadCustomLibraries() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final customLibsJson = prefs.getStringList(_customLibrariesPrefsKey);

      if (customLibsJson != null) {
        for (final jsonStr in customLibsJson) {
          try {
            final lib = GlobalLibrary.fromJson(jsonDecode(jsonStr));
            _libraries.add(lib);
          } catch (e) {
            LoggerService.error('Error parsing custom library: $e');
          }
        }
      }
    } catch (e) {
      LoggerService.error('Error loading custom libraries: $e');
    }
  }

  Future<void> _loadDisabledState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final disabledIds = prefs.getStringList(_disabledLibrariesPrefsKey) ?? [];

      for (final lib in _libraries) {
        if (disabledIds.contains(lib.id)) {
          lib.isEnabled = false;
        }
      }
    } catch (e) {
      LoggerService.error('Error loading disabled state: $e');
    }
  }

  Future<void> toggleLibrary(String id, bool enabled) async {
    final lib = _libraries.firstWhere(
      (l) => l.id == id,
      orElse: () => throw Exception('Library not found'),
    );
    lib.isEnabled = enabled;

    final prefs = await SharedPreferences.getInstance();
    final disabledIds = _libraries
        .where((l) => !l.isEnabled)
        .map((l) => l.id)
        .toList();
    await prefs.setStringList(_disabledLibrariesPrefsKey, disabledIds);
  }

  Future<void> addCustomLibrary(GlobalLibrary library) async {
    _libraries.add(library);
    await _saveCustomLibraries();
  }

  Future<void> removeCustomLibrary(String id) async {
    _libraries.removeWhere((l) => l.id == id);
    await _saveCustomLibraries();

    // Also remove from disabled list if present
    final prefs = await SharedPreferences.getInstance();
    final disabledIds = prefs.getStringList(_disabledLibrariesPrefsKey) ?? [];
    if (disabledIds.contains(id)) {
      disabledIds.remove(id);
      await prefs.setStringList(_disabledLibrariesPrefsKey, disabledIds);
    }
  }

  Future<void> _saveCustomLibraries() async {
    final customLibs = _libraries.where((l) => !l.isBuiltIn).toList();
    final jsonList = customLibs.map((l) => jsonEncode(l.toJson())).toList();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_customLibrariesPrefsKey, jsonList);
  }

  Future<String> getCustomLibraryDirectory() async {
    final appDir = await getApplicationDocumentsDirectory();
    final libDir = Directory('${appDir.path}/$_customLibrariesDirName');
    if (!await libDir.exists()) {
      await libDir.create(recursive: true);
    }
    return libDir.path;
  }

  // Helper to resolve synapse:// URL to local file path
  Future<String?> resolveLibraryPath(String fileName) async {
    // Check built-in assets first (mapped by filename in assets/scripts)
    // Actually, for built-ins, we might just return the asset path if needed,
    // or null if we want the WebView to handle it via rootBundle (which it does for synapse://)
    // But for custom libraries, we need to return the file path.

    // Let's check if this filename belongs to a custom library
    for (final lib in _libraries.where((l) => !l.isBuiltIn)) {
      for (final asset in lib.assets) {
        if (asset.path.endsWith(fileName)) {
          return asset.path; // This should be the full path for custom libs
        }
      }
    }
    return null;
  }
}

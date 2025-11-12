import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persisted storage and access layer for user-provided prompt injections.
class PromptConfigurationService extends ChangeNotifier {
  PromptConfigurationService._internal();

  static final PromptConfigurationService instance =
      PromptConfigurationService._internal();

  static const _storagePrefix = 'prompt_injection:';

  final Map<String, String> _values = {};
  bool _initialized = false;
  Completer<void>? _initializationCompleter;

  Map<String, String> get values => Map.unmodifiable(_values);

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    if (_initializationCompleter != null) {
      return _initializationCompleter!.future;
    }

    _initializationCompleter = Completer<void>();
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys()) {
        if (!key.startsWith(_storagePrefix)) continue;
        final value = prefs.getString(key);
        if (value == null || value.trim().isEmpty) continue;
        final entryId = key.substring(_storagePrefix.length);
        _values[entryId] = value;
      }
      _initialized = true;
      _initializationCompleter!.complete();
    } catch (error, stackTrace) {
      _initializationCompleter!.completeError(error, stackTrace);
      rethrow;
    } finally {
      _initializationCompleter = null;
    }
  }

  String? getValue(String entryId) {
    return _values[entryId];
  }

  Future<void> setValue(String entryId, String value) async {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      await clearValue(entryId);
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_storagePrefix$entryId', trimmed);
    _values[entryId] = trimmed;
    notifyListeners();
  }

  Future<void> clearValue(String entryId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_storagePrefix$entryId');
    final removed = _values.remove(entryId);
    if (removed != null) {
      notifyListeners();
    }
  }
}


import 'package:shared_preferences/shared_preferences.dart';

class ModelPreferenceService {
  static const _preferenceListKey = 'model_preference_list';

  // Private constructor
  ModelPreferenceService._();

  static final instance = ModelPreferenceService._();

  /// Get ordered list of model IDs (preference order)
  /// Empty list means use default model only
  Future<List<String>> getPreferenceList() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_preferenceListKey) ?? [];
  }

  /// Set the preference list (ordered by priority)
  Future<void> setPreferenceList(List<String> modelIds) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_preferenceListKey, modelIds);
  }
}

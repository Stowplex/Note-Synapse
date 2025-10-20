import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/note.dart';
import '../models/relationship.dart';
import '../models/tag.dart';
import '../models/filter.dart';
import '../models/user_app.dart';
import '../models/app_revision.dart';
import '../models/model_config.dart';
import '../services/database_service.dart';
import '../services/ai_service.dart';
import '../services/user_app_service.dart';
import '../services/logger_service.dart';
import '../services/model_storage_service.dart';

class AppProvider extends ChangeNotifier {
  final DatabaseService _databaseService = DatabaseService();

  List<Note> _notes = [];
  List<Tag> _tags = [];
  List<Filter> _filters = [];
  List<UserApp> _userApps = [];
  Map<String, List<AppRevision>> _appRevisions = {}; // Cache revisions by appId
  bool _isLoading = false;
  String? _error;
  bool _isDarkMode = false;
  Locale _locale = const Locale('en', '');
  ModelConfig? _modelConfig;

  List<Note> get notes => _notes;
  List<Tag> get tags => _tags;
  List<Filter> get filters => _filters;
  List<UserApp> get userApps => _userApps;
  Map<String, List<AppRevision>> get appRevisions => _appRevisions;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get isDarkMode => _isDarkMode;
  Locale get locale => _locale;
  ModelConfig? get modelConfig => _modelConfig;

  Future<void> loadData() async {
    _setLoading(true);
    try {
      LoggerService.info('Starting loadData');
      _notes = await _databaseService.getAllNotes();
      LoggerService.debug('Successfully loaded ${_notes.length} notes');

      _tags = await _databaseService.getAllTags();
      LoggerService.debug('Successfully loaded ${_tags.length} tags');

      _filters = await _databaseService.getAllFilters();
      LoggerService.debug('Successfully loaded ${_filters.length} filters');

      _userApps = await UserAppService.getAllUserApps();
      LoggerService.debug('Successfully loaded ${_userApps.length} user apps');

      final selectedModel = await ModelStorageService.getSelectedModel();
      if (selectedModel != null) {
        _modelConfig = await ModelStorageService.getModelConfig(selectedModel);
      }

      _error = null;
      LoggerService.info('loadData completed successfully');
      notifyListeners(); // Notify listeners that data has been updated
    } catch (e) {
      _error = 'Error loading data: ${e.toString()}';
      LoggerService.error('Error in loadData: $e', error: e);
    } finally {
      _setLoading(false);
    }
  }

  void updateModelConfig(ModelConfig newConfig) {
    _modelConfig = newConfig;
    notifyListeners();
  }

  Future<void> addNote(Note note) async {
    try {
      await _databaseService.insertNote(note);

      // Reload the note from database to get properly converted attachment paths
      final addedNote = await _databaseService.getNote(note.id);
      if (addedNote != null) {
        _notes.add(addedNote);
        notifyListeners();
      }

      _error = null; // Clear any previous errors
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow; // Rethrow the error so the calling code can handle it
    }
  }

  Future<void> updateNote(Note note) async {
    try {
      await _databaseService.updateNote(note);
      
      // Reload the note from database to get properly converted attachment paths
      final updatedNote = await _databaseService.getNote(note.id);
      if (updatedNote != null) {
        final noteIndex = _notes.indexWhere((n) => n.id == note.id);
        if (noteIndex != -1) {
          _notes[noteIndex] = updatedNote;
          notifyListeners();
        }
      }
      
      _error = null; // Clear any previous errors
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow; // Rethrow the error so the calling code can handle it
    }
  }

  Future<void> updateNoteContent(String noteId, String newContent) async {
    try {
      final noteIndex = _notes.indexWhere((note) => note.id == noteId);
      if (noteIndex == -1) return;
      
      final note = _notes[noteIndex];
      final updatedNote = note.copyWith(
        content: newContent,
        updatedAt: DateTime.now(),
      );
      
      // Update the note in the database
      await _databaseService.updateNote(updatedNote);
      
      // Update the local state immediately
      _notes[noteIndex] = updatedNote;
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  Future<void> updateTaskStatus(String noteId, TaskStatus status) async {
    try {
      final noteIndex = _notes.indexWhere((note) => note.id == noteId);
      if (noteIndex == -1) return;
      
      final note = _notes[noteIndex];
      if (!note.isTask) return;
      
      final updatedNote = note.copyWith(
        status: status,
        updatedAt: DateTime.now(),
      );
      
      // Update the note in the database
      await _databaseService.updateNote(updatedNote);
      
      // Update the local state immediately
      _notes[noteIndex] = updatedNote;
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  Future<void> toggleNotePin(String noteId) async {
    try {
      final noteIndex = _notes.indexWhere((note) => note.id == noteId);
      if (noteIndex == -1) return;
      
      final note = _notes[noteIndex];
      final updatedNote = note.copyWith(
        pinned: !note.pinned,
        updatedAt: DateTime.now(),
      );
      
      // Update the note in the database
      await _databaseService.updateNote(updatedNote);
      
      // Update the local state immediately
      _notes[noteIndex] = updatedNote;
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  Future<void> deleteNote(String noteId) async {
    try {
      await _databaseService.deleteNote(noteId);
      
      // Remove from local state immediately instead of reloading from database
      _notes.removeWhere((note) => note.id == noteId);
      notifyListeners();
      
      _error = null; // Clear any previous errors
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow; // Rethrow the error so the calling code can handle it
    }
  }

  Future<void> addRelationship(Relationship relationship) async {
    try {
      await _databaseService.insertRelationship(relationship);
      await loadData();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  Future<void> deleteRelationship(String relationshipId) async {
    try {
      await _databaseService.deleteRelationship(relationshipId);
      await loadData();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  Future<void> createNoteRelationships(String fromNoteId, List<String> toNoteIds, String relationshipType) async {
    try {
      for (final toNoteId in toNoteIds) {
        // Check if relationship already exists
        final exists = await _databaseService.relationshipExists(fromNoteId, toNoteId, relationshipType);
        if (!exists) {
          final relationship = Relationship(
            id: const Uuid().v4(),
            fromNoteId: fromNoteId,
            toNoteId: toNoteId,
            type: relationshipType,
            createdAt: DateTime.now(),
          );
          await _databaseService.insertRelationship(relationship);
        }
      }
      await loadData();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  Future<List<Relationship>> getNoteRelationships(String noteId) async {
    try {
      return await _databaseService.getRelationships(noteId);
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return [];
    }
  }

  Future<List<Note>> getLinkedNotes(String noteId) async {
    try {
      final relationships = await _databaseService.getRelationships(noteId);
      final linkedNoteIds = relationships.map((r) => r.fromNoteId == noteId ? r.toNoteId : r.fromNoteId).toList();
      return _notes.where((note) => linkedNoteIds.contains(note.id)).toList();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return [];
    }
  }

  Future<String> answerNoteQuestion(
    String question, 
    List<Note> contextNotes, {
    List<PlatformFile>? attachedFiles,
    bool useOwnKnowledge = false,
  }) async {
    try {
      final response = await AIService.answerNoteQuestion(
        question, 
        contextNotes,
        attachedFiles: attachedFiles,
        useOwnKnowledge: useOwnKnowledge,
      );
      
      
      return response;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  Future<String> transformNote(
    Note note, 
    String transformationPrompt, {
    List<PlatformFile>? attachedFiles,
  }) async {
    try {
      final response = await AIService.transformNote(
        note, 
        transformationPrompt,
        attachedFiles: attachedFiles,
      );
      
      
      return response;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  Future<List<Note>> createNewNotes(
    String prompt, 
    List<Note> contextNotes, {
    List<PlatformFile>? attachedFiles,
  }) async {
    try {
      final newNotes = await AIService.createNewNotes(
        prompt, 
        contextNotes,
        attachedFiles: attachedFiles,
      );
      
      // Save all new notes and reload them from database
      final List<Note> addedNotes = [];
      for (final note in newNotes) {
        await _databaseService.insertNote(note);
        final addedNote = await _databaseService.getNote(note.id);
        if (addedNote != null) {
          addedNotes.add(addedNote);
        }
      }
      
      // Add to local state with properly converted paths
      _notes.addAll(addedNotes);
      notifyListeners();
      
      return addedNotes;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  List<Note> getNotesByTag(String tagName) {
    return _notes.where((note) => note.tags.contains(tagName)).toList();
  }

  Future<void> addTagToNote(String noteId, String tagName) async {
    try {
      final noteIndex = _notes.indexWhere((note) => note.id == noteId);
      if (noteIndex == -1) return;
      
      final note = _notes[noteIndex];
      if (note.tags.contains(tagName)) return; // Tag already exists
      
      final updatedTags = List<String>.from(note.tags)..add(tagName);
      final updatedNote = note.copyWith(
        tags: updatedTags,
        updatedAt: DateTime.now(),
      );
      
      await _databaseService.updateNote(updatedNote);
      _notes[noteIndex] = updatedNote;
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  Future<void> removeTagFromNote(String noteId, String tagName) async {
    try {
      final noteIndex = _notes.indexWhere((note) => note.id == noteId);
      if (noteIndex == -1) return;
      
      final note = _notes[noteIndex];
      if (!note.tags.contains(tagName)) return; // Tag doesn't exist
      
      final updatedTags = List<String>.from(note.tags)..remove(tagName);
      final updatedNote = note.copyWith(
        tags: updatedTags,
        updatedAt: DateTime.now(),
      );
      
      await _databaseService.updateNote(updatedNote);
      _notes[noteIndex] = updatedNote;
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  List<String> getAllAvailableTags() {
    final allTags = <String>{};
    for (final note in _notes) {
      allTags.addAll(note.tags);
    }
    return allTags.toList()..sort();
  }

  Future<int> getTagUsageCount(String tagName) async {
    try {
      return await _databaseService.getTagUsageCount(tagName);
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return 0;
    }
  }

  Future<void> deleteTag(String tagName) async {
    try {
      await _databaseService.deleteTag(tagName);
      
      // Remove the tag from all notes in local state
      for (int i = 0; i < _notes.length; i++) {
        if (_notes[i].tags.contains(tagName)) {
          final updatedTags = List<String>.from(_notes[i].tags)..remove(tagName);
          _notes[i] = _notes[i].copyWith(
            tags: updatedTags,
            updatedAt: DateTime.now(),
          );
        }
      }
      
      // Reload tags to update the list
      _tags = await _databaseService.getAllTags();
      notifyListeners();
      _error = null;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  Future<void> replaceTag(String oldTagName, String newTagName) async {
    try {
      await _databaseService.replaceTag(oldTagName, newTagName);
      
      // Update the tag in all notes in local state
      for (int i = 0; i < _notes.length; i++) {
        if (_notes[i].tags.contains(oldTagName)) {
          final updatedTags = List<String>.from(_notes[i].tags);
          final oldTagIndex = updatedTags.indexOf(oldTagName);
          if (oldTagIndex != -1) {
            updatedTags[oldTagIndex] = newTagName;
            _notes[i] = _notes[i].copyWith(
              tags: updatedTags,
              updatedAt: DateTime.now(),
            );
          }
        }
      }
      
      // Reload tags to update the list
      _tags = await _databaseService.getAllTags();
      notifyListeners();
      _error = null;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  List<Note> getTasksForDate(DateTime date) {
    final dateStr = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    return _notes.where((note) => 
      note.isTask && 
      !note.isArchived &&
      (note.scheduledAt == dateStr || note.completeBy == dateStr ||
       (note.scheduledAt != null && note.completeBy != null &&
        _isDateInRange(dateStr, note.scheduledAt!, note.completeBy!)))
    ).toList();
  }

  bool _isDateInRange(String dateStr, String startDate, String endDate) {
    final date = DateTime.tryParse(dateStr);
    final start = DateTime.tryParse(startDate);
    final end = DateTime.tryParse(endDate);
    
    if (date == null || start == null || end == null) return false;
    
    return date.isAfter(start.subtract(const Duration(days: 1))) && 
           date.isBefore(end.add(const Duration(days: 1)));
  }

  List<Note> getNotesForDate(DateTime date) {
    return _notes.where((note) => 
      !note.isArchived &&
      note.createdAt.year == date.year &&
      note.createdAt.month == date.month &&
      note.createdAt.day == date.day
    ).toList();
  }

  double calculateTaskCompletionPercentage(Note task) {
    if (!task.isTask || task.subNotes.isEmpty) {
      return task.isCompleted ? 1.0 : 0.0;
    }
    
    final completedSubNotes = task.subNotes.where((sn) => sn.isCompleted).length;
    return completedSubNotes / task.subNotes.length;
  }

  void _setLoading(bool loading) {
    _isLoading = loading;
    notifyListeners();
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }

  void toggleTheme() {
    _isDarkMode = !_isDarkMode;
    _saveThemePreference();
    notifyListeners();
  }

  Future<void> _saveThemePreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('is_dark_mode', _isDarkMode);
    } catch (e) {
      LoggerService.error('Error saving theme preference: $e', error: e);
    }
  }

  Future<void> loadThemePreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _isDarkMode = prefs.getBool('is_dark_mode') ?? false;
      notifyListeners();
    } catch (e) {
      LoggerService.error('Error loading theme preference: $e', error: e);
      _isDarkMode = false; // Default to light mode
    }
  }

  void changeLanguage(Locale locale) {
    _locale = locale;
    _saveLanguagePreference();
    notifyListeners();
  }

  Future<void> _saveLanguagePreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('language_code', _locale.languageCode);
      await prefs.setString('country_code', _locale.countryCode ?? '');
    } catch (e) {
      LoggerService.error('Error saving language preference: $e', error: e);
    }
  }

  Future<void> loadLanguagePreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final languageCode = prefs.getString('language_code') ?? 'en';
      final countryCode = prefs.getString('country_code') ?? '';
      _locale = Locale(languageCode, countryCode);
      notifyListeners();
    } catch (e) {
      LoggerService.error('Error loading language preference: $e', error: e);
      _locale = const Locale('en', ''); // Default to English
    }
  }

  Future<void> clearAllData() async {
    _setLoading(true);
    try {
      // Clear all data from the database
      await _databaseService.clearAllData();
      
      // Reset local state
      _notes = [];
      _tags = [];
      _error = null;
      
      // Reset theme to default (light mode)
      _isDarkMode = false;
      await _saveThemePreference();
      
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    } finally {
      _setLoading(false);
    }
  }

  // SubNote management methods
  Future<void> addSubNoteToNote(String noteId, SubNote subNote) async {
    try {
      final noteIndex = _notes.indexWhere((note) => note.id == noteId);
      if (noteIndex == -1) return;
      
      final note = _notes[noteIndex];
      final updatedSubNotes = List<SubNote>.from(note.subNotes)..add(subNote);
      final updatedNote = note.copyWith(
        subNotes: updatedSubNotes,
        updatedAt: DateTime.now(),
      );
      
      await _databaseService.updateNote(updatedNote);
      _notes[noteIndex] = updatedNote;
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  Future<void> updateSubNoteInNote(String noteId, SubNote updatedSubNote) async {
    try {
      final noteIndex = _notes.indexWhere((note) => note.id == noteId);
      if (noteIndex == -1) return;
      
      final note = _notes[noteIndex];
      final updatedSubNotes = note.subNotes.map((sn) => 
        sn.id == updatedSubNote.id ? updatedSubNote : sn
      ).toList();
      
      final updatedNote = note.copyWith(
        subNotes: updatedSubNotes,
        updatedAt: DateTime.now(),
      );
      
      await _databaseService.updateNote(updatedNote);
      _notes[noteIndex] = updatedNote;
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  Future<void> deleteSubNoteFromNote(String noteId, String subNoteId) async {
    try {
      final noteIndex = _notes.indexWhere((note) => note.id == noteId);
      if (noteIndex == -1) return;
      
      final note = _notes[noteIndex];
      final updatedSubNotes = note.subNotes.where((sn) => sn.id != subNoteId).toList();
      
      final updatedNote = note.copyWith(
        subNotes: updatedSubNotes,
        updatedAt: DateTime.now(),
      );
      
      await _databaseService.updateNote(updatedNote);
      _notes[noteIndex] = updatedNote;
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  Future<void> toggleSubNoteCompletion(String noteId, String subNoteId) async {
    try {
      final noteIndex = _notes.indexWhere((note) => note.id == noteId);
      if (noteIndex == -1) return;
      
      final note = _notes[noteIndex];
      final updatedSubNotes = note.subNotes.map((sn) {
        if (sn.id == subNoteId) {
          return sn.copyWith(isCompleted: !sn.isCompleted);
        }
        return sn;
      }).toList();
      
      final updatedNote = note.copyWith(
        subNotes: updatedSubNotes,
        updatedAt: DateTime.now(),
      );
      
      await _databaseService.updateNote(updatedNote);
      _notes[noteIndex] = updatedNote;
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  // Upsert subnote - either add new or update existing
  Future<void> upsertSubNoteInNote(String noteId, SubNote subNote) async {
    try {
      final noteIndex = _notes.indexWhere((note) => note.id == noteId);
      if (noteIndex == -1) return;
      
      final note = _notes[noteIndex];
      final existingSubNoteIndex = note.subNotes.indexWhere((sn) => sn.id == subNote.id);
      
      List<SubNote> updatedSubNotes;
      if (existingSubNoteIndex >= 0) {
        // Update existing subnote
        updatedSubNotes = List<SubNote>.from(note.subNotes);
        updatedSubNotes[existingSubNoteIndex] = subNote;
      } else {
        // Add new subnote
        updatedSubNotes = List<SubNote>.from(note.subNotes)..add(subNote);
      }
      
      final updatedNote = note.copyWith(
        subNotes: updatedSubNotes,
        updatedAt: DateTime.now(),
      );
      
      await _databaseService.updateNote(updatedNote);
      _notes[noteIndex] = updatedNote;
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  // Reparent subnote from one note to another
  Future<void> reparentSubNote(String fromNoteId, String toNoteId, SubNote subNote) async {
    try {
      // Find source and destination notes
      final fromNoteIndex = _notes.indexWhere((note) => note.id == fromNoteId);
      final toNoteIndex = _notes.indexWhere((note) => note.id == toNoteId);
      
      if (fromNoteIndex == -1 || toNoteIndex == -1) return;
      
      final fromNote = _notes[fromNoteIndex];
      final toNote = _notes[toNoteIndex];
      
      // Remove subnote from source note
      final updatedFromSubNotes = fromNote.subNotes.where((sn) => sn.id != subNote.id).toList();
      final updatedFromNote = fromNote.copyWith(
        subNotes: updatedFromSubNotes,
        updatedAt: DateTime.now(),
      );
      
      // Add subnote to destination note
      final updatedToSubNotes = List<SubNote>.from(toNote.subNotes)..add(subNote);
      final updatedToNote = toNote.copyWith(
        subNotes: updatedToSubNotes,
        updatedAt: DateTime.now(),
      );
      
      // Update both notes in database
      await _databaseService.updateNote(updatedFromNote);
      await _databaseService.updateNote(updatedToNote);
      
      // Update local state
      _notes[fromNoteIndex] = updatedFromNote;
      _notes[toNoteIndex] = updatedToNote;
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  // Filter management methods
  Future<void> addFilter(Filter filter) async {
    try {
      await _databaseService.insertFilter(filter);
      _filters.add(filter);
      notifyListeners();
      _error = null;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  Future<void> updateFilter(Filter filter) async {
    try {
      await _databaseService.updateFilter(filter);
      final filterIndex = _filters.indexWhere((f) => f.id == filter.id);
      if (filterIndex != -1) {
        _filters[filterIndex] = filter;
        notifyListeners();
      }
      _error = null;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  Future<void> deleteFilter(String filterId) async {
    try {
      await _databaseService.deleteFilter(filterId);
      _filters.removeWhere((filter) => filter.id == filterId);
      notifyListeners();
      _error = null;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  List<Note> getFilteredNotes(Filter filter) {
    List<Note> filteredNotes = _notes;
    
    // Filter by archived status
    if (!filter.includeArchived) {
      filteredNotes = filteredNotes.where((note) => !note.isArchived).toList();
    }
    
    // Filter by text content
    if (filter.includeText?.isNotEmpty == true) {
      final query = filter.includeText!.toLowerCase();
      filteredNotes = filteredNotes.where((note) {
        return note.title.toLowerCase().contains(query) ||
               note.content.toLowerCase().contains(query) ||
               note.tags.any((tag) => tag.toLowerCase().contains(query));
      }).toList();
    }
    
    // Filter by tags (AND logic - note must have ALL selected tags)
    if (filter.includeTags.isNotEmpty) {
      filteredNotes = filteredNotes.where((note) {
        return filter.includeTags.every((selectedTag) => note.tags.contains(selectedTag));
      }).toList();
    }
    
    // Sort by pinned status first, then by creation date
    filteredNotes.sort((a, b) {
      if (a.pinned && !b.pinned) return -1;
      if (!a.pinned && b.pinned) return 1;
      return b.createdAt.compareTo(a.createdAt);
    });
    
    return filteredNotes;
  }

  // User App management methods
  Future<void> addUserApp(UserApp app) async {
    try {
      await UserAppService.saveUserApp(app);
      _userApps.add(app);
      notifyListeners();
      _error = null;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  Future<void> updateUserApp(UserApp app) async {
    try {
      await UserAppService.updateUserApp(app);
      final appIndex = _userApps.indexWhere((a) => a.id == app.id);
      if (appIndex != -1) {
        _userApps[appIndex] = app;
        notifyListeners();
      }
      _error = null;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  Future<AppRevision> saveManualCodeEdit({
    required UserApp originalApp,
    required String newCode,
    List<String>? attachmentPaths,
  }) async {
    try {
      final revision = await UserAppService.saveManualCodeEdit(
        originalApp: originalApp,
        newCode: newCode,
        attachmentPaths: attachmentPaths,
      );
      
      // Update the app in our local list
      final appIndex = _userApps.indexWhere((app) => app.id == originalApp.id);
      if (appIndex != -1) {
        final updatedApp = await _databaseService.getUserApp(originalApp.id);
        if (updatedApp != null) {
          _userApps[appIndex] = updatedApp;
        }
      }
      
      // Clear and refresh revisions cache for this app
      clearAppRevisionsCache(originalApp.id);
      await refreshAppRevisions(originalApp.id);
      
      _error = null;
      return revision;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  Future<void> deleteUserApp(String appId) async {
    try {
      await UserAppService.deleteUserApp(appId);
      _userApps.removeWhere((app) => app.id == appId);
      notifyListeners();
      _error = null;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  Future<UserApp> createUserApp({
    required String name,
    required String description,
    required List<String> steps,
    UserAppType type = UserAppType.normal,
    List<String>? attachmentPaths,
    List<UserAppLibraryInfo>? libraries,
  }) async {
    try {
      // Construct user prompt from the provided information
      final userPrompt = 'Create a $name app. Description: $description. Steps: ${steps.join(', ')}';
      
      final app = await UserAppService.createUserApp(
        name: name,
        description: description,
        steps: steps,
        type: type,
        userPrompt: userPrompt,
        attachmentPaths: attachmentPaths,
        libraries: libraries,
      );
      _userApps.add(app);
      notifyListeners();
      _error = null;
      return app;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }


  Future<AppRevision> editUserApp({
    required UserApp originalApp,
    required String editSuggestion,
    List<String>? attachmentPaths,
  }) async {
    try {
      final revision = await UserAppService.editUserApp(
        originalApp: originalApp,
        editSuggestion: editSuggestion,
        attachmentPaths: attachmentPaths,
      );
      
      // Update the app in our local list
      final appIndex = _userApps.indexWhere((app) => app.id == originalApp.id);
      if (appIndex != -1) {
        final updatedApp = await _databaseService.getUserApp(originalApp.id);
        if (updatedApp != null) {
          _userApps[appIndex] = updatedApp;
        }
      }
      
      // Clear and refresh revisions cache for this app
      clearAppRevisionsCache(originalApp.id);
      await refreshAppRevisions(originalApp.id);
      
      // Automatically pin the latest revision after editing
      final latestRevisions = _appRevisions[originalApp.id] ?? [];
      if (latestRevisions.isNotEmpty) {
        // Find the latest revision (highest revision number)
        final latestRevision = latestRevisions.reduce((a, b) => a.revisionNumber > b.revisionNumber ? a : b);
        await setSelectedRevision(originalApp.id, latestRevision.id);
      }
      
      _error = null;
      return revision;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  Future<Map<String, dynamic>?> getAppState(String appId) async {
    try {
      return await UserAppService.getAppState(appId);
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return null;
    }
  }

  Future<void> saveAppState(String appId, Map<String, dynamic> state) async {
    try {
      await UserAppService.saveAppState(appId, state);
      _error = null;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  // App Revisions management
  Future<List<AppRevision>> getAppRevisions(String appId) async {
    try {
      // Check if we have cached revisions for this app
      if (_appRevisions.containsKey(appId)) {
        return _appRevisions[appId]!;
      }
      
      // Load revisions from database
      final revisions = await UserAppService.getAppRevisions(appId);
      
      // Cache the revisions (already sorted by revisionNumber ASC from database)
      _appRevisions[appId] = revisions;
      
      return revisions;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  Future<AppRevision?> getAppRevision(String revisionId) async {
    try {
      return await UserAppService.getAppRevision(revisionId);
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  Future<void> deleteAppRevision(String revisionId) async {
    try {
      // Find which app this revision belonged to before deletion
      String? appId;
      for (final id in _appRevisions.keys) {
        final revisions = _appRevisions[id]!;
        if (revisions.any((r) => r.id == revisionId)) {
          appId = id;
          break;
        }
      }
      
      if (appId == null) {
        throw Exception('Revision not found in any app');
      }
      
      await UserAppService.deleteAppRevision(revisionId);
      
      // Clear and refresh revisions cache for this app
      clearAppRevisionsCache(appId);
      await refreshAppRevisions(appId);
      
      // Also refresh the app data in case the pinned revision changed
      final updatedApp = await _databaseService.getUserApp(appId);
      if (updatedApp != null) {
        final appIndex = _userApps.indexWhere((app) => app.id == appId);
        if (appIndex != -1) {
          _userApps[appIndex] = updatedApp;
        }
      }
      
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  Future<void> setSelectedRevision(String appId, String revisionId) async {
    try {
      await UserAppService.setSelectedRevision(appId, revisionId);
      
      // Update the app in our local list
      final appIndex = _userApps.indexWhere((app) => app.id == appId);
      if (appIndex != -1) {
        final updatedApp = await _databaseService.getUserApp(appId);
        if (updatedApp != null) {
          _userApps[appIndex] = updatedApp;
        }
      }
      
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  // Refresh revisions for a specific app
  Future<void> refreshAppRevisions(String appId) async {
    try {
      final revisions = await UserAppService.getAppRevisions(appId);
      _appRevisions[appId] = revisions;
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  // Clear revisions cache for an app (useful when revisions are modified)
  void clearAppRevisionsCache(String appId) {
    _appRevisions.remove(appId);
    notifyListeners();
  }

  Future<AppRevision> createInitialRevision(String appId) async {
    try {
      final revision = await UserAppService.createInitialRevision(appId);
      
      // Update the app in our local list
      final appIndex = _userApps.indexWhere((app) => app.id == appId);
      if (appIndex != -1) {
        final updatedApp = await _databaseService.getUserApp(appId);
        if (updatedApp != null) {
          _userApps[appIndex] = updatedApp;
        }
      }
      
      notifyListeners();
      return revision;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    }
  }

  bool isWebViewSupported() {
    return UserAppService.isWebViewSupported();
  }
}
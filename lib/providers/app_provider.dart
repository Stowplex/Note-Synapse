import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/note.dart';
import '../models/relationship.dart';
import '../models/ai_interaction.dart';
import '../models/tag.dart';
import '../services/database_service.dart';
import '../services/gemini_api_service.dart';

class AppProvider extends ChangeNotifier {
  final DatabaseService _databaseService = DatabaseService();
  
  List<Note> _notes = [];
  List<Tag> _tags = [];
  List<AIInteraction> _aiInteractions = [];
  bool _isLoading = false;
  String? _error;
  bool _isDarkMode = false;

  List<Note> get notes => _notes;
  List<Tag> get tags => _tags;
  List<AIInteraction> get aiInteractions => _aiInteractions;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get isDarkMode => _isDarkMode;

  Future<void> loadData() async {
    _setLoading(true);
    try {
      _notes = await _databaseService.getAllNotes();
      _tags = await _databaseService.getAllTags();
      _aiInteractions = await _databaseService.getAllAIInteractions();
      
      // Clean up expired AI interactions
      await _databaseService.cleanupExpiredAIInteractions();
      
      _error = null;
      notifyListeners(); // Notify listeners that data has been updated
    } catch (e) {
      _error = 'Error loading data: ${e.toString()}';
      print('Error in loadData: $e'); // Debug logging
    } finally {
      _setLoading(false);
    }
  }

  Future<void> addNote(Note note) async {
    try {
      await _databaseService.insertNote(note);
      await loadData();
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
      await loadData();
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
      await loadData();
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
            id: DateTime.now().millisecondsSinceEpoch.toString() + '_${toNoteId}',
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
      final response = await GeminiApiService.answerNoteQuestion(
        question, 
        contextNotes,
        attachedFiles: attachedFiles,
        useOwnKnowledge: useOwnKnowledge,
      );
      
      // Save AI interaction
      final interaction = AIInteraction(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        type: AIInteractionType.noteQa,
        prompt: question,
        response: response,
        contextNoteIds: contextNotes.map((n) => n.id).toList(),
        createdAt: DateTime.now(),
        expiresAt: DateTime.now().add(const Duration(days: 10)),
      );
      await _databaseService.insertAIInteraction(interaction);
      await loadData();
      
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
      final response = await GeminiApiService.transformNote(
        note, 
        transformationPrompt,
        attachedFiles: attachedFiles,
      );
      
      // Save AI interaction
      final interaction = AIInteraction(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        type: AIInteractionType.noteTransformation,
        prompt: transformationPrompt,
        response: response,
        contextNoteIds: [note.id],
        createdAt: DateTime.now(),
        expiresAt: DateTime.now().add(const Duration(days: 10)),
      );
      await _databaseService.insertAIInteraction(interaction);
      await loadData();
      
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
      final newNotes = await GeminiApiService.createNewNotes(
        prompt, 
        contextNotes,
        attachedFiles: attachedFiles,
      );
      
      // Save all new notes
      for (final note in newNotes) {
        await _databaseService.insertNote(note);
      }
      
      // Save AI interaction
      final interaction = AIInteraction(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        type: AIInteractionType.newNoteCreation,
        prompt: prompt,
        response: 'Created ${newNotes.length} new notes',
        contextNoteIds: contextNotes.map((n) => n.id).toList(),
        createdNoteIds: newNotes.map((n) => n.id).toList(),
        createdAt: DateTime.now(),
        expiresAt: DateTime.now().add(const Duration(days: 10)),
      );
      await _databaseService.insertAIInteraction(interaction);
      await loadData();
      
      return newNotes;
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
      print('Error saving theme preference: $e');
    }
  }

  Future<void> loadThemePreference() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _isDarkMode = prefs.getBool('is_dark_mode') ?? false;
      notifyListeners();
    } catch (e) {
      print('Error loading theme preference: $e');
      _isDarkMode = false; // Default to light mode
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
      _aiInteractions = [];
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
}

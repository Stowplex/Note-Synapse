import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
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

  List<Note> get notes => _notes;
  List<Tag> get tags => _tags;
  List<AIInteraction> get aiInteractions => _aiInteractions;
  bool get isLoading => _isLoading;
  String? get error => _error;

  Future<void> loadData() async {
    _setLoading(true);
    try {
      _notes = await _databaseService.getAllNotes();
      _tags = await _databaseService.getAllTags();
      _aiInteractions = await _databaseService.getAllAIInteractions();
      
      // Clean up expired AI interactions
      await _databaseService.cleanupExpiredAIInteractions();
      
      _error = null;
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
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  Future<void> updateNote(Note note) async {
    try {
      await _databaseService.updateNote(note);
      await loadData();
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

  Future<void> deleteNote(String noteId) async {
    try {
      await _databaseService.deleteNote(noteId);
      await loadData();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
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
  }) async {
    try {
      final response = await GeminiApiService.answerNoteQuestion(
        question, 
        contextNotes,
        attachedFiles: attachedFiles,
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

  List<Note> getTasksForDate(DateTime date) {
    final dateStr = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    return _notes.where((note) => 
      note.isTask && 
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
      
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      rethrow;
    } finally {
      _setLoading(false);
    }
  }
}

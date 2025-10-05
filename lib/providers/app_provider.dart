import 'package:flutter/material.dart';
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
      _error = e.toString();
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

  Future<String> answerMultiNoteQuestion(String question, List<Note> contextNotes) async {
    try {
      final response = await GeminiApiService.answerMultiNoteQuestion(question, contextNotes);
      
      // Save AI interaction
      final interaction = AIInteraction(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        type: AIInteractionType.multiNoteQa,
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

  Future<String> transformNote(Note note, String transformationPrompt) async {
    try {
      final response = await GeminiApiService.transformNote(note, transformationPrompt);
      
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

  Future<List<Note>> createNewNotes(String prompt, List<Note> contextNotes) async {
    try {
      final newNotes = await GeminiApiService.createNewNotes(prompt, contextNotes);
      
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
      note.dueDate == dateStr
    ).toList();
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
}

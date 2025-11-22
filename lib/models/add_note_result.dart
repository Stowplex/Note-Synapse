import 'note.dart';

class AddNoteResult {
  AddNoteResult._({
    List<Note>? createdNotes,
    this.appendedNote,
    this.successMessage,
    this.errorMessage,
  }) : createdNotes = createdNotes ?? const [];

  factory AddNoteResult.created(List<Note> notes, {String? successMessage}) {
    return AddNoteResult._(
      createdNotes: List.unmodifiable(notes),
      successMessage: successMessage,
    );
  }

  factory AddNoteResult.appended(Note note, {String? successMessage}) {
    return AddNoteResult._(appendedNote: note, successMessage: successMessage);
  }

  factory AddNoteResult.error(String errorMessage) {
    return AddNoteResult._(errorMessage: errorMessage);
  }

  final List<Note> createdNotes;
  final Note? appendedNote;
  final String? successMessage;
  final String? errorMessage;

  bool get hasCreatedNotes => createdNotes.isNotEmpty;

  bool get isAppend => appendedNote != null;

  bool get isError => errorMessage != null;

  Note? get primaryNote =>
      appendedNote ?? (createdNotes.isNotEmpty ? createdNotes.first : null);
}

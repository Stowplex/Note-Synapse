import 'note.dart';

class AddNoteResult {
  AddNoteResult._({List<Note>? createdNotes, this.appendedNote})
      : createdNotes = createdNotes ?? const [];

  factory AddNoteResult.created(List<Note> notes) {
    return AddNoteResult._(createdNotes: List.unmodifiable(notes));
  }

  factory AddNoteResult.appended(Note note) {
    return AddNoteResult._(appendedNote: note);
  }

  final List<Note> createdNotes;
  final Note? appendedNote;

  bool get hasCreatedNotes => createdNotes.isNotEmpty;

  bool get isAppend => appendedNote != null;

  Note? get primaryNote => appendedNote ?? (createdNotes.isNotEmpty ? createdNotes.first : null);
}


/// An error whose message was written BY THE HOST for a plugin to display.
///
/// Only these are echoed verbatim into the `errors` array returned to plugin
/// JS. Arbitrary exceptions are redacted, because they can embed absolute
/// container paths or (from sqflite) a statement plus its bound arguments, i.e.
/// note content.
///
/// Lives in its own file so services below the bridge (for example
/// [NoteModificationService]) can throw it without importing the bridge.
class PluginFacingException implements Exception {
  PluginFacingException(this.message);
  final String message;
  @override
  String toString() => message;
}

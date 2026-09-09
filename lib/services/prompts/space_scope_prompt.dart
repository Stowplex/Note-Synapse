import '../space_scope_service.dart';

/// The native tools whose behaviour [buildSpaceScopePromptSection] describes.
///
/// Chat sessions reach the note tools through a loaded skill rather than a
/// fixed tool set, so the block is only worth its tokens when at least one of
/// these was actually discovered. Kept next to the block that names them: these
/// strings must equal the tools' own `name` values, and a rename that misses
/// this set would silently stop the announcement (pinned by a test that reads
/// the names off the tool objects).
const Set<String> spaceScopedNoteToolNames = {
  'search_notes',
  'read_note',
  'ls',
  'run_sql',
};

/// The Space block a chat session should carry, given the native tool names a
/// skill brought with it — empty when none of them is scoped by a Space, or
/// when no Space is active.
///
/// A function rather than an inline condition in the chat screen so the
/// decision is reachable from a test: the failure it guards against is silent
/// (the block simply stops appearing) and the screen's prompt builder is
/// private.
String buildChatSpaceScopeSection(
  Set<String> discoveredNativeToolNames, [
  SpaceScopeService? scope,
]) {
  if (!discoveredNativeToolNames.any(spaceScopedNoteToolNames.contains)) {
    return '';
  }
  return buildSpaceScopePromptSection(scope).trim();
}

/// The prompt block that tells a model its note tools are scoped to the active
/// Space — and how to step outside it.
///
/// Design decision 5: **the scoping is announced, never silent.** A model whose
/// `search_notes` quietly returned a subset of the notes would report "there is
/// nothing about X" when there is, and the user would have no way to tell the
/// difference between an empty Space and an empty library. So the block states
/// the scope, names the tags it is made of, and names `scope: "all"` as the one
/// escape.
///
/// Returns an empty string when no Space is active — there is nothing to
/// announce, and an "all notes are visible" paragraph would only spend tokens
/// telling the model that the default is the default.
String buildSpaceScopePromptSection([SpaceScopeService? scope]) {
  final active = scope ?? SpaceScopeService.shared();
  if (!active.isActive) return '';

  final name = active.activeSpaceName;
  final label = (name != null && name.trim().isNotEmpty)
      ? '"${name.trim()}"'
      : 'the current Space';
  final tags = active.stampTags.join(', ');

  return '''

## ACTIVE SPACE (your note tools are scoped)

The user is working inside the Space $label, which holds the notes tagged
$tags, plus any note tagged `${SpaceScopeService.allSpacesTag}`.

- `search_notes` searches **only inside this Space** by default. Tags you pass
  in `tags` narrow the search further, within the Space — they do not leave it.
- To search the user's entire library, pass `scope: "all"`. Use it when the
  Space returns nothing and the question is not Space-specific.
- `ls` marks this Space's node with `(active space)`.
- `read_note` is never scoped: any note id opens, in or out of the Space.

Say which one you did when it matters. If a search inside the Space comes back
empty, say that you looked inside $label before concluding the notes do not
exist.
''';
}

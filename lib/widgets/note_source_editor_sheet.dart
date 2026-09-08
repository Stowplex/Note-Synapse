import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../models/note_source.dart';

/// What [NoteSourceEditorSheet.show] resolves to when the sheet was not
/// simply dismissed.
class NoteSourceEditorResult {
  const NoteSourceEditorResult.saved(NoteSource this.source) : removed = false;

  const NoteSourceEditorResult.removed() : source = null, removed = true;

  /// The source to add or store; null when [removed].
  final NoteSource? source;

  /// The user asked to remove the source being edited. The caller confirms
  /// and performs the removal, like a removal from the card's menu.
  final bool removed;
}

/// Asked with the source about to be returned; `true` keeps the sheet open
/// with a "already a source" message on the URL field.
typedef NoteSourceDuplicateCheck = Future<bool> Function(NoteSource candidate);

/// Bottom sheet to add a source by hand or edit one: URL (required, http or
/// https), title and site name, with Save and — when editing — Remove.
///
/// The sheet only builds the [NoteSource]; the caller performs the service
/// call. A new source is `method: manual` with `clippedAt` now. An edited
/// source keeps its id and every field that is not in the form; a cleared
/// title or site name is cleared on the copy too.
class NoteSourceEditorSheet extends StatefulWidget {
  const NoteSourceEditorSheet({super.key, this.existing, this.isDuplicate});

  /// The source being edited; null when adding one.
  final NoteSource? existing;

  /// The caller's duplicate check (see [NoteSourceDuplicateCheck]); nothing
  /// is checked when null.
  final NoteSourceDuplicateCheck? isDuplicate;

  static Future<NoteSourceEditorResult?> show(
    BuildContext context, {
    NoteSource? existing,
    NoteSourceDuplicateCheck? isDuplicate,
  }) {
    return showModalBottomSheet<NoteSourceEditorResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (_) =>
          NoteSourceEditorSheet(existing: existing, isDuplicate: isDuplicate),
    );
  }

  /// [raw] as an http(s) URL: trimmed, `https://` prefixed when no scheme
  /// was typed, and the scheme and host lowercased (the path and query are
  /// case-sensitive and stay as typed); null when it is not one (blank,
  /// whitespace inside, another scheme, no host).
  static String? normalizeUrl(String raw) {
    final text = raw.trim();
    if (text.isEmpty || text.contains(RegExp(r'\s'))) return null;
    final parsed = Uri.tryParse(text);
    if (parsed == null) return null;
    // `example.com:8080/x` parses with the scheme `example.com`: a dot in
    // the scheme means a bare host with a port, which gets the prefix too —
    // unless `://` was typed (`foo.bar://x` is another scheme, not a host,
    // and is rejected like any non-http scheme).
    final typedScheme =
        parsed.hasScheme &&
        (!parsed.scheme.contains('.') || text.contains('://'));
    if (typedScheme) {
      return _isHttp(parsed) ? _lowercaseSchemeAndHost(text) : null;
    }
    final prefixed = 'https://$text';
    final retry = Uri.tryParse(prefixed);
    return retry != null && _isHttp(retry)
        ? _lowercaseSchemeAndHost(prefixed)
        : null;
  }

  static bool _isHttp(Uri uri) =>
      (uri.scheme == 'http' || uri.scheme == 'https') && uri.host.isNotEmpty;

  /// [url] (`scheme://[userinfo@]host[:port]...`, as [_isHttp] guarantees)
  /// with the scheme and host lowercased textually; user info, path, query
  /// and fragment are left as typed.
  static String _lowercaseSchemeAndHost(String url) {
    final authorityStart = url.indexOf('://') + 3;
    var authorityEnd = url.indexOf(RegExp(r'[/?#]'), authorityStart);
    if (authorityEnd == -1) authorityEnd = url.length;
    final authority = url.substring(authorityStart, authorityEnd);
    final hostStart = authorityStart + authority.lastIndexOf('@') + 1;
    return url.substring(0, authorityStart).toLowerCase() +
        url.substring(authorityStart, hostStart) +
        url.substring(hostStart, authorityEnd).toLowerCase() +
        url.substring(authorityEnd);
  }

  @override
  State<NoteSourceEditorSheet> createState() => _NoteSourceEditorSheetState();
}

class _NoteSourceEditorSheetState extends State<NoteSourceEditorSheet> {
  late final TextEditingController _url = TextEditingController(
    text: widget.existing?.url ?? '',
  );
  late final TextEditingController _title = TextEditingController(
    text: widget.existing?.title ?? '',
  );
  late final TextEditingController _siteName = TextEditingController(
    text: widget.existing?.siteName ?? '',
  );
  String? _urlError;
  bool _checking = false;

  bool get _isEditing => widget.existing != null;

  @override
  void dispose() {
    _url.dispose();
    _title.dispose();
    _siteName.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        0,
        16,
        MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _isEditing ? l10n.editSource : l10n.addSource,
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _url,
              autofocus: !_isEditing,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.next,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: l10n.url,
                hintText: 'https://',
                errorText: _urlError,
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) {
                if (_urlError != null) setState(() => _urlError = null);
              },
              onSubmitted: (_) => FocusScope.of(context).nextFocus(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _title,
              textCapitalization: TextCapitalization.sentences,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: l10n.title,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _siteName,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                labelText: l10n.sourceSiteName,
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                if (_isEditing)
                  TextButton.icon(
                    onPressed: _checking
                        ? null
                        : () => Navigator.of(
                            context,
                          ).pop(const NoteSourceEditorResult.removed()),
                    style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.error,
                    ),
                    icon: const Icon(Icons.delete_outline),
                    label: Text(l10n.remove),
                  ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(l10n.cancel),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _checking ? null : _save,
                  child: Text(l10n.save),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    // The Site-name field's onSubmitted and the Save button can both call
    // this while a duplicate check is in flight.
    if (_checking) return;
    final l10n = AppLocalizations.of(context)!;
    final url = NoteSourceEditorSheet.normalizeUrl(_url.text);
    if (url == null) {
      setState(() => _urlError = l10n.invalidUrl);
      return;
    }
    final existing = widget.existing;
    // Blank title / site name: the NoteSource constructor stores '' as null,
    // and '' is what makes copyWith clear the previous value.
    final candidate = existing == null
        ? NoteSource(
            url: url,
            title: _title.text,
            siteName: _siteName.text,
            method: NoteSourceMethod.manual,
            clippedAt: DateTime.now(),
          )
        : existing.copyWith(
            url: url,
            title: _title.text,
            siteName: _siteName.text,
          );
    final isDuplicate = widget.isDuplicate;
    if (isDuplicate != null) {
      setState(() => _checking = true);
      final duplicate = await isDuplicate(candidate);
      if (!mounted) return;
      setState(() {
        _checking = false;
        if (duplicate) _urlError = l10n.duplicateSourceUrl;
      });
      if (duplicate) return;
    }
    if (!mounted) return;
    Navigator.of(context).pop(NoteSourceEditorResult.saved(candidate));
  }
}

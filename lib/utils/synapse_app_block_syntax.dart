import 'dart:convert';

import 'package:markdown/markdown.dart' as md;
import 'package:yaml/yaml.dart';

import 'synapse_resource_uri.dart';

/// Parsed body of a ```` ```synapse-app ```` fenced block.
///
/// Used to render sandboxed user apps inline in markdown when the embed needs
/// parameters too large to fit comfortably in a URI query string.
class SynapseAppBlockBody {
  const SynapseAppBlockBody({
    required this.appUuid,
    this.revisionNumber,
    this.width,
    this.height,
    this.noteSelectors = const [],
    this.params = const {},
    this.error,
  });

  /// App UUID (the `app:` key in the YAML/JSON body).
  final String appUuid;

  /// Optional revision number (the `revision:` key).
  final int? revisionNumber;

  /// Optional explicit render width (the `width:` key).
  final double? width;

  /// Optional explicit render height (the `height:` key).
  final double? height;

  /// Note selectors (e.g. `current`, or a list of note ids) from the
  /// `notes:` key.
  final List<String> noteSelectors;

  /// Arbitrary parameters forwarded to `window.Synapse.Params`.
  final Map<String, dynamic> params;

  /// Non-null if the body could not be parsed.
  final String? error;

  bool get isValid => error == null && appUuid.isNotEmpty;

  /// Attempts to parse the body of a ```` ```synapse-app ```` fenced block.
  ///
  /// Accepts YAML (which, as a superset of JSON, also parses JSON input). On
  /// failure returns an instance with a non-null [error] field instead of
  /// throwing, so the caller can render an inline error placeholder.
  static SynapseAppBlockBody parse(String body) {
    final trimmed = body.trim();
    if (trimmed.isEmpty) {
      return const SynapseAppBlockBody(
        appUuid: '',
        error: 'Empty synapse-app block body',
      );
    }

    dynamic decoded;
    try {
      decoded = loadYaml(trimmed);
    } catch (_) {
      try {
        decoded = jsonDecode(trimmed);
      } catch (e) {
        return SynapseAppBlockBody(
          appUuid: '',
          error: 'Unable to parse synapse-app body: $e',
        );
      }
    }

    if (decoded is! Map) {
      return const SynapseAppBlockBody(
        appUuid: '',
        error: 'synapse-app body must be a YAML/JSON object',
      );
    }

    final appUuid = (decoded['app'] ?? decoded['uuid'] ?? '').toString().trim();
    if (appUuid.isEmpty) {
      return const SynapseAppBlockBody(
        appUuid: '',
        error: 'synapse-app block missing required `app` key',
      );
    }

    final revisionRaw = decoded['revision'];
    final int? revision = revisionRaw is int
        ? revisionRaw
        : (revisionRaw is String ? int.tryParse(revisionRaw) : null);

    double? parseNum(dynamic v) =>
        v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);
    final width = parseNum(decoded['width']);
    final height = parseNum(decoded['height']);

    final notesRaw = decoded['notes'];
    final noteSelectors = <String>[];
    if (notesRaw is List) {
      for (final entry in notesRaw) {
        final s = entry?.toString().trim() ?? '';
        if (s.isNotEmpty) noteSelectors.add(s);
      }
    } else if (notesRaw is String && notesRaw.trim().isNotEmpty) {
      noteSelectors.addAll(
        notesRaw.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty),
      );
    }

    final paramsRaw = decoded['params'];
    final params = paramsRaw is Map ? _deepUnwrapMap(paramsRaw) : <String, dynamic>{};

    return SynapseAppBlockBody(
      appUuid: appUuid,
      revisionNumber: revision,
      width: width,
      height: height,
      noteSelectors: noteSelectors,
      params: params,
    );
  }

  static Map<String, dynamic> _deepUnwrapMap(Map input) {
    final out = <String, dynamic>{};
    input.forEach((k, v) {
      out[k.toString()] = _deepUnwrap(v);
    });
    return out;
  }

  static dynamic _deepUnwrap(dynamic value) {
    if (value is Map) return _deepUnwrapMap(value);
    if (value is List) return value.map(_deepUnwrap).toList();
    return value;
  }
}

/// `package:markdown` block syntax that recognises a ```` ```synapse-app ````
/// fenced block so [MarkdownBlockTracker] can map it to a discrete block for
/// the drag-to-edit UX. Rendering is handled separately in
/// `InteractiveCheckboxMarkdown` via a preprocessing pass.
class SynapseAppBlockSyntax extends md.BlockSyntax {
  const SynapseAppBlockSyntax();

  @override
  RegExp get pattern => RegExp(r'^```\s*synapse-app\s*$');

  @override
  md.Node parse(md.BlockParser parser) {
    final bodyLines = <String>[];
    parser.advance();
    while (!parser.isDone) {
      final line = parser.current.content;
      if (RegExp(r'^```\s*$').hasMatch(line)) {
        parser.advance();
        break;
      }
      bodyLines.add(line);
      parser.advance();
    }
    return md.Element('synapse-app-embed', [md.Text(bodyLines.join('\n'))]);
  }
}

/// Matches the entire ```` ```synapse-app ``` ```` fenced block in raw
/// markdown, from the opening fence through the closing fence.
final RegExp synapseAppBlockRegExp = RegExp(
  r'```\s*synapse-app\s*\n([\s\S]*?)\n?```',
  multiLine: true,
);

/// Convenience helper that extracts every ```` ```synapse-app ```` block from
/// [content], returning the parsed body and the source range it occupies.
///
/// Used by the markdown widget to preprocess the source before rendering.
Iterable<SynapseAppBlockMatch> findSynapseAppBlocks(String content) sync* {
  for (final match in synapseAppBlockRegExp.allMatches(content)) {
    final body = match.group(1) ?? '';
    yield SynapseAppBlockMatch(
      body: SynapseAppBlockBody.parse(body),
      startOffset: match.start,
      endOffset: match.end,
    );
  }
}

class SynapseAppBlockMatch {
  const SynapseAppBlockMatch({
    required this.body,
    required this.startOffset,
    required this.endOffset,
  });
  final SynapseAppBlockBody body;
  final int startOffset;
  final int endOffset;
}

/// Query key reserved on `synapseresource://app/...` URIs for referencing a
/// preprocessed fenced-block payload by its registration id. Used by the
/// widget to avoid URI length limits when a block's params are large.
const String synapseAppBlockRefKey = '__blockRef';

/// Reserved query keys on `synapseresource://app/...` URIs that configure how
/// the embedded view resolves notes + picks a revision. These are stripped
/// from [params] before being forwarded to `Synapse.Params`.
const Set<String> synapseAppReservedQueryKeys = {
  'note',
  'notes',
  'revision',
  synapseAppBlockRefKey,
};

/// Returns true if [uri] is a `synapseresource://app/...` URI.
bool isSynapseAppUri(String uri) {
  if (!SynapseResourceUri.isSynapseResourceUri(uri)) return false;
  final link = SynapseResourceUri.parse(uri);
  return link?.type == SynapseResourceType.app;
}

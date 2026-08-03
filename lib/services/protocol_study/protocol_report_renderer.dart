import 'dart:convert';

import '../../models/protocol_exchange.dart';
import '../../models/protocol_knowledge.dart';
import '../../models/protocol_study.dart';
import '../note_modification_service.dart';
import 'protocol_sensitivity_classifier.dart';

class ProtocolExportView {
  ProtocolExportView._(this.title, this.markdown);

  final String title;
  final String markdown;

  factory ProtocolExportView.build({
    required ProtocolStudy study,
    required ProtocolKnowledge knowledge,
  }) {
    final renderer = _SafeProtocolReportRenderer(study);
    return ProtocolExportView._(
      renderer.clean(knowledge.title),
      renderer.render(knowledge),
    );
  }
}

/// Converts a constrained export view into a normal Note. Raw study objects or
/// free-form model output are never accepted by this boundary.
class ProtocolNoteExporter {
  const ProtocolNoteExporter(this._notes);

  final NoteModificationService _notes;

  Future<String> export(ProtocolExportView view) async {
    final note = await _notes.createNote({
      'title': view.title,
      'content': view.markdown,
      'type': 'note',
      'tags': ['protocol-study'],
    });
    return note.id;
  }
}

class _SafeProtocolReportRenderer {
  _SafeProtocolReportRenderer(this.study) {
    const classifier = ProtocolSensitivityClassifier();
    for (final exchange in study.exchanges) {
      for (final field in classifier.fieldsFor(exchange)) {
        if (field.isParameter ||
            field.sensitivity != ProtocolSensitivity.none ||
            const {
              ProtocolFieldLocation.query,
              ProtocolFieldLocation.requestBody,
              ProtocolFieldLocation.responseUrlQuery,
              ProtocolFieldLocation.responseBody,
            }.contains(field.location)) {
          _addRawValue(field.value);
        }
        if (field.sensitivity != ProtocolSensitivity.none) {
          _addSensitiveFragments(field.value);
        }
      }
    }
    _rawValues.addAll(
      _rawValues
          .toList(growable: false)
          .map(Uri.encodeComponent)
          .where((value) => value.length >= _minimumRawValueLength),
    );
    final valuesForEncoding = _rawValues.toList(growable: false);
    for (final value in valuesForEncoding) {
      final bytes = utf8.encode(value);
      _rawValues
        ..add(base64.encode(bytes))
        ..add(base64Url.encode(bytes).replaceAll('=', ''))
        ..add(
          bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join(),
        );
    }
    _orderedRawValues = _rawValues.toList(growable: false)
      ..sort((a, b) => b.length.compareTo(a.length));
  }

  static const _minimumRawValueLength = 4;
  final ProtocolStudy study;
  final Set<String> _rawValues = {};
  late final List<String> _orderedRawValues;

  void _addRawValue(String value) {
    final trimmed = value.trim();
    if (trimmed.length >= _minimumRawValueLength) {
      _rawValues.add(trimmed);
    }
  }

  void _addSensitiveFragments(String value) {
    final credential = RegExp(
      r'^\s*(?:Bearer|Basic|Token)\s+(.+)$',
      caseSensitive: false,
    ).firstMatch(value);
    if (credential != null) {
      _addRawValue(credential.group(1)!);
    }

    // A model may mention just a cookie/credential value instead of echoing
    // the complete captured header. Preserve no useful secret fragments at
    // the constrained Note export boundary.
    for (final component in value.split(RegExp(r'[\s;,]+'))) {
      final separator = component.indexOf('=');
      _addRawValue(
        separator < 0 ? component : component.substring(separator + 1),
      );
    }
  }

  String clean(String input) {
    var output = input;
    for (final value in _orderedRawValues) {
      output = output.replaceAll(value, '<redacted>');
    }
    output = output.replaceAll(
      RegExp(r'Bearer\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false),
      'Bearer <redacted>',
    );
    output = output.replaceAll(RegExp(r'\b\d{12,19}\b'), '<redacted>');
    // All model-provided strings are rendered inline by this constrained
    // template. Collapse line breaks and neutralize Markdown/HTML delimiters so
    // the exported Note cannot smuggle raw HTML, links, images, or new blocks.
    return output
        .replaceAll(RegExp(r'[\r\n\t]+'), ' ')
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('`', '′')
        .replaceAll('[', '［')
        .replaceAll(']', '］')
        .trim();
  }

  String render(ProtocolKnowledge knowledge) {
    final buffer = StringBuffer()
      ..writeln('# ${clean(knowledge.title)}')
      ..writeln()
      ..writeln(clean(knowledge.summary))
      ..writeln()
      ..writeln('## Authentication and provenance')
      ..writeln();
    switch (study.sessionProvenance) {
      case ProtocolSessionProvenance.savedLoginRestored:
        buffer.writeln(
          '- Uses the saved login for `${clean(study.savedLoginDomain ?? 'the studied domain')}`. Cookie values are not included. Re-authentication may be required after export.',
        );
      case ProtocolSessionProvenance.noSavedLogin:
        buffer.writeln('- No saved login was selected for this study.');
      case ProtocolSessionProvenance.unknownSharedState:
        buffer.writeln(
          '- No saved login was selected. The in-app WebView uses shared state, so ambient authentication could not be ruled out.',
        );
    }
    buffer
      ..writeln()
      ..writeln('## Parameters')
      ..writeln();
    if (knowledge.parameters.isEmpty) {
      buffer.writeln('- None identified.');
    } else {
      for (final parameter in knowledge.parameters) {
        buffer.writeln(
          '- `${clean(parameter.name)}` (${clean(parameter.location)}, ${parameter.required ? 'required' : 'optional'}): ${clean(parameter.description)}',
        );
      }
    }
    buffer
      ..writeln()
      ..writeln('## Workflow')
      ..writeln();
    for (var i = 0; i < knowledge.steps.length; i++) {
      final step = knowledge.steps[i];
      final mutation = step.mutatesState ? ' — **mutates state**' : '';
      buffer
        ..writeln(
          '${i + 1}. `${step.method}` `${clean(step.urlTemplate)}`$mutation',
        )
        ..writeln('   ${clean(step.purpose)}')
        ..writeln('   Evidence: `${clean(step.exchangeId)}`');
    }
    buffer
      ..writeln()
      ..writeln('## Limitations')
      ..writeln()
      ..writeln(
        '- Captured from Note Synapse’s in-app WebView. Service-worker and WebSocket traffic is not represented.',
      )
      ..writeln(
        '- Request/response bodies may be truncated at user-configured limits.',
      );
    for (final caveat in knowledge.caveats) {
      buffer.writeln('- ${clean(caveat)}');
    }
    buffer
      ..writeln()
      ..writeln('## Next steps')
      ..writeln()
      ..writeln(
        'Attach this note to App Creator to generate a reusable AI tool, AI skill, or full User App. Review mutation warnings and test the minimal repro first.',
      );
    return buffer.toString();
  }
}

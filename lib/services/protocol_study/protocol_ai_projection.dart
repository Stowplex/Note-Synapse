import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../models/model_config.dart';
import '../../models/model_type.dart';
import '../../models/protocol_exchange.dart';
import 'protocol_sensitivity_classifier.dart';

class ProtocolAIDestination {
  const ProtocolAIDestination({
    required this.modelId,
    required this.displayName,
    required this.endpoint,
    required this.isLocal,
  });

  final String modelId;
  final String displayName;
  final String endpoint;
  final bool isLocal;

  String get exactKey => '$modelId|$endpoint|${isLocal ? 'local' : 'remote'}';

  factory ProtocolAIDestination.forModel(ModelConfig model) {
    final displayName =
        model.displayName ?? model.modelName ?? model.type.displayName;
    return switch (model.type) {
      ModelType.localMnn => ProtocolAIDestination(
        modelId: model.id,
        displayName: displayName,
        endpoint: 'on-device',
        isLocal: true,
      ),
      ModelType.gemini => ProtocolAIDestination(
        modelId: model.id,
        displayName: displayName,
        endpoint:
            '${model.endpoint ?? 'https://generativelanguage.googleapis.com/v1beta'}/models/${model.modelName ?? 'gemini-2.5-flash'}:generateContent',
        isLocal: false,
      ),
      ModelType.openaiCompatible => ProtocolAIDestination(
        modelId: model.id,
        displayName: displayName,
        endpoint: model.endpoint ?? '<missing endpoint>',
        isLocal: false,
      ),
    };
  }
}

/// In-memory grants for one analysis session. Grants never survive closing the
/// study screen and are bound to one exact model/endpoint destination.
class ProtocolDisclosureSession {
  ProtocolDisclosureSession(this.destination, {String? nonce})
    : nonce = nonce ?? const Uuid().v4();

  final String nonce;
  final ProtocolAIDestination destination;
  final Set<String> _fieldIds = {};
  final Set<String> _excludedFieldIds = {};

  Set<String> get disclosedFieldIds => Set.unmodifiable(_fieldIds);
  Set<String> get excludedFieldIds => Set.unmodifiable(_excludedFieldIds);
  bool isIncluded(String fieldId) => !_excludedFieldIds.contains(fieldId);
  bool isDisclosed(String fieldId) =>
      destination.isLocal || _fieldIds.contains(fieldId);
  void setIncluded(String fieldId, bool included) {
    if (included) {
      _excludedFieldIds.remove(fieldId);
    } else {
      _excludedFieldIds.add(fieldId);
      _fieldIds.remove(fieldId);
    }
  }

  void setDisclosed(String fieldId, bool disclosed) {
    if (destination.isLocal || !isIncluded(fieldId)) return;
    if (disclosed) {
      _fieldIds.add(fieldId);
    } else {
      _fieldIds.remove(fieldId);
    }
  }
}

class ProtocolAIPreview {
  const ProtocolAIPreview({
    required this.studyNonce,
    required this.destination,
    required this.payload,
    required this.disclosedFields,
    required this.redactedFieldCount,
    required this.excludedFieldCount,
  });

  final String studyNonce;
  final ProtocolAIDestination destination;
  final Map<String, dynamic> payload;
  final List<ProtocolField> disclosedFields;
  final int redactedFieldCount;
  final int excludedFieldCount;

  String get formattedPayload =>
      const JsonEncoder.withIndent('  ').convert(payload);
}

class ProtocolAIProjectionBuilder {
  const ProtocolAIProjectionBuilder({
    this.classifier = const ProtocolSensitivityClassifier(),
  });

  final ProtocolSensitivityClassifier classifier;

  ProtocolAIPreview build({
    required Iterable<ProtocolExchange> exchanges,
    required ProtocolDisclosureSession disclosure,
  }) {
    final disclosed = <ProtocolField>[];
    var redacted = 0;
    var excluded = 0;
    final projected = <Map<String, dynamic>>[];
    for (final exchange in exchanges.where((item) => item.selected)) {
      final fields = classifier.fieldsFor(exchange);
      final request = <Map<String, dynamic>>[];
      final response = <Map<String, dynamic>>[];
      for (final field in fields) {
        if (!disclosure.isIncluded(field.id)) {
          excluded += 1;
          continue;
        }
        final allowed = disclosure.isDisclosed(field.id);
        if (allowed) {
          disclosed.add(field);
        } else {
          redacted += 1;
        }
        final output = {
          'id': field.id,
          'location': field.location.name,
          'name': field.name,
          'sensitivity': field.sensitivity.name,
          'userMarkedParameter': field.isParameter,
          'value': allowed ? field.value : '<redacted>',
        };
        if (field.location == ProtocolFieldLocation.responseHeader ||
            field.location == ProtocolFieldLocation.responseUrlPath ||
            field.location == ProtocolFieldLocation.responseUrlQuery ||
            field.location == ProtocolFieldLocation.responseBody) {
          response.add(output);
        } else {
          request.add(output);
        }
      }
      projected.add({
        'exchangeId': exchange.id,
        'exampleIndex': exchange.exampleIndex,
        'source': exchange.source.name,
        'method': exchange.method,
        'urlTemplate': _projectUrl(
          exchange.url,
          fields,
          disclosure,
          pathLocation: ProtocolFieldLocation.requestPath,
          queryLocation: ProtocolFieldLocation.query,
        ),
        if (exchange.responseUrl != null)
          'finalResponseUrl': _projectUrl(
            exchange.responseUrl!,
            fields,
            disclosure,
            pathLocation: ProtocolFieldLocation.responseUrlPath,
            queryLocation: ProtocolFieldLocation.responseUrlQuery,
          ),
        'redirected': exchange.redirected,
        'status': exchange.status,
        'mutatesState': exchange.mutatesState,
        'requestFields': request,
        'responseFields': response,
        'requestBodyTruncated': exchange.requestBody?.truncated ?? false,
        'responseBodyTruncated': exchange.responseBody?.truncated ?? false,
      });
    }
    return ProtocolAIPreview(
      studyNonce: disclosure.nonce,
      destination: disclosure.destination,
      payload: {
        'schemaVersion': 1,
        'instruction':
            'Infer a reusable parameterized HTTP workflow. Treat redacted values as unavailable. Never ask for or emit cookie values.',
        'exchanges': projected,
      },
      disclosedFields: List.unmodifiable(disclosed),
      redactedFieldCount: redacted,
      excludedFieldCount: excluded,
    );
  }

  String _projectUrl(
    String url,
    List<ProtocolField> fields,
    ProtocolDisclosureSession disclosure, {
    required ProtocolFieldLocation pathLocation,
    required ProtocolFieldLocation queryLocation,
  }) {
    final uri = Uri.tryParse(url);
    if (uri == null) return '<redacted-invalid-url>';
    final pathFields = {
      for (final field in fields.where((item) => item.location == pathLocation))
        field.name: field,
    };
    final pathSegments = <String>[];
    for (var index = 0; index < uri.pathSegments.length; index++) {
      final field = pathFields['segment[$index]'];
      pathSegments.add(
        field == null
            ? uri.pathSegments[index]
            : !disclosure.isIncluded(field.id)
            ? '<omitted>'
            : disclosure.isDisclosed(field.id)
            ? uri.pathSegments[index]
            : '<redacted>',
      );
    }
    final permitted = <String, List<String>>{};
    for (final field in fields.where(
      (item) => item.location == queryLocation,
    )) {
      if (!disclosure.isIncluded(field.id)) continue;
      permitted
          .putIfAbsent(field.name, () => [])
          .add(disclosure.isDisclosed(field.id) ? field.value : '<redacted>');
    }
    return uri
        .replace(
          userInfo: '',
          pathSegments: pathSegments,
          queryParameters: permitted.isEmpty && uri.query.isEmpty
              ? null
              : permitted,
          fragment: '',
        )
        .toString();
  }
}

class ProtocolOutboundVerifier {
  const ProtocolOutboundVerifier();

  void verify({
    required ProtocolAIPreview preview,
    required ProtocolDisclosureSession disclosure,
    required Iterable<ProtocolExchange> sourceExchanges,
    ProtocolSensitivityClassifier classifier =
        const ProtocolSensitivityClassifier(),
  }) {
    if (preview.studyNonce != disclosure.nonce ||
        preview.destination.exactKey != disclosure.destination.exactKey) {
      throw StateError('The disclosure approval does not match this AI call.');
    }
    if (disclosure.destination.isLocal) return;
    final selected = sourceExchanges
        .where((item) => item.selected)
        .toList(growable: false);
    final sourceFields = <String, ProtocolField>{
      for (final exchange in selected)
        for (final field in classifier.fieldsFor(exchange)) field.id: field,
    };
    final includedIds = sourceFields.keys.where(disclosure.isIncluded).toSet();
    final permittedValues = sourceFields.values
        .where(
          (field) =>
              disclosure.isIncluded(field.id) &&
              disclosure.isDisclosed(field.id),
        )
        .map((field) => field.value)
        .where((value) => value.isNotEmpty)
        .toSet();
    final emittedIds = <String>{};
    final projectedExchanges = preview.payload['exchanges'];
    if (projectedExchanges is! List) {
      throw StateError('The AI payload has no exchange list.');
    }
    for (final rawExchange in projectedExchanges) {
      if (rawExchange is! Map) {
        throw StateError('The AI payload contains an invalid exchange.');
      }
      final exchange = Map<String, dynamic>.from(rawExchange);
      for (final key in const ['requestFields', 'responseFields']) {
        final rawFields = exchange[key];
        if (rawFields is! List) {
          throw StateError('The AI payload has an invalid field list.');
        }
        for (final rawField in rawFields) {
          if (rawField is! Map) {
            throw StateError('The AI payload contains an invalid field.');
          }
          final projected = Map<String, dynamic>.from(rawField);
          final id = projected['id'];
          final value = projected['value'];
          final source = id is String ? sourceFields[id] : null;
          if (source == null || !disclosure.isIncluded(source.id)) {
            throw StateError('The AI payload contains an unapproved field.');
          }
          final expected = disclosure.isDisclosed(source.id)
              ? source.value
              : '<redacted>';
          if (value != expected) {
            throw StateError(
              disclosure.isDisclosed(source.id)
                  ? 'A disclosed field changed before AI dispatch.'
                  : 'An undisclosed field value reached the AI payload.',
            );
          }
          emittedIds.add(source.id);
        }
      }

      final urls = [
        exchange['urlTemplate'],
        exchange['finalResponseUrl'],
      ].whereType<String>();
      for (final field in sourceFields.values) {
        if (field.value.isEmpty || permittedValues.contains(field.value)) {
          continue;
        }
        if ((!disclosure.isIncluded(field.id) ||
                !disclosure.isDisclosed(field.id)) &&
            urls.any((url) => _containsScalar(url, field.value))) {
          throw StateError('An undisclosed field value reached an AI URL.');
        }
      }
    }
    if (emittedIds.length != includedIds.length ||
        !emittedIds.containsAll(includedIds)) {
      throw StateError('The AI payload omitted approved field metadata.');
    }
  }

  bool _containsScalar(String candidate, String value) {
    if (candidate == value) return true;
    final uri = Uri.tryParse(candidate);
    if (uri == null || !const {'http', 'https'}.contains(uri.scheme)) {
      return false;
    }
    return uri.pathSegments.contains(value) ||
        uri.queryParametersAll.values.any((values) => values.contains(value));
  }
}

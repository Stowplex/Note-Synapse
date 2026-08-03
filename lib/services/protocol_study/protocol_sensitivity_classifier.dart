import '../../models/protocol_exchange.dart';

class ProtocolSensitivityClassifier {
  const ProtocolSensitivityClassifier();

  ProtocolSensitivity classify(ProtocolField field) {
    final name = field.name.toLowerCase();
    final value = field.value.trim();
    if (RegExp(
      r'(authorization|cookie|session|csrf|xsrf|api[-_]?key|bearer|oauth|token)',
    ).hasMatch(name)) {
      return ProtocolSensitivity.authentication;
    }
    if (RegExp(
      r'(password|passwd|passcode|client[-_]?secret|private[-_]?key)',
    ).hasMatch(name)) {
      return ProtocolSensitivity.secret;
    }
    if (RegExp(
      r'(card|cvv|cvc|iban|routing|bank|payment|billing)',
    ).hasMatch(name)) {
      return ProtocolSensitivity.payment;
    }
    if (RegExp(
      r'(diagnosis|patient|medical|health|prescription)',
    ).hasMatch(name)) {
      return ProtocolSensitivity.health;
    }
    if (RegExp(
      r'(email|phone|address|birth|first[-_]?name|last[-_]?name|ssn|passport)',
    ).hasMatch(name)) {
      return ProtocolSensitivity.personal;
    }
    if (RegExp(r'^[A-Za-z0-9_-]{24,}$').hasMatch(value) ||
        RegExp(r'^Bearer\s+', caseSensitive: false).hasMatch(value)) {
      return ProtocolSensitivity.identifier;
    }
    return ProtocolSensitivity.none;
  }

  ProtocolField label(ProtocolField field) =>
      field.copyWith(sensitivity: classify(field));

  List<ProtocolField> fieldsFor(ProtocolExchange exchange) {
    final fields = <ProtocolField>[
      ...exchange.requestHeaders,
      ..._urlFields(
        exchange.id,
        exchange.url,
        pathLocation: ProtocolFieldLocation.requestPath,
        queryLocation: ProtocolFieldLocation.query,
        includeQuery: false,
      ),
      ...exchange.queryFields,
      ...?exchange.requestBody?.fields,
      ...exchange.responseHeaders,
      if (exchange.responseUrl case final responseUrl?)
        ..._urlFields(
          exchange.id,
          responseUrl,
          pathLocation: ProtocolFieldLocation.responseUrlPath,
          queryLocation: ProtocolFieldLocation.responseUrlQuery,
          includeQuery: true,
        ),
      ...?exchange.responseBody?.fields,
    ];
    void addRaw(ProtocolBody? body, ProtocolFieldLocation location) {
      if (body?.text == null || body!.fields.isNotEmpty) return;
      fields.add(
        ProtocolField(
          id: '${exchange.id}:${location.name}:raw',
          location: location,
          name: r'$raw',
          value: body.text!,
          sensitivity: ProtocolSensitivity.unknown,
        ),
      );
    }

    addRaw(exchange.requestBody, ProtocolFieldLocation.requestBody);
    addRaw(exchange.responseBody, ProtocolFieldLocation.responseBody);
    return fields
        .map(label)
        .map(
          (field) => exchange.parameterFieldIds.contains(field.id)
              ? field.copyWith(isParameter: true)
              : field,
        )
        .toList(growable: false);
  }

  List<ProtocolField> _urlFields(
    String exchangeId,
    String url, {
    required ProtocolFieldLocation pathLocation,
    required ProtocolFieldLocation queryLocation,
    required bool includeQuery,
  }) {
    final uri = Uri.tryParse(url);
    if (uri == null) return const [];
    final fields = <ProtocolField>[];
    for (var index = 0; index < uri.pathSegments.length; index++) {
      final value = uri.pathSegments[index];
      if (value.isEmpty) continue;
      fields.add(
        ProtocolField(
          id: '$exchangeId:${pathLocation.name}:$index',
          location: pathLocation,
          name: 'segment[$index]',
          value: value,
        ),
      );
    }
    if (includeQuery) {
      var index = 0;
      for (final entry in uri.queryParametersAll.entries) {
        for (final value in entry.value) {
          fields.add(
            ProtocolField(
              id: '$exchangeId:${queryLocation.name}:${entry.key}:${index++}',
              location: queryLocation,
              name: entry.key,
              value: value,
            ),
          );
        }
      }
    }
    return fields;
  }
}

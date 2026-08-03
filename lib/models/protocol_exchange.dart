enum ProtocolRequestSource { fetch, xhr, form, navigation, unknown }

enum ProtocolFieldLocation {
  requestHeader,
  requestPath,
  query,
  requestBody,
  responseHeader,
  responseUrlPath,
  responseUrlQuery,
  responseBody,
}

enum ProtocolSensitivity {
  none,
  identifier,
  authentication,
  personal,
  payment,
  health,
  secret,
  unknown,
}

class ProtocolField {
  const ProtocolField({
    required this.id,
    required this.location,
    required this.name,
    required this.value,
    this.sensitivity = ProtocolSensitivity.unknown,
    this.isParameter = false,
  });

  final String id;
  final ProtocolFieldLocation location;
  final String name;
  final String value;
  final ProtocolSensitivity sensitivity;
  final bool isParameter;

  ProtocolField copyWith({
    ProtocolSensitivity? sensitivity,
    bool? isParameter,
  }) => ProtocolField(
    id: id,
    location: location,
    name: name,
    value: value,
    sensitivity: sensitivity ?? this.sensitivity,
    isParameter: isParameter ?? this.isParameter,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'location': location.name,
    'name': name,
    'value': value,
    'sensitivity': sensitivity.name,
    'isParameter': isParameter,
  };

  factory ProtocolField.fromJson(Map<String, dynamic> json) => ProtocolField(
    id: json['id'] as String,
    location: ProtocolFieldLocation.values.byName(json['location'] as String),
    name: json['name'] as String,
    value: json['value'] as String,
    sensitivity: ProtocolSensitivity.values.byName(
      (json['sensitivity'] as String?) ?? ProtocolSensitivity.unknown.name,
    ),
    isParameter: json['isParameter'] as bool? ?? false,
  );
}

class ProtocolBody {
  const ProtocolBody({
    this.text,
    this.mimeType,
    this.byteLength,
    this.truncated = false,
    this.omittedReason,
    this.fields = const [],
  });

  final String? text;
  final String? mimeType;
  final int? byteLength;
  final bool truncated;
  final String? omittedReason;
  final List<ProtocolField> fields;

  bool get isPresent => text != null;

  ProtocolBody copyWith({List<ProtocolField>? fields}) => ProtocolBody(
    text: text,
    mimeType: mimeType,
    byteLength: byteLength,
    truncated: truncated,
    omittedReason: omittedReason,
    fields: fields ?? this.fields,
  );

  Map<String, dynamic> toJson() => {
    if (text != null) 'text': text,
    if (mimeType != null) 'mimeType': mimeType,
    if (byteLength != null) 'byteLength': byteLength,
    'truncated': truncated,
    if (omittedReason != null) 'omittedReason': omittedReason,
    if (fields.isNotEmpty)
      'fields': fields.map((field) => field.toJson()).toList(),
  };

  factory ProtocolBody.fromJson(Map<String, dynamic> json) => ProtocolBody(
    text: json['text'] as String?,
    mimeType: json['mimeType'] as String?,
    byteLength: (json['byteLength'] as num?)?.toInt(),
    truncated: json['truncated'] as bool? ?? false,
    omittedReason: json['omittedReason'] as String?,
    fields: ((json['fields'] as List?) ?? const [])
        .map(
          (field) =>
              ProtocolField.fromJson(Map<String, dynamic>.from(field as Map)),
        )
        .toList(growable: false),
  );
}

class ProtocolInteraction {
  const ProtocolInteraction({
    required this.kind,
    required this.timestamp,
    this.label,
    this.selectorHint,
  });

  final String kind;
  final DateTime timestamp;
  final String? label;
  final String? selectorHint;

  Map<String, dynamic> toJson() => {
    'kind': kind,
    'timestamp': timestamp.toIso8601String(),
    if (label != null) 'label': label,
    if (selectorHint != null) 'selectorHint': selectorHint,
  };

  factory ProtocolInteraction.fromJson(Map<String, dynamic> json) =>
      ProtocolInteraction(
        kind: json['kind'] as String,
        timestamp: DateTime.parse(json['timestamp'] as String),
        label: json['label'] as String?,
        selectorHint: json['selectorHint'] as String?,
      );
}

class ProtocolExchange {
  const ProtocolExchange({
    required this.id,
    required this.pageInstanceId,
    required this.sequence,
    required this.source,
    required this.method,
    required this.url,
    required this.startedAt,
    required this.requestHeaders,
    required this.queryFields,
    required this.responseHeaders,
    this.requestMetadata = const {},
    this.captureIssues = const [],
    this.parameterFieldIds = const {},
    this.exampleIndex = 1,
    this.requestBody,
    this.responseBody,
    this.status,
    this.responseUrl,
    this.redirected = false,
    this.completedAt,
    this.error,
    this.mutatesState = false,
    this.selected = false,
  });

  final String id;
  final String pageInstanceId;
  final int sequence;
  final ProtocolRequestSource source;
  final String method;
  final String url;
  final DateTime startedAt;
  final DateTime? completedAt;
  final int? status;
  final String? responseUrl;
  final bool redirected;
  final List<ProtocolField> requestHeaders;
  final List<ProtocolField> queryFields;
  final ProtocolBody? requestBody;
  final List<ProtocolField> responseHeaders;

  /// Bounded, non-secret transport semantics observed by the page probe.
  ///
  /// These values explain fidelity (for example fetch credentials/mode or a
  /// synchronous XHR). They are not treated as replay instructions unless a
  /// recipe implementation explicitly supports them.
  final Map<String, String> requestMetadata;

  /// Honest, per-exchange capture limitations such as a consumed stream body.
  final List<String> captureIssues;

  /// User-selected parameter fields that are derived from the URL or an
  /// otherwise unstructured body and therefore have no stored [ProtocolField]
  /// object on which to persist [ProtocolField.isParameter].
  final Set<String> parameterFieldIds;

  /// One-based user-marked example run within the same study session.
  final int exampleIndex;
  final ProtocolBody? responseBody;
  final String? error;
  final bool mutatesState;
  final bool selected;

  Duration? get duration => completedAt?.difference(startedAt);

  ProtocolExchange copyWith({
    DateTime? completedAt,
    int? status,
    String? responseUrl,
    bool? redirected,
    List<ProtocolField>? requestHeaders,
    List<ProtocolField>? queryFields,
    ProtocolBody? requestBody,
    List<ProtocolField>? responseHeaders,
    ProtocolBody? responseBody,
    Map<String, String>? requestMetadata,
    List<String>? captureIssues,
    Set<String>? parameterFieldIds,
    int? exampleIndex,
    String? error,
    bool? selected,
  }) => ProtocolExchange(
    id: id,
    pageInstanceId: pageInstanceId,
    sequence: sequence,
    source: source,
    method: method,
    url: url,
    startedAt: startedAt,
    completedAt: completedAt ?? this.completedAt,
    status: status ?? this.status,
    responseUrl: responseUrl ?? this.responseUrl,
    redirected: redirected ?? this.redirected,
    requestHeaders: requestHeaders ?? this.requestHeaders,
    queryFields: queryFields ?? this.queryFields,
    requestBody: requestBody ?? this.requestBody,
    responseHeaders: responseHeaders ?? this.responseHeaders,
    responseBody: responseBody ?? this.responseBody,
    requestMetadata: requestMetadata ?? this.requestMetadata,
    captureIssues: captureIssues ?? this.captureIssues,
    parameterFieldIds: parameterFieldIds ?? this.parameterFieldIds,
    exampleIndex: exampleIndex ?? this.exampleIndex,
    error: error ?? this.error,
    mutatesState: mutatesState,
    selected: selected ?? this.selected,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'pageInstanceId': pageInstanceId,
    'sequence': sequence,
    'source': source.name,
    'method': method,
    'url': url,
    'startedAt': startedAt.toIso8601String(),
    if (completedAt != null) 'completedAt': completedAt!.toIso8601String(),
    if (status != null) 'status': status,
    if (responseUrl != null) 'responseUrl': responseUrl,
    'redirected': redirected,
    'requestHeaders': requestHeaders.map((f) => f.toJson()).toList(),
    'queryFields': queryFields.map((f) => f.toJson()).toList(),
    if (requestBody != null) 'requestBody': requestBody!.toJson(),
    'responseHeaders': responseHeaders.map((f) => f.toJson()).toList(),
    if (requestMetadata.isNotEmpty) 'requestMetadata': requestMetadata,
    if (captureIssues.isNotEmpty) 'captureIssues': captureIssues,
    if (parameterFieldIds.isNotEmpty)
      'parameterFieldIds': parameterFieldIds.toList(growable: false)..sort(),
    'exampleIndex': exampleIndex,
    if (responseBody != null) 'responseBody': responseBody!.toJson(),
    if (error != null) 'error': error,
    'mutatesState': mutatesState,
    'selected': selected,
  };

  factory ProtocolExchange.fromJson(Map<String, dynamic> json) {
    List<ProtocolField> fields(String key) => ((json[key] as List?) ?? const [])
        .map((e) => ProtocolField.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(growable: false);

    return ProtocolExchange(
      id: json['id'] as String,
      pageInstanceId: json['pageInstanceId'] as String,
      sequence: (json['sequence'] as num).toInt(),
      source: ProtocolRequestSource.values.byName(json['source'] as String),
      method: json['method'] as String,
      url: json['url'] as String,
      startedAt: DateTime.parse(json['startedAt'] as String),
      completedAt: json['completedAt'] == null
          ? null
          : DateTime.parse(json['completedAt'] as String),
      status: (json['status'] as num?)?.toInt(),
      responseUrl: json['responseUrl'] as String?,
      redirected: json['redirected'] as bool? ?? false,
      requestHeaders: fields('requestHeaders'),
      queryFields: fields('queryFields'),
      requestBody: json['requestBody'] == null
          ? null
          : ProtocolBody.fromJson(
              Map<String, dynamic>.from(json['requestBody'] as Map),
            ),
      responseHeaders: fields('responseHeaders'),
      requestMetadata: Map<String, String>.unmodifiable(
        ((json['requestMetadata'] as Map?) ?? const {}).map(
          (key, value) => MapEntry(key.toString(), value.toString()),
        ),
      ),
      captureIssues: ((json['captureIssues'] as List?) ?? const [])
          .map((value) => value.toString())
          .toList(growable: false),
      parameterFieldIds: ((json['parameterFieldIds'] as List?) ?? const [])
          .map((value) => value.toString())
          .toSet(),
      exampleIndex: (json['exampleIndex'] as num?)?.toInt() ?? 1,
      responseBody: json['responseBody'] == null
          ? null
          : ProtocolBody.fromJson(
              Map<String, dynamic>.from(json['responseBody'] as Map),
            ),
      error: json['error'] as String?,
      mutatesState: json['mutatesState'] as bool? ?? false,
      selected: json['selected'] as bool? ?? false,
    );
  }
}

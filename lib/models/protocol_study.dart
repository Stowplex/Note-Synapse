import 'protocol_exchange.dart';
import 'protocol_knowledge.dart';

enum ProtocolSessionProvenance {
  savedLoginRestored,
  noSavedLogin,
  unknownSharedState,
}

enum ProtocolCaptureFidelity { verified, partial, unavailable, untested }

class ProtocolCaptureLimits {
  const ProtocolCaptureLimits({
    this.maxRequestBodyBytes = 256 * 1024,
    this.maxResponseBodyBytes = 1024 * 1024,
    this.maxSessionBytes = 20 * 1024 * 1024,
    this.maxEventBytes = 128 * 1024,
    this.maxEvents = 2000,
    this.maxEventsPerSecond = 100,
    this.maxStringLength = 2 * 1024 * 1024,
    this.captureBinary = false,
  });

  final int maxRequestBodyBytes;
  final int maxResponseBodyBytes;
  final int maxSessionBytes;
  final int maxEventBytes;
  final int maxEvents;
  final int maxEventsPerSecond;
  final int maxStringLength;
  final bool captureBinary;

  Map<String, dynamic> toJson() => {
    'maxRequestBodyBytes': maxRequestBodyBytes,
    'maxResponseBodyBytes': maxResponseBodyBytes,
    'maxSessionBytes': maxSessionBytes,
    'maxEventBytes': maxEventBytes,
    'maxEvents': maxEvents,
    'maxEventsPerSecond': maxEventsPerSecond,
    'maxStringLength': maxStringLength,
    'captureBinary': captureBinary,
  };

  factory ProtocolCaptureLimits.fromJson(Map<String, dynamic> json) =>
      ProtocolCaptureLimits(
        maxRequestBodyBytes:
            (json['maxRequestBodyBytes'] as num?)?.toInt() ?? 256 * 1024,
        maxResponseBodyBytes:
            (json['maxResponseBodyBytes'] as num?)?.toInt() ?? 1024 * 1024,
        maxSessionBytes:
            (json['maxSessionBytes'] as num?)?.toInt() ?? 20 * 1024 * 1024,
        maxEventBytes: (json['maxEventBytes'] as num?)?.toInt() ?? 128 * 1024,
        maxEvents: (json['maxEvents'] as num?)?.toInt() ?? 2000,
        maxEventsPerSecond:
            (json['maxEventsPerSecond'] as num?)?.toInt() ?? 100,
        maxStringLength:
            (json['maxStringLength'] as num?)?.toInt() ?? 2 * 1024 * 1024,
        captureBinary: json['captureBinary'] as bool? ?? false,
      );
}

class ProtocolFidelityReport {
  const ProtocolFidelityReport({
    this.documentStart = ProtocolCaptureFidelity.untested,
    this.fetch = ProtocolCaptureFidelity.untested,
    this.xhr = ProtocolCaptureFidelity.untested,
    this.forms = ProtocolCaptureFidelity.untested,
    this.redirects = ProtocolCaptureFidelity.untested,
    this.binaryBodies = ProtocolCaptureFidelity.untested,
    this.serviceWorkers = ProtocolCaptureFidelity.unavailable,
    this.webSockets = ProtocolCaptureFidelity.unavailable,
  });

  final ProtocolCaptureFidelity documentStart;
  final ProtocolCaptureFidelity fetch;
  final ProtocolCaptureFidelity xhr;
  final ProtocolCaptureFidelity forms;
  final ProtocolCaptureFidelity redirects;
  final ProtocolCaptureFidelity binaryBodies;
  final ProtocolCaptureFidelity serviceWorkers;
  final ProtocolCaptureFidelity webSockets;

  bool get canStudy =>
      documentStart == ProtocolCaptureFidelity.verified &&
      fetch != ProtocolCaptureFidelity.unavailable &&
      xhr != ProtocolCaptureFidelity.unavailable;

  Map<String, dynamic> toJson() => {
    'documentStart': documentStart.name,
    'fetch': fetch.name,
    'xhr': xhr.name,
    'forms': forms.name,
    'redirects': redirects.name,
    'binaryBodies': binaryBodies.name,
    'serviceWorkers': serviceWorkers.name,
    'webSockets': webSockets.name,
  };

  factory ProtocolFidelityReport.fromJson(Map<String, dynamic> json) {
    ProtocolCaptureFidelity read(String key, ProtocolCaptureFidelity fallback) {
      final value = json[key] as String?;
      return value == null
          ? fallback
          : ProtocolCaptureFidelity.values.byName(value);
    }

    return ProtocolFidelityReport(
      documentStart: read('documentStart', ProtocolCaptureFidelity.untested),
      fetch: read('fetch', ProtocolCaptureFidelity.untested),
      xhr: read('xhr', ProtocolCaptureFidelity.untested),
      forms: read('forms', ProtocolCaptureFidelity.untested),
      redirects: read('redirects', ProtocolCaptureFidelity.untested),
      binaryBodies: read('binaryBodies', ProtocolCaptureFidelity.untested),
      serviceWorkers: read(
        'serviceWorkers',
        ProtocolCaptureFidelity.unavailable,
      ),
      webSockets: read('webSockets', ProtocolCaptureFidelity.unavailable),
    );
  }
}

class ProtocolStudy {
  const ProtocolStudy({
    required this.id,
    required this.title,
    required this.startUrl,
    required this.createdAt,
    required this.updatedAt,
    required this.sessionProvenance,
    required this.limits,
    required this.exchanges,
    this.savedLoginDomain,
    this.interactions = const [],
    this.fidelity = const ProtocolFidelityReport(),
    this.noteExportedAt,
    this.knowledge,
  });

  final String id;
  final String title;
  final String startUrl;
  final DateTime createdAt;
  final DateTime updatedAt;
  final ProtocolSessionProvenance sessionProvenance;
  final String? savedLoginDomain;
  final ProtocolCaptureLimits limits;
  final List<ProtocolExchange> exchanges;
  final List<ProtocolInteraction> interactions;
  final ProtocolFidelityReport fidelity;
  final DateTime? noteExportedAt;
  final ProtocolKnowledge? knowledge;

  ProtocolStudy copyWith({
    String? title,
    DateTime? updatedAt,
    List<ProtocolExchange>? exchanges,
    List<ProtocolInteraction>? interactions,
    ProtocolFidelityReport? fidelity,
    DateTime? noteExportedAt,
    ProtocolKnowledge? knowledge,
  }) => ProtocolStudy(
    id: id,
    title: title ?? this.title,
    startUrl: startUrl,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    sessionProvenance: sessionProvenance,
    savedLoginDomain: savedLoginDomain,
    limits: limits,
    exchanges: exchanges ?? this.exchanges,
    interactions: interactions ?? this.interactions,
    fidelity: fidelity ?? this.fidelity,
    noteExportedAt: noteExportedAt ?? this.noteExportedAt,
    knowledge: knowledge ?? this.knowledge,
  );

  Map<String, dynamic> toJson() => {
    'schemaVersion': 1,
    'id': id,
    'title': title,
    'startUrl': startUrl,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'sessionProvenance': sessionProvenance.name,
    if (savedLoginDomain != null) 'savedLoginDomain': savedLoginDomain,
    'limits': limits.toJson(),
    'exchanges': exchanges.map((e) => e.toJson()).toList(),
    'interactions': interactions.map((e) => e.toJson()).toList(),
    'fidelity': fidelity.toJson(),
    if (noteExportedAt != null)
      'noteExportedAt': noteExportedAt!.toIso8601String(),
    if (knowledge != null) 'knowledge': knowledge!.toJson(),
  };

  factory ProtocolStudy.fromJson(Map<String, dynamic> json) => ProtocolStudy(
    id: json['id'] as String,
    title: json['title'] as String,
    startUrl: json['startUrl'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
    updatedAt: DateTime.parse(json['updatedAt'] as String),
    sessionProvenance: ProtocolSessionProvenance.values.byName(
      json['sessionProvenance'] as String,
    ),
    savedLoginDomain: json['savedLoginDomain'] as String?,
    limits: ProtocolCaptureLimits.fromJson(
      Map<String, dynamic>.from(json['limits'] as Map),
    ),
    exchanges: ((json['exchanges'] as List?) ?? const [])
        .map(
          (e) => ProtocolExchange.fromJson(Map<String, dynamic>.from(e as Map)),
        )
        .toList(growable: false),
    interactions: ((json['interactions'] as List?) ?? const [])
        .map(
          (e) =>
              ProtocolInteraction.fromJson(Map<String, dynamic>.from(e as Map)),
        )
        .toList(growable: false),
    fidelity: ProtocolFidelityReport.fromJson(
      Map<String, dynamic>.from(json['fidelity'] as Map? ?? const {}),
    ),
    noteExportedAt: json['noteExportedAt'] == null
        ? null
        : DateTime.parse(json['noteExportedAt'] as String),
    knowledge: json['knowledge'] == null
        ? null
        : ProtocolKnowledge.fromJson(
            Map<String, dynamic>.from(json['knowledge'] as Map),
          ),
  );
}

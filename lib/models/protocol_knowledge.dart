class ProtocolParameterKnowledge {
  const ProtocolParameterKnowledge({
    required this.name,
    required this.location,
    required this.description,
    required this.required,
  });

  final String name;
  final String location;
  final String description;
  final bool required;

  ProtocolParameterKnowledge copyWith({
    String? name,
    String? location,
    String? description,
    bool? required,
  }) => ProtocolParameterKnowledge(
    name: name ?? this.name,
    location: location ?? this.location,
    description: description ?? this.description,
    required: required ?? this.required,
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'location': location,
    'description': description,
    'required': required,
  };

  factory ProtocolParameterKnowledge.fromJson(Map<String, dynamic> json) =>
      ProtocolParameterKnowledge(
        name: json['name'] as String,
        location: json['location'] as String,
        description: json['description'] as String? ?? '',
        required: json['required'] as bool? ?? false,
      );
}

class ProtocolStepKnowledge {
  const ProtocolStepKnowledge({
    required this.exchangeId,
    required this.method,
    required this.urlTemplate,
    required this.purpose,
    required this.mutatesState,
  });

  final String exchangeId;
  final String method;
  final String urlTemplate;
  final String purpose;
  final bool mutatesState;

  ProtocolStepKnowledge copyWith({
    String? method,
    String? urlTemplate,
    String? purpose,
    bool? mutatesState,
  }) => ProtocolStepKnowledge(
    exchangeId: exchangeId,
    method: method ?? this.method,
    urlTemplate: urlTemplate ?? this.urlTemplate,
    purpose: purpose ?? this.purpose,
    mutatesState: mutatesState ?? this.mutatesState,
  );

  Map<String, dynamic> toJson() => {
    'exchangeId': exchangeId,
    'method': method,
    'urlTemplate': urlTemplate,
    'purpose': purpose,
    'mutatesState': mutatesState,
  };

  factory ProtocolStepKnowledge.fromJson(Map<String, dynamic> json) =>
      ProtocolStepKnowledge(
        exchangeId: json['exchangeId'] as String,
        method: (json['method'] as String).toUpperCase(),
        urlTemplate: json['urlTemplate'] as String,
        purpose: json['purpose'] as String? ?? '',
        mutatesState: json['mutatesState'] as bool? ?? false,
      );
}

class ProtocolKnowledge {
  const ProtocolKnowledge({
    required this.title,
    required this.summary,
    required this.parameters,
    required this.steps,
    required this.caveats,
    required this.confidence,
  });

  final String title;
  final String summary;
  final List<ProtocolParameterKnowledge> parameters;
  final List<ProtocolStepKnowledge> steps;
  final List<String> caveats;
  final double confidence;

  ProtocolKnowledge copyWith({
    String? title,
    String? summary,
    List<ProtocolParameterKnowledge>? parameters,
    List<ProtocolStepKnowledge>? steps,
    List<String>? caveats,
    double? confidence,
  }) => ProtocolKnowledge(
    title: title ?? this.title,
    summary: summary ?? this.summary,
    parameters: parameters ?? this.parameters,
    steps: steps ?? this.steps,
    caveats: caveats ?? this.caveats,
    confidence: confidence ?? this.confidence,
  );

  Map<String, dynamic> toJson() => {
    'schemaVersion': 1,
    'title': title,
    'summary': summary,
    'parameters': parameters.map((parameter) => parameter.toJson()).toList(),
    'steps': steps.map((step) => step.toJson()).toList(),
    'caveats': caveats,
    'confidence': confidence,
  };

  factory ProtocolKnowledge.fromJson(Map<String, dynamic> json) =>
      ProtocolKnowledge(
        title: json['title'] as String,
        summary: json['summary'] as String? ?? '',
        parameters: ((json['parameters'] as List?) ?? const [])
            .map(
              (item) => ProtocolParameterKnowledge.fromJson(
                Map<String, dynamic>.from(item as Map),
              ),
            )
            .toList(growable: false),
        steps: ((json['steps'] as List?) ?? const [])
            .map(
              (item) => ProtocolStepKnowledge.fromJson(
                Map<String, dynamic>.from(item as Map),
              ),
            )
            .toList(growable: false),
        caveats: ((json['caveats'] as List?) ?? const [])
            .whereType<String>()
            .toList(growable: false),
        confidence: ((json['confidence'] as num?) ?? 0).toDouble().clamp(0, 1),
      );
}

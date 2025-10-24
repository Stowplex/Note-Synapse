import 'dart:convert';

/// Transport type for MCP connections
enum McpTransportType {
  sse,
  streamableHttp;

  String get displayName {
    switch (this) {
      case McpTransportType.sse:
        return 'SSE (Server-Sent Events)';
      case McpTransportType.streamableHttp:
        return 'StreamableHTTP';
    }
  }
}

/// Model representing an MCP endpoint configuration
class McpEndpoint {
  final String id;
  final String name;
  final String baseUrl;
  final McpTransportType transportType;
  final DateTime createdAt;
  final DateTime updatedAt;

  McpEndpoint({
    required this.id,
    required this.name,
    required this.baseUrl,
    this.transportType = McpTransportType.streamableHttp,
    required this.createdAt,
    required this.updatedAt,
  });

  factory McpEndpoint.fromJson(Map<String, dynamic> json) {
    return McpEndpoint(
      id: json['id'] as String,
      name: json['name'] as String,
      baseUrl: json['baseUrl'] as String,
      transportType: json['transportType'] != null
          ? McpTransportType.values.firstWhere(
              (e) => e.name == json['transportType'],
              orElse: () => McpTransportType.streamableHttp,
            )
          : McpTransportType.streamableHttp,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'baseUrl': baseUrl,
      'transportType': transportType.name,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  McpEndpoint copyWith({
    String? id,
    String? name,
    String? baseUrl,
    McpTransportType? transportType,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return McpEndpoint(
      id: id ?? this.id,
      name: name ?? this.name,
      baseUrl: baseUrl ?? this.baseUrl,
      transportType: transportType ?? this.transportType,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

/// Model representing cached MCP tools for an endpoint
class McpToolsCache {
  final String endpointId;
  final List<McpTool> tools;
  final DateTime fetchedAt;

  McpToolsCache({
    required this.endpointId,
    required this.tools,
    required this.fetchedAt,
  });

  factory McpToolsCache.fromJson(Map<String, dynamic> json) {
    return McpToolsCache(
      endpointId: json['endpointId'] as String,
      tools: (json['tools'] as List)
          .map((tool) => McpTool.fromJson(tool as Map<String, dynamic>))
          .toList(),
      fetchedAt: DateTime.parse(json['fetchedAt'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'endpointId': endpointId,
      'tools': tools.map((tool) => tool.toJson()).toList(),
      'fetchedAt': fetchedAt.toIso8601String(),
    };
  }
}

/// Model representing a single MCP tool
class McpTool {
  final String name;
  final String? description;
  final Map<String, dynamic>? inputSchema;

  McpTool({
    required this.name,
    this.description,
    this.inputSchema,
  });

  factory McpTool.fromJson(Map<String, dynamic> json) {
    return McpTool(
      name: json['name'] as String,
      description: json['description'] as String?,
      inputSchema: json['inputSchema'] as Map<String, dynamic>?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      if (description != null) 'description': description,
      if (inputSchema != null) 'inputSchema': inputSchema,
    };
  }

  String toDisplayString() {
    final buffer = StringBuffer();
    buffer.writeln('Tool: $name');
    if (description != null && description!.isNotEmpty) {
      buffer.writeln('Description: $description');
    }
    if (inputSchema != null) {
      buffer.writeln('Schema:');
      buffer.writeln(const JsonEncoder.withIndent('  ').convert(inputSchema));
    }
    return buffer.toString();
  }
}


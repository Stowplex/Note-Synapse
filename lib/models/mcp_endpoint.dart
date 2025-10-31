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
  final McpAuthType authType;
  final OAuthConfig? oauth;
  final DateTime createdAt;
  final DateTime updatedAt;

  McpEndpoint({
    required this.id,
    required this.name,
    required this.baseUrl,
    this.transportType = McpTransportType.streamableHttp,
    this.authType = McpAuthType.token,
    this.oauth,
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
      authType: json['authType'] != null
          ? McpAuthType.values.firstWhere(
              (e) => e.name == json['authType'],
              orElse: () => McpAuthType.token,
            )
          : McpAuthType.token,
      oauth: json['oauth'] != null
          ? OAuthConfig.fromJson(json['oauth'] as Map<String, dynamic>)
          : null,
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
      'authType': authType.name,
      if (oauth != null) 'oauth': oauth!.toJson(),
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  McpEndpoint copyWith({
    String? id,
    String? name,
    String? baseUrl,
    McpTransportType? transportType,
    McpAuthType? authType,
    OAuthConfig? oauth,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return McpEndpoint(
      id: id ?? this.id,
      name: name ?? this.name,
      baseUrl: baseUrl ?? this.baseUrl,
      transportType: transportType ?? this.transportType,
      authType: authType ?? this.authType,
      oauth: oauth ?? this.oauth,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

/// Authentication type for MCP endpoints
enum McpAuthType { token, oauth }

/// OAuth 2.0 configuration for an MCP endpoint
class OAuthConfig {
  final String authorizationEndpoint;
  final String tokenEndpoint;
  final String clientId;
  final String? clientSecret; // optional when using PKCE
  final String scope;
  final bool usePkce;
  final String? discoveryUrl; // metadata URL used for auto-config
  final String redirectUri; // we standardize on localhost redirect
  final String? issuer;
  final String? resourceMetadataUrl;
  final String? authorizationServerMetadataUrl;

  OAuthConfig({
    required this.authorizationEndpoint,
    required this.tokenEndpoint,
    required this.clientId,
    this.clientSecret,
    required this.scope,
    this.usePkce = true,
    this.discoveryUrl,
    required this.redirectUri,
    this.issuer,
    this.resourceMetadataUrl,
    this.authorizationServerMetadataUrl,
  });

  factory OAuthConfig.fromJson(Map<String, dynamic> json) {
    return OAuthConfig(
      authorizationEndpoint: json['authorizationEndpoint'] as String,
      tokenEndpoint: json['tokenEndpoint'] as String,
      clientId: json['clientId'] as String,
      clientSecret: json['clientSecret'] as String?,
      scope: json['scope'] as String? ?? '',
      usePkce: json['usePkce'] as bool? ?? true,
      discoveryUrl: json['discoveryUrl'] as String?,
      redirectUri: json['redirectUri'] as String? ?? 'http://127.0.0.1:51791/callback',
      issuer: json['issuer'] as String?,
      resourceMetadataUrl: json['resourceMetadataUrl'] as String?,
      authorizationServerMetadataUrl: json['authorizationServerMetadataUrl'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'authorizationEndpoint': authorizationEndpoint,
      'tokenEndpoint': tokenEndpoint,
      'clientId': clientId,
      if (clientSecret != null) 'clientSecret': clientSecret,
      'scope': scope,
      'usePkce': usePkce,
      if (discoveryUrl != null) 'discoveryUrl': discoveryUrl,
      'redirectUri': redirectUri,
      if (issuer != null) 'issuer': issuer,
      if (resourceMetadataUrl != null) 'resourceMetadataUrl': resourceMetadataUrl,
      if (authorizationServerMetadataUrl != null)
        'authorizationServerMetadataUrl': authorizationServerMetadataUrl,
    };
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


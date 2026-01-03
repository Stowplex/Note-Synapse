import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mcp_client/mcp_client.dart' as mcp;
import 'package:uuid/uuid.dart';
import '../models/mcp_endpoint.dart';
import 'logger_service.dart';
import 'oauth_token_manager.dart';

/// Service for managing MCP (Model Context Protocol) endpoints and tools
class McpService {
  static const String _endpointsKey = 'mcp_endpoints';
  static const String _toolsCachePrefix = 'mcp_tools_cache_';
  static const String _bearerTokenPrefix = 'mcp_bearer_token_';
  static final Map<String, OAuthTokenManager> _oauthManagers =
      <String, OAuthTokenManager>{};

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      sharedPreferencesName: 'note_synapse_secure',
      preferencesKeyPrefix: 'note_synapse_',
    ),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  static const _uuid = Uuid();

  /// Get all MCP endpoints
  static Future<List<McpEndpoint>> getEndpoints() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final endpointsJson = prefs.getString(_endpointsKey);

      if (endpointsJson == null) {
        return [];
      }

      final List<dynamic> endpointsList = jsonDecode(endpointsJson);
      return endpointsList
          .map((json) => McpEndpoint.fromJson(json as Map<String, dynamic>))
          .toList();
    } catch (e) {
      LoggerService.error('McpService: Error getting endpoints: $e');
      return [];
    }
  }

  /// Save MCP endpoints
  static Future<void> _saveEndpoints(List<McpEndpoint> endpoints) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final endpointsJson = jsonEncode(
        endpoints.map((e) => e.toJson()).toList(),
      );
      await prefs.setString(_endpointsKey, endpointsJson);
      LoggerService.debug('McpService: Saved ${endpoints.length} endpoints');
    } catch (e) {
      LoggerService.error('McpService: Error saving endpoints: $e');
      rethrow;
    }
  }

  /// Add a new MCP endpoint
  static Future<McpEndpoint> addEndpoint({
    required String name,
    required String baseUrl,
    required McpTransportType transportType,
    McpAuthType authType = McpAuthType.token,
    OAuthConfig? oauthConfig,
    String? bearerToken,
    Map<String, String> additionalHeaders = const {},
  }) async {
    try {
      final now = DateTime.now();
      final endpoint = McpEndpoint(
        id: _uuid.v4(),
        name: name,
        baseUrl: baseUrl,
        transportType: transportType,
        authType: authType,
        additionalHeaders: additionalHeaders,
        oauth: oauthConfig,
        createdAt: now,
        updatedAt: now,
      );

      // Save auth tokens/secret based on auth type
      if (authType == McpAuthType.token &&
          bearerToken != null &&
          bearerToken.isNotEmpty) {
        await _storage.write(
          key: '$_bearerTokenPrefix${endpoint.id}',
          value: bearerToken,
        );
      } else if (authType == McpAuthType.oauth && oauthConfig != null) {
        // Initialize token manager for this endpoint
        _oauthManagers[endpoint.id] = OAuthTokenManager(
          endpointId: endpoint.id,
          config: oauthConfig,
        );
      }

      // Add endpoint to list
      final endpoints = await getEndpoints();
      endpoints.add(endpoint);
      await _saveEndpoints(endpoints);

      LoggerService.debug(
        'McpService: Added endpoint: ${endpoint.name} (${endpoint.id}) with ${transportType.displayName}',
      );
      return endpoint;
    } catch (e) {
      LoggerService.error('McpService: Error adding endpoint: $e');
      rethrow;
    }
  }

  /// Update an existing MCP endpoint
  static Future<void> updateEndpoint({
    required String id,
    String? name,
    String? baseUrl,
    McpTransportType? transportType,
    McpAuthType? authType,
    OAuthConfig? oauthConfig,
    String? bearerToken,
    Map<String, String>? additionalHeaders,
  }) async {
    try {
      final endpoints = await getEndpoints();
      final index = endpoints.indexWhere((e) => e.id == id);

      if (index == -1) {
        throw Exception('Endpoint not found: $id');
      }

      final now = DateTime.now();
      endpoints[index] = endpoints[index].copyWith(
        name: name ?? endpoints[index].name,
        baseUrl: baseUrl ?? endpoints[index].baseUrl,
        transportType: transportType ?? endpoints[index].transportType,
        authType: authType ?? endpoints[index].authType,
        additionalHeaders:
            additionalHeaders ?? endpoints[index].additionalHeaders,
        oauth: oauthConfig ?? endpoints[index].oauth,
        updatedAt: now,
      );

      // Update bearer token if provided
      if (bearerToken != null && bearerToken.isNotEmpty) {
        await _storage.write(key: '$_bearerTokenPrefix$id', value: bearerToken);
      }
      // Maintain OAuth manager
      final ep = endpoints[index];
      if (ep.authType == McpAuthType.oauth && ep.oauth != null) {
        _oauthManagers[id] = OAuthTokenManager(
          endpointId: id,
          config: ep.oauth!,
        );
      }

      await _saveEndpoints(endpoints);
      LoggerService.debug('McpService: Updated endpoint: $id');
    } catch (e) {
      LoggerService.error('McpService: Error updating endpoint: $e');
      rethrow;
    }
  }

  /// Delete an MCP endpoint
  static Future<void> deleteEndpoint(String id) async {
    try {
      final endpoints = await getEndpoints();
      endpoints.removeWhere((e) => e.id == id);
      await _saveEndpoints(endpoints);

      // Delete bearer token
      await _storage.delete(key: '$_bearerTokenPrefix$id');

      // Delete cached tools
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('$_toolsCachePrefix$id');

      // Remove OAuth tokens/manager
      _oauthManagers.remove(id);

      LoggerService.debug('McpService: Deleted endpoint: $id');
    } catch (e) {
      LoggerService.error('McpService: Error deleting endpoint: $e');
      rethrow;
    }
  }

  /// Get bearer token for an endpoint
  static Future<String?> getBearerToken(String endpointId) async {
    try {
      final endpoints = await getEndpoints();
      final endpoint = endpoints.firstWhere(
        (e) => e.id == endpointId,
        orElse: () => throw Exception('Endpoint not found'),
      );
      if (endpoint.authType == McpAuthType.oauth) {
        final manager = _oauthManagers[endpointId] ??= (endpoint.oauth != null
            ? OAuthTokenManager(endpointId: endpointId, config: endpoint.oauth!)
            : throw Exception('OAuth config missing for endpoint $endpointId'));
        return await manager.getAccessToken();
      }
      return await _storage.read(key: '$_bearerTokenPrefix$endpointId');
    } catch (e) {
      LoggerService.error('McpService: Error getting bearer token: $e');
      return null;
    }
  }

  /// Get cached tools for an endpoint
  static Future<McpToolsCache?> getCachedTools(String endpointId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cacheJson = prefs.getString('$_toolsCachePrefix$endpointId');

      if (cacheJson == null) {
        return null;
      }

      return McpToolsCache.fromJson(jsonDecode(cacheJson));
    } catch (e) {
      LoggerService.error('McpService: Error getting cached tools: $e');
      return null;
    }
  }

  /// Refresh tools from an MCP endpoint
  static Future<McpToolsCache> refreshTools(String endpointId) async {
    final requestId = 'mcp_refresh_${DateTime.now().millisecondsSinceEpoch}';
    final startTime = DateTime.now();

    try {
      final endpoints = await getEndpoints();
      final endpoint = endpoints.firstWhere((e) => e.id == endpointId);
      final bearerToken = await getBearerToken(endpointId);

      LoggerService.debug(
        'McpService: Refreshing tools from ${endpoint.baseUrl} using ${endpoint.transportType.displayName}',
      );

      // Log MCP refresh request to AI debug overlay
      LoggerService.logAiRequest(
        endpoint: 'MCP: ${endpoint.name} - List Tools',
        headers: {
          'Service': endpoint.name,
          'Base-URL': endpoint.baseUrl,
          'Transport': endpoint.transportType.displayName,
        },
        requestBody: {
          'operation': 'listTools',
          'endpointId': endpointId,
          'endpointName': endpoint.name,
        },
        requestId: requestId,
      );

      // Create MCP client configuration
      final config = mcp.McpClient.simpleConfig(
        name: 'NoteSynapse',
        version: '1.0.0',
        enableDebugLogging: true,
      );

      // Build base headers (let MCP client handle Accept header internally)
      final headers = <String, String>{'User-Agent': 'NoteSynapse/1.0'};
      headers.addAll(endpoint.additionalHeaders);

      // Create transport configuration based on type
      final mcp.TransportConfig transportConfig;
      switch (endpoint.transportType) {
        case McpTransportType.sse:
          // For SSE, bearer token is passed as a parameter
          transportConfig = mcp.TransportConfig.sse(
            serverUrl: endpoint.baseUrl,
            headers: headers,
            bearerToken: bearerToken,
          );
          break;
        case McpTransportType.streamableHttp:
          // For HTTP, bearer token goes in headers
          if (bearerToken != null && bearerToken.isNotEmpty) {
            headers['Authorization'] = 'Bearer $bearerToken';
          }
          transportConfig = mcp.TransportConfig.streamableHttp(
            baseUrl: endpoint.baseUrl,
            headers: headers,
          );
          break;
      }

      // Create and connect client
      final clientResult = await mcp.McpClient.createAndConnect(
        config: config,
        transportConfig: transportConfig,
      );

      final client = clientResult.fold((c) => c, (error) {
        LoggerService.error(
          'McpService: Failed to connect to MCP server: $error',
        );
        throw Exception('Failed to connect to MCP server: $error');
      });

      try {
        // List available tools
        final toolsList = await client.listTools();
        LoggerService.debug(
          'McpService: Fetched ${toolsList.length} tools from ${endpoint.name}',
        );

        // Convert to our model format
        final tools = toolsList.map((tool) {
          return McpTool(
            name: tool.name,
            description: tool.description,
            inputSchema: tool.inputSchema,
          );
        }).toList();

        // Create cache
        final cache = McpToolsCache(
          endpointId: endpointId,
          tools: tools,
          fetchedAt: DateTime.now(),
        );

        // Save to cache
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          '$_toolsCachePrefix$endpointId',
          jsonEncode(cache.toJson()),
        );

        LoggerService.debug(
          'McpService: Cached ${tools.length} tools for ${endpoint.name}',
        );

        // Log successful response to AI debug overlay
        final duration = DateTime.now().difference(startTime);
        LoggerService.logAiResponse(
          statusCode: 200,
          headers: {
            'Service': endpoint.name,
            'Tools-Count': tools.length.toString(),
          },
          responseBody: jsonEncode({
            'success': true,
            'toolsCount': tools.length,
            'tools': tools
                .map(
                  (t) => {'name': t.name, 'description': t.description ?? ''},
                )
                .toList(),
          }),
          requestId: requestId,
          duration: duration,
        );

        return cache;
      } finally {
        // Disconnect client
        client.disconnect();
      }
    } catch (e) {
      LoggerService.error('McpService: Error refreshing tools: $e');

      // Log error to AI debug overlay
      final duration = DateTime.now().difference(startTime);
      final endpoints = await getEndpoints();
      final endpoint = endpoints.firstWhere((e) => e.id == endpointId);

      LoggerService.logAiError(
        error: e.toString(),
        endpoint: 'MCP: ${endpoint.name} - List Tools',
        requestId: requestId,
        duration: duration,
      );

      rethrow;
    }
  }

  /// Call a tool on an MCP endpoint
  static Future<String> callTool({
    required String endpointId,
    required String toolName,
    required Map<String, dynamic> arguments,
  }) async {
    final requestId = 'mcp_call_${DateTime.now().millisecondsSinceEpoch}';
    final startTime = DateTime.now();

    try {
      final endpoints = await getEndpoints();
      final endpoint = endpoints.firstWhere((e) => e.id == endpointId);
      final bearerToken = await getBearerToken(endpointId);

      LoggerService.debug(
        'McpService: Calling tool $toolName on ${endpoint.baseUrl}',
      );

      // Log MCP tool call request to AI debug overlay
      LoggerService.logAiRequest(
        endpoint: 'MCP: ${endpoint.name} - Call Tool: $toolName',
        headers: {
          'Service': endpoint.name,
          'Base-URL': endpoint.baseUrl,
          'Transport': endpoint.transportType.displayName,
          'Tool': toolName,
        },
        requestBody: {
          'operation': 'callTool',
          'endpointId': endpointId,
          'endpointName': endpoint.name,
          'toolName': toolName,
          'arguments': arguments,
        },
        requestId: requestId,
      );

      // Create MCP client configuration
      final config = mcp.McpClient.simpleConfig(
        name: 'NoteSynapse',
        version: '1.0.0',
        enableDebugLogging: false,
      );

      // Build base headers (let MCP client handle Accept header internally)
      final headers = <String, String>{'User-Agent': 'NoteSynapse/1.0'};
      headers.addAll(endpoint.additionalHeaders);

      // Create transport configuration based on type
      final mcp.TransportConfig transportConfig;
      switch (endpoint.transportType) {
        case McpTransportType.sse:
          // For SSE, bearer token is passed as a parameter
          transportConfig = mcp.TransportConfig.sse(
            serverUrl: endpoint.baseUrl,
            headers: headers,
            bearerToken: bearerToken,
          );
          break;
        case McpTransportType.streamableHttp:
          // For HTTP, bearer token goes in headers
          if (bearerToken != null && bearerToken.isNotEmpty) {
            headers['Authorization'] = 'Bearer $bearerToken';
          }
          transportConfig = mcp.TransportConfig.streamableHttp(
            baseUrl: endpoint.baseUrl,
            headers: headers,
          );
          break;
      }

      // Create and connect client
      final clientResult = await mcp.McpClient.createAndConnect(
        config: config,
        transportConfig: transportConfig,
      );

      final client = clientResult.fold((c) => c, (error) {
        throw Exception('Failed to connect to MCP server: $error');
      });

      try {
        // Call the tool
        final result = await client.callTool(toolName, arguments);

        // Extract content from result
        // MCP tools can return multiple content types:
        // - TextContent: simple text responses
        // - ResourceContent: file contents (with text or blob field)
        // - ImageContent: images (not handled yet)
        final buffer = StringBuffer();
        for (final content in result.content) {
          if (content is mcp.TextContent) {
            buffer.write(content.text);
          } else if (content is mcp.ResourceContent) {
            // ResourceContent contains the actual file/resource data
            // Prefer text content, fall back to blob (which is base64)
            if (content.text != null) {
              buffer.write(content.text);
            } else if (content.blob != null) {
              // blob is base64-encoded, decode it for text files
              try {
                final decoded = utf8.decode(base64Decode(content.blob!));
                buffer.write(decoded);
              } catch (_) {
                // If base64 decode fails or isn't valid UTF-8, return raw blob
                buffer.write(content.blob);
              }
            }
          }
        }

        LoggerService.debug('McpService: Tool call successful');

        // Log successful response to AI debug overlay
        final duration = DateTime.now().difference(startTime);
        final resultText = buffer.toString();
        LoggerService.logAiResponse(
          statusCode: 200,
          headers: {
            'Service': endpoint.name,
            'Tool': toolName,
            'Result-Length': resultText.length.toString(),
          },
          responseBody: jsonEncode({
            'success': true,
            'result': resultText,
            'contentItems': result.content.length,
          }),
          requestId: requestId,
          duration: duration,
        );

        return resultText;
      } finally {
        // Disconnect client
        client.disconnect();
      }
    } catch (e) {
      LoggerService.error('McpService: Error calling tool: $e');

      // Log error to AI debug overlay
      final duration = DateTime.now().difference(startTime);
      final endpoints = await getEndpoints();
      final endpoint = endpoints.firstWhere((e) => e.id == endpointId);

      LoggerService.logAiError(
        error: e.toString(),
        endpoint: 'MCP: ${endpoint.name} - Call Tool: $toolName',
        requestId: requestId,
        duration: duration,
      );

      rethrow;
    }
  }
}

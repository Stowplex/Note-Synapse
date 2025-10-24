import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mcp_client/mcp_client.dart';
import 'package:uuid/uuid.dart';
import '../models/mcp_endpoint.dart';
import 'logger_service.dart';

/// Service for managing MCP (Model Context Protocol) endpoints and tools
class McpService {
  static const String _endpointsKey = 'mcp_endpoints';
  static const String _toolsCachePrefix = 'mcp_tools_cache_';
  static const String _bearerTokenPrefix = 'mcp_bearer_token_';

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
      final endpointsJson =
          jsonEncode(endpoints.map((e) => e.toJson()).toList());
      await prefs.setString(_endpointsKey, endpointsJson);
      LoggerService.debug(
          'McpService: Saved ${endpoints.length} endpoints');
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
    String? bearerToken,
  }) async {
    try {
      final now = DateTime.now();
      final endpoint = McpEndpoint(
        id: _uuid.v4(),
        name: name,
        baseUrl: baseUrl,
        transportType: transportType,
        createdAt: now,
        updatedAt: now,
      );

      // Save bearer token to secure storage if provided
      if (bearerToken != null && bearerToken.isNotEmpty) {
        await _storage.write(
          key: '$_bearerTokenPrefix${endpoint.id}',
          value: bearerToken,
        );
      }

      // Add endpoint to list
      final endpoints = await getEndpoints();
      endpoints.add(endpoint);
      await _saveEndpoints(endpoints);

      LoggerService.debug(
          'McpService: Added endpoint: ${endpoint.name} (${endpoint.id}) with ${transportType.displayName}');
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
    String? bearerToken,
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
        updatedAt: now,
      );

      // Update bearer token if provided
      if (bearerToken != null && bearerToken.isNotEmpty) {
        await _storage.write(
          key: '$_bearerTokenPrefix$id',
          value: bearerToken,
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

      LoggerService.debug('McpService: Deleted endpoint: $id');
    } catch (e) {
      LoggerService.error('McpService: Error deleting endpoint: $e');
      rethrow;
    }
  }

  /// Get bearer token for an endpoint
  static Future<String?> getBearerToken(String endpointId) async {
    try {
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
    try {
      final endpoints = await getEndpoints();
      final endpoint = endpoints.firstWhere((e) => e.id == endpointId);
      final bearerToken = await getBearerToken(endpointId);

      LoggerService.debug(
          'McpService: Refreshing tools from ${endpoint.baseUrl} using ${endpoint.transportType.displayName}');

      // Create MCP client configuration
      final config = McpClient.simpleConfig(
        name: 'NoteSynapse',
        version: '1.0.0',
        enableDebugLogging: true,
      );

      // Build headers based on transport type
      final headers = <String, String>{
        'User-Agent': 'NoteSynapse/1.0',
      };
      
      // Add bearer token to headers if available
      if (bearerToken != null && bearerToken.isNotEmpty) {
        headers['Authorization'] = 'Bearer $bearerToken';
      }

      // Create transport configuration based on type
      final TransportConfig transportConfig;
      switch (endpoint.transportType) {
        case McpTransportType.sse:
          // SSE requires text/event-stream
          headers['Accept'] = 'text/event-stream';
          transportConfig = TransportConfig.sse(
            serverUrl: endpoint.baseUrl,
            headers: headers,
          );
          break;
        case McpTransportType.streamableHttp:
          // HTTP accepts JSON
          headers['Accept'] = 'application/json';
          transportConfig = TransportConfig.streamableHttp(
            baseUrl: endpoint.baseUrl,
            headers: headers,
          );
          break;
      }

      // Create and connect client
      final clientResult = await McpClient.createAndConnect(
        config: config,
        transportConfig: transportConfig,
      );

      final client = clientResult.fold(
        (c) => c,
        (error) {
          LoggerService.error('McpService: Failed to connect to MCP server: $error');
          throw Exception('Failed to connect to MCP server: $error');
        },
      );

      try {
        // List available tools
        final toolsList = await client.listTools();
        LoggerService.debug(
            'McpService: Fetched ${toolsList.length} tools from ${endpoint.name}');

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
            'McpService: Cached ${tools.length} tools for ${endpoint.name}');

        return cache;
      } finally {
        // Disconnect client
        client.disconnect();
      }
    } catch (e) {
      LoggerService.error('McpService: Error refreshing tools: $e');
      rethrow;
    }
  }

  /// Call a tool on an MCP endpoint
  static Future<String> callTool({
    required String endpointId,
    required String toolName,
    required Map<String, dynamic> arguments,
  }) async {
    try {
      final endpoints = await getEndpoints();
      final endpoint = endpoints.firstWhere((e) => e.id == endpointId);
      final bearerToken = await getBearerToken(endpointId);

      LoggerService.debug(
          'McpService: Calling tool $toolName on ${endpoint.baseUrl}');

      // Create MCP client configuration
      final config = McpClient.simpleConfig(
        name: 'NoteSynapse',
        version: '1.0.0',
        enableDebugLogging: false,
      );

      // Build headers based on transport type
      final headers = <String, String>{
        'User-Agent': 'NoteSynapse/1.0',
      };
      
      // Add bearer token to headers if available
      if (bearerToken != null && bearerToken.isNotEmpty) {
        headers['Authorization'] = 'Bearer $bearerToken';
      }

      // Create transport configuration based on type
      final TransportConfig transportConfig;
      switch (endpoint.transportType) {
        case McpTransportType.sse:
          // SSE requires text/event-stream
          headers['Accept'] = 'text/event-stream';
          transportConfig = TransportConfig.sse(
            serverUrl: endpoint.baseUrl,
            headers: headers,
          );
          break;
        case McpTransportType.streamableHttp:
          // HTTP accepts JSON
          headers['Accept'] = 'application/json';
          transportConfig = TransportConfig.streamableHttp(
            baseUrl: endpoint.baseUrl,
            headers: headers,
          );
          break;
      }

      // Create and connect client
      final clientResult = await McpClient.createAndConnect(
        config: config,
        transportConfig: transportConfig,
      );

      final client = clientResult.fold(
        (c) => c,
        (error) {
          throw Exception('Failed to connect to MCP server: $error');
        },
      );

      try {
        // Call the tool
        final result = await client.callTool(toolName, arguments);

        // Extract text content from result
        final buffer = StringBuffer();
        for (final content in result.content) {
          if (content is TextContent) {
            buffer.write(content.text);
          }
        }

        LoggerService.debug('McpService: Tool call successful');
        return buffer.toString();
      } finally {
        // Disconnect client
        client.disconnect();
      }
    } catch (e) {
      LoggerService.error('McpService: Error calling tool: $e');
      rethrow;
    }
  }

  /// Test connection to an MCP endpoint
  static Future<bool> testConnection({
    required String baseUrl,
    required McpTransportType transportType,
    String? bearerToken,
  }) async {
    try {
      LoggerService.debug('McpService: Testing connection to $baseUrl using ${transportType.displayName}');

      final config = McpClient.simpleConfig(
        name: 'NoteSynapse',
        version: '1.0.0',
        enableDebugLogging: false,
      );

      // Build headers based on transport type
      final headers = <String, String>{
        'User-Agent': 'NoteSynapse/1.0',
      };
      
      // Add bearer token to headers if available
      if (bearerToken != null && bearerToken.isNotEmpty) {
        headers['Authorization'] = 'Bearer $bearerToken';
      }

      // Create transport configuration based on type
      final TransportConfig transportConfig;
      switch (transportType) {
        case McpTransportType.sse:
          // SSE requires text/event-stream
          headers['Accept'] = 'text/event-stream';
          transportConfig = TransportConfig.sse(
            serverUrl: baseUrl,
            headers: headers,
          );
          break;
        case McpTransportType.streamableHttp:
          // HTTP accepts JSON
          headers['Accept'] = 'application/json';
          transportConfig = TransportConfig.streamableHttp(
            baseUrl: baseUrl,
            headers: headers,
          );
          break;
      }

      final clientResult = await McpClient.createAndConnect(
        config: config,
        transportConfig: transportConfig,
      );

      final client = clientResult.fold(
        (c) => c,
        (error) {
          LoggerService.error('McpService: Connection test failed: $error');
          return null;
        },
      );

      if (client == null) {
        return false;
      }

      try {
        // Try to list tools to verify connection
        await client.listTools();
        LoggerService.debug('McpService: Connection test successful');
        return true;
      } finally {
        client.disconnect();
      }
    } catch (e) {
      LoggerService.error('McpService: Connection test error: $e');
      return false;
    }
  }
}


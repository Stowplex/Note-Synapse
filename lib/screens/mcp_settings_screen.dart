import 'package:flutter/material.dart';
import '../models/mcp_endpoint.dart';
import '../services/mcp_service.dart';
import '../services/logger_service.dart';

class McpSettingsScreen extends StatefulWidget {
  const McpSettingsScreen({super.key});

  @override
  State<McpSettingsScreen> createState() => _McpSettingsScreenState();
}

class _McpSettingsScreenState extends State<McpSettingsScreen> {
  List<McpEndpoint> _endpoints = [];
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadEndpoints();
  }

  Future<void> _loadEndpoints() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final endpoints = await McpService.getEndpoints();
      setState(() {
        _endpoints = endpoints;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading endpoints: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _showAddEndpointDialog() async {
    final nameController = TextEditingController();
    final baseUrlController = TextEditingController();
    final bearerTokenController = TextEditingController();
    bool obscureToken = true;
    McpTransportType selectedTransport = McpTransportType.streamableHttp;

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Add MCP Endpoint'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    hintText: 'My MCP Server',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: baseUrlController,
                  decoration: const InputDecoration(
                    labelText: 'Base URL',
                    hintText: 'https://api.example.com or https://server.smithery.ai/@user/server/mcp?api_key=xxx',
                    border: OutlineInputBorder(),
                    helperText: 'Include query params for auth if needed (e.g., Smithery)',
                    helperMaxLines: 2,
                  ),
                  keyboardType: TextInputType.url,
                  maxLines: 2,
                ),
                const SizedBox(height: 16),
                const Text(
                  'Transport Type',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 8),
                ...McpTransportType.values.map((type) => RadioListTile<McpTransportType>(
                  title: Text(type.displayName),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: type,
                  groupValue: selectedTransport,
                  onChanged: (value) {
                    if (value != null) {
                      setState(() {
                        selectedTransport = value;
                      });
                    }
                  },
                )),
                const SizedBox(height: 16),
                TextField(
                  controller: bearerTokenController,
                  decoration: InputDecoration(
                    labelText: 'Bearer Token (Optional)',
                    hintText: 'Leave empty if auth is in URL params',
                    border: const OutlineInputBorder(),
                    helperText: 'Optional: For header-based authentication',
                    suffixIcon: IconButton(
                      icon: Icon(
                        obscureToken ? Icons.visibility : Icons.visibility_off,
                      ),
                      onPressed: () {
                        setState(() {
                          obscureToken = !obscureToken;
                        });
                      },
                    ),
                  ),
                  obscureText: obscureToken,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () async {
                final name = nameController.text.trim();
                final baseUrl = baseUrlController.text.trim();
                final bearerToken = bearerTokenController.text.trim();

                if (name.isEmpty || baseUrl.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Please provide name and URL'),
                      backgroundColor: Colors.red,
                    ),
                  );
                  return;
                }

                try {
                  // Add endpoint
                  await McpService.addEndpoint(
                    name: name,
                    baseUrl: baseUrl,
                    transportType: selectedTransport,
                    bearerToken: bearerToken.isNotEmpty ? bearerToken : null,
                  );

                  if (context.mounted) {
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Added endpoint: $name'),
                        backgroundColor: Colors.green,
                      ),
                    );
                  }

                  // Reload endpoints
                  _loadEndpoints();
                } catch (e) {
                  LoggerService.error('Error adding endpoint: $e');
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Error: $e'),
                        backgroundColor: Colors.red,
                      ),
                    );
                  }
                }
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteEndpoint(McpEndpoint endpoint) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Endpoint'),
        content: Text(
            'Are you sure you want to delete "${endpoint.name}"? This will also delete cached tools.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await McpService.deleteEndpoint(endpoint.id);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Deleted endpoint: ${endpoint.name}'),
              backgroundColor: Colors.green,
            ),
          );
        }
        _loadEndpoints();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error deleting endpoint: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  Future<void> _refreshTools(McpEndpoint endpoint) async {
    setState(() {
      _isLoading = true;
    });

    try {
      await McpService.refreshTools(endpoint.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Refreshed tools for ${endpoint.name}'),
            backgroundColor: Colors.green,
          ),
        );
      }
      setState(() {
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error refreshing tools: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _showToolsDialog(McpEndpoint endpoint) async {
    final cache = await McpService.getCachedTools(endpoint.id);

    if (!mounted) return;

    if (cache == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'No tools cached for ${endpoint.name}. Click refresh to fetch tools.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Tools - ${endpoint.name}'),
        content: SizedBox(
          width: double.maxFinite,
          height: 400,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Fetched: ${cache.fetchedAt.toString().substring(0, 19)}',
                style: TextStyle(
                  color: Colors.grey[600],
                  fontSize: 12,
                ),
              ),
              Text(
                'Tools: ${cache.tools.length}',
                style: TextStyle(
                  color: Colors.grey[600],
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: SingleChildScrollView(
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.grey[900],
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: Colors.grey[700]!,
                        width: 1,
                      ),
                    ),
                    child: SelectableText(
                      cache.tools.isEmpty
                          ? 'No tools available'
                          : cache.tools
                              .map((tool) => tool.toDisplayString())
                              .join('\n${'=' * 60}\n\n'),
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('MCP Settings'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _showAddEndpointDialog,
                      icon: const Icon(Icons.add),
                      label: const Text('Add MCP Endpoint'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.all(16),
                      ),
                    ),
                  ),
                ),
                if (_endpoints.isEmpty)
                  Expanded(
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.cloud_off,
                            size: 64,
                            color: Colors.grey[400],
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'No MCP endpoints configured',
                            style: TextStyle(
                              fontSize: 18,
                              color: Colors.grey[600],
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Click "Add MCP Endpoint" to get started',
                            style: TextStyle(
                              color: Colors.grey[500],
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: _endpoints.length,
                      itemBuilder: (context, index) {
                        final endpoint = _endpoints[index];
                        return Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: Column(
                            children: [
                              ListTile(
                                leading: const Icon(Icons.cloud),
                                title: Text(endpoint.name),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      endpoint.baseUrl,
                                      style: const TextStyle(fontSize: 12),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 4),
                                    Row(
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                            vertical: 2,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Theme.of(context)
                                                .colorScheme
                                                .primaryContainer,
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                          child: Text(
                                            endpoint.transportType.displayName,
                                            style: TextStyle(
                                              fontSize: 10,
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .onPrimaryContainer,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            'Updated: ${endpoint.updatedAt.toString().substring(0, 19)}',
                                            style: TextStyle(
                                              fontSize: 11,
                                              color: Colors.grey[600],
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                                trailing: IconButton(
                                  icon: const Icon(Icons.delete, color: Colors.red),
                                  onPressed: () => _deleteEndpoint(endpoint),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 8,
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: OutlinedButton.icon(
                                        onPressed: () => _refreshTools(endpoint),
                                        icon: const Icon(Icons.refresh, size: 18),
                                        label: const Text('Refresh Tools'),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: OutlinedButton.icon(
                                        onPressed: () => _showToolsDialog(endpoint),
                                        icon: const Icon(Icons.visibility, size: 18),
                                        label: const Text('View Tools'),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
    );
  }
}


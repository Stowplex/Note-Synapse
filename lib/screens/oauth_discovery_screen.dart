import 'dart:convert';
import 'package:flutter/material.dart';
import '../services/oauth_service.dart';
import '../services/logger_service.dart';

class OAuthDiscoveryResultData {
  final String authorizationEndpoint;
  final String tokenEndpoint;
  final String? clientId;
  final String? clientSecret;
  final String? defaultScope;
  final String? issuer;
  final String? resourceMetadataUrl;
  final String? authorizationServerMetadataUrl;
  final Map<String, dynamic>? resourceMetadata;
  final Map<String, dynamic>? authorizationServerMetadata;
  final String? selectedAuthorizationServer;
  final List<String>? availableAuthorizationServers;
  final String? scopeFromChallenge;
  final String? recommendedScope;

  OAuthDiscoveryResultData({
    required this.authorizationEndpoint,
    required this.tokenEndpoint,
    this.clientId,
    this.clientSecret,
    this.defaultScope,
    this.issuer,
    this.resourceMetadataUrl,
    this.authorizationServerMetadataUrl,
    this.resourceMetadata,
    this.authorizationServerMetadata,
    this.selectedAuthorizationServer,
    this.availableAuthorizationServers,
    this.scopeFromChallenge,
    this.recommendedScope,
  });
}

class OAuthDiscoveryScreen extends StatefulWidget {
  final String baseUrl;
  final bool usePkce;

  const OAuthDiscoveryScreen({super.key, required this.baseUrl, this.usePkce = true});

  @override
  State<OAuthDiscoveryScreen> createState() => _OAuthDiscoveryScreenState();
}

class _OAuthDiscoveryScreenState extends State<OAuthDiscoveryScreen> {
  final _metaController = TextEditingController();

  bool _loading = false;
  String? _error;

  OAuthDiscoverySummary? _summary;
  Map<String, dynamic>? _resourceMetadata;
  Map<String, dynamic>? _authorizationMetadata;
  String? _resourceMetadataUrl;
  String? _authorizationMetadataUrl;
  String? _selectedAuthorizationServer;
  String? _clientId;
  String? _clientSecret;
  String? _challengeScope;
  String? _recommendedScope;

  @override
  void initState() {
    super.initState();
    _metaController.text = '';
  }

  Future<void> _discover({String? preferredServer}) async {
    final input = _metaController.text.trim();
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      var summary = await OAuthService.performDiscovery(
        baseUrl: widget.baseUrl,
        metadataUrl: input.isEmpty ? null : input,
        preferredAuthorizationServer: preferredServer ?? _selectedAuthorizationServer,
      );

      final requiresSelection = summary.availableAuthorizationServers.length > 1 &&
          (preferredServer == null || preferredServer.isEmpty) &&
          (_selectedAuthorizationServer == null ||
              !summary.availableAuthorizationServers.contains(_selectedAuthorizationServer));

      if (requiresSelection) {
        final choice = await _promptAuthorizationServer(
          summary.availableAuthorizationServers,
          summary.selectedAuthorizationServer,
        );
        if (choice != null && choice.isNotEmpty && choice != summary.selectedAuthorizationServer) {
          summary = await OAuthService.performDiscovery(
            baseUrl: widget.baseUrl,
            metadataUrl: input.isEmpty ? null : input,
            preferredAuthorizationServer: choice,
          );
        }
      }

      if (!mounted) return;
      setState(() {
        _summary = summary;
        _resourceMetadata = summary.resourceMetadata;
        _authorizationMetadata = summary.authorizationServerMetadata;
        _resourceMetadataUrl = summary.resourceMetadataUrl;
        _authorizationMetadataUrl = summary.authorizationServerMetadataUrl;
        _selectedAuthorizationServer = summary.selectedAuthorizationServer;
        _challengeScope = summary.scopeFromChallenge;
        _recommendedScope = summary.recommendedScope;
        _error = null;
      });
    } catch (e) {
      LoggerService.error('OAuth discovery failed: $e');
      if (mounted) {
        setState(() {
          _error = '$e';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<String?> _promptAuthorizationServer(List<String> servers, String? current) {
    return showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Select Authorization Server'),
        children: [
          for (final server in servers)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, server),
              child: Text(server, style: const TextStyle(fontSize: 14)),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, current),
            child: const Text('Keep current selection'),
          ),
        ],
      ),
    );
  }

  Future<void> _register() async {
    final summary = _summary;
    if (summary == null) return;
    final registrationEndpoint = summary.authorizationServerMetadata?['registration_endpoint'] as String?;
    if (registrationEndpoint == null || registrationEndpoint.isEmpty) {
      setState(() {
        _error = 'Authorization server metadata does not advertise dynamic client registration.';
      });
      return;
    }

    try {
      String? scope = _challengeScope?.trim().isNotEmpty == true
          ? _challengeScope?.trim()
          : (_recommendedScope?.trim().isNotEmpty == true ? _recommendedScope?.trim() : null);
      final creds = await OAuthService.registerClient(
        registrationEndpoint: registrationEndpoint,
        clientName: 'NoteSynapse',
        redirectUri: 'http://127.0.0.1:51791/callback',
        usePkce: widget.usePkce,
        scope: scope,
      );
      if (!mounted) return;
      setState(() {
        _clientId = creds['client_id'];
        _clientSecret = creds['client_secret'];
        _error = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Client registered successfully.')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
      });
    }
  }

  void _apply() {
    final summary = _summary;
    if (summary == null) return;
    String? defaultScope = _challengeScope?.trim().isNotEmpty == true
        ? _challengeScope?.trim()
        : (_recommendedScope?.trim().isNotEmpty == true ? _recommendedScope?.trim() : null);
    if (defaultScope != null && defaultScope.isEmpty) {
      defaultScope = null;
    }

    Navigator.pop(
      context,
      OAuthDiscoveryResultData(
        authorizationEndpoint: summary.authorizationEndpoint,
        tokenEndpoint: summary.tokenEndpoint,
        clientId: _clientId,
        clientSecret: _clientSecret,
        defaultScope: defaultScope,
        issuer: summary.issuer,
        resourceMetadataUrl: summary.resourceMetadataUrl,
        authorizationServerMetadataUrl: summary.authorizationServerMetadataUrl,
        resourceMetadata: summary.resourceMetadata,
        authorizationServerMetadata: summary.authorizationServerMetadata,
        selectedAuthorizationServer: summary.selectedAuthorizationServer,
        availableAuthorizationServers: summary.availableAuthorizationServers,
        scopeFromChallenge: _challengeScope,
        recommendedScope: _recommendedScope,
      ),
    );
  }

  Widget _buildMetadataSection(String title, Map<String, dynamic> json, {String? subtitle}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        elevation: 0,
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              if (subtitle != null && subtitle.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(subtitle, style: const TextStyle(color: Colors.grey)),
              ],
              const SizedBox(height: 8),
              SelectableText(
                const JsonEncoder.withIndent('  ').convert(json),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final summary = _summary;
    return Scaffold(
      appBar: AppBar(title: const Text('OAuth Discovery')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _metaController,
              decoration: const InputDecoration(
                labelText: 'Metadata URL (optional)',
                hintText: 'Leave blank to auto-detect using RFC 9728',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                ElevatedButton(
                  onPressed: _loading ? null : () => _discover(),
                  child: const Text('Discover'),
                ),
                const SizedBox(width: 12),
                if (summary != null)
                  OutlinedButton(
                    onPressed: _loading ? null : _apply,
                    child: const Text('Apply'),
                  ),
                const SizedBox(width: 12),
                if (summary?.authorizationServerMetadata?['registration_endpoint'] != null)
                  ElevatedButton(
                    onPressed: _loading ? null : _register,
                    child: const Text('Register Client'),
                  ),
              ],
            ),
            if (_loading) const Padding(
              padding: EdgeInsets.only(top: 12),
              child: LinearProgressIndicator(),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),
            const SizedBox(height: 12),
            Expanded(
              child: ListView(
                children: [
                  if (summary != null)
                    Card(
                      elevation: 0,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Authorization Endpoint:\n${summary.authorizationEndpoint}',
                              style: const TextStyle(fontSize: 13),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Token Endpoint:\n${summary.tokenEndpoint}',
                              style: const TextStyle(fontSize: 13),
                            ),
                            if (summary.issuer != null) ...[
                              const SizedBox(height: 8),
                              Text('Issuer: ${summary.issuer}', style: const TextStyle(fontSize: 13)),
                            ],
                            if (summary.availableAuthorizationServers.isNotEmpty) ...[
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  const Text('Authorization server:', style: TextStyle(fontSize: 13)),
                                  const SizedBox(width: 12),
                                  DropdownButton<String>(
                                    value: summary.availableAuthorizationServers.contains(_selectedAuthorizationServer)
                                        ? _selectedAuthorizationServer
                                        : (summary.availableAuthorizationServers.contains(summary.selectedAuthorizationServer)
                                            ? summary.selectedAuthorizationServer
                                            : null),
                                    items: summary.availableAuthorizationServers
                                        .map((server) => DropdownMenuItem(
                                              value: server,
                                              child: Text(server, overflow: TextOverflow.ellipsis),
                                            ))
                                        .toList(),
                                    onChanged: _loading
                                        ? null
                                        : (value) {
                                            if (value == null) return;
                                            setState(() {
                                              _selectedAuthorizationServer = value;
                                            });
                                            _discover(preferredServer: value);
                                          },
                                  ),
                                ],
                              ),
                            ],
                            if (_challengeScope != null && _challengeScope!.isNotEmpty) ...[
                              const SizedBox(height: 8),
                              Text('Scope challenge: $_challengeScope', style: const TextStyle(fontSize: 13)),
                            ],
                            if (_recommendedScope != null && _recommendedScope!.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text('Recommended scope: $_recommendedScope', style: const TextStyle(fontSize: 13, color: Colors.grey)),
                            ],
                            if (_clientId != null) ...[
                              const SizedBox(height: 12),
                              Text('Registered client ID: $_clientId', style: const TextStyle(fontSize: 13)),
                              if (_clientSecret != null)
                                Text('Client secret: $_clientSecret', style: const TextStyle(fontSize: 13)),
                            ],
                          ],
                        ),
                      ),
                    ),
                  if (_resourceMetadata != null)
                    _buildMetadataSection(
                      'Protected Resource Metadata',
                      _resourceMetadata!,
                      subtitle: _resourceMetadataUrl,
                    ),
                  if (_authorizationMetadata != null)
                    _buildMetadataSection(
                      'Authorization Server Metadata',
                      _authorizationMetadata!,
                      subtitle: _authorizationMetadataUrl,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}



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
  final String metadataUrl;

  OAuthDiscoveryResultData({
    required this.authorizationEndpoint,
    required this.tokenEndpoint,
    this.clientId,
    this.clientSecret,
    this.defaultScope,
    required this.metadataUrl,
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
  Map<String, dynamic>? _json;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _metaController.text = _defaultMetadataUrl(widget.baseUrl);
  }

  String _defaultMetadataUrl(String base) {
    final uri = Uri.parse(base);
    final wellKnown = uri.replace(path: '${uri.path.endsWith('/') ? uri.path.substring(0, uri.path.length - 1) : uri.path}/.well-known/oauth-authorization-server');
    return wellKnown.toString();
  }

  Future<void> _run() async {
    setState(() { _loading = true; _error = null; });
    try {
      final meta = await OAuthService.fetchMetadata(_metaController.text.trim());
      setState(() { _json = meta; _loading = false; });
    } catch (e) {
      LoggerService.error('OAuth discovery failed: $e');
      setState(() { _loading = false; _error = '$e'; });
    }
  }

  Future<void> _register() async {
    if (_json == null) return;
    try {
      final parsed = OAuthService.parseMetadata(_json!);
      if (parsed.registrationEndpoint == null) return;
      final creds = await OAuthService.registerClient(
        registrationEndpoint: parsed.registrationEndpoint!,
        clientName: 'NoteSynapse',
        redirectUri: 'http://127.0.0.1:51791/callback',
        usePkce: widget.usePkce,
      );
      final scope = parsed.scopesSupported?.join(' ');
      if (mounted) {
        Navigator.pop(context, OAuthDiscoveryResultData(
          authorizationEndpoint: parsed.authorizationEndpoint,
          tokenEndpoint: parsed.tokenEndpoint,
          clientId: creds['client_id'],
          clientSecret: creds['client_secret'],
          defaultScope: scope,
          metadataUrl: _metaController.text.trim(),
        ));
      }
    } catch (e) {
      setState(() { _error = '$e'; });
    }
  }

  void _useWithoutRegistration() {
    if (_json == null) return;
    final parsed = OAuthService.parseMetadata(_json!);
    final scope = parsed.scopesSupported?.join(' ');
    Navigator.pop(context, OAuthDiscoveryResultData(
      authorizationEndpoint: parsed.authorizationEndpoint,
      tokenEndpoint: parsed.tokenEndpoint,
      defaultScope: scope,
      metadataUrl: _metaController.text.trim(),
    ));
  }

  @override
  Widget build(BuildContext context) {
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
                labelText: 'Metadata URL',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                ElevatedButton(onPressed: _loading ? null : _run, child: const Text('Run')),
                const SizedBox(width: 12),
                if (_json != null)
                  OutlinedButton(onPressed: _useWithoutRegistration, child: const Text('Use')),
                const SizedBox(width: 12),
                if (_json != null && (_json!['registration_endpoint'] != null || _json!['registrationEndpoint'] != null))
                  ElevatedButton(onPressed: _loading ? null : _register, child: const Text('Register')),
              ],
            ),
            const SizedBox(height: 12),
            if (_error != null)
              Text(_error!, style: const TextStyle(color: Colors.red)),
            Expanded(
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(6),
                ),
                padding: const EdgeInsets.all(12),
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : SingleChildScrollView(
                        child: Text(
                          _json == null ? 'No result yet' : const JsonEncoder.withIndent('  ').convert(_json),
                          style: const TextStyle(fontFamily: 'monospace'),
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}



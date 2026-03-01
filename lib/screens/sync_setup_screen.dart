import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:saf_util/saf_util.dart';
import '../l10n/app_localizations.dart';
import '../models/google_oauth_config.dart';
import '../services/oauth_service.dart';
import '../services/oauth_token_manager.dart';
import '../services/service_locator.dart';
import '../services/sync/android_saf_sync_provider.dart';
import '../services/sync/device_identity_service.dart';
import '../services/sync/google_drive_api_client.dart';
import '../services/sync/google_drive_sync_provider.dart';
import '../services/sync/sync_service.dart';
import '../services/sync/sync_storage_provider.dart';
import '../services/sync/folder_sync_provider.dart';
import 'sync_settings_screen.dart';

class SyncSetupScreen extends StatefulWidget {
  const SyncSetupScreen({super.key});

  @override
  State<SyncSetupScreen> createState() => _SyncSetupScreenState();
}

class _SyncSetupScreenState extends State<SyncSetupScreen> {
  // Provider selection
  String _selectedProvider = 'folder';

  // Folder provider
  String? _folderPath;
  String? _safTreeUri;

  // WebDAV provider
  final _webdavUrlController = TextEditingController();
  final _webdavUsernameController = TextEditingController();
  final _webdavPasswordController = TextEditingController();

  // Google Drive provider
  final _syncRootNameController = TextEditingController(text: 'Note Synapse');
  String? _gdriveEmail;        // set after successful OAuth
  bool _gdriveConnecting = false;

  // Encryption
  final _passphraseController = TextEditingController();
  final _confirmPassphraseController = TextEditingController();
  bool _skipEncryption = false;
  bool _obscurePassphrase = true;
  bool _obscureConfirmPassphrase = true;

  // State
  bool _isInitializing = false;
  String? _error;

  // Form key for validation
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _webdavUrlController.dispose();
    _webdavUsernameController.dispose();
    _webdavPasswordController.dispose();
    _syncRootNameController.dispose();
    _passphraseController.dispose();
    _confirmPassphraseController.dispose();
    super.dispose();
  }

  Future<void> _selectFolder() async {
    if (Platform.isAndroid) {
      final result = await SafUtil().pickDirectory(
        writePermission: true,
        persistablePermission: true,
      );
      if (result != null) {
        setState(() {
          _safTreeUri = result.uri;
          _folderPath = result.name;
        });
      }
    } else {
      final result = await FilePicker.platform.getDirectoryPath();
      if (result != null) {
        setState(() {
          _folderPath = result;
        });
      }
    }
  }

  Future<void> _initializeSync() async {
    // Validate folder selection (not a TextFormField, so check manually)
    if (_selectedProvider == 'folder' && _folderPath == null) {
      setState(() => _error = AppLocalizations.of(context)!.syncFolderRequired);
      return;
    }

    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isInitializing = true;
      _error = null;
    });

    try {
      final SyncStorageProvider provider;
      final String providerType;
      final String providerUri;

      if (_selectedProvider == 'folder') {
        if (Platform.isAndroid && _safTreeUri != null) {
          provider = AndroidSafSyncProvider(treeUri: _safTreeUri!);
          providerType = 'saf';
          providerUri = _safTreeUri!;
        } else {
          provider = FolderSyncProvider(rootPath: _folderPath!);
          providerType = 'folder';
          providerUri = _folderPath!;
        }
      } else if (_selectedProvider == 'gdrive') {
        if (_gdriveEmail == null) {
          setState(() => _error = AppLocalizations.of(context)!.syncGoogleDriveNotConnected);
          return;
        }
        final syncRootName = _syncRootNameController.text.trim();
        final tokenManager = OAuthTokenManager(
          endpointId: 'gdrive',
          config: kGoogleDriveOAuthConfig,
        );
        final apiClient = GoogleDriveApiClient(
          getAccessToken: () async {
            final token = await tokenManager.getAccessToken();
            if (token == null) throw GoogleDriveAuthException('No token');
            return token;
          },
        );
        final gdriveProvider = GoogleDriveSyncProvider(
          client: apiClient,
          syncRootName: syncRootName,
        );
        await gdriveProvider.initialize();
        provider = gdriveProvider;
        providerType = 'gdrive';
        providerUri = syncRootName;  // stored for restoreConfiguration()
      } else {
        throw UnimplementedError('WebDAV provider not yet implemented');
      }

      // Persist provider configuration for reconnecting on restart
      final identity = DeviceIdentityService();
      await identity.setSyncProviderType(providerType);
      await identity.setSyncProviderUri(providerUri);

      final syncService = getIt<SyncService>();
      await syncService.initializeSyncRoot(
        provider: provider,
        passphrase: _skipEncryption ? null : _passphraseController.text,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context)!.syncInitSuccess),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => const SyncSettingsScreen(),
          ),
        );
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) {
        setState(() => _isInitializing = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.syncSetupTitle),
        leading: const BackButton(),
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Header description
                Text(
                  l10n.syncSetupDescription,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 24),

                // Step 1: Provider Selection
                _buildSectionTitle(l10n.syncProviderSelection),
                const SizedBox(height: 8),
                _buildProviderSelectionCard(l10n, theme),
                const SizedBox(height: 16),

                // Step 2: Provider Configuration
                _buildSectionTitle(l10n.syncProviderConfiguration),
                const SizedBox(height: 8),
                if (_selectedProvider == 'folder')
                  _buildFolderConfigCard(l10n, theme)
                else if (_selectedProvider == 'webdav')
                  _buildWebDavConfigCard(l10n, theme)
                else if (_selectedProvider == 'gdrive')
                  _buildGoogleDriveConfigCard(l10n, theme),
                const SizedBox(height: 16),

                // Step 3: Encryption
                _buildSectionTitle(l10n.syncEncryption),
                const SizedBox(height: 8),
                _buildEncryptionCard(l10n, theme),
                const SizedBox(height: 24),

                // Error display
                if (_error != null) ...[
                  Card(
                    color: theme.colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Row(
                        children: [
                          Icon(
                            Icons.error_outline,
                            color: theme.colorScheme.onErrorContainer,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _error!,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onErrorContainer,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                // Step 4: Initialize Button
                SizedBox(
                  height: 48,
                  child: FilledButton.icon(
                    onPressed: _isInitializing ? null : _initializeSync,
                    icon: _isInitializing
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.sync),
                    label: Text(
                      _isInitializing
                          ? l10n.syncInitializing
                          : l10n.syncInitialize,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: Theme.of(context)
          .textTheme
          .titleMedium
          ?.copyWith(fontWeight: FontWeight.bold),
    );
  }

  Widget _buildProviderSelectionCard(AppLocalizations l10n, ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            RadioListTile<String>(
              title: Text(l10n.syncProviderFolder),
              subtitle: Text(l10n.syncProviderFolderDescription),
              value: 'folder',
              groupValue: _selectedProvider,
              onChanged: (value) =>
                  setState(() => _selectedProvider = value!),
              contentPadding: EdgeInsets.zero,
            ),
            RadioListTile<String>(
              title: Text(l10n.syncProviderWebDav),
              subtitle: Text(l10n.syncProviderWebDavDescription),
              value: 'webdav',
              groupValue: _selectedProvider,
              onChanged: (value) =>
                  setState(() => _selectedProvider = value!),
              contentPadding: EdgeInsets.zero,
            ),
            RadioListTile<String>(
              title: Text(l10n.syncProviderGoogleDrive),
              subtitle: Text(l10n.syncProviderGoogleDriveDescription),
              value: 'gdrive',
              groupValue: _selectedProvider,
              onChanged: (value) => setState(() => _selectedProvider = value!),
              contentPadding: EdgeInsets.zero,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFolderConfigCard(AppLocalizations l10n, ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.syncFolderSelectDescription,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: theme.colorScheme.outline.withValues(alpha: 0.5),
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _folderPath ?? l10n.syncFolderNotSelected,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: _folderPath != null
                            ? theme.colorScheme.onSurface
                            : theme.colorScheme.onSurfaceVariant,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonalIcon(
                  onPressed: _selectFolder,
                  icon: const Icon(Icons.folder_open),
                  label: Text(l10n.syncSelectFolder),
                ),
              ],
            ),
            // Validation: show error if folder not selected when submitting
            if (_error != null && _folderPath == null && _selectedProvider == 'folder')
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  l10n.syncFolderRequired,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildWebDavConfigCard(AppLocalizations l10n, ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextFormField(
              controller: _webdavUrlController,
              decoration: InputDecoration(
                labelText: l10n.syncWebDavUrl,
                hintText: 'https://dav.example.com/sync/',
                border: const OutlineInputBorder(),
              ),
              validator: (value) {
                if (_selectedProvider == 'webdav' &&
                    (value == null || value.isEmpty)) {
                  return l10n.syncWebDavUrlRequired;
                }
                return null;
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _webdavUsernameController,
              decoration: InputDecoration(
                labelText: l10n.syncWebDavUsername,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _webdavPasswordController,
              decoration: InputDecoration(
                labelText: l10n.syncWebDavPassword,
                border: const OutlineInputBorder(),
              ),
              obscureText: true,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEncryptionCard(AppLocalizations l10n, ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.syncEncryptionDescription,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            if (!_skipEncryption) ...[
              TextFormField(
                controller: _passphraseController,
                decoration: InputDecoration(
                  labelText: l10n.syncPassphrase,
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePassphrase
                          ? Icons.visibility_off
                          : Icons.visibility,
                    ),
                    onPressed: () => setState(
                      () => _obscurePassphrase = !_obscurePassphrase,
                    ),
                  ),
                ),
                obscureText: _obscurePassphrase,
                validator: (value) {
                  if (_skipEncryption) return null;
                  if (value == null || value.isEmpty) {
                    return l10n.syncPassphraseRequired;
                  }
                  if (value.length < 8) {
                    return l10n.syncPassphraseTooShort;
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _confirmPassphraseController,
                decoration: InputDecoration(
                  labelText: l10n.syncConfirmPassphrase,
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscureConfirmPassphrase
                          ? Icons.visibility_off
                          : Icons.visibility,
                    ),
                    onPressed: () => setState(
                      () => _obscureConfirmPassphrase =
                          !_obscureConfirmPassphrase,
                    ),
                  ),
                ),
                obscureText: _obscureConfirmPassphrase,
                validator: (value) {
                  if (_skipEncryption) return null;
                  if (value != _passphraseController.text) {
                    return l10n.syncPassphraseMismatch;
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
            ],
            CheckboxListTile(
              title: Text(l10n.syncSkipEncryption),
              value: _skipEncryption,
              onChanged: (value) =>
                  setState(() => _skipEncryption = value ?? false),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
            ),
            if (_skipEncryption)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: theme.colorScheme.error.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      color: theme.colorScheme.error,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l10n.syncSkipEncryptionWarning,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildGoogleDriveConfigCard(AppLocalizations l10n, ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextFormField(
              controller: _syncRootNameController,
              decoration: InputDecoration(
                labelText: l10n.syncGoogleDriveFolderName,
                hintText: 'Note Synapse',
                border: const OutlineInputBorder(),
              ),
              validator: (value) {
                if (_selectedProvider == 'gdrive' &&
                    (value == null || value.trim().isEmpty)) {
                  return l10n.syncGoogleDriveFolderNameRequired;
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            if (_gdriveEmail != null) ...[
              Row(
                children: [
                  const Icon(Icons.check_circle, color: Colors.green),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.syncGoogleDriveConnected(_gdriveEmail!),
                          style: theme.textTheme.bodyMedium,
                        ),
                        Text(
                          l10n.syncGoogleDriveSyncFolder(
                              _syncRootNameController.text.trim()),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: _gdriveConnecting ? null : _connectGoogleAccount,
                    child: Text(l10n.syncGoogleDriveReconnect),
                  ),
                ],
              ),
            ] else ...[
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _gdriveConnecting ? null : _connectGoogleAccount,
                  icon: _gdriveConnecting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.account_circle),
                  label: Text(l10n.syncGoogleDriveConnect),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _connectGoogleAccount() async {
    setState(() {
      _gdriveConnecting = true;
      _error = null;
    });
    try {
      final state = base64Url.encode(
        List<int>.generate(16, (_) => Random.secure().nextInt(256)),
      );
      final tokens = await OAuthService.authorizationCodeFlow(
        config: kGoogleDriveOAuthConfig,
        state: state,
      );

      // Store tokens
      final tokenManager = OAuthTokenManager(
        endpointId: 'gdrive',
        config: kGoogleDriveOAuthConfig,
      );
      await tokenManager.saveTokens(tokens);

      // Extract email from id_token JWT payload
      final idToken = tokens['id_token'] as String?;
      String? email;
      if (idToken != null) {
        final parts = idToken.split('.');
        if (parts.length == 3) {
          final payload = utf8.decode(
            base64Url.decode(base64Url.normalize(parts[1])),
          );
          final claims = jsonDecode(payload) as Map<String, dynamic>;
          email = claims['email'] as String?;
        }
      }

      if (mounted) {
        setState(() => _gdriveEmail = email ?? 'Google Account');
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _gdriveConnecting = false);
    }
  }
}

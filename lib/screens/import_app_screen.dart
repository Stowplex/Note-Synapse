import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:yaml/yaml.dart';
import 'package:http/http.dart' as http;
import '../providers/app_provider.dart';
import '../models/user_app.dart';
import '../models/app_revision.dart';
import '../services/database_service.dart';
import '../services/logger_service.dart';

class ImportAppScreen extends StatefulWidget {
  final String yamlFilePath;

  const ImportAppScreen({
    super.key,
    required this.yamlFilePath,
  });

  @override
  State<ImportAppScreen> createState() {
    return _ImportAppScreenState();
  }
}

class _ImportAppScreenState extends State<ImportAppScreen> {
  String _currentStatus = 'Reading YAML file...';
  double _progress = 0.0;
  bool _isComplete = false;
  bool _hasError = false;
  final List<String> _progressSteps = [];
  UserApp? _importedApp;

  @override
  void initState() {
    super.initState();
    LoggerService.debug('ImportAppScreen initState called with file: ${widget.yamlFilePath}');
    
    if (widget.yamlFilePath.isEmpty) {
      setState(() {
        _currentStatus = 'Error: YAML file path is empty';
        _hasError = true;
        _progressSteps.add('✗ Error: YAML file path is empty');
      });
      return;
    }
    
    _importApp();
  }

  Future<void> _importApp() async {
    try {
      setState(() {
        _currentStatus = 'Reading YAML file...';
        _progress = 0.1;
      });

      // Read and parse YAML file
      final yamlFile = File(widget.yamlFilePath);
      final yamlContent = await yamlFile.readAsString();
      final yamlData = loadYaml(yamlContent);
      
      // Convert YamlMap to Map<String, dynamic>
      final Map<String, dynamic> parsedData = {};
      if (yamlData is Map) {
        yamlData.forEach((key, value) {
          if (key is String) {
            parsedData[key] = value;
          }
        });
      } else {
        throw Exception('Invalid YAML format: expected a map');
      }

      setState(() {
        _currentStatus = 'Validating YAML structure...';
        _progress = 0.2;
        _progressSteps.add('✓ YAML file read successfully');
      });

      // Validate YAML structure
      _validateYamlStructure(parsedData);

      setState(() {
        _currentStatus = 'Processing app data...';
        _progress = 0.3;
        _progressSteps.add('✓ YAML structure validated');
      });

      // Extract app data
      final appData = _extractAppData(parsedData);

      setState(() {
        _currentStatus = 'Checking for existing app...';
        _progress = 0.4;
        _progressSteps.add('✓ App data extracted');
      });

      // Check if app with same UUID exists
      final databaseService = DatabaseService();
      final existingApps = await databaseService.getAllUserApps();
      final existingApp = existingApps.where((app) => app.uuid == appData['uuid']).firstOrNull;

      print('DEBUG: Found ${existingApps.length} existing apps');
      print('DEBUG: Looking for UUID: ${appData['uuid']}');
      print('DEBUG: Existing app found: ${existingApp != null}');

      if (existingApp != null) {
        setState(() {
          _currentStatus = 'Creating new revision...';
          _progress = 0.5;
          _progressSteps.add('✓ Found existing app, creating new revision');
        });

        // Create new revision for existing app
        await _createNewRevision(existingApp, appData, databaseService);
      } else {
        setState(() {
          _currentStatus = 'Creating new app...';
          _progress = 0.5;
          _progressSteps.add('✓ Creating new app');
        });

        // Create new app
        await _createNewApp(appData, databaseService);
      }
      
      print('DEBUG: After app creation, _importedApp is: ${_importedApp != null}');

      if (_importedApp != null) {
        setState(() {
          _currentStatus = 'Downloading dependencies...';
          _progress = 0.6;
        });

        // Download and store dependencies
        await _downloadDependencies(appData, databaseService);
      } else {
        setState(() {
          _currentStatus = 'Skipping dependencies (no app created)...';
          _progress = 0.8;
          _progressSteps.add('⚠ Skipped dependencies - no app created');
        });
      }

      setState(() {
        _currentStatus = 'Finalizing import...';
        _progress = 0.9;
        _progressSteps.add('✓ Dependencies downloaded and stored');
      });

      // Refresh the app provider
      final appProvider = context.read<AppProvider>();
      await appProvider.loadData();

      setState(() {
        _currentStatus = 'Import completed successfully!';
        _progress = 1.0;
        _isComplete = true;
        _progressSteps.add('✓ Import completed successfully');
      });

    } catch (e) {
      LoggerService.error('Error importing app: $e', error: e);
      setState(() {
        _currentStatus = 'Import failed';
        _hasError = true;
        _progressSteps.add('✗ Import failed: $e');
      });
    }
  }

  void _validateYamlStructure(Map<String, dynamic> yamlData) {
    final requiredFields = ['name', 'uuid', 'description', 'author', 'license', 'code'];
    
    for (final field in requiredFields) {
      if (!yamlData.containsKey(field)) {
        throw Exception('Missing required field: $field');
      }
    }

    if (yamlData['libraries'] != null) {
      final libraries = yamlData['libraries'];
      if (libraries is List) {
        for (final library in libraries) {
          if (library is! Map) {
            throw Exception('Invalid library structure');
          }
          final libraryMap = library;
          if (!libraryMap.containsKey('name') || !libraryMap.containsKey('dependencies')) {
            throw Exception('Library must have name and dependencies');
          }
        }
      } else {
        throw Exception('Libraries must be a list');
      }
    }
  }

  Map<String, dynamic> _extractAppData(Map<String, dynamic> yamlData) {
    return {
      'name': yamlData['name']?.toString() ?? '',
      'uuid': yamlData['uuid']?.toString() ?? '',
      'description': yamlData['description']?.toString() ?? '',
      'author': yamlData['author']?.toString() ?? '',
      'license': yamlData['license']?.toString() ?? '',
      'note_action': yamlData['note_action'] == true,
      'code': yamlData['code']?.toString() ?? '',
      'libraries': _convertLibraries(yamlData['libraries']),
    };
  }

  List<dynamic> _convertLibraries(dynamic libraries) {
    if (libraries == null) return [];
    if (libraries is! List) return [];
    
    return libraries.map((lib) {
      if (lib is Map) {
        final Map<String, dynamic> convertedLib = {};
        lib.forEach((key, value) {
          if (key is String) {
            if (key == 'dependencies' && value is List) {
              convertedLib[key] = value.map((dep) {
                if (dep is Map) {
                  final Map<String, dynamic> convertedDep = {};
                  dep.forEach((depKey, depValue) {
                    if (depKey is String) {
                      convertedDep[depKey] = depValue?.toString();
                    }
                  });
                  return convertedDep;
                }
                return dep;
              }).toList();
            } else {
              convertedLib[key] = value?.toString();
            }
          }
        });
        return convertedLib;
      }
      return lib;
    }).toList();
  }

  List<dynamic> _convertToList(dynamic value) {
    if (value == null) return [];
    if (value is List) return value;
    return [];
  }

  Future<void> _createNewApp(Map<String, dynamic> appData, DatabaseService databaseService) async {
    print('DEBUG: _createNewApp called');
    final appId = DateTime.now().millisecondsSinceEpoch.toString();
    final now = DateTime.now();

    // Decode base64 code
    final decodedCode = utf8.decode(base64Decode(appData['code']));
    print('DEBUG: Decoded code length: ${decodedCode.length}');

    final userApp = UserApp(
      id: appId,
      uuid: appData['uuid'],
      name: appData['name'],
      description: appData['description'],
      steps: ['Imported from YAML'],
      htmlContent: '', // No longer used - code is stored in revisions
      type: appData['note_action'] ? UserAppType.noteAction : UserAppType.normal,
      createdAt: now,
      updatedAt: now,
    );

    await databaseService.insertUserApp(userApp);

    // Create initial revision
    final revisionId = '${appId}_rev_1';
    final revision = AppRevision(
      id: revisionId,
      appId: appId,
      revisionNumber: 1,
      revisionTimestamp: now,
      userPrompt: 'Imported from YAML file',
      aiResponse: 'App imported successfully from YAML file',
      appCode: decodedCode,
      attachmentPaths: [],
    );

    await databaseService.insertAppRevision(revision);

    // Update app with selected revision
    final updatedApp = userApp.copyWith(selectedRevisionId: revisionId);
    await databaseService.updateUserApp(updatedApp);

    setState(() {
      _importedApp = updatedApp;
    });
    print('DEBUG: _createNewApp completed, _importedApp set to: ${_importedApp?.name}');
  }

  Future<void> _createNewRevision(UserApp existingApp, Map<String, dynamic> appData, DatabaseService databaseService) async {
    print('DEBUG: _createNewRevision called for app: ${existingApp.name}');
    // Get next revision number
    final nextRevisionNumber = await databaseService.getNextRevisionNumber(existingApp.id);
    final now = DateTime.now();
    print('DEBUG: Next revision number: $nextRevisionNumber');

    // Decode base64 code
    final decodedCode = utf8.decode(base64Decode(appData['code']));

    // Create new revision
    final revisionId = '${existingApp.id}_rev_$nextRevisionNumber';
    final revision = AppRevision(
      id: revisionId,
      appId: existingApp.id,
      revisionNumber: nextRevisionNumber,
      revisionTimestamp: now,
      userPrompt: 'Imported from YAML file',
      aiResponse: 'App revision imported successfully from YAML file',
      appCode: decodedCode,
      attachmentPaths: [],
    );

    await databaseService.insertAppRevision(revision);

    // Update app with new revision
    final updatedApp = existingApp.copyWith(
      selectedRevisionId: revisionId,
      updatedAt: now,
    );
    await databaseService.updateUserApp(updatedApp);

    setState(() {
      _importedApp = updatedApp;
    });
    print('DEBUG: _createNewRevision completed, _importedApp set to: ${_importedApp?.name}');
  }

  Future<void> _downloadDependencies(Map<String, dynamic> appData, DatabaseService databaseService) async {
    final libraries = _convertToList(appData['libraries']);
    
    for (int i = 0; i < libraries.length; i++) {
      final library = libraries[i];
      final libraryName = library['name']?.toString() ?? '';
      final dependencies = _convertToList(library['dependencies']);
      final instructions = library['instructions']?.toString();

      setState(() {
        _currentStatus = 'Downloading library: $libraryName...';
        _progress = 0.6 + (0.2 * (i + 1) / libraries.length);
        _progressSteps.add('Downloading: $libraryName');
      });

      // Create library entry
      int revisionId = 1;
      if (_importedApp?.selectedRevisionId != null) {
        final revisionIdStr = _importedApp!.selectedRevisionId!;
        final parts = revisionIdStr.split('_rev_');
        if (parts.length > 1) {
          revisionId = int.tryParse(parts.last) ?? 1;
        }
      }
      
      final libraryId = await databaseService.insertUserAppLibrary(
        appUuid: appData['uuid'],
        revisionId: revisionId,
        name: libraryName,
        usageInstructions: instructions,
      );

      // Download dependencies
      for (int j = 0; j < dependencies.length; j++) {
        final dependency = dependencies[j];
        final link = dependency['link']?.toString() ?? '';

        setState(() {
          _currentStatus = 'Downloading: ${Uri.parse(link).pathSegments.last}...';
          _progress = 0.6 + (0.2 * (i + 1) / libraries.length) + (0.1 * (j + 1) / dependencies.length);
          _progressSteps.add('Downloading: ${Uri.parse(link).pathSegments.last}');
        });

        try {
          final response = await http.get(Uri.parse(link));
          if (response.statusCode == 200) {
            final bytes = response.bodyBytes;
            final localPath = Uri.parse(link).path;

            await databaseService.insertUserAppLibraryDependency(
              originalUrl: link,
              localPath: localPath,
              bytes: bytes,
              libraryId: libraryId,
            );

            setState(() {
              _progressSteps.add('  ✓ Downloaded: $localPath');
            });
          } else {
            setState(() {
              _progressSteps.add('  ✗ Failed to download: $link (Status: ${response.statusCode})');
            });
          }
        } catch (e) {
          setState(() {
            _progressSteps.add('  ✗ Error downloading $link: $e');
          });
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Import App'),
        automaticallyImplyLeading: false,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            // Progress section
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Import Progress',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    LinearProgressIndicator(
                      value: _progress,
                      backgroundColor: Colors.grey[300],
                      valueColor: AlwaysStoppedAnimation<Color>(
                        _hasError ? Colors.red : Colors.blue,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${(_progress * 100).toInt()}%',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _currentStatus,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            
            // Log section
            Expanded(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Import Log',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          IconButton(
                            icon: const Icon(Icons.copy),
                            onPressed: () => _copyLogToClipboard(),
                            tooltip: 'Copy log',
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.grey[900],
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.grey[700]!),
                          ),
                          child: SingleChildScrollView(
                            child: SelectableText(
                              _getLogContent(),
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
              ),
            ),
            const SizedBox(height: 16),
            
            // Close button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () => Navigator.of(context).pop(),
                icon: Icon(
                  _isComplete && !_hasError ? Icons.check : Icons.close,
                  color: _isComplete && !_hasError ? Colors.white : Colors.white,
                ),
                label: Text(
                  'Close ${_isComplete && !_hasError ? '✓' : '✗'}',
                  style: const TextStyle(color: Colors.white),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isComplete && !_hasError ? Colors.green : Colors.red,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _getLogContent() {
    final buffer = StringBuffer();
    buffer.writeln('Importing from File: ${widget.yamlFilePath}');
    buffer.writeln('');
    
    for (final step in _progressSteps) {
      buffer.writeln(step);
    }
    
    if (_hasError) {
      buffer.writeln('');
      buffer.writeln('Error: $_currentStatus');
    } else if (_isComplete) {
      buffer.writeln('');
      buffer.writeln('Import complete!');
    }
    
    return buffer.toString();
  }

  void _copyLogToClipboard() {
    Clipboard.setData(ClipboardData(text: _getLogContent()));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Log copied to clipboard'),
        duration: Duration(seconds: 2),
      ),
    );
  }
}

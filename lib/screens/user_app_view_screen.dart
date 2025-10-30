import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:file_picker/file_picker.dart';
import 'package:uuid/uuid.dart';
import '../l10n/app_localizations.dart';
import '../providers/app_provider.dart';
import '../models/user_app.dart';
import '../models/app_revision.dart';
import '../models/note.dart';
import '../services/user_app_service.dart';
import '../services/ai_service.dart';
import '../services/database_service.dart';
import '../services/logger_service.dart';
import '../utils/file_utils.dart';
import '../utils/file_type_utils.dart';
import 'user_app_edit_screen.dart';
import 'note_detail_screen.dart';

class UserAppViewScreen extends StatefulWidget {
  final UserApp app;
  final List<Note>? selectedNotes;

  const UserAppViewScreen({
    super.key,
    required this.app,
    this.selectedNotes,
  });

  @override
  State<UserAppViewScreen> createState() => _UserAppViewScreenState();
}

class _UserAppViewScreenState extends State<UserAppViewScreen> {
  List<String> _consoleOutput = [];
  bool _isLoading = true;
  AppRevision? _selectedRevision;
  bool _showRevisionDetails = false;

  @override
  void initState() {
    super.initState();
    _validateNoteActionApp();
    _loadRevisions();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Update selected revision when provider data changes
    final appProvider = context.watch<AppProvider>();
    final currentApp = appProvider.userApps.firstWhere(
      (app) => app.id == widget.app.id,
      orElse: () => widget.app,
    );
    final revisions = appProvider.appRevisions[widget.app.id] ?? [];
    
    // If the provider's selected revision is different from our local state, update it
    if (currentApp.selectedRevisionId != null && 
        _selectedRevision?.id != currentApp.selectedRevisionId) {
      try {
        final newSelectedRevision = revisions.firstWhere(
          (r) => r.id == currentApp.selectedRevisionId,
        );
        setState(() {
          _selectedRevision = newSelectedRevision;
        });
        LoggerService.debug('Updated selected revision from provider: ${newSelectedRevision.id}');
      } catch (e) {
        LoggerService.warning('Selected revision not found in provider data: ${currentApp.selectedRevisionId}');
      }
    }
  }

  Future<void> _loadRevisions() async {
    try {
      final appProvider = context.read<AppProvider>();
      await appProvider.getAppRevisions(widget.app.id);
      
      // Get the current app from provider (it will be updated after editing)
      final currentApp = appProvider.userApps.firstWhere(
        (app) => app.id == widget.app.id,
        orElse: () => widget.app,
      );
      
      // Get revisions from provider (already sorted consistently)
      final revisions = appProvider.appRevisions[widget.app.id] ?? [];
      
      setState(() {
        if (currentApp.selectedRevisionId != null) {
          try {
            _selectedRevision = revisions.firstWhere(
              (r) => r.id == currentApp.selectedRevisionId,
            );
          } catch (e) {
            LoggerService.warning('Selected revision not found, using latest');
            _selectedRevision = revisions.isNotEmpty ? revisions.last : null; // Use last (highest revision number)
          }
        } else if (revisions.isNotEmpty) {
          _selectedRevision = revisions.last; // Use last (highest revision number)
        } else {
          _selectedRevision = null;
        }
        _isLoading = false;
      });
    } catch (e) {
      LoggerService.error('Error loading revisions: $e', error: e);
      setState(() {
        _selectedRevision = null;
        _isLoading = false;
      });
    }
  }

  Future<void> _refreshAppData() async {
    // Simply reload revisions - the provider handles all state management
    await _loadRevisions();
  }

  void _validateNoteActionApp() {
    if (widget.app.type == UserAppType.noteAction) {
      if (widget.selectedNotes == null || widget.selectedNotes!.isEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _showNoteSelectionDialog();
        });
      }
    }
  }

  void _showNoteSelectionDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Note Selection Required'),
        content: const Text(
          'This Note Action App requires at least one note to be selected. Please go back and select notes first.',
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop(); // Close dialog
              Navigator.of(context).pop(); // Go back to previous screen
            },
            child: const Text('Go Back'),
          ),
        ],
      ),
    );
  }

  void _selectRevision(AppRevision revision) {
    setState(() {
      _selectedRevision = revision;
      _showRevisionDetails = false;
    });
    LoggerService.debug('Selected revision: ${revision.id} (revision ${revision.revisionNumber})');
  }

  void _toggleRevisionDetails(AppRevision revision) {
    setState(() {
      _selectedRevision = revision;
      _showRevisionDetails = true;
    });
  }


  Future<void> _pinRevision(AppRevision revision) async {
    try {
      final appProvider = context.read<AppProvider>();
      await appProvider.setSelectedRevision(widget.app.id, revision.id);
      
      // The provider will notify listeners and the UI will update automatically
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Revision ${revision.revisionNumber} pinned'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error pinning revision: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _deleteRevision(AppRevision revision) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Revision'),
        content: Text('Are you sure you want to delete revision ${revision.revisionNumber}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        final appProvider = context.read<AppProvider>();
        await appProvider.deleteAppRevision(revision.id);
        
        // The provider will notify listeners and the UI will update automatically
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Revision ${revision.revisionNumber} deleted'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          String errorMessage = 'Error deleting revision: $e';
          if (e.toString().contains('Cannot delete the only remaining revision')) {
            errorMessage = 'Cannot delete the only remaining revision. At least one revision must exist.';
          }
          
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(errorMessage),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final appProvider = context.watch<AppProvider>();
    
    // Get current app and revisions from provider
    final currentApp = appProvider.userApps.firstWhere(
      (app) => app.id == widget.app.id,
      orElse: () => widget.app,
    );
    final revisions = appProvider.appRevisions[widget.app.id] ?? [];
    
    // Check if WebView is supported
    if (!UserAppService.isWebViewSupported()) {
      return _buildWebViewNotSupportedScreen(context, l10n);
    }

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.app.name),
            if (widget.app.type == UserAppType.noteAction && widget.selectedNotes != null)
              Text(
                '${widget.selectedNotes!.length} notes selected',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Colors.white70,
                ),
              ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.code),
            onPressed: () => _showConsole(context),
            tooltip: l10n.console,
          ),
          IconButton(
            icon: const Icon(Icons.edit),
            onPressed: () => _navigateToEdit(context),
            tooltip: l10n.edit,
          ),
          IconButton(
            icon: const Icon(Icons.delete),
            onPressed: () => _showDeleteDialog(context, l10n),
            tooltip: l10n.delete,
          ),
        ],
      ),
      body: Column(
        children: [
          // Revision tabs
          if (revisions.isNotEmpty)
            Container(
              height: 60,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                border: Border(
                  bottom: BorderSide(
                    color: Theme.of(context).dividerColor,
                    width: 1,
                  ),
                ),
              ),
              child: Row(
                children: [
                  // Revision numbers on the left
                  Expanded(
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.only(left: 8.0, right: 16.0),
                      itemCount: revisions.length,
                      itemBuilder: (context, index) {
                        final revision = revisions[index];
                        final isSelected = _selectedRevision?.id == revision.id;
                        final isPinned = currentApp.selectedRevisionId == revision.id;
                        
                        return Container(
                          margin: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 8.0),
                          child: GestureDetector(
                            onTap: () => _selectRevision(revision),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 8.0),
                              decoration: BoxDecoration(
                                color: isSelected 
                                    ? Theme.of(context).colorScheme.primary
                                    : Theme.of(context).colorScheme.surface,
                                borderRadius: BorderRadius.circular(8.0),
                                border: Border.all(
                                  color: isSelected 
                                      ? Theme.of(context).colorScheme.primary
                                      : Theme.of(context).dividerColor,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    '${revision.revisionNumber}',
                                    style: TextStyle(
                                      color: isSelected 
                                          ? Theme.of(context).colorScheme.onPrimary
                                          : Theme.of(context).colorScheme.onSurface,
                                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                    ),
                                  ),
                                  if (isPinned) ...[
                                    const SizedBox(width: 4),
                                    Icon(
                                      Icons.push_pin,
                                      size: 12,
                                      color: isSelected 
                                          ? Theme.of(context).colorScheme.onPrimary
                                          : Theme.of(context).colorScheme.primary,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  // Action buttons on the right
                  if (_selectedRevision != null)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // AI Response button
                        IconButton(
                          onPressed: () => _toggleRevisionDetails(_selectedRevision!),
                          icon: Icon(
                            _showRevisionDetails ? Icons.web : Icons.chat,
                            size: 16,
                          ),
                          tooltip: _showRevisionDetails ? 'Show App' : 'Show AI Response',
                          padding: const EdgeInsets.all(4),
                          constraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 32,
                          ),
                        ),
                        // Pin button
                        IconButton(
                          onPressed: () => _pinRevision(_selectedRevision!),
                          icon: Icon(
                            currentApp.selectedRevisionId == _selectedRevision!.id 
                                ? Icons.push_pin 
                                : Icons.push_pin_outlined,
                            size: 16,
                          ),
                          tooltip: currentApp.selectedRevisionId == _selectedRevision!.id 
                              ? 'Unpin Revision' 
                              : 'Pin Revision',
                          padding: const EdgeInsets.all(4),
                          constraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 32,
                          ),
                        ),
                        // Delete button
                        IconButton(
                          onPressed: () => _deleteRevision(_selectedRevision!),
                          icon: const Icon(Icons.delete, size: 16),
                          tooltip: 'Delete Revision',
                          padding: const EdgeInsets.all(4),
                          constraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 32,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          // Main content area
          Expanded(
            child: _showRevisionDetails && _selectedRevision != null
                ? _buildRevisionDetailsView()
                : _buildWebView(),
          ),
        ],
      ),
    );
  }

  Widget _buildWebView() {
    final htmlData = _selectedRevision?.appCode ?? '';
    LoggerService.debug('WebView loading data: ${htmlData.length} characters');
    LoggerService.debug('Using revision: ${_selectedRevision?.id ?? 'none'} (revision ${_selectedRevision?.revisionNumber ?? 'N/A'})');
    LoggerService.debug('Data preview: ${htmlData.substring(0, htmlData.length > 200 ? 200 : htmlData.length)}...');
    LoggerService.debug('WebView key: ${_selectedRevision?.id ?? 'app_${widget.app.id}'}');
    
    return Stack(
        children: [
          InAppWebView(
            key: ValueKey(_selectedRevision?.id ?? 'app_${widget.app.id}'), // Force rebuild when revision changes
            initialData: InAppWebViewInitialData(
            data: htmlData,
              mimeType: 'text/html',
              encoding: 'utf8',
            ),
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              domStorageEnabled: true,
              databaseEnabled: true,
              clearCache: true,
              cacheEnabled: true,
              supportZoom: true,
              builtInZoomControls: true,
              displayZoomControls: false,
              resourceCustomSchemes: ['synapse', 'synapseuser'],
            ),
            onLoadResourceWithCustomScheme: (controller, request) async {
              LoggerService.debug('onLoadResourceWithCustomScheme: ${request.url} - ${request.url.path}');
              if (request.url.scheme.toLowerCase() == 'synapse') {
                final data = await rootBundle.loadString("assets/scripts/${request.url.host}");
                return CustomSchemeResponse(
                  contentType: 'text/plain',
                  data: Uint8List.fromList(utf8.encode(data)),
                );
              } else if (request.url.scheme.toLowerCase() == 'synapseuser') {
                print("handling synapseuser scheme: ${request.url}");
                return await _handleSynapseUserScheme(request);
              }
              return null;            
            },
            initialUserScripts: UnmodifiableListView<UserScript>([
              _createInitialUserScript(),
            ]),
            onWebViewCreated: (controller) {
              _setupJavaScriptHandlers(controller);
            },
            onLoadStart: (controller, url) {
              setState(() {
                _isLoading = true;
              });
            },
            onLoadStop: (controller, url) {
              setState(() {
                _isLoading = false;
              });
              
              // Override navigator.clipboard.writeText for Android clipboard fix
              controller.evaluateJavascript(
                source: '''
                  if (!navigator.clipboard) {
                    navigator.clipboard = {
                      writeText: (msg) => {
                        return window.flutter_inappwebview?.callHandler("copy-to-clipboard", msg);
                      }
                    };
                  } else {
                    navigator.clipboard.writeText = (msg) => { 
                      return window.flutter_inappwebview?.callHandler("copy-to-clipboard", msg); 
                    };
                  }

                  
                  // Fallback for older browsers - create a global copy function
                  window.copyToClipboard = (text) => {
                    return window.flutter_inappwebview?.callHandler("copy-to-clipboard", text);
                  };
                  
                  // Override common copy functions
                  if (typeof document !== 'undefined') {
                    const originalExecCommand = document.execCommand;
                    document.execCommand = function(command, showUI, value) {
                      if (command === 'copy' && value) {
                        return window.flutter_inappwebview?.callHandler("copy-to-clipboard", value);
                      }
                      return originalExecCommand.call(this, command, showUI, value);
                    };
                  }
                '''
              );
            },
            onConsoleMessage: (controller, consoleMessage) {
              setState(() {
                _consoleOutput.add('${consoleMessage.messageLevel}: ${consoleMessage.message}');
              });
            },
            onReceivedError: (controller, request, error) {
              setState(() {
                _consoleOutput.add('ERROR: ${error.description}');
              });
            },
          ),
          if (_isLoading)
            const Center(
              child: CircularProgressIndicator(),
            ),
      ],
    );
  }

  Widget _buildRevisionDetailsView() {
    if (_selectedRevision == null) return const SizedBox.shrink();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with revision info
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'Revision ${_selectedRevision!.revisionNumber}',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const Spacer(),
                      Text(
                        '${_selectedRevision!.revisionTimestamp.day}/${_selectedRevision!.revisionTimestamp.month}/${_selectedRevision!.revisionTimestamp.year}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.grey[600],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'User Prompt:',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    height: 120, // Fixed height for user prompt
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(4.0),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: SingleChildScrollView(
                        child: Text(
                          _selectedRevision!.userPrompt,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            fontFamily: 'monospace',
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  ),
                  // Show attached images below the user prompt
                  if (_selectedRevision!.attachmentPaths.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Attached Images:',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8.0,
                      runSpacing: 8.0,
                      children: _selectedRevision!.attachmentPaths.map((path) {
                        return GestureDetector(
                          onTap: () => FileUtils.openFile(path, context),
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8.0),
                              border: Border.all(
                                color: Colors.grey.withOpacity(0.3),
                                width: 1,
                              ),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(7.0),
                              child: Image.file(
                                File(path),
                                width: 80,
                                height: 80,
                                fit: BoxFit.cover,
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          // AI Response - Fixed height with scrollable content
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'AI Response:',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: double.infinity,
                    height: 400, // Fixed height
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(4.0),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: SingleChildScrollView(
                        child: Text(
                          _selectedRevision!.aiResponse,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            fontFamily: 'monospace',
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWebViewNotSupportedScreen(BuildContext context, AppLocalizations l10n) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.app.name),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.web_asset_off,
                size: 64,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 16),
              Text(
                l10n.webViewNotSupported,
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                l10n.webViewNotSupportedDescription,
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Create the initial user script for Synapse API injection
  UserScript _createInitialUserScript() {
    // Convert selected notes to JSON for JavaScript
    String notesJson = '[]';
    if (widget.selectedNotes != null && widget.selectedNotes!.isNotEmpty) {
      final notesData = widget.selectedNotes!.map((note) => {
        'id': note.id,
        'title': note.title,
        'content': note.content,
        'tags': note.tags,
        'createdAt': note.createdAt.toIso8601String(),
        'updatedAt': note.updatedAt.toIso8601String(),
        'isTask': note.isTask,
        'status': note.isTask ? note.status.toString() : null,
        'pinned': note.pinned,
        'isArchived': note.isArchived,
        'attachmentPaths': note.attachmentPaths,
      }).toList();
      notesJson = jsonEncode(notesData);
    }

    return UserScript(
      source: '''
        // Override console.log to also send to Flutter
        const originalConsoleLog = console.log;
        const originalConsoleError = console.error;
        const originalConsoleWarn = console.warn;
        
        console.log = function(...args) {
          const msg = args.map((arg) => JSON.stringify(arg, null, 2)).join('\\n');
          originalConsoleLog(msg);
          window.flutter_inappwebview.callHandler('log', msg, 'LOG');
        };
        
        console.error = function(...args) {
          const msg = args.map((arg) => JSON.stringify(arg, null, 2)).join('\\n');
          originalConsoleError(msg);
          window.flutter_inappwebview.callHandler('log', msg, 'ERROR');
        };
        
        console.warn = function(...args) {
          const msg = args.map((arg) => JSON.stringify(arg, null, 2)).join('\\n');
          originalConsoleError(msg);
          window.flutter_inappwebview.callHandler('log', msg, 'WARN');
        };
        
        window.Synapse = {
          /**
           * Execute a SQL query on the database
           * @param {string} sql - SQL query to execute
           * @returns {Promise<{success: boolean, data?: Array, error?: string}>}
           */
          runQuery: async (sql) => {
            const result = await window.flutter_inappwebview.callHandler('runQuery', sql);
            return result;
          },
          
          /**
           * Store application state
           * @param {Object} state - State object to store
           * @returns {Promise<{success: boolean, error?: string}>}
           */
          storeAppState: async (state) => {
            const result = await window.flutter_inappwebview.callHandler('storeAppState', state);
            return result;
          },
          
          /**
           * Load application state
           * @returns {Promise<{success: boolean, data?: Object, error?: string}>}
           */
          loadAppState: async () => {
            const result = await window.flutter_inappwebview.callHandler('loadAppState');
            return result;
          },
          
          /**
           * Chat with AI using configurable parameters
           * @param {string} prompt - The prompt to send to the AI
           * @param {Object} [options={}] - Configuration options
           * @param {number} [options.temperature] - Temperature (0.0 to 1.0), controls randomness
           * @param {number} [options.topK] - Top-K (1 to 100), number of tokens to consider
           * @param {number} [options.topP] - Top-P (0.0 to 1.0), nucleus sampling parameter
           * @param {(string|Object)[]} [options.attachments] - Array of attachment file paths or base64 data objects
           * @returns {Promise<{success: boolean, response?: string, error?: string}>}
           * 
           * @example
           * // Basic usage
           * const result = await Synapse.chatAI('Hello, world!');
           * 
           * @example
           * // With parameters and file path attachments
           * const result = await Synapse.chatAI('Explain quantum computing', {
           *   temperature: 0.7,
           *   topK: 40,
           *   topP: 0.9,
           *   attachments: ['/path/to/image.jpg']
           * });
           * 
           * @example
           * // With mixed attachment types
           * const result = await Synapse.chatAI('Analyze these images', {
           *   attachments: [
           *     '/path/to/image1.jpg',  // File path
           *     {                      // Base64 data object
           *       type: 'base64',
           *       mimeType: 'image/png',
           *       data: 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAA...'
           *     }
           *   ]
           * });
           */
          chatAI: async (prompt, options = {}) => {
            // Parameter validation and type conversion for JavaScript side
            const validatedOptions = {};
            
            // Validate and convert temperature (number, 0.0 to 1.0)
            if (options.temperature !== undefined) {
              const temp = Number(options.temperature);
              if (isNaN(temp) || temp < 0 || temp > 1) {
                throw new Error('Parameter validation failed: temperature must be a number between 0.0 and 1.0, got ' + options.temperature);
              }
              validatedOptions.temperature = temp;
            }
            
            // Validate and convert topK (integer, 1 to 100)
            if (options.topK !== undefined) {
              const topK = Number(options.topK);
              if (isNaN(topK) || !Number.isInteger(topK) || topK < 1 || topK > 100) {
                throw new Error('Parameter validation failed: topK must be an integer between 1 and 100, got ' + options.topK);
              }
              validatedOptions.topK = topK;
            }
            
            // Validate and convert topP (number, 0.0 to 1.0)
            if (options.topP !== undefined) {
              const topP = Number(options.topP);
              if (isNaN(topP) || topP < 0 || topP > 1) {
                throw new Error('Parameter validation failed: topP must be a number between 0.0 and 1.0, got ' + options.topP);
              }
              validatedOptions.topP = topP;
            }
            
            // Validate attachments (array of strings or base64 objects)
            if (options.attachments !== undefined) {
              if (!Array.isArray(options.attachments)) {
                throw new Error('Parameter validation failed: attachments must be an array, got ' + typeof options.attachments);
              }
              
              // Validate each attachment element
              for (let i = 0; i < options.attachments.length; i++) {
                const attachment = options.attachments[i];
                if (typeof attachment === 'string') {
                  // File path - validate it's a non-empty string
                  if (attachment.trim() === '') {
                    throw new Error('Parameter validation failed: attachment at index ' + i + ' is an empty string');
                  }
                } else if (typeof attachment === 'object' && attachment !== null) {
                  // Base64 object - validate required properties
                  if (attachment.type !== 'base64') {
                    throw new Error('Parameter validation failed: attachment at index ' + i + ' has invalid type property, expected \\'base64\\', got \\'' + attachment.type + '\\'');
                  }
                  if (typeof attachment.mimeType !== 'string' || attachment.mimeType.trim() === '') {
                    throw new Error('Parameter validation failed: attachment at index ' + i + ' has invalid mimeType property, must be a non-empty string');
                  }
                  if (typeof attachment.data !== 'string' || attachment.data.trim() === '') {
                    throw new Error('Parameter validation failed: attachment at index ' + i + ' has invalid data property, must be a non-empty string');
                  }
                } else {
                  throw new Error('Parameter validation failed: attachment at index ' + i + ' must be a string (file path) or object (base64 data), got ' + typeof attachment);
                }
              }
              
              validatedOptions.attachments = options.attachments;
            }
            
            const result = await window.flutter_inappwebview.callHandler('chatAI', prompt, validatedOptions);
            return result;
          },
          
          /**
           * Read an attachment file and return its base64 encoded data
           * @param {string} attachmentPath - Path to the attachment file
           * @returns {Promise<{success: boolean, data?: string, mimeType?: string, error?: string}>}
           * 
           * @example
           * // Read an attachment
           * const result = await Synapse.readAttachment('/path/to/image.jpg');
           * if (result.success) {
           *   console.log('MIME type:', result.mimeType);
           *   console.log('Base64 data:', result.data);
           * }
           */
          readAttachment: async (attachmentPath) => {
            if (typeof attachmentPath !== 'string' || attachmentPath.trim() === '') {
              throw new Error('Parameter validation failed: attachmentPath must be a non-empty string');
            }
            
            const result = await window.flutter_inappwebview.callHandler('readAttachment', attachmentPath);
            return result;
          },
          
          /**
           * Save new notes to the database
           * @param {Array} notes - Array of note objects to save (IDs will be generated automatically)
           * @returns {Promise<{success: boolean, savedCount?: number, error?: string}>}
           * 
           * @example
           * // Basic usage
           * const result = await Synapse.saveNotes([
           *   {
           *     title: 'My Note',
           *     content: 'Note content', // Required
           *     type: 'note',
           *     subNotes: [],
           *     attachments: ['file:///path/to/file.jpg'] // File URI
           *   }
           * ]);
           * 
           * @example
           * // With base64 attachments
           * const result = await Synapse.saveNotes([
           *   {
           *     title: 'Note with Base64',
           *     content: 'Note content', // Required
           *     type: 'task',
           *     subNotes: [
           *       {
           *         name: 'Sub Task',
           *         content: 'Sub task content',
           *         isCompleted: false
           *       }
           *     ],
           *     attachments: [
           *       {
           *         type: 'base64',
           *         data: 'data:image/jpeg;base64,/9j/4AAQSkZJRgABAQAAAQ...',
           *         fileName: 'image.jpg'
           *       }
           *     ],
           *     status: 'todo',
           *     completionPercentage: 0.0,
           *     pinned: false,
           *     isArchived: false
           *   }
           * ]);
           */
          saveNotes: async (notes) => {
            if (!Array.isArray(notes)) {
              throw new Error('Parameter validation failed: notes must be an array, got ' + typeof notes);
            }
            
            const result = await window.flutter_inappwebview.callHandler('saveNotes', notes);
            return result;
          },
          
          /**
           * Open a note natively on the platform
           * @param {string} noteId - ID of the note to open
           * @param {boolean} [replaceWindow=false] - If true, replaces the current view with the note view
           * @returns {Promise<{success: boolean, error?: string}>}
           * 
           * @example
           * // Open note in new view
           * const result = await Synapse.openNote('note-id-123');
           * 
           * @example
           * // Replace current view with note view
           * const result = await Synapse.openNote('note-id-123', true);
           */
          openNote: async (noteId, replaceWindow = false) => {
            if (typeof noteId !== 'string' || noteId.trim() === '') {
              throw new Error('Parameter validation failed: noteId must be a non-empty string');
            }
            if (typeof replaceWindow !== 'boolean') {
              throw new Error('Parameter validation failed: replaceWindow must be a boolean');
            }
            
            const result = await window.flutter_inappwebview.callHandler('openNote', noteId, replaceWindow);
            return result;
          },
          Notes: $notesJson
        };
      ''',
      injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
    );
  }

  void _setupJavaScriptHandlers(InAppWebViewController controller) {
    // Add JavaScript handlers for the Synapse API
    controller.addJavaScriptHandler(
      handlerName: 'runQuery',
      callback: (args) async {
        final startTime = DateTime.now();
        try {
          final sql = args[0] as String;
          LoggerService.debug('[Synapse.runQuery] Called with SQL: $sql');
          
          // Execute the SQL query using the database service
          final result = await _executeSQLQuery(sql);
          final duration = DateTime.now().difference(startTime);
          
          LoggerService.debug('[Synapse.runQuery] Success - Returned ${result.length} rows in ${duration.inMilliseconds}ms');
          
          return {'success': true, 'data': result};
        } catch (e) {
          final duration = DateTime.now().difference(startTime);
          LoggerService.error('[Synapse.runQuery] Error after ${duration.inMilliseconds}ms: $e', error: e);
          return {'success': false, 'error': e.toString()};
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'storeAppState',
      callback: (args) async {
        final startTime = DateTime.now();
        try {
          final state = args[0] as Map<String, dynamic>;
          LoggerService.debug('[Synapse.storeAppState] Called with state keys: ${state.keys.toList()}');
          
          final appProvider = context.read<AppProvider>();
          await appProvider.saveAppState(widget.app.id, state);
          final duration = DateTime.now().difference(startTime);
          
          LoggerService.debug('[Synapse.storeAppState] Success - State saved in ${duration.inMilliseconds}ms');
          
          return {'success': true};
        } catch (e) {
          final duration = DateTime.now().difference(startTime);
          LoggerService.error('[Synapse.storeAppState] Error after ${duration.inMilliseconds}ms: $e', error: e);
          return {'success': false, 'error': e.toString()};
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'loadAppState',
      callback: (args) async {
        final startTime = DateTime.now();
        try {
          LoggerService.debug('[Synapse.loadAppState] Called for app: ${widget.app.id}');
          
          final appProvider = context.read<AppProvider>();
          final state = await appProvider.getAppState(widget.app.id);
          final duration = DateTime.now().difference(startTime);
          
          if (state != null) {
            LoggerService.debug('[Synapse.loadAppState] Success - State loaded with keys: ${state.keys.toList()} in ${duration.inMilliseconds}ms');
          } else {
            LoggerService.debug('[Synapse.loadAppState] Success - No state found in ${duration.inMilliseconds}ms');
          }
          
          return {'success': true, 'data': state};
        } catch (e) {
          final duration = DateTime.now().difference(startTime);
          LoggerService.error('[Synapse.loadAppState] Error after ${duration.inMilliseconds}ms: $e', error: e);
          return {'success': false, 'error': e.toString()};
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'chatAI',
      callback: (args) async {
        final startTime = DateTime.now();
        try {
          final prompt = args[0] as String;
          final options = args.length > 1 ? args[1] as Map<String, dynamic>? : <String, dynamic>{};
          LoggerService.debug('[Synapse.chatAI] Called with prompt: ${prompt.length > 100 ? prompt.substring(0, 100) + '...' : prompt}');
          LoggerService.debug('[Synapse.chatAI] Raw options received: $options');
          
          // Extract and validate optional parameters with explicit type checking
          double? temperature;
          int? topK;
          double? topP;
          List<dynamic>? attachmentPaths;
          
          // Validate temperature parameter
          if (options?.containsKey('temperature') == true) {
            final tempValue = options!['temperature'];
            if (tempValue is double) {
              temperature = tempValue;
            } else if (tempValue is int) {
              temperature = tempValue.toDouble();
            } else {
              throw Exception('Parameter validation failed: temperature must be a number (double or int), got ${tempValue.runtimeType}');
            }
          }
          
          // Validate topK parameter - must be integer
          if (options?.containsKey('topK') == true) {
            final topKValue = options!['topK'];
            if (topKValue is int) {
              topK = topKValue;
            } else if (topKValue is double && topKValue == topKValue.roundToDouble()) {
              topK = topKValue.round();
            } else {
              throw Exception('Parameter validation failed: topK must be an integer, got ${topKValue.runtimeType} with value $topKValue');
            }
          }
          
          // Validate topP parameter - must be double between 0 and 1
          if (options?.containsKey('topP') == true) {
            final topPValue = options!['topP'];
            if (topPValue is double) {
              if (topPValue >= 0.0 && topPValue <= 1.0) {
                topP = topPValue;
              } else {
                throw Exception('Parameter validation failed: topP must be between 0.0 and 1.0, got $topPValue');
              }
            } else if (topPValue is int) {
              final doubleValue = topPValue.toDouble();
              if (doubleValue >= 0.0 && doubleValue <= 1.0) {
                topP = doubleValue;
              } else {
                throw Exception('Parameter validation failed: topP must be between 0.0 and 1.0, got $doubleValue');
              }
            } else {
              throw Exception('Parameter validation failed: topP must be a number between 0.0 and 1.0, got ${topPValue.runtimeType}');
            }
          }
          
          // Validate attachments parameter
          if (options?.containsKey('attachments') == true) {
            final attachmentsValue = options!['attachments'];
            if (attachmentsValue is List) {
              attachmentPaths = attachmentsValue;
            } else {
              throw Exception('Parameter validation failed: attachments must be an array, got ${attachmentsValue.runtimeType}');
            }
          }
          
          // Log validated parameters for debugging
          LoggerService.debug('[Synapse.chatAI] Validated parameters: temperature=$temperature, topK=$topK, topP=$topP, attachments=${attachmentPaths?.length ?? 0}');
          
          // Process and verify attachments
          List<PlatformFile>? attachedFiles;
          if (attachmentPaths != null && attachmentPaths.isNotEmpty) {
            attachedFiles = await _processMixedAttachments(attachmentPaths);
          }
          
          // Use the new chatAI service with configurable parameters and attachments
          final response = await _callChatAI(
            prompt, 
            temperature: temperature, 
            topK: topK, 
            topP: topP,
            attachedFiles: attachedFiles,
          );
          final duration = DateTime.now().difference(startTime);
          
          LoggerService.debug('[Synapse.chatAI] Success - Response length: ${response.length} in ${duration.inMilliseconds}ms');
          
          return {'success': true, 'response': response};
        } catch (e) {
          final duration = DateTime.now().difference(startTime);
          LoggerService.error('[Synapse.chatAI] Error after ${duration.inMilliseconds}ms: $e', error: e);
          return {'success': false, 'error': e.toString()};
        }
      },
    );

    // Add a log handler for explicit logging from JavaScript
    controller.addJavaScriptHandler(
      handlerName: 'log',
      callback: (args) async {
        try {
          final message = args[0] as String;
          final level = args.length > 1 ? args[1] as String : 'LOG';
          LoggerService.info('[UserApp.${level.toUpperCase()}] $message');
        } catch (e) {
          LoggerService.error('[UserApp.LOG] Error in log handler: $e', error: e);
        }
      },
    );

    // Add clipboard copy handler for Android clipboard fix
    controller.addJavaScriptHandler(
      handlerName: 'copy-to-clipboard',
      callback: (args) async {
        try {
          final text = args[0] as String;
          await Clipboard.setData(ClipboardData(text: text));
          LoggerService.debug('[UserApp.CLIPBOARD] Text copied to clipboard: ${text.length > 50 ? text.substring(0, 50) + '...' : text}');
          return {'success': true};
        } catch (e) {
          LoggerService.error('[UserApp.CLIPBOARD] Error copying to clipboard: $e', error: e);
          return {'success': false, 'error': e.toString()};
        }
      },
    );

    // Add readAttachment handler
    controller.addJavaScriptHandler(
      handlerName: 'readAttachment',
      callback: (args) async {
        final startTime = DateTime.now();
        try {
          final attachmentPath = args[0] as String;
          LoggerService.debug('[Synapse.readAttachment] Called with path: $attachmentPath');
          
          final result = await _readAttachmentFromPath(attachmentPath);
          final duration = DateTime.now().difference(startTime);
          
          if (result != null) {
            LoggerService.debug('[Synapse.readAttachment] Success - Read ${result['data']?.length ?? 0} characters in ${duration.inMilliseconds}ms');
            return {'success': true, 'data': result['data'], 'mimeType': result['mimeType']};
          } else {
            LoggerService.warning('[Synapse.readAttachment] Attachment not found in database: $attachmentPath');
            return {'success': false, 'error': 'Attachment not found in database'};
          }
        } catch (e) {
          final duration = DateTime.now().difference(startTime);
          LoggerService.error('[Synapse.readAttachment] Error after ${duration.inMilliseconds}ms: $e', error: e);
          return {'success': false, 'error': e.toString()};
        }
      },
    );

    // Add saveNotes handler
    controller.addJavaScriptHandler(
      handlerName: 'saveNotes',
      callback: (args) async {
        final startTime = DateTime.now();
        try {
          final notesData = args[0] as List<dynamic>;
          LoggerService.debug('[Synapse.saveNotes] Called with ${notesData.length} notes');
          
          final savedCount = await _saveNotesFromJavaScript(notesData);
          final duration = DateTime.now().difference(startTime);
          
          LoggerService.debug('[Synapse.saveNotes] Success - Saved $savedCount notes in ${duration.inMilliseconds}ms');
          
          return {'success': true, 'savedCount': savedCount};
        } catch (e) {
          final duration = DateTime.now().difference(startTime);
          LoggerService.error('[Synapse.saveNotes] Error after ${duration.inMilliseconds}ms: $e', error: e);
          return {'success': false, 'error': e.toString()};
        }
      },
    );

    // Add openNote handler
    controller.addJavaScriptHandler(
      handlerName: 'openNote',
      callback: (args) async {
        final startTime = DateTime.now();
        try {
          final noteId = args[0] as String;
          final replaceWindow = args.length > 1 ? (args[1] as bool? ?? false) : false;
          
          LoggerService.debug('[Synapse.openNote] Called with noteId: $noteId, replaceWindow: $replaceWindow');
          
          // Get the note from database
          final databaseService = DatabaseService();
          final note = await databaseService.getNote(noteId);
          
          if (note == null) {
            final duration = DateTime.now().difference(startTime);
            LoggerService.warning('[Synapse.openNote] Note not found: $noteId after ${duration.inMilliseconds}ms');
            return {'success': false, 'error': 'Note not found: $noteId'};
          }
          
          // Navigate to note detail screen
          // Use postFrameCallback to ensure navigation happens after the handler returns
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (replaceWindow) {
              Navigator.of(context).pushReplacement(
                MaterialPageRoute(
                  builder: (context) => NoteDetailScreen(note: note),
                ),
              );
            } else {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => NoteDetailScreen(note: note),
                ),
              );
            }
          });
          
          final duration = DateTime.now().difference(startTime);
          LoggerService.debug('[Synapse.openNote] Success - Opening note: ${note.title} in ${duration.inMilliseconds}ms');
          
          return {'success': true};
        } catch (e) {
          final duration = DateTime.now().difference(startTime);
          LoggerService.error('[Synapse.openNote] Error after ${duration.inMilliseconds}ms: $e', error: e);
          return {'success': false, 'error': e.toString()};
        }
      },
    );

  }

  void _showConsole(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) => Container(
        height: MediaQuery.of(context).size.height * 0.6,
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  l10n.consoleOutput,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                Row(
                  children: [
                    if (_consoleOutput.isNotEmpty)
                      IconButton(
                        onPressed: () => _copyConsoleToClipboard(context),
                        icon: const Icon(Icons.copy),
                        tooltip: l10n.copyToClipboard,
                      ),
                    IconButton(
                      onPressed: () {
                        setState(() {
                          _consoleOutput.clear();
                        });
                        Navigator.pop(context);
                      },
                      icon: const Icon(Icons.clear),
                      tooltip: l10n.clearConsole,
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: _consoleOutput.isEmpty
                  ? Center(
                      child: Text(
                        l10n.noConsoleOutput,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.grey,
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: _consoleOutput.length,
                      itemBuilder: (context, index) {
                        final message = _consoleOutput[index];
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2.0),
                          child: Text(
                            message,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              fontFamily: 'monospace',
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  void _copyConsoleToClipboard(BuildContext context) {
    if (_consoleOutput.isEmpty) return;
    
    final consoleText = _consoleOutput.join('\n');
    Clipboard.setData(ClipboardData(text: consoleText));
    
    final l10n = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(l10n.consoleOutputCopied),
        duration: const Duration(seconds: 2),
      ),
    );
  }


  void _navigateToEdit(BuildContext context) async {
    final appProvider = context.read<AppProvider>();
    final revisions = appProvider.appRevisions[widget.app.id] ?? [];
    
    // If no revisions exist, create an initial revision first
    if (revisions.isEmpty) {
      try {
        await appProvider.createInitialRevision(widget.app.id);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error creating initial revision: $e'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }
    }
    
    // Get the current app from the provider
    final currentApp = appProvider.userApps.firstWhere(
      (app) => app.id == widget.app.id,
      orElse: () => widget.app,
    );
    
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => UserAppEditScreen(
          app: currentApp,
          selectedRevision: _selectedRevision,
        ),
      ),
    );
    
    // If we returned from edit screen, refresh the data to show latest changes
    if (result == true && mounted) {
      await _refreshAppData();
    }
  }

  void _showDeleteDialog(BuildContext context, AppLocalizations l10n) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.delete),
        content: Text(l10n.confirmDeleteApp),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              try {
                final appProvider = context.read<AppProvider>();
                await appProvider.deleteUserApp(widget.app.id);
                if (mounted) {
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(l10n.appDeletedSuccessfully),
                      backgroundColor: Colors.green,
                    ),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(l10n.errorDeletingApp(e.toString())),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              }
            },
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
  }

  // Execute SQL query using the database service
  Future<List<Map<String, dynamic>>> _executeSQLQuery(String sql) async {
    try {
      final databaseService = DatabaseService();
      return await databaseService.executeRawQuery(sql);
    } catch (e) {
      throw Exception('SQL query failed: $e');
    }
  }


  // Call chat AI service with configurable parameters
  Future<String> _callChatAI(
    String prompt, {
    double? temperature,
    int? topK,
    double? topP,
    List<PlatformFile>? attachedFiles,
  }) async {
    try {
      // Use the new chatAI service with configurable parameters
      return await AIService.chatAI(
        prompt,
        temperature: temperature,
        topK: topK,
        topP: topP,
        attachedFiles: attachedFiles,
      );
    } catch (e) {
      throw Exception('Chat AI call failed: $e');
    }
  }


  // Process mixed attachments (file paths and base64 data objects)
  Future<List<PlatformFile>> _processMixedAttachments(List<dynamic> attachments) async {
    final List<PlatformFile> validAttachments = [];
    final databaseService = DatabaseService();
    
    for (int i = 0; i < attachments.length; i++) {
      final attachment = attachments[i];
      
      try {
        if (attachment is String) {
          // File path attachment
          final attachmentPath = attachment;
          
          // Verify that the attachment belongs to a note
          final isValid = await databaseService.verifyAttachmentPath(attachmentPath);
          if (!isValid) {
            LoggerService.warning('[Synapse.chatAI] Warning: Attachment path not found in database: $attachmentPath');
            continue;
          }
          
          // Read the file and create PlatformFile
          final file = File(attachmentPath);
          if (await file.exists()) {
            final bytes = await file.readAsBytes();
            final fileName = attachmentPath.split('/').last;
            
            final platformFile = PlatformFile(
              name: fileName,
              path: attachmentPath,
              size: bytes.length,
              bytes: bytes,
            );
            
            validAttachments.add(platformFile);
            LoggerService.debug('[Synapse.chatAI] Added file attachment: $fileName (${bytes.length} bytes)');
          } else {
            LoggerService.warning('[Synapse.chatAI] Warning: Attachment file not found: $attachmentPath');
          }
        } else if (attachment is Map<String, dynamic>) {
          // Base64 data object
          final type = attachment['type'] as String?;
          final mimeType = attachment['mimeType'] as String?;
          final data = attachment['data'] as String?;
          
          if (type == 'base64' && mimeType != null && data != null) {
            // Extract base64 data (remove data:image/jpeg;base64, prefix if present)
            String base64String = data;
            if (base64String.contains(',')) {
              base64String = base64String.split(',').last;
            }
            
            try {
              final bytes = base64Decode(base64String);
              
              // Generate a filename based on MIME type
              final extension = _getExtensionFromMimeType(mimeType);
              final fileName = 'attachment_${DateTime.now().millisecondsSinceEpoch}.$extension';
              
              final platformFile = PlatformFile(
                name: fileName,
                path: '', // No file path for base64 data
                size: bytes.length,
                bytes: bytes,
              );
              
              validAttachments.add(platformFile);
              LoggerService.debug('[Synapse.chatAI] Added base64 attachment: $fileName (${bytes.length} bytes, $mimeType)');
            } catch (e) {
              LoggerService.error('[Synapse.chatAI] Error decoding base64 data at index $i: $e', error: e);
              continue;
            }
          } else {
            LoggerService.warning('[Synapse.chatAI] Warning: Invalid base64 attachment object at index $i: missing type, mimeType, or data');
          }
        } else {
          LoggerService.warning('[Synapse.chatAI] Warning: Invalid attachment type at index $i: expected string or object, got ${attachment.runtimeType}');
        }
      } catch (e) {
        LoggerService.error('[Synapse.chatAI] Error processing attachment at index $i: $e', error: e);
        // Continue with other attachments even if one fails
      }
    }
    
    return validAttachments;
  }

  // Read attachment from path and return base64 data with MIME type
  Future<Map<String, dynamic>?> _readAttachmentFromPath(String attachmentPath) async {
    try {
      final databaseService = DatabaseService();
      
      // Verify that the attachment belongs to a note
      final isValid = await databaseService.verifyAttachmentPath(attachmentPath);
      if (!isValid) {
        LoggerService.warning('[Synapse.readAttachment] Attachment path not found in database: $attachmentPath');
        return null;
      }
      
      // Read the file
      final file = File(attachmentPath);
      if (!await file.exists()) {
        LoggerService.warning('[Synapse.readAttachment] Attachment file not found: $attachmentPath');
        return null;
      }
      
      final bytes = await file.readAsBytes();
      final fileName = attachmentPath.split('/').last;
      final mimeType = _getMimeTypeFromExtension(FileTypeUtils.getFileExtension(fileName));
      
      // Encode to base64
      final base64Data = base64Encode(bytes);
      
      return {
        'data': base64Data,
        'mimeType': mimeType,
      };
    } catch (e) {
      LoggerService.error('[Synapse.readAttachment] Error reading attachment $attachmentPath: $e', error: e);
      return null;
    }
  }

  // Get file extension from MIME type
  String _getExtensionFromMimeType(String mimeType) {
    switch (mimeType.toLowerCase()) {
      case 'image/jpeg':
      case 'image/jpg':
        return 'jpg';
      case 'image/png':
        return 'png';
      case 'image/gif':
        return 'gif';
      case 'image/svg+xml':
        return 'svg';
      case 'image/webp':
        return 'webp';
      case 'text/plain':
        return 'txt';
      case 'text/html':
        return 'html';
      case 'text/css':
        return 'css';
      case 'application/javascript':
        return 'js';
      case 'application/json':
        return 'json';
      case 'application/pdf':
        return 'pdf';
      case 'application/zip':
        return 'zip';
      default:
        return 'bin';
    }
  }

  // Get MIME type from file extension
  String _getMimeTypeFromExtension(String extension) {
    switch (extension.toLowerCase()) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'svg':
        return 'image/svg+xml';
      case 'webp':
        return 'image/webp';
      case 'txt':
        return 'text/plain';
      case 'html':
        return 'text/html';
      case 'css':
        return 'text/css';
      case 'js':
        return 'application/javascript';
      case 'json':
        return 'application/json';
      case 'pdf':
        return 'application/pdf';
      case 'zip':
        return 'application/zip';
      default:
        return 'application/octet-stream';
    }
  }

  // Save notes from JavaScript API
  Future<int> _saveNotesFromJavaScript(List<dynamic> notesData) async {
    final appProvider = Provider.of<AppProvider>(context, listen: false);
    int savedCount = 0;
    
    for (final noteData in notesData) {
      try {
        final note = await _createNoteFromJavaScriptData(noteData);
        await appProvider.addNote(note);
        savedCount++;
        LoggerService.debug('[Synapse.saveNotes] Saved note: ${note.id} - ${note.title}');
      } catch (e) {
        LoggerService.error('[Synapse.saveNotes] Error saving note: $e', error: e);
        // Continue with other notes even if one fails
      }
    }
    
    return savedCount;
  }

  // Create Note object from JavaScript data
  Future<Note> _createNoteFromJavaScriptData(Map<String, dynamic> data) async {
    // Validate required fields
    if (data['title'] == null || data['title'].toString().trim().isEmpty) {
      throw Exception('Note title is required and cannot be empty');
    }
    if (data['content'] == null) {
      throw Exception('Note content is required and cannot be empty');
    }
    if (data['type'] == null) throw Exception('Note type is required');

    // Generate unique ID on Flutter side
    final noteId = _generateUniqueId();
    final now = DateTime.now();

    // Parse note type
    final noteType = _parseNoteType(data['type']);

    // Parse subnotes
    final subNotes = <SubNote>[];
    if (data['subNotes'] != null && data['subNotes'] is List) {
      for (final subNoteData in data['subNotes']) {
        if (subNoteData is Map<String, dynamic>) {
          subNotes.add(_createSubNoteFromJavaScriptData(subNoteData));
        }
      }
    }

    // Skip tags for now - complex logic to create tags if they don't exist
    final tags = <String>[];

    // Process attachments - throw exception if invalid
    final attachmentPaths = <String>[];
    if (data['attachments'] != null && data['attachments'] is List) {
      for (final attachment in data['attachments']) {
        final attachmentPath = await _processAttachmentFromJavaScript(attachment);
        attachmentPaths.add(attachmentPath); // This will throw if invalid
      }
    }

    // Parse task-specific fields
    String? scheduledAt;
    String? completeBy;
    TaskStatus? status;
    double? completionPercentage;

    if (noteType == NoteType.task) {
      scheduledAt = data['scheduledAt']?.toString();
      completeBy = data['completeBy']?.toString();
      status = data['status'] != null ? _parseTaskStatus(data['status'].toString()) : TaskStatus.todo;
      completionPercentage = data['completionPercentage'] != null 
          ? (data['completionPercentage'] as num).toDouble() 
          : 0.0;
    }

    return Note(
      id: noteId,
      title: data['title'].toString().trim(),
      content: data['content'].toString().trim(),
      type: noteType,
      createdAt: now,
      updatedAt: now,
      subNotes: subNotes,
      tags: tags,
      attachmentPaths: attachmentPaths,
      scheduledAt: scheduledAt,
      completeBy: completeBy,
      status: status,
      completionPercentage: completionPercentage,
      pinned: data['pinned'] == true,
      isArchived: data['isArchived'] == true,
    );
  }

  // Create SubNote object from JavaScript data
  SubNote _createSubNoteFromJavaScriptData(Map<String, dynamic> data) {
    if (data['name'] == null || data['name'].toString().trim().isEmpty) {
      throw Exception('SubNote name is required and cannot be empty');
    }

    return SubNote(
      id: _generateUniqueId(),
      name: data['name'].toString().trim(),
      content: data['content']?.toString().trim() ?? '',
      createdAt: DateTime.now(),
      isCompleted: data['isCompleted'] == true,
    );
  }

  // Generate unique ID for notes and subnotes
  String _generateUniqueId() {
    return const Uuid().v4();
  }

  // Parse NoteType from string
  NoteType _parseNoteType(String typeString) {
    switch (typeString.toLowerCase()) {
      case 'note':
        return NoteType.note;
      case 'task':
        return NoteType.task;
      default:
        throw Exception('Invalid note type: $typeString');
    }
  }

  // Parse TaskStatus from string
  TaskStatus _parseTaskStatus(String statusString) {
    switch (statusString.toLowerCase()) {
      case 'todo':
        return TaskStatus.todo;
      case 'in_progress':
        return TaskStatus.inProgress;
      case 'complete':
        return TaskStatus.complete;
      case 'abandoned':
        return TaskStatus.abandoned;
      default:
        return TaskStatus.todo;
    }
  }

  // Process attachment from JavaScript data
  Future<String> _processAttachmentFromJavaScript(dynamic attachment) async {
    if (attachment is String) {
      // File URI - verify it exists in database
      final databaseService = DatabaseService();
      final isValid = await databaseService.verifyAttachmentPath(attachment);
      if (isValid) {
        return attachment;
      } else {
        throw Exception('Invalid attachment path: $attachment - file not found in database');
      }
    } else if (attachment is Map<String, dynamic>) {
      // Base64 attachment
      if (attachment['type'] == 'base64' && attachment['data'] != null && attachment['fileName'] != null) {
        return await _saveBase64Attachment(attachment['data'], attachment['fileName']);
      } else {
        throw Exception('Invalid base64 attachment format: missing type, data, or fileName');
      }
    }
    
    throw Exception('Invalid attachment format: expected string (file URI) or object (base64), got ${attachment.runtimeType}');
  }

  // Save base64 attachment to private storage and database
  Future<String> _saveBase64Attachment(String base64Data, String fileName) async {
    try {
      // Extract base64 data (remove data:image/jpeg;base64, prefix if present)
      String base64String = base64Data;
      if (base64String.contains(',')) {
        base64String = base64String.split(',').last;
      }

      // Decode base64 data
      final bytes = base64Decode(base64String);

      // Save to private storage and get relative path
      final relativePath = await FileUtils.saveFileToPrivateStorage(bytes, fileName);

      LoggerService.debug('[Synapse.saveNotes] Saved base64 attachment: $fileName (${bytes.length} bytes) to $relativePath');
      
      return relativePath;
    } catch (e) {
      LoggerService.error('[Synapse.saveNotes] Error saving base64 attachment: $e', error: e);
      rethrow;
    }
  }

  // Handle synapse_user:// URL scheme for custom dependencies
  Future<CustomSchemeResponse?> _handleSynapseUserScheme(dynamic request) async {
    try {
      final path = request.url.path;
      LoggerService.debug('[SynapseUser] Handling request for path: $path');
      
      // Get current app and revision info
      final appProvider = context.read<AppProvider>();
      final currentApp = appProvider.userApps.firstWhere(
        (app) => app.id == widget.app.id,
        orElse: () => widget.app,
      );
      
      // Get the selected revision ID
      final revisionId = _selectedRevision?.revisionNumber ?? 1;
      
      LoggerService.debug('[SynapseUser] Looking for dependency: app_uuid=${currentApp.uuid}, revision_id=$revisionId, path=$path');
      
      // Query the database for the dependency
      final databaseService = DatabaseService();
      final dependency = await databaseService.getDependencyByAppAndPath(
        currentApp.uuid,
        revisionId,
        path,
      );
      
      if (dependency == null) {
        LoggerService.warning('[SynapseUser] Dependency not found for path: $path');
        return CustomSchemeResponse(
          contentType: 'text/plain',
          data: Uint8List.fromList(utf8.encode('// Dependency not found: $path')),
        );
      }
      
      // Get the bytes from the dependency
      final bytes = dependency['bytes'] as List<int>;
      LoggerService.debug('[SynapseUser] Found dependency: ${bytes.length} bytes');
      
      // Determine content type based on file extension
      String contentType = 'text/plain';
      final extension = FileTypeUtils.getFileExtension(path);
      switch (extension) {
        case 'js':
          contentType = 'application/javascript';
          break;
        case 'mjs':
          contentType = 'application/javascript';
          break;
        case 'css':
          contentType = 'text/css';
          break;
        case 'html':
          contentType = 'text/html';
          break;
        case 'json':
          contentType = 'application/json';
          break;
        case 'png':
          contentType = 'image/png';
          break;
        case 'jpg':
        case 'jpeg':
          contentType = 'image/jpeg';
          break;
        case 'gif':
          contentType = 'image/gif';
          break;
        case 'svg':
          contentType = 'image/svg+xml';
          break;
        default:
          contentType = 'text/plain';
      }
      
      return CustomSchemeResponse(
        contentType: contentType,
        data: Uint8List.fromList(bytes),
      );
    } catch (e) {
      LoggerService.error('[SynapseUser] Error handling synapse_user scheme: $e', error: e);
      return CustomSchemeResponse(
        contentType: 'text/plain',
        data: Uint8List.fromList(utf8.encode('// Error loading dependency: $e')),
      );
    }
  }

}

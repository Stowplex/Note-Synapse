import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:file_picker/file_picker.dart';
import '../l10n/app_localizations.dart';
import '../providers/app_provider.dart';
import '../models/user_app.dart';
import '../models/app_revision.dart';
import '../models/note.dart';
import '../services/user_app_service.dart';
import '../services/gemini_api_service.dart';
import '../services/database_service.dart';
import 'user_app_edit_screen.dart';

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
  List<AppRevision> _revisions = [];
  AppRevision? _selectedRevision;
  bool _showRevisionDetails = false;

  @override
  void initState() {
    super.initState();
    _validateNoteActionApp();
    _loadRevisions();
  }

  Future<void> _loadRevisions() async {
    try {
      final appProvider = context.read<AppProvider>();
      final revisions = await appProvider.getAppRevisions(widget.app.id);
      print('Loaded ${revisions.length} revisions for app ${widget.app.id}');
      print('App selectedRevisionId: ${widget.app.selectedRevisionId}');
      
      setState(() {
        _revisions = revisions;
        if (widget.app.selectedRevisionId != null) {
          try {
            _selectedRevision = revisions.firstWhere(
              (r) => r.id == widget.app.selectedRevisionId,
            );
            print('Selected revision: ${_selectedRevision?.id} with code length: ${_selectedRevision?.appCode.length}');
          } catch (e) {
            print('Selected revision not found, using first available');
            _selectedRevision = revisions.isNotEmpty ? revisions.first : null;
          }
        } else if (revisions.isNotEmpty) {
          _selectedRevision = revisions.first;
          print('No selected revision, using first: ${_selectedRevision?.id}');
        } else {
          // Fallback: if no revisions exist, create a virtual revision from the app's htmlContent
          // This handles cases where the migration didn't run or apps were created before revisions
          _selectedRevision = null;
          print('No revisions found, using app htmlContent');
        }
      });
    } catch (e) {
      print('Error loading revisions: $e');
      // Fallback: if loading revisions fails, set to null to use app's htmlContent
      setState(() {
        _selectedRevision = null;
      });
    }
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
      
      // Reload revisions to update the UI
      await _loadRevisions();
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Revision ${revision.revisionNumber} ${widget.app.selectedRevisionId == revision.id ? 'unpinned' : 'pinned'}'),
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
        
        // Reload revisions
        await _loadRevisions();
        
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
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error deleting revision: $e'),
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
          if (_revisions.isNotEmpty)
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
                      itemCount: _revisions.length,
                      itemBuilder: (context, index) {
                        final revision = _revisions[index];
                        final isSelected = _selectedRevision?.id == revision.id;
                        final isPinned = widget.app.selectedRevisionId == revision.id;
                        
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
                            widget.app.selectedRevisionId == _selectedRevision!.id 
                                ? Icons.push_pin 
                                : Icons.push_pin_outlined,
                            size: 16,
                          ),
                          tooltip: widget.app.selectedRevisionId == _selectedRevision!.id 
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
    final htmlData = _selectedRevision?.appCode ?? widget.app.htmlContent;
    print('WebView loading data: ${htmlData.length} characters');
    print('Using revision: ${_selectedRevision?.id ?? 'none'}');
    print('Data preview: ${htmlData.substring(0, htmlData.length > 200 ? 200 : htmlData.length)}...');
    
    return Stack(
        children: [
          InAppWebView(
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
              resourceCustomSchemes: ['synapse'],
            ),
            onLoadResourceWithCustomScheme: (controller, request) async {
              print('onLoadResourceWithCustomScheme: ${request.url} - ${request.url.path} - ${request.url.path}');
              if (request.url.scheme.toLowerCase() == 'synapse') {
                final data = await rootBundle.loadString("assets/scripts/${request.url.host}");
                return CustomSchemeResponse(
                  contentType: 'text/plain',
                  data: Uint8List.fromList(utf8.encode(data)),
                );
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
          originalConsoleLog.apply(console, args);
          window.flutter_inappwebview.callHandler('log', args.join(' '), 'LOG');
        };
        
        console.error = function(...args) {
          originalConsoleError.apply(console, args);
          window.flutter_inappwebview.callHandler('log', args.join(' '), 'ERROR');
        };
        
        console.warn = function(...args) {
          originalConsoleWarn.apply(console, args);
          window.flutter_inappwebview.callHandler('log', args.join(' '), 'WARN');
        };
        
        window.Synapse = {
          runQuery: async (sql) => {
            const result = await window.flutter_inappwebview.callHandler('runQuery', sql);
            return result;
          },
          storeAppState: async (state) => {
            const result = await window.flutter_inappwebview.callHandler('storeAppState', state);
            return result;
          },
          loadAppState: async () => {
            const result = await window.flutter_inappwebview.callHandler('loadAppState');
            return result;
          },
          chatAI: async (prompt, options = {}) => {
            const result = await window.flutter_inappwebview.callHandler('chatAI', prompt, options);
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
          print('[Synapse.runQuery] Called with SQL: $sql');
          
          // Execute the SQL query using the database service
          final result = await _executeSQLQuery(sql);
          final duration = DateTime.now().difference(startTime);
          
          print('[Synapse.runQuery] Success - Returned ${result.length} rows in ${duration.inMilliseconds}ms');
          
          return {'success': true, 'data': result};
        } catch (e) {
          final duration = DateTime.now().difference(startTime);
          print('[Synapse.runQuery] Error after ${duration.inMilliseconds}ms: $e');
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
          print('[Synapse.storeAppState] Called with state keys: ${state.keys.toList()}');
          
          final appProvider = context.read<AppProvider>();
          await appProvider.saveAppState(widget.app.id, state);
          final duration = DateTime.now().difference(startTime);
          
          print('[Synapse.storeAppState] Success - State saved in ${duration.inMilliseconds}ms');
          
          return {'success': true};
        } catch (e) {
          final duration = DateTime.now().difference(startTime);
          print('[Synapse.storeAppState] Error after ${duration.inMilliseconds}ms: $e');
          return {'success': false, 'error': e.toString()};
        }
      },
    );

    controller.addJavaScriptHandler(
      handlerName: 'loadAppState',
      callback: (args) async {
        final startTime = DateTime.now();
        try {
          print('[Synapse.loadAppState] Called for app: ${widget.app.id}');
          
          final appProvider = context.read<AppProvider>();
          final state = await appProvider.getAppState(widget.app.id);
          final duration = DateTime.now().difference(startTime);
          
          if (state != null) {
            print('[Synapse.loadAppState] Success - State loaded with keys: ${state.keys.toList()} in ${duration.inMilliseconds}ms');
          } else {
            print('[Synapse.loadAppState] Success - No state found in ${duration.inMilliseconds}ms');
          }
          
          return {'success': true, 'data': state};
        } catch (e) {
          final duration = DateTime.now().difference(startTime);
          print('[Synapse.loadAppState] Error after ${duration.inMilliseconds}ms: $e');
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
          print('[Synapse.chatAI] Called with prompt: ${prompt.length > 100 ? prompt.substring(0, 100) + '...' : prompt}');
          
          // Extract optional parameters
          final temperature = options?['temperature'] as double?;
          final topK = options?['topK'] as int?;
          final topP = options?['topP'] as double?;
          final attachmentPaths = options?['attachments'] as List<dynamic>?;
          
          // Process and verify attachments
          List<PlatformFile>? attachedFiles;
          if (attachmentPaths != null && attachmentPaths.isNotEmpty) {
            attachedFiles = await _processAttachments(attachmentPaths.cast<String>());
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
          
          print('[Synapse.chatAI] Success - Response length: ${response.length} in ${duration.inMilliseconds}ms');
          
          return {'success': true, 'response': response};
        } catch (e) {
          final duration = DateTime.now().difference(startTime);
          print('[Synapse.chatAI] Error after ${duration.inMilliseconds}ms: $e');
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
          print('[UserApp.${level.toUpperCase()}] $message');
        } catch (e) {
          print('[UserApp.LOG] Error in log handler: $e');
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
          print('[UserApp.CLIPBOARD] Text copied to clipboard: ${text.length > 50 ? text.substring(0, 50) + '...' : text}');
          return {'success': true};
        } catch (e) {
          print('[UserApp.CLIPBOARD] Error copying to clipboard: $e');
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
    // If no revisions exist, create an initial revision first
    if (_revisions.isEmpty) {
      try {
        final appProvider = context.read<AppProvider>();
        await appProvider.createInitialRevision(widget.app.id);
        // Reload revisions after creating initial revision
        await _loadRevisions();
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
    
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => UserAppEditScreen(app: widget.app),
      ),
    );
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
      return await GeminiApiService.chatAI(
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

  // Process and verify attachment paths
  Future<List<PlatformFile>> _processAttachments(List<String> attachmentPaths) async {
    final List<PlatformFile> validAttachments = [];
    final databaseService = DatabaseService();
    
    for (final attachmentPath in attachmentPaths) {
      try {
        // Verify that the attachment belongs to a note
        final isValid = await databaseService.verifyAttachmentPath(attachmentPath);
        if (!isValid) {
          print('[Synapse.chatAI] Warning: Attachment path not found in database: $attachmentPath');
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
          print('[Synapse.chatAI] Added attachment: $fileName (${bytes.length} bytes)');
        } else {
          print('[Synapse.chatAI] Warning: Attachment file not found: $attachmentPath');
        }
      } catch (e) {
        print('[Synapse.chatAI] Error processing attachment $attachmentPath: $e');
        // Continue with other attachments even if one fails
      }
    }
    
    return validAttachments;
  }

}

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

  @override
  void initState() {
    super.initState();
    _validateNoteActionApp();
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
      body: Stack(
        children: [
          InAppWebView(
            initialData: InAppWebViewInitialData(
              data: widget.app.htmlContent,
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


  void _navigateToEdit(BuildContext context) {
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

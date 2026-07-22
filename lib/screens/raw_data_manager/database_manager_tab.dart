import 'dart:io';
import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import 'package:file_picker/file_picker.dart';
import 'package:file_saver/file_saver.dart';
import 'package:path/path.dart' as path;
import 'package:note_synapse/l10n/app_localizations.dart';
import '../../services/data_change_notifier.dart';
import '../../services/database_service.dart';
import '../../services/ai_service.dart';
import '../../services/service_locator.dart';

import 'package:note_synapse/widgets/interactive_checkbox_markdown.dart';
import 'package:url_launcher/url_launcher.dart';

class ChatMessage {
  final String role;
  final String content;
  ChatMessage({required this.role, required this.content});
}

class DatabaseManagerTab extends StatefulWidget {
  const DatabaseManagerTab({super.key});

  @override
  State<DatabaseManagerTab> createState() => _DatabaseManagerTabState();
}

class _DatabaseManagerTabState extends State<DatabaseManagerTab> {
  Database? _rawDb;
  String _dbPath = '';
  String _statusMessage = '';
  final TextEditingController _queryController = TextEditingController();
  List<Map<String, Object?>>? _queryResults;
  bool _isLoading = false;

  // AI Chat
  final TextEditingController _chatController = TextEditingController();
  final List<ChatMessage> _chatMessages = [];
  bool _isAiLoading = false;
  int _selectedViewIndex = 0;

  bool _hasInitialized = false;

  @override
  void initState() {
    super.initState();
    // Don't call _openDefaultDatabase here - context is not ready
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_statusMessage.isEmpty) {
      _statusMessage = AppLocalizations.of(context)!.notConnected;
    }
    // Initialize database only once, after context is available
    if (!_hasInitialized) {
      _hasInitialized = true;
      _openDefaultDatabase();
    }
  }

  @override
  void dispose() {
    _rawDb?.close();
    _queryController.dispose();
    _chatController.dispose();
    super.dispose();
  }

  Future<void> _openDefaultDatabase() async {
    final l10n = AppLocalizations.of(context)!;
    try {
      final dbPath = await DatabaseService().getDatabasePath();
      await _openDatabase(dbPath);
    } catch (e) {
      setState(() => _statusMessage = l10n.errorOpeningDefaultDb(e.toString()));
    }
  }

  Future<void> _openDatabase(String path) async {
    final l10n = AppLocalizations.of(context)!;
    await _rawDb?.close();
    try {
      // Open RAW - no helpers, no migrations from DatabaseService
      final db = await openDatabase(path);
      setState(() {
        _rawDb = db;
        _dbPath = path;
        _statusMessage = l10n.connectedTo(path.split('/').last);
        _queryResults = null;
      });
    } catch (e) {
      setState(() => _statusMessage = l10n.errorOpeningDb(e.toString()));
    }
  }

  Future<void> _pickDatabaseFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any, // Allow any file as DB might be renamed
    );

    if (result != null && result.files.single.path != null) {
      await _openDatabase(result.files.single.path!);
    }
  }

  Future<void> _exportDatabase() async {
    if (_dbPath.isEmpty) return;
    final l10n = AppLocalizations.of(context)!;
    try {
      final file = File(_dbPath);
      final bytes = await file.readAsBytes();
      final name = path.basename(_dbPath);

      await FileSaver.instance.saveAs(
        name: name,
        bytes: bytes,
        fileExtension: 'db',
        mimeType: MimeType.other,
      );

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l10n.databaseExportedSuccess)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.exportFailed(e.toString()))),
        );
      }
    }
  }

  Future<void> _executeQuery() async {
    if (_rawDb == null) return;
    final query = _queryController.text.trim();
    if (query.isEmpty) return;
    final l10n = AppLocalizations.of(context)!;

    setState(() {
      _isLoading = true;
      _queryResults = null;
    });

    try {
      if (query.toLowerCase().startsWith('select') ||
          query.toLowerCase().startsWith('pragma')) {
        final results = await _rawDb!.rawQuery(query);
        setState(() {
          _queryResults = results;
          _statusMessage = l10n.queryExecutedMessage(results.length);
        });
      } else {
        final count = await _rawDb!.rawUpdate(query);
        // This tab writes on a raw handle, bypassing the change-capture
        // journal — invalidate broadly so AppProvider caches don't go stale.
        DataChangeNotifier.shared().publish(const DataChangeEvent(bulk: true));
        setState(() {
          _statusMessage = l10n.updateExecutedMessage(count);
        });
      }
    } catch (e) {
      setState(() => _statusMessage = l10n.queryError(e.toString()));
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _sendMessageToAi() async {
    final message = _chatController.text.trim();
    if (message.isEmpty) return;

    setState(() {
      _chatMessages.add(ChatMessage(role: 'user', content: message));
      _chatController.clear();
      _isAiLoading = true;
    });

    try {
      // Build context
      final schema = DatabaseService.getSchema().join('\n');
      String actualSchema = '';
      try {
        if (_rawDb != null) {
          final tables = await _rawDb!.rawQuery(
            "SELECT sql FROM sqlite_master WHERE type='table'",
          );
          actualSchema = tables.map((r) => r['sql']).join('\n');
        }
      } catch (e) {
        actualSchema = 'Error reading actual schema: $e';
      }

      final systemPrompt =
          '''
You are a Database Recovery Assistant.
The application expects the following schema:
$schema

The actual database schema is:
$actualSchema

The user is asking for help with database recovery or querying.
Provide SQL queries if asked. Explain errors.
Do NOT execute queries yourself, just suggest them.
The response shall be in markdown format.
''';

      final response = await getIt<AIService>().chatAI(
        '$systemPrompt\n\nUser Question: $message',
      );

      setState(() {
        _chatMessages.add(ChatMessage(role: 'assistant', content: response));
      });
    } catch (e) {
      setState(() {
        _chatMessages.add(ChatMessage(role: 'assistant', content: 'Error: $e'));
      });
    } finally {
      setState(() {
        _isAiLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      children: [
        // Top Toolbar with View Switcher and Actions
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Column(
            children: [
              // View Switcher
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<int>(
                  segments: [
                    ButtonSegment(
                      value: 0,
                      label: Text(l10n.queryAndResults),
                      icon: const Icon(Icons.table_chart),
                    ),
                    ButtonSegment(
                      value: 1,
                      label: Text(l10n.aiAssistant),
                      icon: const Icon(Icons.smart_toy),
                    ),
                  ],
                  selected: {_selectedViewIndex},
                  onSelectionChanged: (Set<int> newSelection) {
                    setState(() {
                      _selectedViewIndex = newSelection.first;
                    });
                  },
                ),
              ),
              const SizedBox(height: 4),
              // DB Actions
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _statusMessage,
                      style: Theme.of(context).textTheme.bodySmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.folder_open),
                    tooltip: l10n.openDbFileTooltip,
                    onPressed: _pickDatabaseFile,
                    iconSize: 20,
                  ),
                  IconButton(
                    icon: const Icon(Icons.restore),
                    tooltip: l10n.resetToDefaultDbTooltip,
                    onPressed: _openDefaultDatabase,
                    iconSize: 20,
                  ),
                  IconButton(
                    icon: const Icon(Icons.download),
                    tooltip: l10n.exportDbTooltip,
                    onPressed: _exportDatabase,
                    iconSize: 20,
                  ),
                ],
              ),
            ],
          ),
        ),

        // Main Content Area
        Expanded(
          child: _selectedViewIndex == 0 ? _buildQueryView() : _buildChatView(),
        ),
      ],
    );
  }

  Widget _buildQueryView() {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Column(
            children: [
              TextField(
                controller: _queryController,
                decoration: InputDecoration(
                  labelText: l10n.sqlQueryLabel,
                  hintText: l10n.sqlQueryHint,
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: _isLoading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.play_arrow),
                    onPressed: _isLoading ? null : _executeQuery,
                    tooltip: l10n.runQueryTooltip,
                  ),
                ),
                maxLines: 3,
                minLines: 1,
                style: const TextStyle(fontFamily: 'monospace'),
              ),
            ],
          ),
        ),
        Expanded(
          child: _queryResults == null
              ? Center(
                  child: Text(
                    l10n.enterQueryMessage,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              : _queryResults!.isEmpty
              ? Center(child: Text(l10n.noResultsReturned))
              : SingleChildScrollView(
                  scrollDirection: Axis.vertical,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: DataTable(
                      headingRowColor: MaterialStateProperty.all(
                        Theme.of(context).colorScheme.surfaceContainer,
                      ),
                      columns: _queryResults!.first.keys
                          .map(
                            (k) => DataColumn(
                              label: Text(
                                k,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          )
                          .toList(),
                      rows: _queryResults!
                          .map(
                            (row) => DataRow(
                              cells: row.values
                                  .map(
                                    (v) => DataCell(
                                      ConstrainedBox(
                                        constraints: const BoxConstraints(
                                          maxWidth: 200,
                                        ),
                                        child: SingleChildScrollView(
                                          scrollDirection: Axis.horizontal,
                                          child: SelectableText(
                                            v.toString(),
                                            style: Theme.of(
                                              context,
                                            ).textTheme.bodyMedium,
                                          ),
                                        ),
                                      ),
                                    ),
                                  )
                                  .toList(),
                            ),
                          )
                          .toList(),
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildChatView() {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: _chatMessages.length,
            itemBuilder: (context, index) {
              final msg = _chatMessages[index];
              final isUser = msg.role == 'user';
              return Align(
                alignment: isUser
                    ? Alignment.centerRight
                    : Alignment.centerLeft,
                child: Container(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  padding: const EdgeInsets.all(12),
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.8,
                  ),
                  decoration: BoxDecoration(
                    color: isUser
                        ? Theme.of(context).colorScheme.primaryContainer
                        : Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: SelectionArea(
                    child: InteractiveCheckboxMarkdown(
                      originalContent: msg.content,
                      style: TextStyle(
                        color: isUser
                            ? Theme.of(context).colorScheme.onPrimaryContainer
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      onLinkTap: (url, _) {
                        final uri = Uri.tryParse(url);
                        if (uri != null) {
                          canLaunchUrl(uri).then((canLaunch) {
                            if (canLaunch) {
                              launchUrl(
                                uri,
                                mode: LaunchMode.externalApplication,
                              );
                            } else {
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text('Could not open link: $url'),
                                  ),
                                );
                              }
                            }
                          });
                        }
                      },
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        if (_isAiLoading) const LinearProgressIndicator(),
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _chatController,
                  decoration: InputDecoration(
                    hintText: l10n.askAiHint,
                    border: const OutlineInputBorder(),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                  ),
                  onSubmitted: (_) => _sendMessageToAi(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                icon: const Icon(Icons.send),
                onPressed: _isAiLoading ? null : _sendMessageToAi,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

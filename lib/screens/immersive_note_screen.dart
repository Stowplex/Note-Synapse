import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/conversation.dart';
import '../models/note.dart';
import '../providers/app_provider.dart';
import '../services/ai_service.dart';
import '../services/conversation_service.dart';
import '../services/database_service.dart';
import '../services/logger_service.dart';
import '../services/prompts/ai_prompts.dart';
import '../services/prompts/note_prompt_builder.dart';
import '../services/prompts/prompt_models.dart';
import '../services/prompts/system_prompt_builder.dart';
import '../utils/file_type_utils.dart';
import '../utils/file_utils.dart';
import '../utils/synapse_temp_utils.dart';
import '../widgets/interactive_checkbox_markdown.dart';
import 'conversation_tree_screen.dart';

class ImmersiveNoteScreen extends StatefulWidget {
  const ImmersiveNoteScreen({
    super.key,
    required this.notes,
    this.initialAttachmentPath,
  }) : assert(notes.length > 0, 'Immersive mode requires at least one note.');

  final List<Note> notes;
  final String? initialAttachmentPath;

  @override
  State<ImmersiveNoteScreen> createState() => _ImmersiveNoteScreenState();
}

class _ImmersiveNoteScreenState extends State<ImmersiveNoteScreen>
    with TickerProviderStateMixin {
  final ConversationService _conversationService = ConversationService();
  final DatabaseService _databaseService = DatabaseService();
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _chatScrollController = ScrollController();
  final GlobalKey _noteBoundaryKey = GlobalKey();

  late final Map<String, Note> _initialNotesById;
  late List<String> _noteOrder;
  final List<ConversationMessage> _messages = [];
  final List<PlatformFile> _pendingAttachments = [];
  final Map<String, List<Uint8List>> _pdfRasterCache = {};
  final Map<String, Future<List<Uint8List>>> _pdfRasterPending = {};

  Conversation? _conversation;
  List<Note> _conversationNotes = [];

  bool _isAiExpanded = false;
  bool _isPenMode = false;
  bool _isLoadingConversation = true;
  bool _isSending = false;
  Rect? _selectionRect;
  Offset? _dragStart;
  int _activeNoteIndex = 0;
  String? _activeAttachmentPath;
  final DateTime _sessionStart = DateTime.now();

  @override
  void initState() {
    super.initState();
    _initialNotesById = {
      for (final note in widget.notes) note.id: note,
    };
    _noteOrder = widget.notes.map((note) => note.id).toList(growable: false);

    if (widget.initialAttachmentPath != null) {
      _activeAttachmentPath = widget.initialAttachmentPath;
      final index = _findNoteIndexForAttachment(
        widget.initialAttachmentPath!,
        widget.notes,
      );
      if (index != null) {
        _activeNoteIndex = index;
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initializeConversation();
    });
  }

  @override
  void dispose() {
    _messageController.dispose();
    _chatScrollController.dispose();
    super.dispose();
  }

  Future<void> _initializeConversation() async {
    setState(() => _isLoadingConversation = true);

    try {
      final appProvider = context.read<AppProvider>();
      final noteIds = List<String>.from(_noteOrder);

      String? conversationId = await _findExistingConversationId(
        noteIds,
        appProvider,
      );

      Conversation? conversation;
      List<ConversationMessage> messages = [];

      if (conversationId != null) {
        final result = await _conversationService.getConversationWithFullHistory(
          conversationId,
        );
        if (result != null) {
          conversation = result.conversation;
          messages = result.messages;
        }
      }

      if (conversation == null) {
        final primaryNote = await _databaseService.getNote(noteIds.first);
        final title = primaryNote?.title ?? 'Immersive Session';
        conversation = await _conversationService.createConversation(
          title: 'Immersive: $title',
          noteIds: noteIds,
        );
      } else {
        final existingNoteIds = await _databaseService.getConversationNoteIds(
          conversation.id,
        );
        final missing = noteIds.where((id) => !existingNoteIds.contains(id));
        if (missing.isNotEmpty) {
          await _conversationService.addNotesToConversation(
            conversation.id,
            missing.toList(),
          );
        }
      }

      final conversationNotes = await _conversationService.getConversationNotes(
        conversation.id,
      );

      if (!mounted) return;

      setState(() {
        _conversation = conversation;
        _messages
          ..clear()
          ..addAll(messages);
        _conversationNotes = conversationNotes;
      });

      _scrollToBottom();
    } catch (e, stackTrace) {
      LoggerService.error(
        'Failed to initialize immersive conversation: $e',
        error: e,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error loading AI conversation: $e')),
      );
    } finally {
      if (mounted) {
        setState(() => _isLoadingConversation = false);
      }
    }
  }

  Future<String?> _findExistingConversationId(
    List<String> noteIds,
    AppProvider appProvider,
  ) async {
    if (noteIds.isEmpty) return null;

    final candidateIds = <String>{};
    for (final noteId in noteIds) {
      final ids = await appProvider.getNoteConversationIds(noteId);
      candidateIds.addAll(ids);
    }

    String? bestMatchId;
    int? bestMatchSize;

    for (final candidateId in candidateIds) {
      final noteSet = await _databaseService.getConversationNoteIds(candidateId);
      final conversation = await _databaseService.getConversation(candidateId);
      if (conversation == null || conversation.isArchived) {
        continue;
      }

      final set = noteSet.toSet();
      if (set.isEmpty) continue;

      final containsAll = noteIds.every(set.contains);
      if (!containsAll) continue;

      if (bestMatchId == null || (bestMatchSize != null && set.length < bestMatchSize)) {
        bestMatchId = candidateId;
        bestMatchSize = set.length;
      }
    }

    return bestMatchId;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Consumer<AppProvider>(
      builder: (context, appProvider, _) {
        final notes = _resolveNotes(appProvider);
        if (notes.isEmpty) {
          return Scaffold(
            appBar: AppBar(
              title: Text(l10n.immersiveMode),
            ),
            body: Center(
              child: Text(l10n.noNotesFound),
            ),
          );
        }

        final activeNote = notes[_activeNoteIndex.clamp(0, notes.length - 1)];

        return Scaffold(
          appBar: AppBar(
            title: Text(l10n.immersiveMode),
          ),
          body: SafeArea(
            child: Column(
              children: [
                _buildAiBar(l10n, notes),
                const Divider(height: 1),
                Expanded(
                  child: Stack(
                    children: [
                      _buildNoteArea(activeNote, l10n),
                      if (_isPenMode)
                        Positioned.fill(
                          child: GestureDetector(
                            onPanStart: _handlePenPanStart,
                            onPanUpdate: _handlePenPanUpdate,
                            onPanEnd: (_) => _handlePenPanEnd(),
                            child: IgnorePointer(
                              ignoring: false,
                              child: CustomPaint(
                                painter: _SelectionPainter(_selectionRect),
                                size: Size.infinite,
                              ),
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
      },
    );
  }

  List<Note> _resolveNotes(AppProvider provider) {
    final notesById = {
      for (final note in provider.notes) note.id: note,
    };

    final resolved = <Note>[];
    for (final id in _noteOrder) {
      final note = notesById[id] ?? _initialNotesById[id];
      if (note != null) {
        resolved.add(note);
      }
    }

    if (resolved.isEmpty && _initialNotesById.isNotEmpty) {
      resolved.addAll(_initialNotesById.values);
    }

    if (_activeNoteIndex >= resolved.length) {
      _activeNoteIndex = resolved.length - 1;
    }

    return resolved;
  }

  Widget _buildAiBar(AppLocalizations l10n, List<Note> notes) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: _isAiExpanded ? MediaQuery.of(context).size.height * 0.6 : 72,
        ),
        child: Material(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          elevation: 1,
          child: _isAiExpanded
              ? _buildExpandedAiBar(l10n, notes)
              : _buildCollapsedAiBar(l10n, notes),
        ),
      ),
    );
  }

  Widget _buildCollapsedAiBar(AppLocalizations l10n, List<Note> notes) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.expand_more),
            tooltip: l10n.expand,
            onPressed: () => setState(() => _isAiExpanded = true),
          ),
          Expanded(
            child: Text(
              l10n.aiChat,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.format_list_bulleted),
            tooltip: l10n.outline,
            onPressed: () => _showOutline(notes, l10n),
          ),
          IconButton(
            icon: const Icon(Icons.account_tree),
            tooltip: l10n.viewTree,
            onPressed: _conversation == null ? null : _openConversationTree,
          ),
        ],
      ),
    );
  }

  Widget _buildExpandedAiBar(AppLocalizations l10n, List<Note> notes) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                icon: const Icon(Icons.expand_less),
                tooltip: l10n.collapse,
                onPressed: () => setState(() => _isAiExpanded = false),
              ),
              Text(
                l10n.aiChat,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.format_list_bulleted),
                tooltip: l10n.outline,
                onPressed: () => _showOutline(notes, l10n),
              ),
              IconButton(
                icon: const Icon(Icons.account_tree),
                tooltip: l10n.viewTree,
                onPressed: _conversation == null ? null : _openConversationTree,
              ),
            ],
          ),
          if (_isLoadingConversation)
            const LinearProgressIndicator(minHeight: 2),
          const SizedBox(height: 8),
          Expanded(
            child: _buildConversationList(l10n),
          ),
          if (_pendingAttachments.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _buildPendingAttachmentsPreview(l10n),
            ),
          Row(
            children: [
              IconButton(
                icon: Icon(
                  Icons.brush,
                  color: _isPenMode
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
                tooltip: l10n.annotate,
                onPressed: () {
                  setState(() {
                    _isPenMode = !_isPenMode;
                    _selectionRect = null;
                  });
                },
              ),
              Expanded(
                child: TextField(
                  controller: _messageController,
                  maxLines: 4,
                  minLines: 1,
                  decoration: InputDecoration(
                    hintText: l10n.askAiHint,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  onSubmitted: (_) => _sendMessage(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: _isSending
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send),
                tooltip: l10n.send,
                onPressed: _isSending ? null : _sendMessage,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildConversationList(AppLocalizations l10n) {
    if (_messages.isEmpty) {
      return Align(
        alignment: Alignment.topCenter,
        child: Text(
          l10n.startConversationHint,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      );
    }

    return ListView.builder(
      controller: _chatScrollController,
      padding: const EdgeInsets.only(bottom: 12),
      itemCount: _messages.length,
      itemBuilder: (context, index) {
        final message = _messages[index];
        final isUser = message.type == MessageType.user;
        return Align(
          alignment:
              isUser ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.7,
            ),
            margin: const EdgeInsets.symmetric(vertical: 6),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isUser
                  ? Theme.of(context).colorScheme.primaryContainer
                  : Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
            child: Column(
              crossAxisAlignment:
                  isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                SelectableText(
                  message.content,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                ),
                if (message.attachmentPaths.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: _buildMessageAttachmentChips(message, l10n),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildMessageAttachmentChips(
    ConversationMessage message,
    AppLocalizations l10n,
  ) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: message.attachmentPaths.map((path) {
        final label = path.split(Platform.pathSeparator).last;
        return ActionChip(
          avatar: Icon(_iconForAttachment(path), size: 18),
          label: Text(
            label,
            overflow: TextOverflow.ellipsis,
          ),
          onPressed: () => _openAttachment(path, l10n),
        );
      }).toList(),
    );
  }

  Widget _buildPendingAttachmentsPreview(AppLocalizations l10n) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: List.generate(_pendingAttachments.length, (index) {
        final file = _pendingAttachments[index];
        return InputChip(
          avatar: const Icon(Icons.image, size: 18),
          label: Text(
            file.name,
            overflow: TextOverflow.ellipsis,
          ),
          onDeleted: () => setState(() {
            _pendingAttachments.removeAt(index);
          }),
        );
      }),
    );
  }

  Widget _buildNoteArea(Note note, AppLocalizations l10n) {
    return RepaintBoundary(
      key: _noteBoundaryKey,
      child: Container(
        color: Theme.of(context).colorScheme.surface,
        child: _activeAttachmentPath == null
            ? _buildNoteContent(note, l10n)
            : _buildAttachmentViewer(_activeAttachmentPath!, l10n),
      ),
    );
  }

  Widget _buildNoteContent(Note note, AppLocalizations l10n) {
    return Scrollbar(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              note.title,
              style: Theme.of(context)
                  .textTheme
                  .headlineSmall
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            SelectionArea(
              child: InteractiveCheckboxMarkdown(
                key: ValueKey('immersive_note_${note.id}_${note.updatedAt.toIso8601String()}'),
                originalContent: note.content,
                onContentChanged: (newContent) {
                  context.read<AppProvider>().updateNoteContent(
                        note.id,
                        newContent,
                      );
                },
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAttachmentViewer(String attachmentPath, AppLocalizations l10n) {
    return FutureBuilder<_AttachmentSource?>(
      future: _loadAttachmentSource(attachmentPath),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        final source = snapshot.data;
        if (source == null) {
          return Center(
            child: Text(l10n.attachmentMissing),
          );
        }

        final extension = source.extension;
        if (_isImageExtension(extension)) {
          return InteractiveViewer(
            panEnabled: true,
            minScale: 0.5,
            maxScale: 4,
            child: source.bytes != null
                ? Image.memory(source.bytes!, fit: BoxFit.contain)
                : Image.file(source.file, fit: BoxFit.contain),
          );
        }

        if (extension == 'svg') {
          return _buildSvgViewer(source, l10n);
        }

        if (extension == 'pdf') {
          return _buildPdfViewer(source, l10n);
        }

        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.insert_drive_file, size: 48),
              const SizedBox(height: 12),
              Text(l10n.unsupportedAttachment(extension)),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: () => _openAttachment(source.originalPath, l10n),
                child: Text(l10n.openAttachment),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSvgViewer(_AttachmentSource source, AppLocalizations l10n) {
    return FutureBuilder<String>(
      future: source.file.readAsString(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (!snapshot.hasData || snapshot.hasError) {
          return Center(child: Text(l10n.failedToLoadAttachment));
        }

        final svgContent = snapshot.data!;
        return InAppWebView(
          initialData: InAppWebViewInitialData(
            data: svgContent,
            mimeType: 'image/svg+xml',
            encoding: 'utf-8',
          ),
          initialSettings: InAppWebViewSettings(
            supportZoom: true,
            builtInZoomControls: true,
            transparentBackground: true,
          ),
        );
      },
    );
  }

  Widget _buildPdfViewer(_AttachmentSource source, AppLocalizations l10n) {
    return FutureBuilder<List<Uint8List>>(
      future: _rasterizePdf(source),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (!snapshot.hasData || snapshot.hasError) {
          return Center(child: Text(l10n.failedToLoadAttachment));
        }

        final pages = snapshot.data!;
        if (pages.isEmpty) {
          return Center(child: Text(l10n.failedToLoadAttachment));
        }

        return PageView.builder(
          itemCount: pages.length,
          itemBuilder: (context, index) {
            final bytes = pages[index];
            return InteractiveViewer(
              panEnabled: true,
              minScale: 0.5,
              maxScale: 4,
              child: Image.memory(bytes, fit: BoxFit.contain),
            );
          },
        );
      },
    );
  }

  Future<List<Uint8List>> _rasterizePdf(_AttachmentSource source) {
    final cacheKey = source.cacheKey;
    if (_pdfRasterCache.containsKey(cacheKey)) {
      return SynchronousFuture(_pdfRasterCache[cacheKey]!);
    }
    if (_pdfRasterPending.containsKey(cacheKey)) {
      return _pdfRasterPending[cacheKey]!;
    }

    final future = () async {
      final bytes = source.bytes ?? await source.file.readAsBytes();
      final pages = <Uint8List>[];
      await for (final page in Printing.raster(bytes, dpi: 150)) {
        final png = await page.toPng();
        pages.add(png);
      }
      _pdfRasterCache[cacheKey] = pages;
      _pdfRasterPending.remove(cacheKey);
      return pages;
    }();

    _pdfRasterPending[cacheKey] = future;
    return future;
  }

  void _showOutline(List<Note> notes, AppLocalizations l10n) {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 12),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(
                  l10n.outline,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              for (int i = 0; i < notes.length; i++) ...[
                ListTile(
                  leading: const Icon(Icons.description),
                  title: Text(notes[i].title),
                  onTap: () {
                    setState(() {
                      _activeNoteIndex = i;
                      _activeAttachmentPath = null;
                    });
                    Navigator.pop(context);
                  },
                ),
                for (final attachment in notes[i].attachmentPaths)
                  ListTile(
                    contentPadding: const EdgeInsets.only(left: 48, right: 16),
                    leading: Icon(_iconForAttachment(attachment)),
                    title: Text(
                      attachment.split(Platform.pathSeparator).last,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () {
                      setState(() {
                        _activeNoteIndex = i;
                        _activeAttachmentPath = attachment;
                      });
                      Navigator.pop(context);
                    },
                  ),
              ],
            ],
          ),
        );
      },
    );
  }

  void _openConversationTree() {
    if (_conversation == null) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => ConversationTreeScreen(
          activeConversationIds: [_conversation!.id],
        ),
      ),
    );
  }

  Future<void> _openAttachment(String path, AppLocalizations l10n) async {
    try {
      await FileUtils.openFile(path, context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.failedToOpenAttachment(e.toString()))),
      );
    }
  }

  Future<void> _sendMessage() async {
    final trimmed = _messageController.text.trim();
    if (trimmed.isEmpty && _pendingAttachments.isEmpty) {
      return;
    }
    if (_conversation == null) {
      return;
    }

    setState(() {
      _isSending = true;
    });

    final content = trimmed;
    final attachments = List<PlatformFile>.from(_pendingAttachments);

    _messageController.clear();
    setState(() {
      _pendingAttachments.clear();
    });

    try {
      final attachmentPaths = attachments
          .where((file) => file.path != null)
          .map((file) => file.path!)
          .toList();

      final userMessage = await _conversationService.addUserMessage(
        conversationId: _conversation!.id,
        content: content,
        attachmentPaths: attachmentPaths,
      );

      setState(() {
        _messages.add(userMessage);
      });
      _scrollToBottom();

      final response = await _generateAiResponse(content, attachments);
      final aiMessage = await _conversationService.addAIResponse(
        conversationId: _conversation!.id,
        content: response.content,
        metadata: null,
      );

      if (!mounted) return;
      setState(() {
        _messages.add(aiMessage);
      });
      _scrollToBottom();
    } catch (e, stackTrace) {
      LoggerService.error(
        'Error sending immersive message: $e',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error sending message: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSending = false;
        });
      }
    }
  }

  Future<_AssistantResponse> _generateAiResponse(
    String userMessage,
    List<PlatformFile> latestAttachments,
  ) async {
    final noteBuilder = NotePromptBuilder(_databaseService);
    final systemMessage = _buildSystemPrompt();
    final contextMessage = await noteBuilder.buildContextMessage(
      _conversationNotes,
    );

    final messages = <PromptMessage>[];
    for (final message in _messages) {
      final role = message.type == MessageType.user
          ? PromptRole.user
          : PromptRole.assistant;

      final attachments = await _loadConversationAttachments(
        message,
        latestAttachments,
      );

      messages.add(
        PromptMessage(
          role: role,
          content: message.content,
          attachments: attachments,
          metadata: message.metadata,
        ),
      );
    }

    messages.add(
      PromptMessage(
        role: PromptRole.user,
        content: userMessage,
        attachments: latestAttachments,
      ),
    );

    final request = PromptRequest(
      systemMessage: systemMessage,
      contextMessages: contextMessage.content.trim().isEmpty &&
              contextMessage.attachments.isEmpty
          ? const []
          : [contextMessage],
      conversationMessages: messages,
    );

    final responseText = await AIService.executePrompt(request);
    return _AssistantResponse(responseText);
  }

  PromptMessage _buildSystemPrompt() {
    final lines = <String>[
      'Engage in a focused conversation grounded in the selected notes and attachments.',
      'Reference the note titles when citing content and prefer concise, direct answers.',
      'Format your responses using markdown.',
    ];

    if (_conversationNotes.isEmpty) {
      lines.add('No note context is currently attached. Rely on the conversation history.');
    }

    final taskContext = lines.join('\n');

    return SystemPromptBuilder.build(
      taskContext: taskContext,
      guidelines: [
        'Highlight referenced note sections explicitly when possible.',
        AIPrompts.mathFormulaGuidelines,
        AIPrompts.relationshipGuidelines,
      ],
      now: _sessionStart,
      needTimeInContext: false,
    );
  }

  Future<List<PlatformFile>> _loadConversationAttachments(
    ConversationMessage message,
    List<PlatformFile> latestUserAttachments,
  ) async {
    if (message.type != MessageType.user) {
      return const [];
    }

    final isMostRecent =
        _messages.isNotEmpty && identical(message, _messages.last);
    if (isMostRecent && latestUserAttachments.isNotEmpty) {
      return latestUserAttachments;
    }

    if (message.attachmentPaths.isEmpty) {
      return const [];
    }

    final files = <PlatformFile>[];
    for (final path in message.attachmentPaths) {
      try {
        final file = File(path);
        if (!await file.exists()) continue;
        final bytes = await file.readAsBytes();
        files.add(
          PlatformFile(
            name: path.split(Platform.pathSeparator).last,
            path: file.path,
            size: bytes.length,
            bytes: bytes,
          ),
        );
      } catch (e) {
        LoggerService.warning('Failed to load attachment $path: $e');
      }
    }
    return files;
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_chatScrollController.hasClients) return;
      _chatScrollController.animateTo(
        _chatScrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }

  void _handlePenPanStart(DragStartDetails details) {
    final renderObject = _noteBoundaryKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox) return;
    final localPosition = renderObject.globalToLocal(details.globalPosition);
    setState(() {
      _dragStart = localPosition;
      _selectionRect = Rect.fromLTWH(localPosition.dx, localPosition.dy, 0, 0);
    });
  }

  void _handlePenPanUpdate(DragUpdateDetails details) {
    if (_dragStart == null) return;
    final renderObject = _noteBoundaryKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox) return;
    final localPosition = renderObject.globalToLocal(details.globalPosition);
    setState(() {
      _selectionRect = Rect.fromPoints(_dragStart!, localPosition);
    });
  }

  Future<void> _handlePenPanEnd() async {
    if (_selectionRect == null) return;
    final rect = _selectionRect!;
    setState(() {
      _selectionRect = null;
    });

    if (rect.width < 12 || rect.height < 12) {
      return;
    }

    try {
      final croppedBytes = await _captureSelection(rect);
      final result = await SynapseTempUtils.saveTempData(
        mimeType: 'image/png',
        bytes: croppedBytes,
      );
      final file = result.file;
      final platformFile = PlatformFile(
        name: 'annotation_${DateTime.now().millisecondsSinceEpoch}.png',
        path: file.path,
        size: croppedBytes.length,
        bytes: croppedBytes,
      );

      if (mounted) {
        setState(() {
          _pendingAttachments.add(platformFile);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Annotation added to attachments.')),
        );
      }
    } catch (e, stackTrace) {
      LoggerService.error('Failed to capture annotation: $e', error: e, stackTrace: stackTrace);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to capture annotation: $e')),
        );
      }
    }
  }

  Future<Uint8List> _captureSelection(Rect logicalRect) async {
    final renderObject = _noteBoundaryKey.currentContext?.findRenderObject();
    if (renderObject is! RenderRepaintBoundary) {
      throw Exception('Note view unavailable for capture.');
    }

    final devicePixelRatio = MediaQuery.of(context).devicePixelRatio;
    final image = await renderObject.toImage(pixelRatio: devicePixelRatio);

    final scaledRect = Rect.fromLTWH(
      logicalRect.left * devicePixelRatio,
      logicalRect.top * devicePixelRatio,
      logicalRect.width * devicePixelRatio,
      logicalRect.height * devicePixelRatio,
    );

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final paint = Paint();

    canvas.drawImageRect(
      image,
      scaledRect,
      Rect.fromLTWH(0, 0, scaledRect.width, scaledRect.height),
      paint,
    );

    final highlightPaint = Paint()
      ..color = Colors.redAccent.withValues(alpha: 0.7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = max(3, 3 * devicePixelRatio / 2);

    canvas.drawOval(
      Rect.fromLTWH(4, 4, scaledRect.width - 8, scaledRect.height - 8),
      highlightPaint,
    );

    final picture = recorder.endRecording();
    final croppedImage = await picture.toImage(
      max(1, scaledRect.width.round()),
      max(1, scaledRect.height.round()),
    );

    final byteData = await croppedImage.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) {
      throw Exception('Failed to encode annotation.');
    }
    return byteData.buffer.asUint8List();
  }

  Future<_AttachmentSource?> _loadAttachmentSource(String path) async {
    try {
      if (SynapseTempUtils.isSynapseTempUri(path)) {
        final tempFile = await SynapseTempUtils.loadFile(path);
        return _AttachmentSource(
          file: tempFile.file,
          bytes: tempFile.bytes,
          extension: FileTypeUtils.getFileExtension(tempFile.fileName),
          originalPath: tempFile.file.path,
        );
      }

      final file = File(path);
      if (!await file.exists()) {
        return null;
      }
      final extension = FileTypeUtils.getFileExtension(file.path);
      return _AttachmentSource(
        file: file,
        extension: extension,
        originalPath: file.path,
      );
    } catch (e) {
      LoggerService.warning('Failed to load attachment $path: $e');
      return null;
    }
  }

  IconData _iconForAttachment(String path) {
    final extension = FileTypeUtils.getFileExtension(path);
    switch (extension) {
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'svg':
        return Icons.photo_size_select_large;
      case 'png':
      case 'jpg':
      case 'jpeg':
      case 'gif':
      case 'webp':
      case 'bmp':
        return Icons.image;
      default:
        return Icons.insert_drive_file;
    }
  }

  int? _findNoteIndexForAttachment(String attachmentPath, List<Note> notes) {
    for (var i = 0; i < notes.length; i++) {
      if (notes[i].attachmentPaths.contains(attachmentPath)) {
        return i;
      }
    }
    return null;
  }

  bool _isImageExtension(String extension) {
    return const {
      'png',
      'jpg',
      'jpeg',
      'gif',
      'bmp',
      'webp',
    }.contains(extension);
  }
}

class _AttachmentSource {
  _AttachmentSource({
    required this.file,
    required this.extension,
    required this.originalPath,
    this.bytes,
  });

  final File file;
  final Uint8List? bytes;
  final String extension;
  final String originalPath;

  String get cacheKey => originalPath;
}

class _SelectionPainter extends CustomPainter {
  _SelectionPainter(this.rect);

  final Rect? rect;

  @override
  void paint(Canvas canvas, Size size) {
    if (rect == null) return;
    final highlight = Paint()
      ..color = Colors.redAccent.withValues(alpha: 0.25)
      ..style = PaintingStyle.fill;
    final border = Paint()
      ..color = Colors.redAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    canvas.drawOval(rect!, highlight);
    canvas.drawOval(rect!, border);
  }

  @override
  bool shouldRepaint(covariant _SelectionPainter oldDelegate) {
    return oldDelegate.rect != rect;
  }
}

class _AssistantResponse {
  const _AssistantResponse(this.content);

  final String content;
}


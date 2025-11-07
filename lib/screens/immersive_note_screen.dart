import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_pdfview/flutter_pdfview.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

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

  static const double _strokeCaptureMargin = 16;

  late final Map<String, Note> _initialNotesById;
  late List<String> _noteOrder;
  final List<ConversationMessage> _messages = [];
  final List<PlatformFile> _pendingAttachments = [];
  final Map<String, Future<_AttachmentSource?>> _attachmentSourceFutures = {};
  final Map<String, int> _pdfCurrentPages = {};
  final Map<String, int> _pdfTotalPages = {};
  final Map<String, PDFViewController> _pdfControllers = {};
  final Map<String, TransformationController> _imageTransforms = {};

  Conversation? _conversation;
  List<Note> _conversationNotes = [];

  bool _isPenMode = false;
  bool _isLoadingConversation = true;
  bool _isSending = false;
  final List<Offset> _penStrokePoints = [];
  int _activeNoteIndex = 0;
  String? _activeAttachmentPath;
  final DateTime _sessionStart = DateTime.now();
  static const double _aiHandleHeight = 76.0;
  static const double _aiHandleWidth = 420.0;
  static const double _aiPanelHeightFraction = 0.45;
  static const double _aiHandleMargin = 12.0;
  double _aiHandleFraction = 0.75;
  bool _isAiPanelExpanded = false;
  _AiPanelSide _aiPanelSide = _AiPanelSide.bottom;

  @override
  void initState() {
    super.initState();
    _initialNotesById = {for (final note in widget.notes) note.id: note};
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

    // Don't create conversation immediately - wait for first message
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadConversationNotes();
    });
  }

  @override
  void dispose() {
    _messageController.dispose();
    _chatScrollController.dispose();
    _disposePdfResources();
    _disposeImageResources();
    super.dispose();
  }

  /// Load conversation notes without creating a conversation
  Future<void> _loadConversationNotes() async {
    setState(() => _isLoadingConversation = true);

    try {
      final noteIds = List<String>.from(_noteOrder);
      final notes = <Note>[];

      for (final noteId in noteIds) {
        final note = await _databaseService.getNote(noteId);
        if (note != null) {
          notes.add(note);
        }
      }

      if (!mounted) return;

      setState(() {
        _conversationNotes = notes;
        for (final note in notes) {
          _initialNotesById[note.id] = note;
        }
      });
    } catch (e, stackTrace) {
      LoggerService.error(
        'Failed to load notes for immersive view: $e',
        error: e,
        stackTrace: stackTrace,
      );
    } finally {
      if (mounted) {
        setState(() => _isLoadingConversation = false);
      }
    }
  }

  /// Create conversation when first message is sent
  Future<void> _initializeConversation() async {
    if (_conversation != null) return;

    try {
      final noteIds = List<String>.from(_noteOrder);
      final primaryNote = await _databaseService.getNote(noteIds.first);
      final title = primaryNote?.title ?? 'Immersive Session';
      final conversation = await _conversationService.createConversation(
        title: 'Immersive: $title',
        noteIds: noteIds,
      );

      if (!mounted) return;

      setState(() {
        _conversation = conversation;
      });
    } catch (e, stackTrace) {
      LoggerService.error(
        'Failed to create immersive conversation: $e',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Consumer<AppProvider>(
      builder: (context, appProvider, _) {
        final notes = _resolveNotes(appProvider);
        if (notes.isEmpty) {
          return Scaffold(
            appBar: AppBar(title: Text(l10n.immersiveMode)),
            body: Center(child: Text(l10n.noNotesFound)),
          );
        }

        final activeNote = notes[_activeNoteIndex.clamp(0, notes.length - 1)];

        return Scaffold(
          appBar: AppBar(
            title: Text(l10n.immersiveMode),
            actions: [
              IconButton(
                icon: const Icon(Icons.format_list_bulleted),
                tooltip: l10n.outline,
                onPressed: () => _showOutline(notes, l10n),
              ),
              IconButton(
                icon: const Icon(Icons.account_tree),
                tooltip: l10n.viewTree,
                onPressed: _conversation == null
                    ? null
                    : () => _openConversationTree(),
              ),
            ],
          ),
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = constraints.biggest;
                final overlays = _buildAiOverlays(size, l10n);
                return Stack(
                  children: [
                    Positioned.fill(child: _buildNoteArea(activeNote, l10n)),
                    if (_isPenMode)
                      Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onPanStart: _handlePenPanStart,
                          onPanUpdate: _handlePenPanUpdate,
                          onPanEnd: (_) => _handlePenPanEnd(),
                          onPanCancel: _resetPenStroke,
                          child: CustomPaint(
                            painter: _FreeformStrokePainter(
                              _penStrokePoints.isEmpty
                                  ? null
                                  : List<Offset>.from(_penStrokePoints),
                            ),
                            size: Size.infinite,
                          ),
                        ),
                      ),
                    ...overlays,
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  List<Note> _resolveNotes(AppProvider provider) {
    final notesById = {for (final note in provider.notes) note.id: note};

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

  List<Widget> _buildAiOverlays(Size size, AppLocalizations l10n) {
    final overlays = <Widget>[];
    final totalHeight = size.height;
    final handleHeight = _currentHandleHeight();
    final panelHeight = _computePanelHeight(totalHeight);

    double handleTop;

    if (_isAiPanelExpanded) {
      final clampedPanelHeight = panelHeight.clamp(
        handleHeight * 1.2,
        totalHeight - handleHeight - (_aiHandleMargin * 2),
      );

      if (_aiPanelSide == _AiPanelSide.top) {
        overlays.add(
          Positioned(
            top: 0,
            left: _aiHandleMargin,
            right: _aiHandleMargin,
            height: clampedPanelHeight,
            child: _buildAiPanelContent(l10n),
          ),
        );
        // Position handle below the panel with margin
        handleTop = clampedPanelHeight + _aiHandleMargin;
      } else {
        overlays.add(
          Positioned(
            bottom: 0,
            left: _aiHandleMargin,
            right: _aiHandleMargin,
            height: clampedPanelHeight,
            child: _buildAiPanelContent(l10n),
          ),
        );
        // Position handle above the panel with margin
        handleTop =
            totalHeight -
            clampedPanelHeight -
            handleHeight -
            (_aiHandleMargin * 2);
      }
    } else {
      final trackHeight = totalHeight - handleHeight;
      handleTop = (_aiHandleFraction * trackHeight).clamp(
        _aiHandleMargin,
        totalHeight - handleHeight - _aiHandleMargin,
      );
    }

    final double clampedHandleTop = handleTop.clamp(
      _aiHandleMargin,
      totalHeight - handleHeight - _aiHandleMargin,
    );

    final handleWidth = min(size.width - (_aiHandleMargin * 2), _aiHandleWidth);
    overlays.add(
      Positioned(
        left: _aiHandleMargin,
        right: _aiHandleMargin,
        top: clampedHandleTop,
        child: Center(
          child: SizedBox(
            width: handleWidth,
            child: _buildAiHandle(l10n, size, handleWidth),
          ),
        ),
      ),
    );

    return overlays;
  }

  double _computePanelHeight(double totalHeight) {
    final desired = totalHeight * _aiPanelHeightFraction;
    final minHeight = totalHeight * 0.25;
    final maxHeight = totalHeight * 0.75;
    return desired.clamp(minHeight, maxHeight);
  }

  double _currentHandleHeight() {
    if (_pendingAttachments.isEmpty) {
      return _aiHandleHeight;
    }
    final attachmentRows = (_pendingAttachments.length / 2).ceil();
    return _aiHandleHeight + attachmentRows * 32.0;
  }

  Widget _buildAiHandle(
    AppLocalizations l10n,
    Size canvasSize,
    double handleWidth,
  ) {
    final theme = Theme.of(context);
    final bool expanded = _isAiPanelExpanded;
    final double dynamicHeight = _currentHandleHeight();

    final Widget controlWidget;
    if (expanded) {
      controlWidget = Center(
        child: IconButton(
          icon: const Icon(Icons.chevron_left),
          tooltip: l10n.collapse,
          onPressed: _collapseAiPanel,
        ),
      );
    } else {
      Widget buildArrowButton(IconData icon, _AiPanelSide side) {
        return SizedBox(
          width: 36,
          height: 36,
          child: IconButton(
            icon: Icon(icon, size: 20),
            padding: EdgeInsets.zero,
            tooltip: l10n.expand,
            onPressed: () => _expandAiPanel(side, canvasSize.height),
          ),
        );
      }

      controlWidget = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          buildArrowButton(Icons.keyboard_arrow_up, _AiPanelSide.top),
          const SizedBox(height: 4),
          buildArrowButton(Icons.keyboard_arrow_down, _AiPanelSide.bottom),
        ],
      );
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanUpdate: (details) =>
          _updateHandleDrag(details.delta.dy, canvasSize.height),
      child: Material(
        color: theme.colorScheme.surface.withOpacity(0.85),
        elevation: 6,
        borderRadius: BorderRadius.circular(16),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minHeight: dynamicHeight,
            maxWidth: handleWidth,
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 44, child: controlWidget),
                    const SizedBox(width: 8),
                    Expanded(child: _buildAiComposer(l10n)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAiComposer(AppLocalizations l10n) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_pendingAttachments.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _buildPendingAttachmentsPreview(l10n),
          ),
        DecoratedBox(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                IconButton(
                  icon: Icon(
                    Icons.brush,
                    color: _isPenMode ? theme.colorScheme.primary : null,
                  ),
                  tooltip: l10n.annotate,
                  onPressed: () {
                    setState(() {
                      _isPenMode = !_isPenMode;
                      _penStrokePoints.clear();
                    });
                  },
                ),
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    maxLines: 6,
                    minLines: 3,
                    decoration: InputDecoration.collapsed(
                      hintText: l10n.askAiHint,
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
          ),
        ),
      ],
    );
  }

  Widget _buildAiPanelContent(AppLocalizations l10n) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.95),
      elevation: 10,
      child: Column(
        mainAxisSize: MainAxisSize.max,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_isLoadingConversation)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: _buildConversationList(l10n),
            ),
          ),
        ],
      ),
    );
  }

  void _expandAiPanel(_AiPanelSide side, double totalHeight) {
    setState(() {
      _isAiPanelExpanded = true;
      _aiPanelSide = side;
      final handleHeight = _currentHandleHeight();
      final handleTravel = totalHeight - handleHeight;
      final panelHeight = _computePanelHeight(totalHeight).clamp(
        handleHeight * 1.2,
        totalHeight - handleHeight - (_aiHandleMargin * 2),
      );
      final targetTop = side == _AiPanelSide.top
          ? panelHeight - handleHeight
          : totalHeight - panelHeight - handleHeight;
      final clampedTop = targetTop.clamp(
        _aiHandleMargin,
        totalHeight - handleHeight - _aiHandleMargin,
      );
      _aiHandleFraction = handleTravel <= 0
          ? 0.5
          : (clampedTop / handleTravel).clamp(0.0, 1.0);
    });
  }

  void _collapseAiPanel() {
    setState(() {
      _isAiPanelExpanded = false;
    });
  }

  void _updateHandleDrag(double deltaDy, double totalHeight) {
    final handleHeight = _currentHandleHeight();
    final handleTravel = totalHeight - handleHeight;
    if (handleTravel <= 0) {
      return;
    }

    final currentTop = _aiHandleFraction * handleTravel;
    final newTop = (currentTop + deltaDy).clamp(
      _aiHandleMargin,
      totalHeight - handleHeight - _aiHandleMargin,
    );

    setState(() {
      _aiHandleFraction = (newTop / handleTravel).clamp(0.0, 1.0);
      _isAiPanelExpanded = false;
    });
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
          alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
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
              crossAxisAlignment: isUser
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                if (isUser)
                  SelectableText(
                    message.content,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  )
                else
                  SelectionArea(
                    child: InteractiveCheckboxMarkdown(
                      originalContent: message.content,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                      onLinkTap: (url, _) => _handleMarkdownLinkTap(url, l10n),
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
          label: Text(label, overflow: TextOverflow.ellipsis),
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
          label: Text(file.name, overflow: TextOverflow.ellipsis),
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
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            SelectionArea(
              child: InteractiveCheckboxMarkdown(
                key: ValueKey(
                  'immersive_note_${note.id}_${note.updatedAt.toIso8601String()}',
                ),
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
            // Add subnotes if present
            if (note.subNotes.isNotEmpty) ...[
              const SizedBox(height: 24),
              Text(
                l10n.subNotes,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              ...note.subNotes.map(
                (subNote) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              if (subNote.isCompleted)
                                const Icon(
                                  Icons.check_circle,
                                  color: Colors.green,
                                  size: 20,
                                )
                              else
                                const Icon(
                                  Icons.radio_button_unchecked,
                                  size: 20,
                                ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  subNote.name,
                                  style: Theme.of(context).textTheme.titleSmall
                                      ?.copyWith(fontWeight: FontWeight.bold),
                                ),
                              ),
                            ],
                          ),
                          if (subNote.content.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            SelectionArea(
                              child: InteractiveCheckboxMarkdown(
                                key: ValueKey(
                                  'subnote_${subNote.id}_${subNote.createdAt.toIso8601String()}',
                                ),
                                originalContent: subNote.content,
                                onContentChanged: (_) {},
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAttachmentViewer(String attachmentPath, AppLocalizations l10n) {
    final future = _attachmentSourceFutures.putIfAbsent(
      attachmentPath,
      () => _loadAttachmentSource(attachmentPath),
    );

    return FutureBuilder<_AttachmentSource?>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        final source = snapshot.data;
        if (source == null) {
          return Center(child: Text(l10n.attachmentMissing));
        }

        final extension = source.extension;
        if (_isImageExtension(extension)) {
          final transformController = _ensureImageTransformationController(
            source.cacheKey,
          );
          final imageWidget = source.bytes != null
              ? Image.memory(source.bytes!)
              : Image.file(source.file);

          return InteractiveViewer(
            transformationController: transformController,
            minScale: 0.1,
            maxScale: 4,
            constrained: true,
            clipBehavior: Clip.hardEdge,
            child: imageWidget,
          );
        }

        if (extension == 'svg') {
          return _buildSvgViewer(source, l10n);
        }

        if (extension == 'pdf') {
          return LayoutBuilder(
            builder: (context, constraints) {
              final availableHeight =
                  constraints.hasBoundedHeight &&
                      constraints.maxHeight.isFinite &&
                      constraints.maxHeight > 0
                  ? constraints.maxHeight
                  : MediaQuery.of(context).size.height;
              return _PdfDocumentView(
                source: source,
                availableHeight: availableHeight,
                currentPageMap: _pdfCurrentPages,
                totalPageMap: _pdfTotalPages,
                controllerMap: _pdfControllers,
                onError: (message) => LoggerService.error(message),
              );
            },
          );
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

  Future<void> _showOutline(List<Note> notes, AppLocalizations l10n) async {
    // Collect linked notes with circular reference prevention
    final linkedNotesMap = <String, List<Note>>{};
    final appProvider = context.read<AppProvider>();

    for (final note in notes) {
      try {
        final linkedNotes = await _collectLinkedNotes(note.id, appProvider);
        if (linkedNotes.isNotEmpty) {
          linkedNotesMap[note.id] = linkedNotes;
        }
      } catch (e) {
        LoggerService.warning('Failed to load linked notes for ${note.id}: $e');
      }
    }

    if (!mounted) return;

    showModalBottomSheet<void>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 12),
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
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
                // Add linked notes section if present
                if (linkedNotesMap.containsKey(notes[i].id)) ...[
                  Padding(
                    padding: const EdgeInsets.only(left: 48, top: 8, bottom: 4),
                    child: Text(
                      'Linked Notes',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Colors.grey[600],
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  for (final linkedNote in linkedNotesMap[notes[i].id]!)
                    ListTile(
                      contentPadding: const EdgeInsets.only(
                        left: 64,
                        right: 16,
                      ),
                      leading: const Icon(Icons.link, size: 20),
                      title: Text(
                        linkedNote.title,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      onTap: () {
                        // Find if this linked note is already in the notes list
                        final linkedIndex = notes.indexWhere(
                          (n) => n.id == linkedNote.id,
                        );
                        if (linkedIndex >= 0) {
                          setState(() {
                            _activeNoteIndex = linkedIndex;
                            _activeAttachmentPath = null;
                          });
                        }
                        Navigator.pop(context);
                      },
                    ),
                ],
              ],
            ],
          ),
        );
      },
    );
  }

  /// Collect linked notes with circular reference prevention
  Future<List<Note>> _collectLinkedNotes(
    String noteId,
    AppProvider appProvider,
  ) async {
    final visited = <String>{noteId}; // Start with current note as visited
    final result = <Note>[];

    try {
      final linkedNotes = await appProvider.getLinkedNotes(noteId);
      for (final linkedNote in linkedNotes) {
        if (!visited.contains(linkedNote.id)) {
          visited.add(linkedNote.id);
          result.add(linkedNote);
        }
      }
    } catch (e) {
      LoggerService.warning('Failed to collect linked notes: $e');
    }

    return result;
  }

  Future<void> _openConversationTree() async {
    if (_conversation == null) return;

    try {
      final appProvider = context.read<AppProvider>();
      final noteIds = List<String>.from(_noteOrder);
      final conversationIds = <String>{_conversation!.id};

      for (final noteId in noteIds) {
        final ids = await appProvider.getNoteConversationIds(noteId);
        conversationIds.addAll(ids);
      }

      if (conversationIds.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No conversations found for these notes.'),
            ),
          );
        }
        return;
      }

      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => ConversationTreeScreen(
            activeConversationIds: conversationIds.toList(growable: false),
            filterByActiveConversations: true,
            onOpenConversation: _handleConversationOpenedFromTree,
          ),
        ),
      );
    } catch (e, stackTrace) {
      LoggerService.error(
        'Failed to open conversation tree: $e',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error loading conversations: $e')),
        );
      }
    }
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

  Future<void> _handleMarkdownLinkTap(String url, AppLocalizations l10n) async {
    final uri = Uri.tryParse(url);
    if (uri == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Invalid URL: $url')));
      return;
    }

    try {
      final canLaunchLink = await canLaunchUrl(uri);
      if (!canLaunchLink) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Could not open link: $url')));
        }
        return;
      }
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e, stackTrace) {
      LoggerService.warning(
        'Failed to open link $url: $e',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error opening link: $e')));
      }
    }
  }

  Future<void> _sendMessage() async {
    final trimmed = _messageController.text.trim();
    if (trimmed.isEmpty && _pendingAttachments.isEmpty) {
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
      // Create conversation on first message if it doesn't exist
      if (_conversation == null) {
        await _initializeConversation();
      }

      if (_conversation == null) {
        throw Exception('Failed to create conversation');
      }

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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error sending message: $e')));
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
      contextMessages:
          contextMessage.content.trim().isEmpty &&
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
      lines.add(
        'No note context is currently attached. Rely on the conversation history.',
      );
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
      _penStrokePoints
        ..clear()
        ..add(localPosition);
    });
  }

  void _handlePenPanUpdate(DragUpdateDetails details) {
    final renderObject = _noteBoundaryKey.currentContext?.findRenderObject();
    if (renderObject is! RenderBox) return;
    final localPosition = renderObject.globalToLocal(details.globalPosition);
    setState(() {
      final lastPoint = _penStrokePoints.isEmpty ? null : _penStrokePoints.last;
      if (lastPoint == null ||
          (lastPoint - localPosition).distanceSquared > 1) {
        _penStrokePoints.add(localPosition);
      }
    });
  }

  Future<void> _handlePenPanEnd() async {
    if (_penStrokePoints.length < 2) {
      _resetPenStroke();
      return;
    }

    final strokePoints = List<Offset>.from(_penStrokePoints);
    final bounds = _computeStrokeBounds(strokePoints);
    _resetPenStroke();

    if (bounds.width < 12 || bounds.height < 12) {
      return;
    }

    try {
      final croppedBytes = await _captureStroke(strokePoints, bounds);
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
      LoggerService.error(
        'Failed to capture annotation: $e',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to capture annotation: $e')),
        );
      }
    }
  }

  void _resetPenStroke() {
    if (_penStrokePoints.isEmpty) {
      return;
    }
    setState(() {
      _penStrokePoints.clear();
    });
  }

  void _disposePdfResources() {
    _pdfControllers.clear();
    _pdfCurrentPages.clear();
    _pdfTotalPages.clear();
    _attachmentSourceFutures.clear();
  }

  void _disposeImageResources() {
    for (final controller in _imageTransforms.values) {
      controller.dispose();
    }
    _imageTransforms.clear();
  }

  void _resetPdfState() {
    _disposePdfResources();
  }

  TransformationController _ensureImageTransformationController(String path) {
    return _imageTransforms.putIfAbsent(path, () => TransformationController());
  }

  Future<bool> _switchConversation(String conversationId) async {
    setState(() => _isLoadingConversation = true);

    try {
      final result = await _conversationService.getConversationWithFullHistory(
        conversationId,
      );

      if (result == null) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Conversation not found.')));
        }
        return false;
      }

      final conversationNotes = await _conversationService.getConversationNotes(
        conversationId,
      );

      if (!mounted) return false;

      setState(() {
        _resetPdfState();
        _disposeImageResources();
        _conversation = result.conversation;
        _messages
          ..clear()
          ..addAll(result.messages);
        _conversationNotes = conversationNotes;
        for (final note in conversationNotes) {
          _initialNotesById[note.id] = note;
        }
        if (conversationNotes.isNotEmpty) {
          _noteOrder = conversationNotes
              .map((note) => note.id)
              .toList(growable: false);
          _activeNoteIndex = min(
            _activeNoteIndex,
            conversationNotes.length - 1,
          );
        } else if (_noteOrder.isNotEmpty) {
          _activeNoteIndex = min(_activeNoteIndex, _noteOrder.length - 1);
        } else if (_initialNotesById.isNotEmpty) {
          _noteOrder = _initialNotesById.keys.toList(growable: false);
          _activeNoteIndex = 0;
        } else {
          _activeNoteIndex = 0;
        }
        _activeAttachmentPath = null;
      });

      _scrollToBottom();
      return true;
    } catch (e, stackTrace) {
      LoggerService.error(
        'Failed to load conversation $conversationId: $e',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to open conversation: $e')),
        );
      }
      return false;
    } finally {
      if (mounted) {
        setState(() => _isLoadingConversation = false);
      }
    }
  }

  Future<bool> _handleConversationOpenedFromTree(
    BuildContext treeContext,
    String conversationId,
  ) async {
    final success = await _switchConversation(conversationId);
    if (success) {
      final navigator = Navigator.of(treeContext);
      if (navigator.canPop()) {
        await navigator.maybePop();
      }
    }
    return true;
  }

  Rect _computeStrokeBounds(List<Offset> points) {
    double minX = points.first.dx;
    double maxX = points.first.dx;
    double minY = points.first.dy;
    double maxY = points.first.dy;

    for (final point in points.skip(1)) {
      if (point.dx < minX) minX = point.dx;
      if (point.dx > maxX) maxX = point.dx;
      if (point.dy < minY) minY = point.dy;
      if (point.dy > maxY) maxY = point.dy;
    }

    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  Rect _clampRectToSize(Rect rect, Size size) {
    final double left = rect.left.clamp(0.0, size.width).toDouble();
    final double top = rect.top.clamp(0.0, size.height).toDouble();
    final double right = rect.right.clamp(0.0, size.width).toDouble();
    final double bottom = rect.bottom.clamp(0.0, size.height).toDouble();
    final double width = max(0.0, right - left);
    final double height = max(0.0, bottom - top);
    return Rect.fromLTWH(left, top, width, height);
  }

  Future<Uint8List> _captureStroke(List<Offset> points, Rect bounds) async {
    final renderObject = _noteBoundaryKey.currentContext?.findRenderObject();
    if (renderObject is! RenderRepaintBoundary) {
      throw Exception('Note view unavailable for capture.');
    }

    final Rect cappedRect = _clampRectToSize(
      bounds.inflate(_strokeCaptureMargin),
      renderObject.size,
    );

    if (cappedRect.width <= 0 || cappedRect.height <= 0) {
      throw Exception('Failed to determine annotation bounds.');
    }

    final double devicePixelRatio = MediaQuery.of(context).devicePixelRatio;
    final ui.Image image = await renderObject.toImage(
      pixelRatio: devicePixelRatio,
    );

    final Rect scaledRect = Rect.fromLTWH(
      cappedRect.left * devicePixelRatio,
      cappedRect.top * devicePixelRatio,
      cappedRect.width * devicePixelRatio,
      cappedRect.height * devicePixelRatio,
    );

    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(recorder);
    final Paint paint = Paint();

    canvas.drawImageRect(
      image,
      scaledRect,
      Rect.fromLTWH(0, 0, scaledRect.width, scaledRect.height),
      paint,
    );

    final List<Offset> scaledPoints = points
        .map(
          (point) => Offset(
            (point.dx - cappedRect.left) * devicePixelRatio,
            (point.dy - cappedRect.top) * devicePixelRatio,
          ),
        )
        .toList();

    if (scaledPoints.length >= 2) {
      final Path strokePath = _FreeformStrokePainter.buildPath(scaledPoints);
      final double strokeWidth = max(4.0, 2.0 * devicePixelRatio);

      final Paint glowPaint = Paint()
        ..color = Colors.redAccent.withOpacity(0.18)
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = strokeWidth * 2;

      final Paint strokePaint = Paint()
        ..color = Colors.redAccent
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = strokeWidth;

      canvas.drawPath(strokePath, glowPaint);
      canvas.drawPath(strokePath, strokePaint);
    }

    final ui.Picture picture = recorder.endRecording();
    final ui.Image croppedImage = await picture.toImage(
      max(1, scaledRect.width.round()),
      max(1, scaledRect.height.round()),
    );
    image.dispose();

    final ByteData? byteData = await croppedImage.toByteData(
      format: ui.ImageByteFormat.png,
    );
    croppedImage.dispose();

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

class _PdfDocumentView extends StatefulWidget {
  const _PdfDocumentView({
    required this.source,
    required this.availableHeight,
    required this.currentPageMap,
    required this.totalPageMap,
    required this.controllerMap,
    required this.onError,
  });

  final _AttachmentSource source;
  final double availableHeight;
  final Map<String, int> currentPageMap;
  final Map<String, int> totalPageMap;
  final Map<String, PDFViewController> controllerMap;
  final void Function(String message) onError;

  @override
  State<_PdfDocumentView> createState() => _PdfDocumentViewState();
}

class _PdfDocumentViewState extends State<_PdfDocumentView>
    with AutomaticKeepAliveClientMixin {
  late Future<String> _pdfPathFuture;
  String? _resolvedPath;
  Widget? _cachedView;

  String get _cacheKey => widget.source.cacheKey;

  @override
  void initState() {
    super.initState();
    _pdfPathFuture = _resolvePdfPath();
  }

  @override
  void didUpdateWidget(covariant _PdfDocumentView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source.cacheKey != widget.source.cacheKey) {
      _pdfPathFuture = _resolvePdfPath();
      _resolvedPath = null;
      _cachedView = null;
    }
  }

  Future<String> _resolvePdfPath() async {
    final file = widget.source.file;
    if (await file.exists()) {
      return file.path;
    }

    final bytes = widget.source.bytes ?? await file.readAsBytes();
    final result = await SynapseTempUtils.saveTempData(
      mimeType: 'application/pdf',
      bytes: bytes,
    );
    return result.file.path;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return FutureBuilder<String>(
      future: _pdfPathFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (!snapshot.hasData || snapshot.hasError) {
          return const Center(child: Text('Failed to load PDF'));
        }

        final filePath = snapshot.data!;
        if (_cachedView == null || _resolvedPath != filePath) {
          _resolvedPath = filePath;
          _cachedView = _buildPdfView(filePath);
        }

        return _cachedView!;
      },
    );
  }

  Widget _buildPdfView(String filePath) {
    widget.currentPageMap.putIfAbsent(_cacheKey, () => 0);

    return PDFView(
      key: ValueKey('${_cacheKey}_pdf_view'),
      filePath: filePath,
      autoSpacing: false,
      pageFling: false,
      pageSnap: false,
      enableSwipe: true,
      swipeHorizontal: false,
      fitPolicy: FitPolicy.BOTH,
      preventLinkNavigation: false,
      onViewCreated: (controller) async {
        widget.controllerMap[_cacheKey] = controller;
        final storedPage = widget.currentPageMap[_cacheKey] ?? 0;
        try {
          final currentPage = await controller.getCurrentPage();
          if (currentPage != storedPage) {
            await controller.setPage(storedPage);
          }
        } catch (e) {
          widget.onError('Unable to set initial PDF page: $e');
        }
      },
      onRender: (pages) {
        if (pages != null) {
          widget.totalPageMap[_cacheKey] = pages;
          final stored = widget.currentPageMap[_cacheKey];
          if (stored != null && stored >= pages) {
            widget.currentPageMap[_cacheKey] = pages - 1;
          }
        }
      },
      onPageChanged: (page, total) {
        if (page != null) {
          widget.currentPageMap[_cacheKey] = page;
        }
        if (total != null) {
          widget.totalPageMap[_cacheKey] = total;
        }
      },
      onError: (error) {
        widget.onError('PDFView error: $error');
      },
      onPageError: (page, error) {
        widget.onError('PDFView page error ($page): $error');
      },
      backgroundColor: Colors.transparent,
    );
  }

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    widget.controllerMap.remove(_cacheKey);
    super.dispose();
  }
}

class _FreeformStrokePainter extends CustomPainter {
  _FreeformStrokePainter(List<Offset>? points)
    : _points = points == null ? null : List<Offset>.unmodifiable(points);

  final List<Offset>? _points;

  @override
  void paint(Canvas canvas, Size size) {
    final points = _points;
    if (points == null || points.length < 2) return;

    final path = buildPath(points);

    final glowPaint = Paint()
      ..color = Colors.redAccent.withOpacity(0.18)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 8;

    final strokePaint = Paint()
      ..color = Colors.redAccent
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 3;

    canvas.drawPath(path, glowPaint);
    canvas.drawPath(path, strokePaint);
  }

  static Path buildPath(List<Offset> points) {
    final path = Path();
    path.moveTo(points.first.dx, points.first.dy);
    for (int i = 1; i < points.length; i++) {
      final prev = points[i - 1];
      final current = points[i];
      final midPoint = Offset(
        (prev.dx + current.dx) / 2,
        (prev.dy + current.dy) / 2,
      );
      path.quadraticBezierTo(prev.dx, prev.dy, midPoint.dx, midPoint.dy);
    }
    path.lineTo(points.last.dx, points.last.dy);
    return path;
  }

  @override
  bool shouldRepaint(covariant _FreeformStrokePainter oldDelegate) {
    return !listEquals(oldDelegate._points, _points);
  }
}

class _AssistantResponse {
  const _AssistantResponse(this.content);

  final String content;
}

enum _AiPanelSide { top, bottom }

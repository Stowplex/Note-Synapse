import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:markdown/markdown.dart' as md;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';
import '../models/note.dart';
import '../providers/app_provider.dart';
import '../l10n/app_localizations.dart';
import '../utils/file_utils.dart';
import '../services/logger_service.dart';
import '../utils/file_type_utils.dart';
import '../utils/synapse_temp_utils.dart';
import 'svg_renderer_service.dart';

class ShareService {
  static const MethodChannel _channel = MethodChannel(
    'com.github.kkspeed/share',
  );
  static bool _initialized = false;
  static bool _waitingForNavigatorFrame = false;
  static bool _isPresentingShareScreen = false;
  static final List<Map<String, dynamic>> _pendingSharedQueue =
      <Map<String, dynamic>>[];
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();
  static final _ShareLifecycleObserver _lifecycleObserver =
      _ShareLifecycleObserver();
  static bool _observerAttached = false;

  static Future<void> init([AppProvider? appProvider]) async {
    if (_initialized) {
      final hasNew = await _fetchAndQueueSharedContent();
      if (hasNew || _pendingSharedQueue.isNotEmpty) {
        _handlePendingQueue();
      }
      return;
    }

    _initialized = true;
    _attachLifecycleObserver();
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'newSharedContent') {
        await handleSharedContent();
      }
    });

    final hasNew = await _fetchAndQueueSharedContent();
    if (hasNew || _pendingSharedQueue.isNotEmpty) {
      _handlePendingQueue();
    }
  }

  static Future<void> handleSharedContent([AppProvider? appProvider]) async {
    final hasNew = await _fetchAndQueueSharedContent();
    if (hasNew || _pendingSharedQueue.isNotEmpty) {
      _handlePendingQueue();
    }
  }

  static void _attachLifecycleObserver() {
    if (_observerAttached) {
      return;
    }
    WidgetsBinding.instance.addObserver(_lifecycleObserver);
    _observerAttached = true;
  }

  static void _handleAppResumed() {
    Future<void>(() async {
      final hasNew = await _fetchAndQueueSharedContent();
      if (hasNew || _pendingSharedQueue.isNotEmpty) {
        _handlePendingQueue();
      }
    });
  }

  /// Generates markdown text from a list of notes with optional sub-notes and linked notes
  static Future<String> generateMarkdownText({
    required List<Note> notes,
    required bool includeSubNotesAndLinkedNotes,
    required AppProvider appProvider,
    required AppLocalizations l10n,
  }) async {
    final buffer = StringBuffer();
    final Set<String> visitedNoteIds = <String>{};
    final Queue<Note> noteQueue = Queue<Note>();

    // Add root notes to the queue
    for (final note in notes) {
      noteQueue.add(note);
    }

    // Breadth-first traversal
    while (noteQueue.isNotEmpty) {
      final currentNote = noteQueue.removeFirst();

      // Skip if already processed
      if (visitedNoteIds.contains(currentNote.id)) {
        continue;
      }

      // Mark as visited
      visitedNoteIds.add(currentNote.id);

      // Add current note to buffer
      await _addNoteToBuffer(
        note: currentNote,
        buffer: buffer,
        processedNoteIds: visitedNoteIds,
        includeSubNotesAndLinkedNotes: includeSubNotesAndLinkedNotes,
        appProvider: appProvider,
        l10n: l10n,
        level: 0,
      );

      // If including linked notes, add them to the queue for processing
      if (includeSubNotesAndLinkedNotes) {
        try {
          final relationships = await appProvider.getNoteRelationships(
            currentNote.id,
          );
          final linkedNotes = await appProvider.getLinkedNotes(currentNote.id);

          for (final relationship in relationships) {
            final linkedNote = linkedNotes.firstWhere(
              (n) =>
                  n.id ==
                  (relationship.fromNoteId == currentNote.id
                      ? relationship.toNoteId
                      : relationship.fromNoteId),
              orElse: () => Note(
                id: 'unknown',
                title: 'Unknown Note',
                content: '',
                type: NoteType.note,
                createdAt: DateTime.now(),
                updatedAt: DateTime.now(),
              ),
            );

            // Add to queue if not already visited and not unknown
            if (linkedNote.id != 'unknown' &&
                !visitedNoteIds.contains(linkedNote.id)) {
              noteQueue.add(linkedNote);
            }
          }
        } catch (e) {
          // If there's an error loading relationships, just continue
          // Silently handle relationship loading errors
        }
      }
    }

    return buffer.toString();
  }

  /// Generates a PDF from selected notes and shares or saves it depending on the platform.
  static Future<_PdfShareResult?> shareAsPdf({
    required List<Note> notes,
    required bool includeSubNotesAndLinkedNotes,
    required AppProvider appProvider,
    required AppLocalizations l10n,
    required Size pageSize,
    bool useSinglePageLayout = false,
  }) async {
    try {
      final notesToExport = await _collectNotesForExport(
        notes: notes,
        includeLinkedNotes: includeSubNotesAndLinkedNotes,
        appProvider: appProvider,
      );

      if (notesToExport.isEmpty) {
        return null;
      }

      final pdfBytes = await _buildPdfBytes(
        notes: notesToExport,
        includeSubNotes: includeSubNotesAndLinkedNotes,
        l10n: l10n,
        pageSize: pageSize,
        useSinglePageLayout: useSinglePageLayout,
      );

      final fileName = 'notes_${DateTime.now().millisecondsSinceEpoch}.pdf';

      File? cacheFile;
      if (!kIsWeb) {
        final cacheDir = await getTemporaryDirectory();
        cacheFile = File(p.join(cacheDir.path, fileName));
        await cacheFile.writeAsBytes(pdfBytes, flush: true);
      }

      if (kIsWeb) {
        await FileSaver.instance.saveAs(
          name: fileName,
          bytes: Uint8List.fromList(pdfBytes),
          fileExtension: 'pdf',
          mimeType: MimeType.pdf,
        );
      } else if (Platform.isAndroid) {
        final tempFile = cacheFile!;
        await Share.shareXFiles([
          XFile(tempFile.path, mimeType: 'application/pdf', name: fileName),
        ], subject: l10n.shareDialogTitle);
      } else if (Platform.isIOS) {
        // On iOS, try to use save dialog first, then fall back to share sheet if needed
        final tempFile = cacheFile!;
        try {
          // Try to use file picker save dialog (if supported on iOS)
          final result = await FilePicker.platform.saveFile(
            dialogTitle: l10n.selectFileLocation,
            fileName: fileName,
            type: FileType.custom,
            allowedExtensions: const ['pdf'],
          );

          if (result != null) {
            // User selected a location, save the file
            final destination = File(result);
            await destination.writeAsBytes(pdfBytes, flush: true);
          } else {
            // User cancelled save dialog, show share sheet instead
            // Share sheet allows saving to Files app and sharing to other apps
            await Share.shareXFiles([
              XFile(tempFile.path, mimeType: 'application/pdf', name: fileName),
            ], subject: l10n.shareDialogTitle);
          }
        } catch (e) {
          // If save dialog is not supported or fails, use share sheet
          // Share sheet is the standard iOS way and allows saving to Files app
          await Share.shareXFiles([
            XFile(tempFile.path, mimeType: 'application/pdf', name: fileName),
          ], subject: l10n.shareDialogTitle);
        }
      } else if (Platform.isLinux || Platform.isWindows || Platform.isMacOS) {
        final result = await FilePicker.platform.saveFile(
          dialogTitle: l10n.selectFileLocation,
          fileName: fileName,
          type: FileType.custom,
          allowedExtensions: const ['pdf'],
        );

        if (result != null) {
          final destination = File(result);
          await destination.writeAsBytes(pdfBytes, flush: true);
        }
      }

      return _PdfShareResult(fileName: fileName, cacheFile: cacheFile);
    } catch (e, stackTrace) {
      LoggerService.error(
        'Error generating PDF for sharing: $e',
        error: e,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  static Future<List<Note>> _collectNotesForExport({
    required List<Note> notes,
    required bool includeLinkedNotes,
    required AppProvider appProvider,
  }) async {
    final visited = <String>{};
    final queue = Queue<Note>();
    final ordered = <Note>[];

    for (final note in notes) {
      if (!visited.contains(note.id)) {
        queue.add(note);
      }
    }

    while (queue.isNotEmpty) {
      final current = queue.removeFirst();
      if (visited.contains(current.id)) {
        continue;
      }
      visited.add(current.id);
      ordered.add(current);

      if (includeLinkedNotes) {
        try {
          final linkedNotes = await appProvider.getLinkedNotes(current.id);
          for (final linked in linkedNotes) {
            if (!visited.contains(linked.id)) {
              queue.add(linked);
            }
          }
        } catch (e, stackTrace) {
          LoggerService.warning(
            'Failed to load linked notes for ${current.id}: $e',
            error: e,
            stackTrace: stackTrace,
          );
        }
      }
    }

    return ordered;
  }

  static Future<List<int>> _buildPdfBytes({
    required List<Note> notes,
    required bool includeSubNotes,
    required AppLocalizations l10n,
    required Size pageSize,
    required bool useSinglePageLayout,
  }) async {
    final fonts = await _PdfFontManager.instance.load();

    // If single page layout is requested, we need to calculate the height first
    // We'll use a temporary page format for content generation
    var pageFormat = PdfPageFormat(pageSize.width, pageSize.height);

    final theme = pw.ThemeData.withFont(
      base: fonts.base,
      bold: fonts.bold,
      italic: fonts.italic,
      boldItalic: fonts.boldItalic,
    );

    final exporter = _PdfNoteRenderer(
      notes: notes,
      includeSubNotes: includeSubNotes,
      l10n: l10n,
      pageFormat: pageFormat,
      fonts: fonts,
    );

    final content = await exporter.buildContent();

    // Collect all PDF attachments from notes
    final pdfAttachments = await _collectPdfAttachments(notes);

    // Create the main document
    final document = pw.Document(theme: theme);

    if (useSinglePageLayout) {
      // Calculate estimated height for single page
      double estimatedHeight = 100.0; // margins

      // Heuristic estimation
      // We can't verify exact height of widgets without layout, so we overestimate conservatively
      for (final note in notes) {
        // Title
        estimatedHeight += 40.0;

        // Metadata
        estimatedHeight += 40.0;

        // Content
        if (note.content.isNotEmpty) {
          // Estimate text height: approx 80 chars per line, 14pt per line
          final lineCount = (note.content.length / 80).ceil();
          estimatedHeight += lineCount * 14.0;

          // Add extra for newlines which might be paragraphs
          final paragraphCount = note.content.split('\n').length;
          estimatedHeight += paragraphCount * 10.0;

          // Check for markdown images in content
          final imageMatches = RegExp(
            r'!\[.*?\]\(.*?\)',
          ).allMatches(note.content);
          // Assume max height for images (e.g. 400pt)
          estimatedHeight += imageMatches.length * 400.0;
        }

        // Subnotes
        if (includeSubNotes) {
          for (final subNote in note.subNotes) {
            estimatedHeight += 30.0; // Header
            final lineCount = (subNote.content.length / 80).ceil();
            estimatedHeight += lineCount * 14.0;
            final paragraphCount = subNote.content.split('\n').length;
            estimatedHeight += paragraphCount * 10.0;
          }
        }

        // Attachments
        for (final path in note.attachmentPaths) {
          // Assume each attachment takes some vertical space (image or file listing)
          // Images/SVGs can be up to 500px wide, let's assume 400px height avg
          estimatedHeight += 400.0;
        }

        // Spacing/Divider
        estimatedHeight += 50.0;
      }

      // Add a safety buffer (20%) + fixed minimum
      estimatedHeight = (estimatedHeight * 1.2) + 1000.0;

      LoggerService.debug('Estimated single page PDF height: $estimatedHeight');

      pageFormat = PdfPageFormat(pageSize.width, estimatedHeight);

      document.addPage(
        pw.Page(
          pageFormat: pageFormat,
          margin: const pw.EdgeInsets.all(24),
          build: (context) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: content,
          ),
        ),
      );
    } else {
      // Add the generated note content pages FIRST
      document.addPage(
        pw.MultiPage(
          pageFormat: pageFormat,
          margin: const pw.EdgeInsets.all(24),
          build: (context) => content,
          maxPages: 10000, // Allow up to 10000 pages to handle large exports
        ),
      );
    }

    // If there are PDF attachments, add them as image pages AFTER the note content
    if (pdfAttachments.isNotEmpty) {
      for (var i = 0; i < pdfAttachments.length; i++) {
        try {
          final pdfBytes = pdfAttachments[i];
          LoggerService.debug(
            'Converting PDF attachment ${i + 1} to images (${pdfBytes.length} bytes)',
          );

          // Convert each PDF page to an image and add it to the document
          await for (final page in Printing.raster(pdfBytes, dpi: 150)) {
            final imageBytes = await page.toPng();
            final image = pw.MemoryImage(imageBytes);

            document.addPage(
              pw.Page(
                pageFormat: pageFormat,
                build: (context) =>
                    pw.Center(child: pw.Image(image, fit: pw.BoxFit.contain)),
              ),
            );
          }

          LoggerService.debug(
            'Successfully added PDF attachment ${i + 1} as images',
          );
        } catch (e, stackTrace) {
          LoggerService.warning(
            'Failed to convert PDF attachment ${i + 1} to images: $e',
            error: e,
            stackTrace: stackTrace,
          );

          // Add a placeholder page for the failed PDF
          document.addPage(
            pw.Page(
              pageFormat: pageFormat,
              build: (context) => pw.Center(
                child: pw.Text(
                  'PDF Attachment ${i + 1}\n(Preview unavailable)',
                  style: pw.TextStyle(fontSize: 16, color: PdfColors.grey600),
                  textAlign: pw.TextAlign.center,
                ),
              ),
            ),
          );
        }
      }
    }

    final result = await document.save();
    LoggerService.debug('Generated final PDF: ${result.length} bytes');
    return result;
  }

  /// Collect all PDF attachments from the notes
  static Future<List<Uint8List>> _collectPdfAttachments(
    List<Note> notes,
  ) async {
    final pdfAttachments = <Uint8List>[];

    for (final note in notes) {
      for (final attachmentPath in note.attachmentPaths) {
        try {
          final extension = FileTypeUtils.getFileExtension(
            attachmentPath,
          ).toLowerCase();
          if (extension != 'pdf') {
            continue;
          }

          final file = File(attachmentPath);
          if (!await file.exists()) {
            LoggerService.warning('PDF attachment not found: $attachmentPath');
            continue;
          }

          final bytes = await file.readAsBytes();
          pdfAttachments.add(bytes);
          LoggerService.debug(
            'Collected PDF attachment: $attachmentPath (${bytes.length} bytes)',
          );
        } catch (e, stackTrace) {
          LoggerService.warning(
            'Failed to load PDF attachment $attachmentPath: $e',
            error: e,
            stackTrace: stackTrace,
          );
        }
      }
    }

    return pdfAttachments;
  }

  static Future<Uint8List?> _loadImageBytesFromSource(String source) async {
    if (source.isEmpty) {
      return null;
    }

    try {
      if (SynapseTempUtils.isSynapseTempUri(source)) {
        final tempFile = await SynapseTempUtils.loadFile(source);
        return tempFile.bytes;
      }

      final uri = Uri.tryParse(source);
      if (uri != null && uri.hasScheme) {
        if (uri.scheme == 'http' || uri.scheme == 'https') {
          final response = await http
              .get(uri)
              .timeout(const Duration(seconds: 12));
          if (response.statusCode == 200) {
            return response.bodyBytes;
          }
          return null;
        }

        if (uri.scheme == 'file') {
          final file = File(uri.toFilePath());
          if (await file.exists()) {
            return await file.readAsBytes();
          }
        }

        if (uri.scheme == 'data') {
          try {
            final dataUri = UriData.parse(source);
            return Uint8List.fromList(dataUri.contentAsBytes());
          } catch (e) {
            LoggerService.warning(
              'Failed to parse data URI image: $e',
              error: e,
            );
            return null;
          }
        }
      }

      final file = File(source);
      if (await file.exists()) {
        return await file.readAsBytes();
      }
    } catch (e, stackTrace) {
      LoggerService.warning(
        'Failed to load image bytes from $source: $e',
        error: e,
        stackTrace: stackTrace,
      );
    }
    return null;
  }

  static Future<Uint8List?> _loadImageBytesFromFilePath(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        return await file.readAsBytes();
      }
    } catch (e, stackTrace) {
      LoggerService.warning(
        'Failed to read image bytes from $path: $e',
        error: e,
        stackTrace: stackTrace,
      );
    }
    return null;
  }

  static bool _isSvgSource(String source) {
    if (source.isEmpty) return false;
    final lower = source.toLowerCase().trim();
    if (lower.startsWith('data:')) {
      try {
        final data = UriData.parse(source);
        final mime = data.mimeType.toLowerCase();
        return mime.contains('image/svg');
      } catch (_) {
        return false;
      }
    }

    final uri = Uri.tryParse(source);
    if (uri != null) {
      final path = uri.path.toLowerCase();
      if (path.endsWith('.svg')) {
        return true;
      }
    }

    return lower.endsWith('.svg');
  }

  static bool _isSvgFileName(String fileName) {
    return fileName.toLowerCase().endsWith('.svg');
  }

  static String _decodeBytesToString(Uint8List bytes) {
    try {
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return String.fromCharCodes(bytes);
    }
  }

  static Future<String?> _loadSvgStringFromSource(String source) async {
    try {
      if (SynapseTempUtils.isSynapseTempUri(source)) {
        final tempFile = await SynapseTempUtils.loadFile(source);
        return _decodeBytesToString(tempFile.bytes);
      }

      final uri = Uri.tryParse(source);
      if (uri != null) {
        if (uri.scheme == 'data') {
          final data = UriData.parse(source);
          return data.contentAsString();
        }

        if (uri.scheme == 'http' || uri.scheme == 'https') {
          final response = await http
              .get(uri)
              .timeout(const Duration(seconds: 12));
          if (response.statusCode == 200) {
            return response.body;
          }
          return null;
        }

        if (uri.scheme == 'file') {
          final file = File(uri.toFilePath());
          if (await file.exists()) {
            return await file.readAsString();
          }
          return null;
        }
      }

      final file = File(source);
      if (await file.exists()) {
        return await file.readAsString();
      }
    } catch (e, stackTrace) {
      LoggerService.warning(
        'Failed to load SVG from $source: $e',
        error: e,
        stackTrace: stackTrace,
      );
    }
    return null;
  }

  static Future<String?> _loadSvgStringFromFilePath(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) {
        return await file.readAsString();
      }
    } catch (e, stackTrace) {
      LoggerService.warning(
        'Failed to read SVG file $path: $e',
        error: e,
        stackTrace: stackTrace,
      );
    }
    return null;
  }

  /// Adds a note to the buffer with proper markdown formatting
  static Future<void> _addNoteToBuffer({
    required Note note,
    required StringBuffer buffer,
    required Set<String> processedNoteIds,
    required bool includeSubNotesAndLinkedNotes,
    required AppProvider appProvider,
    required AppLocalizations l10n,
    required int level,
  }) async {
    // Note: We don't need to check for duplicates here since the main BFS loop
    // already handles the visited check before calling this method

    // Add note header
    final headerPrefix = '#${'#' * level}';
    buffer.writeln('$headerPrefix ${note.title}');
    buffer.writeln();

    // Add note metadata
    buffer.writeln('**${l10n.type}:** ${note.isTask ? l10n.task : l10n.note}');
    if (note.isTask && note.status != null) {
      buffer.writeln(
        '**${l10n.status}:** ${_getStatusText(note.status!, l10n)}',
      );
    }
    if (note.tags.isNotEmpty) {
      buffer.writeln('**${l10n.tags}:** ${note.tags.join(', ')}');
    }
    buffer.writeln('**${l10n.created}:** ${_formatDateTime(note.createdAt)}');
    if (note.updatedAt != note.createdAt) {
      buffer.writeln('**${l10n.updated}:** ${_formatDateTime(note.updatedAt)}');
    }
    buffer.writeln();

    // Add note content
    if (note.content.isNotEmpty) {
      buffer.writeln(note.content);
      buffer.writeln();
    }

    // Add sub-notes if requested
    if (includeSubNotesAndLinkedNotes && note.subNotes.isNotEmpty) {
      buffer.writeln('## ${l10n.subNotes}');
      buffer.writeln();

      for (final subNote in note.subNotes) {
        buffer.writeln('### ${subNote.name}');
        if (subNote.isCompleted) {
          buffer.writeln('✅ **${l10n.completed}**');
        }
        buffer.writeln(
          '**${l10n.created}:** ${_formatDateTime(subNote.createdAt)}',
        );
        buffer.writeln();
        if (subNote.content.isNotEmpty) {
          buffer.writeln(subNote.content);
          buffer.writeln();
        }
      }
    }

    // Add separator between notes
    if (level == 0) {
      buffer.writeln('---');
      buffer.writeln();
    }
  }

  /// Copies text to clipboard
  static Future<void> copyToClipboard(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
  }

  /// Shares text as a file (platform-specific)
  static Future<void> shareAsText(String text, BuildContext context) async {
    if (Platform.isAndroid || Platform.isIOS) {
      await _shareAsTextMobile(text, context);
    } else if (!kIsWeb &&
        (Platform.isLinux || Platform.isWindows || Platform.isMacOS)) {
      await _shareAsTextDesktop(text, context);
    } else {
      // Fallback: copy to clipboard
      await copyToClipboard(text);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Text copied to clipboard (sharing not supported on this platform)',
            ),
            backgroundColor: Colors.orange,
          ),
        );
      }
    }
  }

  /// Mobile sharing using share_plus (Android and iOS)
  static Future<void> _shareAsTextMobile(
    String text,
    BuildContext context,
  ) async {
    try {
      await Share.share(text, subject: 'Shared Notes');
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error sharing: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Desktop sharing (Linux, Windows, macOS) - Save as file
  static Future<void> _shareAsTextDesktop(
    String text,
    BuildContext context,
  ) async {
    try {
      // Use file_picker to let user choose where to save
      final result = await FilePicker.platform.saveFile(
        dialogTitle: 'Save Notes as Markdown',
        fileName: 'notes_${DateTime.now().millisecondsSinceEpoch}.md',
        type: FileType.custom,
        allowedExtensions: ['md'],
      );

      if (result != null) {
        final file = File(result);
        await file.writeAsString(text);

        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Notes saved successfully'),
              backgroundColor: Colors.green,
            ),
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error saving file: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  /// Helper method to get status text
  static String _getStatusText(TaskStatus status, AppLocalizations l10n) {
    switch (status) {
      case TaskStatus.complete:
        return l10n.completed;
      case TaskStatus.inProgress:
        return l10n.inProgress;
      case TaskStatus.abandoned:
        return l10n.cancelled;
      case TaskStatus.todo:
        return l10n.toDo;
    }
  }

  /// Helper method to format DateTime
  static String _formatDateTime(DateTime dateTime) {
    return '${dateTime.day}/${dateTime.month}/${dateTime.year} at ${dateTime.hour}:${dateTime.minute.toString().padLeft(2, '0')}';
  }

  /// Process shared content from platform channels
  static Future<Map<String, dynamic>> processSharedContent(
    Map<String, dynamic> sharedData,
  ) async {
    try {
      final String? action = sharedData['action'];
      final String? type = sharedData['type'];
      final String? text = sharedData['text'];
      final String? filePath = sharedData['filePath'];
      final String? fileName = sharedData['fileName'];
      final String? contentType = sharedData['contentType'];
      final String? url = sharedData['url'];

      if (action == 'SEND' || action == 'SEND_MULTIPLE') {
        // Handle URL content type (from clipboard detection)
        if (contentType == 'url' && url != null) {
          return {'success': true, 'contentType': 'url', 'url': url};
        }
        // Handle regular text content
        else if (type == 'text/plain' && text != null) {
          return await _processTextContent(text);
        }
        // Handle image content
        else if (type?.startsWith('image/') == true && filePath != null) {
          return await _processImageContent(filePath, fileName);
        }
        // Handle PDF content
        else if (type == 'application/pdf' && filePath != null) {
          return await _processPdfContent(filePath, fileName);
        }
      }

      return {'success': false, 'error': 'Unsupported content type: $type'};
    } catch (e) {
      return {'success': false, 'error': 'Error processing shared content: $e'};
    }
  }

  /// Process text content
  static Future<Map<String, dynamic>> _processTextContent(String text) async {
    try {
      // Check if the text is a URL (fallback detection)
      final url = _extractUrl(text);
      if (url != null) {
        return {'success': true, 'contentType': 'url', 'url': url};
      }

      final note = Note(
        id: const Uuid().v4(),
        title: 'Shared Text - ${DateTime.now().toString().substring(0, 16)}',
        content: text,
        type: NoteType.note,
        tags: ['shared', 'text'],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      return {'success': true, 'note': note};
    } catch (e) {
      return {'success': false, 'error': 'Error processing text content: $e'};
    }
  }

  /// Extract URL from text.
  /// Returns the first URL match if its length is greater than 1/5 of the total text length.
  static String? _extractUrl(String text) {
    if (text.isEmpty) return null;

    // Find all potential URLs
    // Using a more robust regex that stops at common punctuation if at end, but simplifying for now
    // to match typical "http://..." non-whitespace sequences which is standard for simple extractors.
    final uriPattern = RegExp(r'https?://[^\s]+');
    final matches = uriPattern.allMatches(text);

    for (final match in matches) {
      final urlString = match.group(0);
      if (urlString == null) continue;

      try {
        // Validate URL structure
        final uri = Uri.parse(urlString);
        if (uri.scheme != 'http' && uri.scheme != 'https') continue;

        // Ratio check: URL length > Total text length / 5
        // Example: URL is 21 chars. Text is 100 chars. 21 > 20 => TRUE.
        if (urlString.length > text.length / 5.0) {
          return urlString;
        }
      } catch (e) {
        // Invalid URI, skip
      }
    }

    return null;
  }

  /// Check if file already exists in persistent storage and get relative path
  static Future<String?> _getOrCopyToPersistentStorage(
    String absolutePath,
    String fileName,
  ) async {
    try {
      // Check if file already exists in persistent storage
      final appDir = await getApplicationDocumentsDirectory();
      final persistentPath = '${appDir.path}/attachments/$fileName';
      final persistentFile = File(persistentPath);

      if (await persistentFile.exists()) {
        // File already exists, return relative path
        return 'attachments/$fileName';
      }

      // File doesn't exist, copy from Android temp location to persistent storage
      final sourceFile = File(absolutePath);
      if (await sourceFile.exists()) {
        final bytes = await sourceFile.readAsBytes();
        return await FileUtils.saveFileToPrivateStorage(bytes, fileName);
      }

      return null;
    } catch (e) {
      LoggerService.error('Error handling file: $e', error: e);
      return null;
    }
  }

  /// Process image content
  static Future<Map<String, dynamic>> _processImageContent(
    String filePath,
    String? fileName,
  ) async {
    try {
      // Check if file already exists in persistent storage or copy it
      final relativePath = await _getOrCopyToPersistentStorage(
        filePath,
        fileName ?? 'shared_image',
      );
      if (relativePath == null) {
        return {
          'success': false,
          'error': 'Could not process image file: $filePath',
        };
      }

      final note = Note(
        id: const Uuid().v4(),
        title: 'Shared Image - ${DateTime.now().toString().substring(0, 16)}',
        content: 'Image shared from ${fileName ?? 'unknown source'}',
        type: NoteType.note,
        tags: ['shared', 'image'],
        attachmentPaths: [relativePath],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      return {'success': true, 'note': note};
    } catch (e) {
      return {'success': false, 'error': 'Error processing image content: $e'};
    }
  }

  /// Process PDF content
  static Future<Map<String, dynamic>> _processPdfContent(
    String filePath,
    String? fileName,
  ) async {
    try {
      // Check if file already exists in persistent storage or copy it
      final relativePath = await _getOrCopyToPersistentStorage(
        filePath,
        fileName ?? 'shared_pdf',
      );
      if (relativePath == null) {
        return {
          'success': false,
          'error': 'Could not process PDF file: $filePath',
        };
      }

      final note = Note(
        id: const Uuid().v4(),
        title: 'Shared PDF - ${DateTime.now().toString().substring(0, 16)}',
        content: 'PDF shared from ${fileName ?? 'unknown source'}',
        type: NoteType.note,
        tags: ['shared', 'pdf'],
        attachmentPaths: [relativePath],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      return {'success': true, 'note': note};
    } catch (e) {
      return {'success': false, 'error': 'Error processing PDF content: $e'};
    }
  }

  static Future<bool> _fetchAndQueueSharedContent() async {
    try {
      final rawShared = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'getSharedContent',
      );
      if (rawShared == null || rawShared.isEmpty) {
        return false;
      }

      final normalized = _normalizeSharedData(rawShared);
      LoggerService.info(
        'ShareService received shared content: ${normalized.keys}',
      );
      _pendingSharedQueue.add(normalized);
      return true;
    } catch (e, stackTrace) {
      LoggerService.error(
        'Error retrieving shared content: $e',
        error: e,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  static Map<String, dynamic> _normalizeSharedData(
    Map<dynamic, dynamic> input,
  ) {
    final result = <String, dynamic>{};
    input.forEach((key, value) {
      if (key == null) {
        return;
      }
      final stringKey = key.toString();
      if (value is Map) {
        result[stringKey] = _normalizeSharedData(
          value.cast<dynamic, dynamic>(),
        );
      } else if (value is List) {
        result[stringKey] = value
            .map(
              (item) => item is Map
                  ? _normalizeSharedData(item.cast<dynamic, dynamic>())
                  : item,
            )
            .toList();
      } else {
        result[stringKey] = value;
      }
    });
    return result;
  }

  static void _handlePendingQueue() {
    if (_pendingSharedQueue.isEmpty) {
      return;
    }
    if (Platform.isIOS) {
      _scheduleNavigatorCheck(forceFrame: true);
    } else {
      final presented = _tryPresentPendingSharedContent();
      if (!presented) {
        _scheduleNavigatorCheck(forceFrame: true);
      }
    }
  }

  static void _scheduleNavigatorCheck({bool forceFrame = false}) {
    if (_waitingForNavigatorFrame) {
      return;
    }
    if (_pendingSharedQueue.isEmpty) {
      return;
    }
    _waitingForNavigatorFrame = true;
    if (forceFrame) {
      WidgetsBinding.instance.scheduleFrame();
    }
    final navigator = navigatorKey.currentState;
    final bool needsDelay = navigator == null || !navigator.mounted;

    void callback(_) {
      _waitingForNavigatorFrame = false;
      _tryPresentPendingSharedContent();
    }

    if (needsDelay) {
      Future.microtask(() => callback(null));
    } else {
      WidgetsBinding.instance.addPostFrameCallback(callback);
    }
  }

  static bool _tryPresentPendingSharedContent({bool allowReschedule = true}) {
    if (_pendingSharedQueue.isEmpty) {
      return false;
    }

    final navigator = navigatorKey.currentState;
    if (navigator == null || !navigator.mounted) {
      if (allowReschedule) {
        _scheduleNavigatorCheck(forceFrame: true);
      }
      return false;
    }

    if (_isPresentingShareScreen) {
      return true;
    }

    final sharedData = _pendingSharedQueue.removeAt(0);

    late final Future<dynamic> navigationFuture;
    try {
      navigationFuture = navigator.pushNamed('/share', arguments: sharedData);
    } catch (error, stackTrace) {
      LoggerService.error(
        'ShareService failed to present share screen: $error',
        error: error,
        stackTrace: stackTrace,
      );
      _isPresentingShareScreen = false;
      _pendingSharedQueue.insert(0, sharedData);
      _handlePendingQueue();
      return false;
    }

    _isPresentingShareScreen = true;

    navigationFuture.whenComplete(() {
      _isPresentingShareScreen = false;
      if (_pendingSharedQueue.isNotEmpty) {
        _handlePendingQueue();
      }
    });
    navigationFuture.catchError((error, stackTrace) {
      LoggerService.error(
        'ShareService encountered navigation error: $error',
        error: error,
        stackTrace: stackTrace,
      );
      _isPresentingShareScreen = false;
      _pendingSharedQueue.insert(0, sharedData);
      _handlePendingQueue();
    });

    return true;
  }
}

class _ShareLifecycleObserver extends WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ShareService._handleAppResumed();
    }
  }
}

class _PdfShareResult {
  const _PdfShareResult({required this.fileName, this.cacheFile});

  final String fileName;
  final File? cacheFile;
}

class _PdfFonts {
  const _PdfFonts({
    required this.base,
    required this.bold,
    required this.italic,
    required this.boldItalic,
    required this.monospace,
    required this.fallback,
  });

  final pw.Font base;
  final pw.Font bold;
  final pw.Font italic;
  final pw.Font boldItalic;
  final pw.Font monospace;
  final List<pw.Font> fallback;
}

class _PdfFontManager {
  _PdfFontManager._();

  static final _PdfFontManager instance = _PdfFontManager._();

  _PdfFonts? _cache;

  Future<_PdfFonts> load() async {
    if (_cache != null) {
      return _cache!;
    }

    try {
      final base = await PdfGoogleFonts.notoSansSCRegular();
      final bold = await PdfGoogleFonts.notoSansSCBold();
      final monospace = await PdfGoogleFonts.robotoMonoRegular();

      _cache = _PdfFonts(
        base: base,
        bold: bold,
        italic: base,
        boldItalic: bold,
        monospace: monospace,
        fallback: [base],
      );
    } catch (e, stackTrace) {
      LoggerService.warning(
        'Failed to load PDF fonts from Google Fonts, falling back to Helvetica: $e',
        error: e,
        stackTrace: stackTrace,
      );

      final base = pw.Font.helvetica();
      final bold = pw.Font.helveticaBold();
      final italic = pw.Font.helveticaOblique();
      final boldItalic = pw.Font.helveticaBoldOblique();
      final monospace = pw.Font.courier();

      _cache = _PdfFonts(
        base: base,
        bold: bold,
        italic: italic,
        boldItalic: boldItalic,
        monospace: monospace,
        fallback: [base],
      );
    }

    return _cache!;
  }
}

class _PdfNoteRenderer {
  _PdfNoteRenderer({
    required this.notes,
    required this.includeSubNotes,
    required this.l10n,
    required this.pageFormat,
    required this.fonts,
  }) : _contentWidth = math.max(pageFormat.width - 48, 0),
       _markdownRenderer = _MarkdownPdfRenderer(
         l10n: l10n,
         maxContentWidth: math.max(pageFormat.width - 48, 0),
         fonts: fonts,
       );

  final List<Note> notes;
  final bool includeSubNotes;
  final AppLocalizations l10n;
  final PdfPageFormat pageFormat;
  final _PdfFonts fonts;

  final double _contentWidth;
  final _MarkdownPdfRenderer _markdownRenderer;

  Future<List<pw.Widget>> buildContent() async {
    final widgets = <pw.Widget>[];
    final titleStyle = pw.TextStyle(
      fontSize: 20,
      fontWeight: pw.FontWeight.bold,
      fontFallback: fonts.fallback,
    );
    final sectionTitleStyle = pw.TextStyle(
      fontSize: 14,
      fontWeight: pw.FontWeight.bold,
      color: PdfColors.grey700,
      fontFallback: fonts.fallback,
    );

    for (var index = 0; index < notes.length; index++) {
      final note = notes[index];

      widgets.add(
        pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 8),
          child: pw.Text(
            note.title.isEmpty ? l10n.note : note.title,
            style: titleStyle,
          ),
        ),
      );

      widgets.add(_buildMetadata(note));

      final content = note.content.trim();
      if (content.isNotEmpty) {
        final markdownWidgets = await _markdownRenderer.render(content);
        for (final widget in markdownWidgets) {
          widgets.add(
            pw.Padding(
              padding: const pw.EdgeInsets.only(top: 6),
              child: widget,
            ),
          );
        }
      }

      if (includeSubNotes && note.subNotes.isNotEmpty) {
        final subNoteWidgets = await _buildSubNotes(note, sectionTitleStyle);
        widgets.addAll(subNoteWidgets);
      }

      final attachmentWidgets = await _buildAttachments(
        note,
        sectionTitleStyle,
      );
      widgets.addAll(attachmentWidgets);

      if (index < notes.length - 1) {
        widgets
          ..add(pw.SizedBox(height: 16))
          ..add(pw.Divider(color: PdfColors.grey400))
          ..add(pw.SizedBox(height: 16));
      }
    }

    return widgets;
  }

  pw.Widget _buildMetadata(Note note) {
    final metadata = <pw.Widget>[
      _metadataLine(l10n.type, note.isTask ? l10n.task : l10n.note),
    ];

    if (note.isTask && note.status != null) {
      metadata.add(
        _metadataLine(
          l10n.status,
          ShareService._getStatusText(note.status!, l10n),
        ),
      );
    }

    if (note.tags.isNotEmpty) {
      metadata.add(_metadataLine(l10n.tags, note.tags.join(', ')));
    }

    metadata
      ..add(
        _metadataLine(
          l10n.created,
          ShareService._formatDateTime(note.createdAt),
        ),
      )
      ..add(
        _metadataLine(
          l10n.updated,
          ShareService._formatDateTime(note.updatedAt),
        ),
      );

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: metadata,
    );
  }

  pw.Widget _metadataLine(String label, String value) {
    final labelStyle = pw.TextStyle(
      fontSize: 10,
      fontWeight: pw.FontWeight.bold,
      color: PdfColors.grey700,
      fontFallback: fonts.fallback,
    );
    final valueStyle = pw.TextStyle(
      fontSize: 10,
      color: PdfColors.grey800,
      fontFallback: fonts.fallback,
    );

    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 2),
      child: pw.RichText(
        text: pw.TextSpan(
          text: '$label: ',
          style: labelStyle,
          children: [pw.TextSpan(text: value, style: valueStyle)],
        ),
      ),
    );
  }

  Future<List<pw.Widget>> _buildSubNotes(
    Note note,
    pw.TextStyle sectionStyle,
  ) async {
    final widgets = <pw.Widget>[];

    widgets
      ..add(pw.SizedBox(height: 12))
      ..add(pw.Text(l10n.subNotes, style: sectionStyle));

    for (final subNote in note.subNotes) {
      final subNoteHeader = <pw.Widget>[
        pw.Text(
          subNote.name,
          style: pw.TextStyle(
            fontSize: 12,
            fontWeight: pw.FontWeight.bold,
            fontFallback: fonts.fallback,
          ),
        ),
        pw.SizedBox(height: 2),
        pw.Text(
          '${l10n.created}: ${ShareService._formatDateTime(subNote.createdAt)}',
          style: pw.TextStyle(
            fontSize: 10,
            color: PdfColors.grey700,
            fontFallback: fonts.fallback,
          ),
        ),
      ];

      if (subNote.isCompleted) {
        subNoteHeader.add(
          pw.Text(
            l10n.completed,
            style: pw.TextStyle(
              fontSize: 10,
              color: PdfColors.green800,
              fontFallback: fonts.fallback,
            ),
          ),
        );
      }

      widgets.add(
        pw.Padding(
          padding: const pw.EdgeInsets.only(top: 6),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: subNoteHeader,
          ),
        ),
      );

      final content = subNote.content.trim();
      if (content.isNotEmpty) {
        final rendered = await _markdownRenderer.render(content);
        for (final widget in rendered) {
          widgets.add(
            pw.Padding(
              padding: const pw.EdgeInsets.only(left: 12, top: 4),
              child: widget,
            ),
          );
        }
      }
    }

    return widgets;
  }

  Future<List<pw.Widget>> _buildAttachments(
    Note note,
    pw.TextStyle sectionStyle,
  ) async {
    if (note.attachmentPaths.isEmpty) {
      return const [];
    }

    final widgets = <pw.Widget>[
      pw.SizedBox(height: 12),
      pw.Text(l10n.attachments, style: sectionStyle),
    ];

    for (final rawPath in note.attachmentPaths) {
      final fileName = p.basename(rawPath);
      try {
        final file = File(rawPath);
        if (!await file.exists()) {
          widgets.add(
            pw.Padding(
              padding: const pw.EdgeInsets.only(top: 6),
              child: pw.Text(
                '$fileName (${l10n.attachmentMissing})',
                style: pw.TextStyle(
                  fontSize: 10,
                  color: PdfColors.red700,
                  fontFallback: fonts.fallback,
                ),
              ),
            ),
          );
          continue;
        }

        final extension = FileTypeUtils.getFileExtension(fileName);
        final mimeType = await FileTypeUtils.getMimeTypeForFile(
          rawPath,
          extension: extension,
        );

        widgets.add(
          pw.Padding(
            padding: const pw.EdgeInsets.only(top: 6),
            child: pw.Text(
              '$fileName ($mimeType)',
              style: pw.TextStyle(
                fontSize: 10,
                color: PdfColors.grey700,
                fontFallback: fonts.fallback,
              ),
            ),
          ),
        );

        if (ShareService._isSvgFileName(fileName)) {
          try {
            // Check file size before loading to prevent OOM with extremely large SVGs
            final file = File(rawPath);
            if (await file.exists()) {
              final fileSize = await file.length();
              const maxSvgSize = 10 * 1024 * 1024; // 10MB limit
              if (fileSize > maxSvgSize) {
                LoggerService.warning(
                  'SVG file too large ($fileSize bytes), skipping: $fileName',
                );
                widgets.add(
                  pw.Padding(
                    padding: const pw.EdgeInsets.only(top: 6),
                    child: pw.Text(
                      '$fileName (SVG too large to include)',
                      style: pw.TextStyle(
                        fontSize: 10,
                        color: PdfColors.grey700,
                        fontFallback: fonts.fallback,
                      ),
                    ),
                  ),
                );
                continue;
              }
            }

            final svgContent = await ShareService._loadSvgStringFromFilePath(
              rawPath,
            );
            if (svgContent != null && svgContent.trim().isNotEmpty) {
              final pngBytes = await SvgRendererService.renderSvgToPng(
                svgContent,
              );
              if (pngBytes != null) {
                // Constrain the image to 500px width as per requirements
                final maxWidth = math.min(_contentWidth, 500.0).toDouble();
                final image = pw.MemoryImage(pngBytes);
                widgets.add(
                  pw.Padding(
                    padding: const pw.EdgeInsets.only(top: 4, bottom: 8),
                    child: pw.Image(
                      image,
                      width: maxWidth,
                      fit: pw.BoxFit.contain,
                    ),
                  ),
                );
              } else {
                // Fallback: show error message if rendering failed
                LoggerService.warning('Failed to render SVG to PNG: $fileName');
                widgets.add(
                  pw.Padding(
                    padding: const pw.EdgeInsets.only(top: 6),
                    child: pw.Text(
                      '$fileName (SVG rendering failed)',
                      style: pw.TextStyle(
                        fontSize: 10,
                        color: PdfColors.red700,
                        fontFallback: fonts.fallback,
                      ),
                    ),
                  ),
                );
              }
            }
          } catch (e, stackTrace) {
            LoggerService.warning(
              'Failed to process SVG attachment $rawPath: $e',
              error: e,
              stackTrace: stackTrace,
            );
            widgets.add(
              pw.Padding(
                padding: const pw.EdgeInsets.only(top: 6),
                child: pw.Text(
                  '$fileName (${l10n.attachmentUnavailable})',
                  style: pw.TextStyle(
                    fontSize: 10,
                    color: PdfColors.red700,
                    fontFallback: fonts.fallback,
                  ),
                ),
              ),
            );
          }
          continue;
        }

        final bytes = await ShareService._loadImageBytesFromFilePath(rawPath);
        if (bytes != null && FileTypeUtils.isImage(extension)) {
          final image = pw.MemoryImage(bytes);
          widgets.add(
            pw.Padding(
              padding: const pw.EdgeInsets.only(top: 4, bottom: 8),
              child: pw.Image(
                image,
                width: math.min(_contentWidth, 360),
                fit: pw.BoxFit.contain,
              ),
            ),
          );
        } else if (mimeType == 'application/pdf') {
          // PDF attachments are merged as separate pages at the document level
          // Show a note in the attachments section that it's included
          widgets.add(
            pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 8, top: 2),
              child: pw.Text(
                '$fileName (PDF included as separate pages)',
                style: pw.TextStyle(
                  fontSize: 9,
                  color: PdfColors.grey600,
                  fontStyle: pw.FontStyle.italic,
                  fontFallback: fonts.fallback,
                ),
              ),
            ),
          );
        }
      } catch (e, stackTrace) {
        LoggerService.warning(
          'Failed to include attachment $rawPath: $e',
          error: e,
          stackTrace: stackTrace,
        );
        widgets.add(
          pw.Padding(
            padding: const pw.EdgeInsets.only(top: 6),
            child: pw.Text(
              '$fileName (${l10n.attachmentUnavailable})',
              style: pw.TextStyle(
                fontSize: 10,
                color: PdfColors.red700,
                fontFallback: fonts.fallback,
              ),
            ),
          ),
        );
      }
    }

    return widgets;
  }
}

class _MarkdownPdfRenderer {
  _MarkdownPdfRenderer({
    required this.l10n,
    required this.maxContentWidth,
    required this.fonts,
  }) : _baseTextStyle = pw.TextStyle(
         fontSize: 12,
         lineSpacing: 1.3,
         fontFallback: fonts.fallback,
       ),
       _linkStyle = pw.TextStyle(
         color: PdfColors.blue,
         decoration: pw.TextDecoration.underline,
         fontFallback: fonts.fallback,
       ),
       _codeStyle = pw.TextStyle(
         fontSize: 11,
         font: fonts.monospace,
         fontFallback: fonts.fallback,
       ),
       _imageFallbackStyle = pw.TextStyle(
         fontSize: 10,
         color: PdfColors.grey600,
         fontStyle: pw.FontStyle.italic,
         fontFallback: fonts.fallback,
       );

  final AppLocalizations l10n;
  final double maxContentWidth;
  final _PdfFonts fonts;

  final pw.TextStyle _baseTextStyle;
  final pw.TextStyle _linkStyle;
  final pw.TextStyle _codeStyle;
  final pw.TextStyle _imageFallbackStyle;

  final Map<String, pw.ImageProvider> _imageCache = {};

  Future<List<pw.Widget>> render(String markdown) async {
    final sanitized = markdown.replaceAll('\r\n', '\n');
    final document = md.Document(extensionSet: md.ExtensionSet.gitHubFlavored);
    final nodes = document.parseLines(sanitized.split('\n'));

    final widgets = <pw.Widget>[];
    for (final node in nodes) {
      final widget = await _buildBlock(node);
      if (widget != null) {
        widgets.add(widget);
      }
    }
    return widgets;
  }

  Future<pw.Widget?> _buildBlock(md.Node node) async {
    if (node is md.Element) {
      switch (node.tag) {
        case 'p':
          final spans = await _buildInlineSpans(node.children ?? []);
          if (spans.isEmpty) {
            return null;
          }
          final onlyWidgets = spans.every((span) => span is pw.WidgetSpan);
          if (onlyWidgets) {
            return pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: spans
                  .map((span) => (span as pw.WidgetSpan).child)
                  .toList(),
            );
          }
          return pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 6),
            child: pw.RichText(
              text: pw.TextSpan(style: _baseTextStyle, children: spans),
            ),
          );
        case 'h1':
        case 'h2':
        case 'h3':
        case 'h4':
        case 'h5':
        case 'h6':
          final level = int.tryParse(node.tag.substring(1)) ?? 1;
          final style = _headingStyle(level);
          final spans = await _buildInlineSpans(
            node.children ?? [],
            styleOverride: style,
          );
          return pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 6, top: 6),
            child: pw.RichText(
              text: pw.TextSpan(style: style, children: spans),
            ),
          );
        case 'blockquote':
          final quoteChildren = <pw.Widget>[];
          for (final child in node.children ?? []) {
            final childWidget = await _buildBlock(child);
            if (childWidget != null) {
              quoteChildren.add(childWidget);
            }
          }
          if (quoteChildren.isEmpty) {
            return null;
          }
          return pw.Container(
            margin: const pw.EdgeInsets.only(bottom: 8, top: 4),
            padding: const pw.EdgeInsets.fromLTRB(12, 6, 8, 6),
            decoration: pw.BoxDecoration(
              color: PdfColors.grey100,
              border: pw.Border(
                left: pw.BorderSide(color: PdfColors.grey600, width: 3),
              ),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: quoteChildren,
            ),
          );
        case 'pre':
          final codeNode = (node.children ?? []).firstWhere(
            (child) => child is md.Element && child.tag == 'code',
            orElse: () => node,
          );
          final codeText = _extractPlainText(codeNode).trimRight();
          return pw.Container(
            width: double.infinity,
            margin: const pw.EdgeInsets.only(top: 6, bottom: 8),
            padding: const pw.EdgeInsets.all(8),
            decoration: pw.BoxDecoration(
              color: PdfColors.grey100,
              borderRadius: pw.BorderRadius.circular(4),
              border: pw.Border.all(color: PdfColors.grey400),
            ),
            child: pw.Text(codeText, style: _codeStyle),
          );
        case 'hr':
          return pw.Padding(
            padding: const pw.EdgeInsets.symmetric(vertical: 8),
            child: pw.Divider(color: PdfColors.grey400),
          );
        case 'ul':
          return await _buildList(node, ordered: false);
        case 'ol':
          return await _buildList(node, ordered: true);
        case 'table':
          return await _buildTable(node);
        case 'img':
          final spans = await _buildInlineSpan(node, _baseTextStyle);
          if (spans.isEmpty) {
            return null;
          }
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: spans
                .map(
                  (span) => span is pw.WidgetSpan ? span.child : pw.SizedBox(),
                )
                .toList(),
          );
      }
    } else if (node is md.Text) {
      final text = node.text.trim();
      if (text.isEmpty) {
        return null;
      }
      return pw.Text(text, style: _baseTextStyle);
    }
    return null;
  }

  Future<pw.Widget?> _buildTable(md.Element element) async {
    final rows = <pw.TableRow>[];

    // Process table headers (thead) usually contains one row of th
    final thead =
        element.children
                ?.where((c) => c is md.Element && c.tag == 'thead')
                .firstOrNull
            as md.Element?;
    if (thead != null) {
      for (final row in thead.children ?? []) {
        if (row is md.Element && row.tag == 'tr') {
          rows.add(await _buildTableRow(row, isHeader: true));
        }
      }
    }

    // Process table body (tbody)
    final tbody =
        element.children
                ?.where((c) => c is md.Element && c.tag == 'tbody')
                .firstOrNull
            as md.Element?;
    if (tbody != null) {
      for (final row in tbody.children ?? []) {
        if (row is md.Element && row.tag == 'tr') {
          rows.add(await _buildTableRow(row, isHeader: false));
        }
      }
    }

    // If no explicit thead/tbody, try parsing direct tr children (unlikely in GFM but safe to handle)
    if (rows.isEmpty) {
      for (final child in element.children ?? []) {
        if (child is md.Element && child.tag == 'tr') {
          rows.add(await _buildTableRow(child, isHeader: false));
        }
      }
    }

    if (rows.isEmpty) {
      return null;
    }

    // Determine column count from the first row (or max cols)
    int colCount = 0;
    if (rows.isNotEmpty) {
      colCount = rows.first.children.length;
    }

    // Create table with specific border styling
    // Using FlexColumnWidth to handle ultra-wide tables by letting columns flex within available width
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 8),
      child: pw.Table(
        border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
        columnWidths: {
          for (int i = 0; i < colCount; i++) i: const pw.FlexColumnWidth(),
        },
        children: rows,
      ),
    );
  }

  Future<pw.TableRow> _buildTableRow(
    md.Element row, {
    required bool isHeader,
  }) async {
    final cells = <pw.Widget>[];

    for (final child in row.children ?? []) {
      if (child is md.Element) {
        // th or td
        final isTh = child.tag == 'th' || isHeader;

        final spans = await _buildInlineSpans(child.children ?? []);

        // Apply header styling override if needed, or just standard text
        final style = isTh
            ? _baseTextStyle.copyWith(
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.black,
              )
            : _baseTextStyle;

        // If spans are empty, add empty text
        if (spans.isEmpty) {
          cells.add(
            pw.Padding(
              padding: const pw.EdgeInsets.all(6),
              child: pw.Text('', style: style),
            ),
          );
        } else if (spans.every((span) => span is pw.WidgetSpan)) {
          // If all widgets (e.g. images), wrap in column
          cells.add(
            pw.Padding(
              padding: const pw.EdgeInsets.all(6),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: spans
                    .map((span) => (span as pw.WidgetSpan).child)
                    .toList(),
              ),
            ),
          );
        } else {
          // Mixed content or just text
          // Re-apply style to all text spans if it's a header to ensure bolding
          if (isTh) {
            for (var i = 0; i < spans.length; i++) {
              if (spans[i] is pw.TextSpan) {
                final ts = spans[i] as pw.TextSpan;
                spans[i] = pw.TextSpan(
                  text: ts.text,
                  style: ts.style?.merge(style) ?? style,
                  children: ts.children,
                  annotation: ts.annotation,
                );
              }
            }
          }

          cells.add(
            pw.Padding(
              padding: const pw.EdgeInsets.all(6),
              child: pw.RichText(
                text: pw.TextSpan(style: style, children: spans),
              ),
            ),
          );
        }
      }
    }

    return pw.TableRow(
      decoration: isHeader
          ? const pw.BoxDecoration(color: PdfColors.grey200)
          : null,
      children: cells,
    );
  }

  Future<pw.Widget?> _buildList(
    md.Element element, {
    required bool ordered,
  }) async {
    final items = element.children?.whereType<md.Element>().toList() ?? [];
    if (items.isEmpty) {
      return null;
    }

    final listWidgets = <pw.Widget>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      if (item.tag != 'li') {
        continue;
      }

      final marker = ordered ? '${i + 1}.' : '•';
      final inlineNodes = <md.Node>[];
      final nestedBlocks = <md.Node>[];

      for (final node in item.children ?? []) {
        if (node is md.Element && (node.tag == 'ul' || node.tag == 'ol')) {
          nestedBlocks.add(node);
        } else {
          inlineNodes.add(node);
        }
      }

      final spans = await _buildInlineSpans(inlineNodes);
      pw.Widget contentWidget;
      if (spans.isEmpty) {
        contentWidget = pw.SizedBox();
      } else if (spans.every((span) => span is pw.WidgetSpan)) {
        contentWidget = pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: spans.map((span) => (span as pw.WidgetSpan).child).toList(),
        );
      } else {
        contentWidget = pw.RichText(
          text: pw.TextSpan(style: _baseTextStyle, children: spans),
        );
      }

      listWidgets.add(
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Container(
              width: ordered ? 24 : 12,
              alignment: pw.Alignment.topRight,
              child: pw.Text(marker, style: _baseTextStyle),
            ),
            pw.SizedBox(width: 6),
            pw.Expanded(child: contentWidget),
          ],
        ),
      );

      for (final nested in nestedBlocks) {
        final nestedWidget = await _buildBlock(nested);
        if (nestedWidget != null) {
          listWidgets.add(
            pw.Padding(
              padding: const pw.EdgeInsets.only(left: 18),
              child: nestedWidget,
            ),
          );
        }
      }
    }

    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 6),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: listWidgets,
      ),
    );
  }

  Future<List<pw.InlineSpan>> _buildInlineSpans(
    List<md.Node> nodes, {
    pw.TextStyle? styleOverride,
  }) async {
    final spans = <pw.InlineSpan>[];
    for (final node in nodes) {
      spans.addAll(
        await _buildInlineSpan(node, styleOverride ?? _baseTextStyle),
      );
    }
    return spans;
  }

  Future<List<pw.InlineSpan>> _buildInlineSpan(
    md.Node node,
    pw.TextStyle style,
  ) async {
    if (node is md.Text) {
      final text = node.text;
      if (text.isEmpty) {
        return const [];
      }
      return [pw.TextSpan(text: text, style: style)];
    }

    if (node is! md.Element) {
      return const [];
    }

    switch (node.tag) {
      case 'strong':
      case 'b':
        return _buildInlineSpans(
          node.children ?? [],
          styleOverride: style.merge(
            pw.TextStyle(fontWeight: pw.FontWeight.bold),
          ),
        );
      case 'em':
      case 'i':
        return _buildInlineSpans(
          node.children ?? [],
          styleOverride: style.merge(
            pw.TextStyle(fontStyle: pw.FontStyle.italic),
          ),
        );
      case 'code':
        final text = _extractPlainText(node);
        if (text.isEmpty) {
          return const [];
        }
        return [pw.TextSpan(text: text, style: _codeStyle)];
      case 'del':
        return _buildInlineSpans(
          node.children ?? [],
          styleOverride: style.merge(
            pw.TextStyle(decoration: pw.TextDecoration.lineThrough),
          ),
        );
      case 'br':
        return [pw.TextSpan(text: '\n', style: style)];
      case 'a':
        final href = node.attributes['href'] ?? '';
        final childSpans = await _buildInlineSpans(
          node.children ?? [],
          styleOverride: style.merge(_linkStyle),
        );
        return [
          pw.TextSpan(
            style: style.merge(_linkStyle),
            children: childSpans,
            annotation: href.isNotEmpty ? pw.AnnotationUrl(href) : null,
          ),
        ];
      case 'img':
        final imageSpan = await _buildImageSpan(node);
        return imageSpan ?? const [];
      default:
        return _buildInlineSpans(node.children ?? [], styleOverride: style);
    }
  }

  Future<pw.ImageProvider?> _resolveImage(String src) async {
    if (src.isEmpty) {
      return null;
    }

    if (_imageCache.containsKey(src)) {
      return _imageCache[src];
    }

    final bytes = await ShareService._loadImageBytesFromSource(src);
    if (bytes == null) {
      return null;
    }

    final image = pw.MemoryImage(bytes);
    _imageCache[src] = image;
    return image;
  }

  Future<List<pw.InlineSpan>?> _buildImageSpan(md.Element element) async {
    final src = element.attributes['src'] ?? '';
    final alt = element.attributes['alt'] ?? '';

    if (ShareService._isSvgSource(src)) {
      final svgContent = await ShareService._loadSvgStringFromSource(src);
      if (svgContent != null && svgContent.trim().isNotEmpty) {
        final pngBytes = await SvgRendererService.renderSvgToPng(svgContent);
        if (pngBytes != null) {
          // Constrain the image to 500px width as per requirements
          final maxWidth = math.min(maxContentWidth, 500.0).toDouble();
          final image = pw.MemoryImage(pngBytes);
          final imageWidget = pw.Container(
            padding: const pw.EdgeInsets.symmetric(vertical: 4),
            child: pw.Image(image, width: maxWidth, fit: pw.BoxFit.contain),
          );
          return [pw.WidgetSpan(child: imageWidget)];
        } else {
          // Fallback: show placeholder if rendering failed
          LoggerService.warning(
            'Failed to render SVG to PNG from markdown: $src',
          );
          // Return a placeholder text span
          return [
            pw.TextSpan(
              text: alt.isNotEmpty ? '[$alt]' : '[SVG Image]',
              style: _imageFallbackStyle,
            ),
          ];
        }
      }
    } else {
      final imageProvider = await _resolveImage(src);
      if (imageProvider != null) {
        final imageWidget = pw.Container(
          padding: const pw.EdgeInsets.symmetric(vertical: 4),
          child: pw.Image(
            imageProvider,
            width: math.min(maxContentWidth, 360),
            fit: pw.BoxFit.contain,
          ),
        );
        return [pw.WidgetSpan(child: imageWidget)];
      }
    }

    final placeholder = alt.isNotEmpty ? '![$alt]' : src;
    if (placeholder.isEmpty) {
      return [pw.TextSpan(text: '[${l10n.image}]', style: _imageFallbackStyle)];
    }

    return [pw.TextSpan(text: placeholder, style: _imageFallbackStyle)];
  }

  pw.TextStyle _headingStyle(int level) {
    final baseSize = 22.0;
    final size = baseSize - (level - 1) * 2.0;
    return pw.TextStyle(
      fontSize: size.clamp(14.0, baseSize),
      fontWeight: pw.FontWeight.bold,
    );
  }

  String _extractPlainText(md.Node node) {
    if (node is md.Text) {
      return node.text;
    }
    if (node is md.Element) {
      final buffer = StringBuffer();
      for (final child in node.children ?? []) {
        buffer.write(_extractPlainText(child));
      }
      return buffer.toString();
    }
    return '';
  }
}

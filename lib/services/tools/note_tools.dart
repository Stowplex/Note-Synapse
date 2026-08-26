import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import '../approval_service.dart';
import '../data_change_notifier.dart';
import '../database_service.dart';
import '../note_modification_service.dart';
import '../logger_service.dart';
import '../sql_query_service.dart';
import '../service_locator.dart';
import '../../utils/file_utils.dart';

import '../ai_service.dart';
import '../search/search_service.dart';
import '../../models/generation_context.dart';
import '../../models/filter.dart';
import '../../models/note.dart';

abstract class NativeTool {
  String get name;
  String get description;
  Map<String, dynamic> get inputSchema;
  Future<dynamic> execute(Map<String, dynamic> args);
}

class NoteSearchTool implements NativeTool {
  DatabaseService get _db => getIt<DatabaseService>();
  SearchService get _searchService => getIt<SearchService>();

  /// Result cap, mirroring the LIMIT 50 of the pre-layered FTS path.
  static const int _maxResults = 50;

  /// Candidate caps applied BEFORE loading full note rows (the substring
  /// fallback can return the entire corpus, and notes.content can be huge).
  /// Only [_maxResults] entries can reach the output; the caps leave slack
  /// for notes deleted between search and load — extra slack when tags were
  /// requested, even though [NoteFilterContext.requiredTags] already
  /// filtered the results inside the search.
  static const int _maxCandidatesWithoutTags = 200;
  static const int _maxCandidatesWithTags = 500;

  @override
  String get name => 'search_notes';

  @override
  String get description => '''
Search for notes using ranked full-text search (BM25). Matches note titles, bodies, subnotes, and annotations — and indexed attachment content as extraction layers come online. Returns matching notes with titles, IDs, best-match snippets, and tags, best matches first.
Supports optional tag filtering for more targeted results.

DISCOVERY TIP: Use this for keyword-based filtering across notes.
Priority order for exploring user's notes:
1. ls / run_sql → metadata exploration (no content loading) - PREFERRED
2. search_notes → keyword-based filtering
3. read_note mode='toc'/'summary' → structural overview
4. read_note mode='full' → only for targeted deep reads
''';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'query': {'type': 'string', 'description': 'The search query string.'},
      'tags': {
        'type': 'array',
        'items': {'type': 'string'},
        'description': 'Optional list of tags to filter by.',
      },
    },
    'required': ['query'],
  };

  @override
  Future<dynamic> execute(Map<String, dynamic> args) async {
    final query = args['query'] as String;
    final tags = (args['tags'] as List?)?.cast<String>();

    final trimmedQuery = query.trim();
    if (trimmedQuery.isEmpty) {
      // Tag-only lookup (AND semantics), unchanged from the pre-layered path.
      if (tags == null || tags.isEmpty) return <Map<String, dynamic>>[];
      final firstTagNotes = await _db.getNotesByTag(tags.first);
      return [
        for (final note in firstTagNotes)
          if (tags.every(note.tags.contains)) _entry(note, _head(note.content)),
      ];
    }

    final hasTags = tags != null && tags.isNotEmpty;
    final response = await _searchService.searchFused(
      query,
      // The AI audience excludes chunks from attachments with
      // includeInAIContext = false.
      audience: SearchAudience.ai,
      // The pre-layered FTS path never filtered archived notes; preserve that
      // so agents keep finding archived material. The tag filter (AND
      // semantics, exact tag-name match — the old SQL EXISTS-per-tag) runs
      // INSIDE the search, during result accumulation, so tagged notes
      // ranked below untagged material are still found rather than being
      // truncated away with the top slice.
      filter: NoteFilterContext(
        includeArchived: true,
        requiredTags: hasTags ? tags : null,
      ),
    );
    if (response.results.isEmpty) return <Map<String, dynamic>>[];

    // Cap the candidate list BEFORE fetching notes: the fallback path can
    // return the whole corpus, and each note load pulls full content.
    final cap = hasTags ? _maxCandidatesWithTags : _maxCandidatesWithoutTags;
    final candidates = response.results.length > cap
        ? response.results.sublist(0, cap)
        : response.results;

    final notesById = {
      for (final note in await _db.getNotesByIds([
        for (final result in candidates) result.noteId,
      ]))
        note.id: note,
    };

    final output = <Map<String, dynamic>>[];
    for (final result in candidates) {
      final note = notesById[result.noteId];
      if (note == null) continue; // Deleted between search and load.
      output.add(_entry(note, _rankedSnippet(result, note)));
      if (output.length >= _maxResults) break;
    }
    return output;
  }

  /// Output schema kept identical to the pre-layered tool: id / title /
  /// snippet / tags (AI-facing contract).
  static Map<String, dynamic> _entry(Note note, String snippet) => {
    'id': note.id,
    'title': note.title,
    'snippet': snippet,
    'tags': note.tags,
  };

  static String _head(String content) =>
      content.length > 200 ? '${content.substring(0, 200)}...' : content;

  /// The ranked best-chunk snippet, with ellipses marking truncation; falls
  /// back to the head of the note body when the search produced no snippet
  /// text (e.g. a title-only substring match on an empty body).
  static String _rankedSnippet(NoteSearchResult result, Note note) {
    final snippet = result.best.snippet;
    if (snippet.text.isEmpty) return _head(note.content);
    return '${snippet.truncatedStart ? '…' : ''}${snippet.text}'
        '${snippet.truncatedEnd ? '…' : ''}';
  }
}

class NoteReadTool implements NativeTool {
  DatabaseService get _db => getIt<DatabaseService>();

  @override
  String get name => 'read_note';

  @override
  String get description => '''
Read a note with progressive discovery modes:
- 'stat' (default): Returns metadata including line count, attachment info with sizes/pages, PDF ToCs with real page numbers, and linked notes. Use this FIRST to understand the note structure.
- 'lines': Read specific line range. Provide start_line and end_line (1-indexed, inclusive).
- 'pdf_pages': Read specific pages from a PDF attachment as images. Provide attachment name, start_page and end_page (1-indexed).
- 'summary': Returns summary block or first 500 chars.
- 'toc': Returns table of contents (headers from markdown).
- 'full': Returns full text content. If extraction_guide is provided, uses AI to extract info from content and specified attachments.

Progressive discovery workflow:
1. Call with mode='stat' to see note structure and attachment sizes
2. Use mode='lines' or 'toc' to explore content sections
3. Use mode='pdf_pages' to read specific PDF pages
4. Use mode='full' with extraction_guide only when you need AI analysis of large attachments
''';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'note_id': {
        'type': 'string',
        'description': 'The ID of the note to read.',
      },
      'mode': {
        'type': 'string',
        'enum': ['stat', 'lines', 'pdf_pages', 'summary', 'toc', 'full'],
        'description':
            'Reading mode. Defaults to "stat" for progressive discovery.',
        'default': 'stat',
      },
      'start_line': {
        'type': 'integer',
        'description': 'For "lines" mode: starting line number (1-indexed).',
      },
      'end_line': {
        'type': 'integer',
        'description':
            'For "lines" mode: ending line number (1-indexed, inclusive).',
      },
      'attachment': {
        'type': 'string',
        'description': 'For "pdf_pages" mode: the attachment filename.',
      },
      'start_page': {
        'type': 'integer',
        'description':
            'For "pdf_pages" mode: starting page number (1-indexed).',
      },
      'end_page': {
        'type': 'integer',
        'description':
            'For "pdf_pages" mode: ending page number (1-indexed, inclusive).',
      },
      'extraction_guide': {
        'type': 'string',
        'description':
            'For "full" mode: AI extraction guidance for analyzing note and attachments.',
      },
      'attachments': {
        'type': 'array',
        'items': {'type': 'string'},
        'description':
            'For "full" mode with extraction_guide: filter to specific attachment names.',
      },
    },
    'required': ['note_id'],
  };

  @override
  Future<dynamic> execute(Map<String, dynamic> args) async {
    final noteId = args['note_id'] as String;
    final mode = args['mode'] as String? ?? 'stat';

    final note = await _db.getNoteById(noteId);
    if (note == null) {
      return {'error': 'Note not found'};
    }

    switch (mode) {
      case 'stat':
        return await _executeStat(note);
      case 'lines':
        return await _executeLines(note, args);
      case 'pdf_pages':
        return await _executePdfPages(note, args);
      case 'summary':
        return _executeSummary(note);
      case 'toc':
        return _executeToc(note);
      case 'full':
        return await _executeFull(note, args);
      default:
        return {'error': 'Unknown mode: $mode'};
    }
  }

  /// Stat mode: Return comprehensive metadata for progressive discovery
  Future<Map<String, dynamic>> _executeStat(note) async {
    final lines = note.content.split('\n');
    final lineCount = lines.length;

    // Get attachments with detailed info
    final attachmentInfos = <Map<String, dynamic>>[];
    for (final path in note.attachmentPaths) {
      final info = await _getAttachmentInfo(path);
      if (info != null) {
        attachmentInfos.add(info);
      }
    }

    // Get linked notes
    final relationships = await _db.getRelationships(note.id);
    final linkedNotes = <Map<String, dynamic>>[];
    for (final rel in relationships) {
      final linkedId = rel.fromNoteId == note.id
          ? rel.toNoteId
          : rel.fromNoteId;
      final linkedNote = await _db.getNoteById(linkedId);
      if (linkedNote != null) {
        final direction = rel.fromNoteId == note.id ? '→' : '←';
        linkedNotes.add({
          'id': linkedNote.id,
          'title': linkedNote.title,
          'relation': '${rel.type} $direction',
        });
      }
    }

    return {
      'id': note.id,
      'title': note.title,
      'line_count': lineCount,
      'tags': note.tags,
      'attachments': attachmentInfos,
      'linked_notes': linkedNotes,
      'subnotes': note.subNotes.map((s) => s.name).toList(),
      'updated_at': note.updatedAt.toIso8601String(),
      'hint':
          'Use mode="lines" to read specific line ranges, mode="pdf_pages" to read PDF pages, or mode="toc" for headers.',
    };
  }

  /// Get attachment info including PDF ToC with real page numbers
  Future<Map<String, dynamic>?> _getAttachmentInfo(String path) async {
    try {
      final fullPath = await FileUtils.getFullFilePath(
        path,
        !path.startsWith('/'),
      );
      final file = File(fullPath);
      if (!await file.exists()) {
        return {'name': path.split('/').last, 'error': 'File not found'};
      }

      final fileName = path.split('/').last;
      final extension = fileName.split('.').last.toLowerCase();
      final sizeBytes = await file.length();
      final sizeKb = (sizeBytes / 1024).round();

      final info = <String, dynamic>{
        'name': fileName,
        'type': extension,
        'size_kb': sizeKb,
      };

      // For PDFs, get page count and ToC
      if (extension == 'pdf') {
        try {
          // Ensure Pdfrx cache directory is set
          Pdfrx.getCacheDirectory ??= () async {
            final tempDir = await getTemporaryDirectory();
            return tempDir.path;
          };

          final pdfDoc = await PdfDocument.openFile(fullPath);
          info['pages'] = pdfDoc.pages.length;

          // Extract ToC with real page destinations
          final outline = await pdfDoc.loadOutline();
          if (outline.isNotEmpty) {
            info['toc'] = _extractToc(outline, pdfDoc.pages.length);
          }

          pdfDoc.dispose();
        } catch (e) {
          LoggerService.warning('Failed to read PDF info: $e');
          info['pdf_error'] = 'Could not read PDF metadata';
        }
      }

      return info;
    } catch (e) {
      return {'name': path.split('/').last, 'error': e.toString()};
    }
  }

  /// Extract PDF ToC with real page numbers (from dest.pageNumber)
  List<Map<String, dynamic>> _extractToc(
    List<PdfOutlineNode> nodes,
    int totalPages, [
    int depth = 0,
  ]) {
    final result = <Map<String, dynamic>>[];
    for (final node in nodes) {
      // Use real destination page number (0-indexed, convert to 1-indexed)
      final pageNum = node.dest?.pageNumber != null
          ? (node.dest!.pageNumber + 1).clamp(1, totalPages)
          : null;

      result.add({
        'title': node.title,
        'page': pageNum,
        if (depth > 0) 'depth': depth,
      });

      // Recursively add children (limit depth to avoid huge ToCs)
      if (node.children.isNotEmpty && depth < 2) {
        result.addAll(_extractToc(node.children, totalPages, depth + 1));
      }
    }
    return result;
  }

  /// Lines mode: Return specific line range
  Future<Map<String, dynamic>> _executeLines(
    note,
    Map<String, dynamic> args,
  ) async {
    final lines = note.content.split('\n');
    final totalLines = lines.length;

    final startLine = (args['start_line'] as int?) ?? 1;
    final endLine = (args['end_line'] as int?) ?? totalLines.clamp(1, 50);

    // Validate and clamp
    final actualStart = startLine.clamp(1, totalLines);
    final actualEnd = endLine.clamp(actualStart, totalLines);

    // Lines are 1-indexed, list is 0-indexed
    final selectedLines = lines.sublist(actualStart - 1, actualEnd);

    return {
      'id': note.id,
      'title': note.title,
      'lines': selectedLines.join('\n'),
      'start_line': actualStart,
      'end_line': actualEnd,
      'total_lines': totalLines,
    };
  }

  /// PDF pages mode: Render specific pages as images
  Future<dynamic> _executePdfPages(note, Map<String, dynamic> args) async {
    final attachmentName = args['attachment'] as String?;
    if (attachmentName == null) {
      return {'error': 'attachment parameter is required for pdf_pages mode'};
    }

    final startPage = (args['start_page'] as int?) ?? 1;
    final endPage = (args['end_page'] as int?) ?? startPage;

    // Find the attachment path
    String? attachmentPath;
    for (final path in note.attachmentPaths) {
      if (path.split('/').last == attachmentName) {
        attachmentPath = path;
        break;
      }
    }

    if (attachmentPath == null) {
      return {'error': 'Attachment not found: $attachmentName'};
    }

    // Validate that the attachment is a PDF
    final extension = attachmentName.split('.').last.toLowerCase();
    if (extension != 'pdf') {
      return {
        'error':
            'Attachment "$attachmentName" is not a PDF (type: $extension). Use pdf_pages mode only for PDF attachments.',
      };
    }

    try {
      final fullPath = await FileUtils.getFullFilePath(
        attachmentPath,
        !attachmentPath.startsWith('/'),
      );

      // Ensure Pdfrx cache directory is set
      Pdfrx.getCacheDirectory ??= () async {
        final tempDir = await getTemporaryDirectory();
        return tempDir.path;
      };

      final pdfDoc = await PdfDocument.openFile(fullPath);
      final totalPages = pdfDoc.pages.length;

      final actualStart = startPage.clamp(1, totalPages);
      final actualEnd = endPage.clamp(actualStart, totalPages);

      // Render pages as images and collect as PlatformFile attachments
      final pageImages = <PlatformFile>[];
      for (int pageNum = actualStart; pageNum <= actualEnd; pageNum++) {
        final page = pdfDoc.pages[pageNum - 1]; // 0-indexed

        // Render at 2x resolution for clarity
        final renderWidth = (page.width * 2).toInt();
        final renderHeight = (page.height * 2).toInt();

        final pdfImage = await page.render(
          width: renderWidth,
          height: renderHeight,
        );

        if (pdfImage != null) {
          final uiImage = await pdfImage.createImage();
          final byteData = await uiImage.toByteData(
            format: ui.ImageByteFormat.png,
          );

          if (byteData != null) {
            final pngBytes = byteData.buffer.asUint8List();
            pageImages.add(
              PlatformFile(
                name: '${attachmentName}_page$pageNum.png',
                path: null,
                size: pngBytes.length,
                bytes: Uint8List.fromList(pngBytes),
              ),
            );
          }
          uiImage.dispose();
        }
      }

      pdfDoc.dispose();

      if (pageImages.isEmpty) {
        return {'error': 'Failed to render PDF pages'};
      }

      // Use AI to describe the pages or return as attachments for the LLM
      final prompt =
          '''
Describe the content of these PDF pages (${pageImages.length} page(s) from "$attachmentName", pages $actualStart-$actualEnd).
Provide a detailed summary of what you see on each page.
''';

      final aiResponse = await getIt<AIService>().generateWithAttachments(
        prompt,
        pageImages,
        generationContext: GenerationContext(
          values: {'type': 'pdf_page_extraction', 'noteId': note.id},
        ),
      );

      return {
        'id': note.id,
        'attachment': attachmentName,
        'pages_read': '$actualStart-$actualEnd',
        'total_pages': totalPages,
        'content': aiResponse,
      };
    } catch (e) {
      LoggerService.error('Failed to read PDF pages: $e');
      return {'error': 'Failed to read PDF pages: $e'};
    }
  }

  /// Summary mode: Return summary block or preview
  Map<String, dynamic> _executeSummary(note) {
    final summaryMatch = RegExp(
      r'> \[!SUMMARY\]\n(.*?)(?=\n\n|$)',
    ).firstMatch(note.content);
    if (summaryMatch != null) {
      return {
        'id': note.id,
        'title': note.title,
        'summary': summaryMatch.group(1),
      };
    }
    return {
      'id': note.id,
      'title': note.title,
      'preview': note.content.take(500),
    };
  }

  /// ToC mode: Extract headers
  Map<String, dynamic> _executeToc(note) {
    final headers = RegExp(r'^(#{1,6})\s+(.+)$', multiLine: true)
        .allMatches(note.content)
        .map((m) => {'level': m.group(1)!.length, 'text': m.group(2)})
        .toList();
    return {'id': note.id, 'title': note.title, 'toc': headers};
  }

  /// Full mode: Return content with optional AI extraction
  Future<Map<String, dynamic>> _executeFull(
    note,
    Map<String, dynamic> args,
  ) async {
    final extractionGuide = args['extraction_guide'] as String?;
    final attachmentFilter = (args['attachments'] as List?)?.cast<String>();

    if (extractionGuide != null && extractionGuide.isNotEmpty) {
      // AI Extraction Mode
      try {
        final attachments = <PlatformFile>[];
        for (final path in note.attachmentPaths) {
          final fileName = path.split('/').last;

          // Apply filter if specified
          if (attachmentFilter != null &&
              !attachmentFilter.contains(fileName)) {
            continue;
          }

          final fullPath = await FileUtils.getFullFilePath(
            path,
            !path.startsWith('/'),
          );
          final file = File(fullPath);
          if (await file.exists()) {
            attachments.add(
              PlatformFile(
                name: fileName,
                path: fullPath,
                size: await file.length(),
                bytes: await file.readAsBytes(),
              ),
            );
          }
        }

        final prompt =
            '''
Analyze the following note and its attachments based on the Extraction Guide.

Note Title: ${note.title}
Note Content:
${note.content}

Extraction Guide:
$extractionGuide
''';

        final aiResponse = await getIt<AIService>().generateWithAttachments(
          prompt,
          attachments,
          generationContext: GenerationContext(
            values: {'type': 'tool_extraction', 'noteId': note.id},
          ),
        );

        return {'id': note.id, 'title': note.title, 'extraction': aiResponse};
      } catch (e) {
        return {
          'error': 'Failed to perform AI extraction: $e',
          'content': note.content, // Fallback
        };
      }
    } else {
      // Standard Full Read - no AI, just return content and paths
      return {
        'id': note.id,
        'title': note.title,
        'content': note.content,
        'attachments': note.attachmentPaths
            .map((p) => p.split('/').last)
            .toList(),
        'hint':
            'Use mode="stat" for attachment details, or provide extraction_guide to analyze with AI.',
        'metadata': {
          'tags': note.tags,
          'updatedAt': note.updatedAt.toIso8601String(),
        },
      };
    }
  }
}

class RunSqlTool implements NativeTool {
  SqlQueryService get _sqlService => getIt<SqlQueryService>();

  /// Legacy static callback for backwards compatibility.
  /// Prefer using ApprovalService.onApprovalRequest instead.
  @Deprecated('Use ApprovalService.onApprovalRequest instead')
  static Future<bool> Function(String sql, SqlQueryType queryType)?
  onWriteApprovalRequest;

  /// Whether write operations have been approved for this session.
  /// Now delegates to ApprovalService.
  static bool get _sessionApprovedWrites =>
      ApprovalService.sessionApprovedSqlWrites;

  /// Approve writes for this session (called after user approves).
  /// Now delegates to ApprovalService.
  static void approveWritesForSession() {
    ApprovalService.sessionApprovedSqlWrites = true;
    LoggerService.debug('[RunSqlTool] Write operations approved for session');
  }

  /// Reset session approval (called when agent session ends).
  /// Now delegates to ApprovalService.
  static void resetSessionApproval() {
    ApprovalService.resetSession();
  }

  @override
  String get name => 'run_sql';

  @override
  String get description =>
      '''
Run a SQL query on the local database. Supports SELECT, INSERT, UPDATE, DELETE.
Write operations require user approval.

DATABASE SCHEMA:
${DatabaseService.getSchemaDescription()}

DISCOVERY TIP: Use for metadata exploration before loading note content.
Example: SELECT id, title, tags FROM notes WHERE tags LIKE '%topic%' ORDER BY updatedAt DESC LIMIT 10
''';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'query': {
        'type': 'string',
        'description':
            'The SQL query to run (SELECT, INSERT, UPDATE, DELETE, etc.).',
      },
    },
    'required': ['query'],
  };

  @override
  Future<dynamic> execute(Map<String, dynamic> args) async {
    final query = args['query'] as String;

    // Check if this is a write operation that needs approval
    final isReadOnly = _sqlService.isReadOnlyQuery(query);

    if (!isReadOnly && !_sessionApprovedWrites) {
      // Use ApprovalService for approval
      final queryType = _sqlService.getQueryType(query);
      final approved = await ApprovalService.requestSqlWriteApproval(
        sql: query,
        queryType: queryType,
        queryTypeDescription: _sqlService.getQueryTypeDescription(queryType),
        source: 'Agent',
      );
      if (!approved) {
        return {
          'error': 'User denied the SQL write operation.',
          'query_type': _sqlService.getQueryTypeDescription(queryType),
        };
      }
    }

    // Execute the query
    final result = await _sqlService.executeQuery(
      query,
      allowWriteOperations: true,
      requireApprovalForWrites: false, // Already handled above
      maxRows: 50,
    );

    if (!result.success) {
      return {'error': result.error};
    }

    if (result.data == null || result.data!.isEmpty) {
      if (isReadOnly) {
        return 'No results found.';
      } else {
        return 'Query executed successfully (no rows returned).';
      }
    }

    if (result.truncated) {
      return {
        'warning':
            'Result truncated to ${result.data!.length} of ${result.totalRows} rows',
        'data': result.toMarkdownTable(),
      };
    }

    return result.toMarkdownTable();
  }
}

extension StringExtension on String {
  String take(int n) => length > n ? substring(0, n) : this;
}

class ListFiltersTool implements NativeTool {
  DatabaseService get _db => getIt<DatabaseService>();

  @override
  String get name => 'ls';

  @override
  String get description => '''
Lists all tag filters (folders) in a tree structure. Use this to understand the organization of notes.
Filters define sets of tags for organizing notes into logical groups.

DISCOVERY TIP: This is the PREFERRED starting point for exploring notes.
- Returns hierarchical structure of how notes are organized
- Each filter shows its included tags and note count
- Use this before search_notes or run_sql to understand the note taxonomy
''';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': <String, dynamic>{},
  };

  @override
  Future<dynamic> execute(Map<String, dynamic> args) async {
    try {
      final filters = await _db.getAllFilters();
      if (filters.isEmpty) {
        return "No filters found (Root is empty).";
      }

      // Build tree
      // 1. Identify relationships
      final Map<String, List<String>> childrenMap =
          {}; // parentId -> [childIds]
      final Set<String> rootIds = {};

      for (final filter in filters) {
        childrenMap.putIfAbsent(filter.id, () => []);
      }

      for (final child in filters) {
        // Find all possible parents
        final possibleParents = filters
            .where((parent) => child.isChildOf(parent))
            .toList();

        if (possibleParents.isEmpty) {
          rootIds.add(child.id);
        } else {
          // Find closest parent: The one with the most specificity (e.g. most tags)
          // Sort by specificity descending
          possibleParents.sort((a, b) {
            final specA = (a.includeTags.length) + (a.includeText?.length ?? 0);
            final specB = (b.includeTags.length) + (b.includeText?.length ?? 0);
            return specB.compareTo(specA);
          });

          final closestParent = possibleParents.first;
          childrenMap[closestParent.id]!.add(child.id);
        }
      }

      // Sort roots by name
      final roots = filters.where((f) => rootIds.contains(f.id)).toList();
      roots.sort((a, b) => a.name.compareTo(b.name));

      final buffer = StringBuffer();
      buffer.writeln("File System (Filters Hierarchy):");

      void printNode(Filter node, String prefix) {
        buffer.writeln("$prefix- [${node.name}]");
        final indent = "$prefix  ";

        if (node.includeTags.isNotEmpty) {
          buffer.writeln("${indent}Tags: ${node.includeTags.join(', ')}");
        }
        if (node.includeText != null && node.includeText!.isNotEmpty) {
          buffer.writeln("${indent}Text: ${node.includeText}");
        }

        final childrenIds = childrenMap[node.id] ?? [];
        final children = filters
            .where((f) => childrenIds.contains(f.id))
            .toList();
        children.sort((a, b) => a.name.compareTo(b.name));

        for (final child in children) {
          printNode(child, indent);
        }
      }

      for (final root in roots) {
        printNode(root, "");
      }

      return buffer.toString();
    } catch (e) {
      return "Error listing filters: $e";
    }
  }
}

class ModifyNoteTool implements NativeTool {
  NoteModificationService get _service => getIt<NoteModificationService>();

  @override
  String get name => 'modify_note';

  @override
  String get description =>
      'Modify a note\'s content, title, tags, attachments, subnotes, or links. Supports whole-note append/prepend/replace and section-targeted markdown inserts.';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'note_id': {
        'type': 'string',
        'description': 'The ID of the note to modify.',
      },
      'modification': {
        'type': 'object',
        'description': 'The modification object.',
        'properties': _modificationProperties,
      },
    },
    'required': ['note_id', 'modification'],
  };

  @override
  Future<dynamic> execute(Map<String, dynamic> args) async {
    final noteId = args['note_id'] as String;
    final modification = args['modification'] as Map<String, dynamic>;

    // Check approval before modification
    if (!ApprovalService.sessionApprovedNoteModifications) {
      final approved = await ApprovalService.requestNoteModificationApproval(
        noteId: noteId,
        modification: modification,
        source: 'Agent',
      );
      if (!approved) {
        return {'error': 'User denied the note modification.'};
      }
    }

    try {
      final updatedNote = await _service.applyModifications(
        noteId,
        modification,
      );
      return {
        'status': 'success',
        'note_id': updatedNote.id,
        'new_title': updatedNote.title,
        'message': 'Note modified successfully.',
      };
    } catch (e) {
      return {'error': 'Failed to modify note: $e'};
    }
  }
}

class ModifyNotesTool implements NativeTool {
  NoteModificationService get _service => getIt<NoteModificationService>();

  @override
  String get name => 'modify_notes';

  @override
  String get description =>
      'Modify multiple notes in one atomic batch. Use this when index, log, source-tag, and compiled notes must be updated together. Requires a single approval for the whole batch.';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'modifications': {
        'type': 'array',
        'description':
            'List of note modifications. The batch is validated first, then applied atomically.',
        'items': {
          'type': 'object',
          'properties': {
            'note_id': {
              'type': 'string',
              'description': 'The ID of the note to modify.',
            },
            'modification': {
              'type': 'object',
              'description': 'The modification object.',
              'properties': _modificationProperties,
            },
          },
          'required': ['note_id', 'modification'],
        },
      },
    },
    'required': ['modifications'],
  };

  @override
  Future<dynamic> execute(Map<String, dynamic> args) async {
    final modifications = (args['modifications'] as List? ?? [])
        .whereType<Map<String, dynamic>>()
        .toList();

    if (modifications.isEmpty) {
      return {'error': 'No note modifications provided.'};
    }

    if (!ApprovalService.sessionApprovedNoteModifications) {
      final approved =
          await ApprovalService.requestBatchNoteModificationApproval(
            modifications: modifications,
            source: 'Agent',
          );
      if (!approved) {
        return {'error': 'User denied the note modification batch.'};
      }
    }

    try {
      final updatedNotes = await _service.applyBatchModifications(
        modifications,
      );
      return {
        'status': 'success',
        'modified_count': updatedNotes.length,
        'notes': updatedNotes
            .map((note) => {'note_id': note.id, 'title': note.title})
            .toList(),
      };
    } catch (e) {
      return {'error': 'Failed to modify notes: $e'};
    }
  }
}

const Map<String, dynamic> _modificationProperties = {
  'content': {
    'type': 'object',
    'properties': {
      'action': {
        'type': 'string',
        'enum': ['append', 'prepend', 'replace', 'no-op'],
      },
      'text': {'type': 'string'},
      'section': {
        'type': 'string',
        'description':
            'Optional markdown heading to target, for example "## Entities".',
      },
      'insert_position': {
        'type': 'string',
        'enum': ['append', 'prepend'],
        'description':
            'When section is provided, insert within that section instead of editing the whole note.',
      },
    },
  },
  'title': {
    'type': 'object',
    'properties': {
      'new_title': {'type': 'string'},
    },
  },
  'tags': {
    'type': 'object',
    'properties': {
      'added': {
        'type': 'array',
        'items': {'type': 'string'},
      },
      'removed': {
        'type': 'array',
        'items': {'type': 'string'},
      },
    },
  },
  'link': {
    'type': 'object',
    'description': 'Add or remove relationships to other notes.',
    'properties': {
      'added': {
        'type': 'array',
        'description': 'Relationships to create.',
        'items': {
          'type': 'object',
          'properties': {
            'relation': {'type': 'string', 'description': 'Relationship type.'},
            'target': {'type': 'string', 'description': 'Target note ID.'},
          },
          'required': ['relation', 'target'],
        },
      },
      'removed': {
        'type': 'array',
        'description': 'Target note IDs whose relationships should be deleted.',
        'items': {'type': 'string'},
      },
    },
  },
  'attachments': {
    'type': 'object',
    'properties': {
      'added': {
        'type': 'array',
        'items': {'type': 'string'},
      },
      'removed': {
        'type': 'array',
        'items': {'type': 'string'},
      },
    },
  },
  'subnote': {
    'type': 'object',
    'properties': {
      'added': {
        'type': 'array',
        'items': {
          'type': 'object',
          'properties': {
            'name': {'type': 'string'},
            'content': {'type': 'string'},
          },
        },
      },
      'removed': {
        'type': 'array',
        'items': {'type': 'string'},
      },
    },
  },
};

class CreateNotesTool implements NativeTool {
  NoteModificationService get _service => getIt<NoteModificationService>();

  @override
  String get name => 'create_notes';

  @override
  String get description =>
      'Create one or more new notes. Supports title, content, type (note/task), tags, subnotes, and attachments. For attachments, use filenames or synapsetemp:// URIs obtained from previous steps. IMPORTANT: Completion of this tool will assign new UUIDs to created notes.';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'notes': {
        'type': 'array',
        'description': 'A list of note objects to create.',
        'items': {
          'type': 'object',
          'properties': {
            'title': {
              'type': 'string',
              'description': 'The title of the note.',
            },
            'content': {
              'type': 'string',
              'description': 'The markdown content of the note.',
            },
            'type': {
              'type': 'string',
              'enum': ['note', 'task'],
              'description': 'The type of note.',
              'default': 'note',
            },
            'tags': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': 'Optional tags to add.',
            },
            'attachments': {
              'type': 'array',
              'items': {
                'type': 'string',
                'description':
                    'Filename or synapsetemp:// URI. DO NOT PROVIDE BASE64 DATA.',
              },
              'description': 'Optional list of attachment identifiers.',
            },
            'subnotes': {
              'type': 'array',
              'items': {
                'type': 'object',
                'properties': {
                  'name': {'type': 'string'},
                  'content': {'type': 'string'},
                  'is_completed': {'type': 'boolean', 'default': false},
                },
                'required': ['name'],
              },
              'description': 'Optional list of subnotes/tasks.',
            },
            'scheduled_at': {
              'type': 'string',
              'description':
                  'For tasks: ISO 8601 timestamp for when it is scheduled.',
            },
            'complete_by': {
              'type': 'string',
              'description':
                  'For tasks: ISO 8601 timestamp for when it should be completed.',
            },
            'status': {
              'type': 'string',
              'enum': ['todo', 'in_progress', 'complete', 'abandoned'],
              'description': 'For tasks: current status.',
              'default': 'todo',
            },
            'link': {
              'type': 'array',
              'description':
                  'Optional relationships to other notes. Created at note-creation time.',
              'items': {
                'type': 'object',
                'properties': {
                  'relation': {
                    'type': 'string',
                    'description':
                        'Relationship type (e.g., derived_from, related, references).',
                  },
                  'target': {
                    'type': 'string',
                    'description': 'The ID of the target note.',
                  },
                },
                'required': ['relation', 'target'],
              },
            },
          },
          'required': ['title', 'content'],
        },
      },
    },
    'required': ['notes'],
  };

  @override
  Future<dynamic> execute(Map<String, dynamic> args) async {
    final notesData = args['notes'] as List<dynamic>;
    final createdNotes = <Map<String, String>>[];

    for (final noteData in notesData) {
      if (noteData is! Map<String, dynamic>) continue;

      // Strict validation: Ensure no base64-like strings in attachments
      if (noteData.containsKey('attachments')) {
        final attachments = noteData['attachments'] as List<dynamic>;
        for (final att in attachments) {
          if (att is! String) {
            return {
              'error': 'Invalid attachment format. Must be a string (URI).',
            };
          }
          if (att.length > 2048 || att.contains(';base64,')) {
            return {
              'error':
                  'Base64 data is not allowed in create_notes. Use synapsetemp:// URIs or filenames instead.',
            };
          }
        }
      }

      try {
        final note = await _service.createNote(noteData);
        createdNotes.add({'id': note.id, 'title': note.title});
      } catch (e) {
        return {'error': 'Failed to create note "${noteData['title']}": $e'};
      }
    }

    return {
      'status': 'success',
      'created_count': createdNotes.length,
      'notes': createdNotes,
    };
  }
}

/// Tool for deleting notes.
/// Requires user approval before deletion.
class DeleteNoteTool implements NativeTool {
  DatabaseService get _databaseService => getIt<DatabaseService>();

  @override
  String get name => 'delete_notes';

  @override
  String get description =>
      'Delete one or more notes by their IDs. IMPORTANT: This action cannot be undone. Requires user approval.';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'note_ids': {
        'type': 'array',
        'description': 'List of note IDs to delete.',
        'items': {'type': 'string'},
      },
    },
    'required': ['note_ids'],
  };

  @override
  Future<dynamic> execute(Map<String, dynamic> args) async {
    final noteIdsRaw = args['note_ids'];
    if (noteIdsRaw is! List) {
      return {'error': 'note_ids must be a list of strings.'};
    }

    final noteIds = noteIdsRaw.whereType<String>().toList();
    if (noteIds.isEmpty) {
      return {'error': 'No valid note IDs provided.'};
    }

    // Check approval before deletion
    if (!ApprovalService.sessionApprovedNoteDeletions) {
      final approved = await ApprovalService.requestNoteDeletionApproval(
        noteIds: noteIds,
        source: 'Agent',
      );
      if (!approved) {
        return {'error': 'User denied the note deletion.'};
      }
    }

    final deletedIds = <String>[];
    final failedIds = <String, String>{};

    for (final noteId in noteIds) {
      try {
        final note = await _databaseService.getNote(noteId);
        if (note == null) {
          failedIds[noteId] = 'Note not found';
          continue;
        }
        await _databaseService.deleteNote(noteId);
        deletedIds.add(noteId);
      } catch (e) {
        failedIds[noteId] = e.toString();
      }
    }

    // This tool deletes via DatabaseService directly (not through
    // NoteModificationService or AppProvider), so it must publish its own
    // invalidation — only the ids that actually got deleted. Publish is
    // enqueue-only and cannot affect the tool result.
    if (deletedIds.isNotEmpty) {
      DataChangeNotifier.shared().publish(
        DataChangeEvent(noteIds: deletedIds.toSet()),
      );
    }

    if (deletedIds.isEmpty && failedIds.isNotEmpty) {
      return {'error': 'Failed to delete all notes.', 'failed': failedIds};
    }

    return {
      'status': 'success',
      'deleted_count': deletedIds.length,
      'deleted_ids': deletedIds,
      if (failedIds.isNotEmpty) 'failed': failedIds,
    };
  }
}

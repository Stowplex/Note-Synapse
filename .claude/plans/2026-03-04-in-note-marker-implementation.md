# In-Note Marker Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Render numbered badge markers on PDFs/images/text notes in immersive mode whenever the user draws a rectangle and sends it to AI; tapping a badge shows a preview popup with the captured image, user message, and AI reply.

**Architecture:** Markers are stored in existing `metadata` JSON fields on the `attachments` table (PDF/image) and a new `metadata` column on the `notes` table (text notes). A thin `NoteMarkerService` wraps read/write. The immersive screen captures a normalized bounding rect at draw-confirm time, stashes it as `_pendingMarkerPosition`, then saves the marker with the real `messageId` after `addUserMessage` returns.

**Tech Stack:** Flutter/Dart, sqflite, pdfrx (`PdfViewerController`), existing `DatabaseService`/`ConversationService`.

---

## Background: Key File Locations

- `lib/models/attachment.dart` — `Attachment`, `PdfBookmark` (mirror this pattern)
- `lib/services/database_service.dart:49` — `DATABASE_VERSION = 41` (bump to 42)
- `lib/services/database_service.dart:1878` — `updateAttachmentMetadata(id, metadata)`
- `lib/screens/immersive_note_screen.dart:2057` — `_confirmDrawing()` ← capture point
- `lib/screens/immersive_note_screen.dart:4276` — `addUserMessage` returns `userMessage` ← save point
- `lib/screens/immersive_note_screen.dart:3481` — `_buildAttachmentViewer` ← add overlay here
- `lib/screens/immersive_note_screen.dart:5277` — `_buildPdfView` → `PdfViewerParams` ← add `pageOverlaysBuilder`
- `lib/screens/conversation_chat_screen.dart:61` — needs `initialMessageId` param

---

## Task 1: `InNoteMarker` model

**Files:**
- Create: `lib/models/in_note_marker.dart`
- Create: `test/in_note_marker_test.dart`

**Step 1: Write the failing test**

```dart
// test/in_note_marker_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/in_note_marker.dart';

void main() {
  group('NormalizedRect', () {
    test('roundtrips through JSON', () {
      final rect = NormalizedRect(x: 0.1, y: 0.2, w: 0.3, h: 0.15);
      final json = rect.toJson();
      final restored = NormalizedRect.fromJson(json);
      expect(restored.x, closeTo(0.1, 0.001));
      expect(restored.y, closeTo(0.2, 0.001));
      expect(restored.w, closeTo(0.3, 0.001));
      expect(restored.h, closeTo(0.15, 0.001));
    });
  });

  group('InNoteMarker', () {
    test('roundtrips attachment marker through JSON', () {
      final marker = InNoteMarker.forAttachment(
        id: 'test-id',
        index: 1,
        page: 3,
        normalizedRect: NormalizedRect(x: 0.1, y: 0.2, w: 0.3, h: 0.15),
        conversationId: 'conv-1',
        messageId: 'msg-1',
        createdAt: DateTime.utc(2026, 3, 4),
      );
      final json = marker.toJson();
      final restored = InNoteMarker.fromJson(json);
      expect(restored.id, 'test-id');
      expect(restored.index, 1);
      expect(restored.page, 3);
      expect(restored.normalizedRect, isNotNull);
      expect(restored.normalizedRect!.x, closeTo(0.1, 0.001));
      expect(restored.conversationId, 'conv-1');
      expect(restored.messageId, 'msg-1');
      expect(restored.charStart, isNull);
    });

    test('roundtrips text note marker through JSON', () {
      final marker = InNoteMarker.forNote(
        id: 'note-marker-id',
        index: 2,
        charStart: 120,
        charEnd: 250,
        conversationId: 'conv-2',
        messageId: 'msg-2',
        createdAt: DateTime.utc(2026, 3, 4),
      );
      final json = marker.toJson();
      final restored = InNoteMarker.fromJson(json);
      expect(restored.charStart, 120);
      expect(restored.charEnd, 250);
      expect(restored.normalizedRect, isNull);
      expect(restored.page, isNull);
    });
  });
}
```

**Step 2: Run to confirm failure**

```bash
flutter test test/in_note_marker_test.dart
```

Expected: FAIL — `in_note_marker.dart` not found.

**Step 3: Implement**

```dart
// lib/models/in_note_marker.dart
import 'package:uuid/uuid.dart';

class NormalizedRect {
  final double x, y, w, h;

  const NormalizedRect({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
  });

  factory NormalizedRect.fromJson(Map<String, dynamic> json) => NormalizedRect(
    x: (json['x'] as num).toDouble(),
    y: (json['y'] as num).toDouble(),
    w: (json['w'] as num).toDouble(),
    h: (json['h'] as num).toDouble(),
  );

  Map<String, dynamic> toJson() => {'x': x, 'y': y, 'w': w, 'h': h};
}

class InNoteMarker {
  final String id;
  final int index;
  final String conversationId;
  final String messageId;
  final DateTime createdAt;

  // PDF/image fields
  final int? page;
  final NormalizedRect? normalizedRect;

  // Text note fields
  final int? charStart;
  final int? charEnd;

  const InNoteMarker({
    required this.id,
    required this.index,
    required this.conversationId,
    required this.messageId,
    required this.createdAt,
    this.page,
    this.normalizedRect,
    this.charStart,
    this.charEnd,
  });

  factory InNoteMarker.forAttachment({
    String? id,
    required int index,
    required int page,
    required NormalizedRect normalizedRect,
    required String conversationId,
    required String messageId,
    DateTime? createdAt,
  }) => InNoteMarker(
    id: id ?? const Uuid().v4(),
    index: index,
    page: page,
    normalizedRect: normalizedRect,
    conversationId: conversationId,
    messageId: messageId,
    createdAt: createdAt ?? DateTime.now(),
  );

  factory InNoteMarker.forNote({
    String? id,
    required int index,
    required int charStart,
    required int charEnd,
    required String conversationId,
    required String messageId,
    DateTime? createdAt,
  }) => InNoteMarker(
    id: id ?? const Uuid().v4(),
    index: index,
    charStart: charStart,
    charEnd: charEnd,
    conversationId: conversationId,
    messageId: messageId,
    createdAt: createdAt ?? DateTime.now(),
  );

  factory InNoteMarker.fromJson(Map<String, dynamic> json) {
    final rectJson = json['normalizedRect'] as Map<String, dynamic>?;
    return InNoteMarker(
      id: json['id'] as String,
      index: json['index'] as int,
      conversationId: json['conversationId'] as String,
      messageId: json['messageId'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
      page: json['page'] as int?,
      normalizedRect: rectJson != null ? NormalizedRect.fromJson(rectJson) : null,
      charStart: json['charStart'] as int?,
      charEnd: json['charEnd'] as int?,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'index': index,
    'conversationId': conversationId,
    'messageId': messageId,
    'createdAt': createdAt.toIso8601String(),
    if (page != null) 'page': page,
    if (normalizedRect != null) 'normalizedRect': normalizedRect!.toJson(),
    if (charStart != null) 'charStart': charStart,
    if (charEnd != null) 'charEnd': charEnd,
  };
}
```

**Step 4: Run tests**

```bash
flutter test test/in_note_marker_test.dart
```

Expected: PASS

**Step 5: Commit**

```bash
git add lib/models/in_note_marker.dart test/in_note_marker_test.dart
git commit -m "feat: add InNoteMarker model with JSON serialization"
```

---

## Task 2: DB migration — add `metadata` column to `notes` table

**Files:**
- Modify: `lib/services/database_service.dart`

The `notes` table (line 54) currently has no `metadata` column. We need to add it and provide methods to read/write it.

**Step 1: Write the failing test**

Add to an existing test file or create `test/note_metadata_test.dart`:

```dart
// test/note_metadata_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() => sqfliteFfiInit());

  test('updateNoteMetadata persists and getNoteMetadata retrieves', () async {
    final db = await DatabaseService.createNew(
      databaseName: 'test_note_meta_${DateTime.now().millisecondsSinceEpoch}.db',
    );

    // Create a minimal note
    final noteId = 'test-note-1';
    await db.database.then((d) => d.insert('notes', {
      'id': noteId,
      'title': 'Test',
      'content': '',
      'type': 'text',
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
      'pinned': 0,
      'isArchived': 0,
    }));

    await db.updateNoteMetadata(noteId, {'markers': []});
    final meta = await db.getNoteMetadata(noteId);
    expect(meta, isNotNull);
    expect(meta!['markers'], isEmpty);
  });
}
```

**Step 2: Run to confirm failure**

```bash
flutter test test/note_metadata_test.dart
```

Expected: FAIL — `updateNoteMetadata` not found.

**Step 3: Implement**

In `lib/services/database_service.dart`:

3a. Bump version (line 49):
```dart
static const int DATABASE_VERSION = 42;
```

3b. In `_onUpgrade`, add a case for version 42. Find the existing `_onUpgrade` method and add at the end of the switch/if-else chain:

```dart
if (oldVersion < 42) {
  await db.execute('ALTER TABLE notes ADD COLUMN metadata TEXT');
}
```

3c. In the `_onCreate` method, update the notes table CREATE statement (around line 54) to include the new column:

```dart
// Add to notes CREATE TABLE statement:
metadata TEXT
```

3d. Add the two new methods near the existing `updateAttachmentMetadata` method (around line 1892):

```dart
Future<void> updateNoteMetadata(
  String noteId,
  Map<String, dynamic>? metadata,
) async {
  final db = await database;
  await db.update(
    'notes',
    {'metadata': metadata != null ? jsonEncode(metadata) : null},
    where: 'id = ?',
    whereArgs: [noteId],
  );
}

Future<Map<String, dynamic>?> getNoteMetadata(String noteId) async {
  final db = await database;
  final rows = await db.query(
    'notes',
    columns: ['metadata'],
    where: 'id = ?',
    whereArgs: [noteId],
  );
  if (rows.isEmpty) return null;
  final raw = rows.first['metadata'] as String?;
  if (raw == null) return null;
  return jsonDecode(raw) as Map<String, dynamic>;
}
```

**Step 4: Run tests**

```bash
flutter test test/note_metadata_test.dart
```

Expected: PASS

**Step 5: Also update `recovery_screen.dart`**

Per CLAUDE.md: when modifying tables, update recovery_screen. Search for the notes table handling in `lib/screens/recovery_screen.dart` and add `metadata` to the column list for notes recovery. Find where notes columns are listed and add `'metadata'`.

**Step 6: Commit**

```bash
git add lib/services/database_service.dart lib/screens/recovery_screen.dart test/note_metadata_test.dart
git commit -m "feat: add metadata column to notes table (DB v42)"
```

---

## Task 3: `NoteMarkerService`

**Files:**
- Create: `lib/services/note_marker_service.dart`
- Create: `test/note_marker_service_test.dart`

**Step 1: Write the failing tests**

```dart
// test/note_marker_service_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/attachment.dart';
import 'package:note_synapse/models/in_note_marker.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/note_marker_service.dart';

import 'helpers/test_helpers.dart'; // existing mock setup

@GenerateMocks([DatabaseService])
void main() {
  late MockDatabaseService mockDb;
  late NoteMarkerService service;

  setUp(() async {
    await resetForTesting();
    mockDb = MockDatabaseService();
    getIt.registerSingleton<DatabaseService>(mockDb);
    service = NoteMarkerService(mockDb);
  });

  group('saveMarkerForAttachment', () {
    test('appends marker to empty metadata', () async {
      final attachment = Attachment(
        id: 'att-1',
        noteId: 'note-1',
        filePath: 'test.pdf',
        fileName: 'test.pdf',
        fileType: 'pdf',
        createdAt: DateTime.now(),
        isRelativePath: true,
        includeInAIContext: true,
        metadata: null,
      );

      when(mockDb.getAttachment('att-1')).thenAnswer((_) async => attachment);
      when(mockDb.updateAttachmentMetadata(any, any)).thenAnswer((_) async {});

      final marker = InNoteMarker.forAttachment(
        index: 1,
        page: 2,
        normalizedRect: NormalizedRect(x: 0.1, y: 0.2, w: 0.3, h: 0.1),
        conversationId: 'conv-1',
        messageId: 'msg-1',
      );

      await service.saveMarkerForAttachment('att-1', marker);

      final captured = verify(
        mockDb.updateAttachmentMetadata('att-1', captureAny),
      ).captured.single as Map<String, dynamic>;
      final markers = captured['markers'] as List;
      expect(markers.length, 1);
      expect(markers.first['messageId'], 'msg-1');
    });

    test('appends to existing markers preserving others', () async {
      final existing = InNoteMarker.forAttachment(
        id: 'existing',
        index: 1,
        page: 1,
        normalizedRect: NormalizedRect(x: 0, y: 0, w: 0.1, h: 0.1),
        conversationId: 'conv-0',
        messageId: 'msg-0',
      );
      final attachment = Attachment(
        id: 'att-1',
        noteId: 'note-1',
        filePath: 'test.pdf',
        fileName: 'test.pdf',
        fileType: 'pdf',
        createdAt: DateTime.now(),
        isRelativePath: true,
        includeInAIContext: true,
        metadata: {'markers': [existing.toJson()]},
      );

      when(mockDb.getAttachment('att-1')).thenAnswer((_) async => attachment);
      when(mockDb.updateAttachmentMetadata(any, any)).thenAnswer((_) async {});

      final newMarker = InNoteMarker.forAttachment(
        index: 2,
        page: 3,
        normalizedRect: NormalizedRect(x: 0.5, y: 0.5, w: 0.2, h: 0.1),
        conversationId: 'conv-1',
        messageId: 'msg-1',
      );

      await service.saveMarkerForAttachment('att-1', newMarker);

      final captured = verify(
        mockDb.updateAttachmentMetadata('att-1', captureAny),
      ).captured.single as Map<String, dynamic>;
      expect((captured['markers'] as List).length, 2);
    });
  });

  group('getMarkersForAttachment', () {
    test('returns empty list when no metadata', () async {
      final attachment = Attachment(
        id: 'att-1', noteId: 'n', filePath: 'f', fileName: 'f',
        fileType: 'pdf', createdAt: DateTime.now(),
        isRelativePath: true, includeInAIContext: true, metadata: null,
      );
      when(mockDb.getAttachment('att-1')).thenAnswer((_) async => attachment);

      final markers = await service.getMarkersForAttachment('att-1');
      expect(markers, isEmpty);
    });

    test('returns deserialized markers', () async {
      final marker = InNoteMarker.forAttachment(
        id: 'm1', index: 1, page: 2,
        normalizedRect: NormalizedRect(x: 0.1, y: 0.1, w: 0.2, h: 0.1),
        conversationId: 'c', messageId: 'm',
      );
      final attachment = Attachment(
        id: 'att-1', noteId: 'n', filePath: 'f', fileName: 'f',
        fileType: 'pdf', createdAt: DateTime.now(),
        isRelativePath: true, includeInAIContext: true,
        metadata: {'markers': [marker.toJson()]},
      );
      when(mockDb.getAttachment('att-1')).thenAnswer((_) async => attachment);

      final markers = await service.getMarkersForAttachment('att-1');
      expect(markers.length, 1);
      expect(markers.first.id, 'm1');
    });
  });

  group('deleteMarkerForAttachment', () {
    test('removes marker by id', () async {
      final m1 = InNoteMarker.forAttachment(
        id: 'keep', index: 1, page: 1,
        normalizedRect: NormalizedRect(x: 0, y: 0, w: 0.1, h: 0.1),
        conversationId: 'c', messageId: 'msg-keep',
      );
      final m2 = InNoteMarker.forAttachment(
        id: 'delete', index: 2, page: 2,
        normalizedRect: NormalizedRect(x: 0.5, y: 0.5, w: 0.1, h: 0.1),
        conversationId: 'c', messageId: 'msg-delete',
      );
      final attachment = Attachment(
        id: 'att-1', noteId: 'n', filePath: 'f', fileName: 'f',
        fileType: 'pdf', createdAt: DateTime.now(),
        isRelativePath: true, includeInAIContext: true,
        metadata: {'markers': [m1.toJson(), m2.toJson()]},
      );
      when(mockDb.getAttachment('att-1')).thenAnswer((_) async => attachment);
      when(mockDb.updateAttachmentMetadata(any, any)).thenAnswer((_) async {});

      await service.deleteMarkerForAttachment('att-1', 'delete');

      final captured = verify(
        mockDb.updateAttachmentMetadata('att-1', captureAny),
      ).captured.single as Map<String, dynamic>;
      final remaining = captured['markers'] as List;
      expect(remaining.length, 1);
      expect(remaining.first['id'], 'keep');
    });
  });
}
```

**Step 2: Run to confirm failure**

```bash
flutter test test/note_marker_service_test.dart
```

Expected: FAIL

**Step 3: Implement**

```dart
// lib/services/note_marker_service.dart
import 'package:note_synapse/models/in_note_marker.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/logger_service.dart';

class NoteMarkerService {
  final DatabaseService _db;
  NoteMarkerService(this._db);

  // ── Attachment markers (PDF / image) ────────────────────────────────────

  Future<void> saveMarkerForAttachment(
    String attachmentId,
    InNoteMarker marker,
  ) async {
    try {
      final attachment = await _db.getAttachment(attachmentId);
      if (attachment == null) return;
      final metadata = Map<String, dynamic>.from(attachment.metadata ?? {});
      final markers = _parseMarkers(metadata['markers']);
      markers.add(marker.toJson());
      metadata['markers'] = markers;
      await _db.updateAttachmentMetadata(attachmentId, metadata);
    } catch (e) {
      LoggerService.warning('Failed to save attachment marker: $e');
    }
  }

  Future<List<InNoteMarker>> getMarkersForAttachment(
    String attachmentId,
  ) async {
    try {
      final attachment = await _db.getAttachment(attachmentId);
      if (attachment == null) return [];
      return _parseMarkers(attachment.metadata?['markers'])
          .map((e) => InNoteMarker.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      LoggerService.warning('Failed to get attachment markers: $e');
      return [];
    }
  }

  Future<void> deleteMarkerForAttachment(
    String attachmentId,
    String markerId,
  ) async {
    try {
      final attachment = await _db.getAttachment(attachmentId);
      if (attachment == null) return;
      final metadata = Map<String, dynamic>.from(attachment.metadata ?? {});
      final markers = _parseMarkers(metadata['markers'])
        ..removeWhere((m) => (m as Map<String, dynamic>)['id'] == markerId);
      metadata['markers'] = markers;
      await _db.updateAttachmentMetadata(attachmentId, metadata);
    } catch (e) {
      LoggerService.warning('Failed to delete attachment marker: $e');
    }
  }

  // ── Note markers (text notes) ────────────────────────────────────────────

  Future<void> saveMarkerForNote(String noteId, InNoteMarker marker) async {
    try {
      final metadata = Map<String, dynamic>.from(
        await _db.getNoteMetadata(noteId) ?? {},
      );
      final markers = _parseMarkers(metadata['markers']);
      markers.add(marker.toJson());
      metadata['markers'] = markers;
      await _db.updateNoteMetadata(noteId, metadata);
    } catch (e) {
      LoggerService.warning('Failed to save note marker: $e');
    }
  }

  Future<List<InNoteMarker>> getMarkersForNote(String noteId) async {
    try {
      final metadata = await _db.getNoteMetadata(noteId);
      return _parseMarkers(metadata?['markers'])
          .map((e) => InNoteMarker.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      LoggerService.warning('Failed to get note markers: $e');
      return [];
    }
  }

  Future<void> deleteMarkerForNote(String noteId, String markerId) async {
    try {
      final metadata = Map<String, dynamic>.from(
        await _db.getNoteMetadata(noteId) ?? {},
      );
      final markers = _parseMarkers(metadata['markers'])
        ..removeWhere((m) => (m as Map<String, dynamic>)['id'] == markerId);
      metadata['markers'] = markers;
      await _db.updateNoteMetadata(noteId, metadata);
    } catch (e) {
      LoggerService.warning('Failed to delete note marker: $e');
    }
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  List<dynamic> _parseMarkers(dynamic raw) {
    if (raw is List) return List<dynamic>.from(raw);
    return [];
  }
}
```

Register in `lib/services/service_locator.dart` following the existing pattern (find where other services are registered with `getIt.registerSingleton` or `registerLazySingleton` and add):

```dart
getIt.registerLazySingleton<NoteMarkerService>(
  () => NoteMarkerService(getIt<DatabaseService>()),
);
```

**Step 4: Generate mocks and run tests**

```bash
dart run build_runner build --delete-conflicting-outputs
flutter test test/note_marker_service_test.dart
```

Expected: PASS

**Step 5: Commit**

```bash
git add lib/models/in_note_marker.dart lib/services/note_marker_service.dart \
        lib/services/service_locator.dart test/note_marker_service_test.dart
git commit -m "feat: add NoteMarkerService for reading/writing in-note markers"
```

---

## Task 4: Capture normalized marker position at draw confirmation

**Files:**
- Modify: `lib/screens/immersive_note_screen.dart`

We need to stash the drawn rectangle in document-normalized coordinates when `_confirmDrawing()` runs.

**Coordinate strategy:**
- **PDF**: `_pdfCurrentPages[_activeAttachmentPath]` gives current page (0-indexed). We normalize the drawn `totalBounds` rect relative to the RepaintBoundary widget size. Badge rendering will use the same normalization. (Using page-relative coords requires deeper pdfrx integration; screen-relative is sufficient for MVP.)
- **Image**: Same — normalize to widget size via RepaintBoundary.
- **Text note** (`_activeAttachmentPath == null`): normalize to widget height, then convert leading-edge Y to a rough character offset using `RenderEditable` (best-effort; fall back to scroll percentage stored as `charStart = (y/h * contentLength).round()`).

**Step 1: Add state field**

Near the existing `_pendingAttachments` declaration (line 122), add:

```dart
// in _ImmersiveNoteScreenState:
InNoteMarkerPosition? _pendingMarkerPosition;
```

Also add a small data class at the bottom of the file (outside the state class):

```dart
/// Transient position captured at draw-confirm time.
class InNoteMarkerPosition {
  final NormalizedRect normalizedRect;
  final int? page; // null for text notes
  final int? charStart; // text note only
  final int? charEnd;   // text note only
  const InNoteMarkerPosition({
    required this.normalizedRect,
    this.page,
    this.charStart,
    this.charEnd,
  });
}
```

**Step 2: Compute and stash position in `_confirmDrawing`**

In `_confirmDrawing` (line 2057), after `if (totalBounds == null) return;` and before the `try {` block, add:

```dart
// Capture normalized marker position
_pendingMarkerPosition = _computeMarkerPosition(totalBounds!);
```

Add the helper method to the state class:

```dart
InNoteMarkerPosition? _computeMarkerPosition(Rect drawBounds) {
  final renderObject = _noteBoundaryKey.currentContext?.findRenderObject();
  if (renderObject is! RenderRepaintBoundary) return null;
  final size = renderObject.size;
  if (size.isEmpty) return null;

  final norm = NormalizedRect(
    x: (drawBounds.left / size.width).clamp(0.0, 1.0),
    y: (drawBounds.top / size.height).clamp(0.0, 1.0),
    w: (drawBounds.width / size.width).clamp(0.0, 1.0),
    h: (drawBounds.height / size.height).clamp(0.0, 1.0),
  );

  if (_activeAttachmentPath != null) {
    // PDF or image: include current page (0-indexed)
    final page = _pdfCurrentPages[_activeAttachmentPath!];
    return InNoteMarkerPosition(normalizedRect: norm, page: page);
  } else {
    // Text note: no char offset for now; store Y as a rough anchor
    return InNoteMarkerPosition(normalizedRect: norm);
  }
}
```

**Step 3: Clear `_pendingMarkerPosition` when drawing is cleared without sending**

In the existing drawing reset/clear locations (search for `_drawingActions.clear()`), also clear:

```dart
_pendingMarkerPosition = null;
```

There are two places: inside `_confirmDrawing` (after `_drawingActions.clear()`) and in any "cancel drawing" handler.

**Step 4: Verify app still compiles**

```bash
flutter analyze lib/screens/immersive_note_screen.dart
```

Expected: no new errors.

**Step 5: Commit**

```bash
git add lib/screens/immersive_note_screen.dart
git commit -m "feat: capture normalized marker position on drawing confirm"
```

---

## Task 5: Save marker after message is sent

**Files:**
- Modify: `lib/screens/immersive_note_screen.dart`

After `addUserMessage` returns with a real `messageId`, save the pending marker.

**Step 1: Add import and service reference**

At the top of `immersive_note_screen.dart`, add:
```dart
import 'package:note_synapse/models/in_note_marker.dart';
import 'package:note_synapse/services/note_marker_service.dart';
```

In the state class, add field:
```dart
late final NoteMarkerService _noteMarkerService = getIt<NoteMarkerService>();
```

**Step 2: Save marker in `_sendMessage` after `addUserMessage` returns**

In `_sendMessage` (around line 4276–4284), after:
```dart
final userMessage = await _conversationService.addUserMessage(
  conversationId: _conversation!.id,
  content: content,
  attachmentPaths: attachmentPaths,
);
```

Add:
```dart
// Save in-note marker if a drawing was confirmed before this send
if (_pendingMarkerPosition != null) {
  await _saveInNoteMarker(
    userMessage.id,
    _conversation!.id,
    _pendingMarkerPosition!,
  );
  _pendingMarkerPosition = null;
}
```

**Step 3: Add `_saveInNoteMarker` helper**

```dart
Future<void> _saveInNoteMarker(
  String messageId,
  String conversationId,
  InNoteMarkerPosition position,
) async {
  if (_activeAttachmentPath != null) {
    final attachment = await _resolveAttachment(_activeAttachmentPath!);
    if (attachment == null) return;
    final existingMarkers = await _noteMarkerService.getMarkersForAttachment(
      attachment.id,
    );
    final marker = InNoteMarker.forAttachment(
      index: existingMarkers.length + 1,
      page: position.page ?? 0,
      normalizedRect: position.normalizedRect,
      conversationId: conversationId,
      messageId: messageId,
    );
    await _noteMarkerService.saveMarkerForAttachment(attachment.id, marker);
    // Trigger overlay rebuild
    if (mounted) setState(() {});
  } else {
    // Text note
    final note = widget.notes[_activeNoteIndex];
    final existingMarkers = await _noteMarkerService.getMarkersForNote(note.id);
    final marker = InNoteMarker.forNote(
      index: existingMarkers.length + 1,
      charStart: position.charStart ?? 0,
      charEnd: position.charEnd ?? 0,
      conversationId: conversationId,
      messageId: messageId,
    );
    await _noteMarkerService.saveMarkerForNote(note.id, marker);
    if (mounted) setState(() {});
  }
}
```

**Step 4: Verify**

```bash
flutter analyze lib/screens/immersive_note_screen.dart
```

**Step 5: Commit**

```bash
git add lib/screens/immersive_note_screen.dart
git commit -m "feat: save in-note marker after message is sent"
```

---

## Task 6: `InNoteMarkerBadge` widget + preview popup

**Files:**
- Create: `lib/widgets/in_note_marker_badge.dart`
- Create: `lib/widgets/in_note_marker_preview.dart`
- Create: `test/in_note_marker_badge_test.dart`

**Step 1: Write badge widget test**

```dart
// test/in_note_marker_badge_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/widgets/in_note_marker_badge.dart';

void main() {
  testWidgets('InNoteMarkerBadge shows correct index number', (tester) async {
    bool tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InNoteMarkerBadge(
            index: 3,
            onTap: () => tapped = true,
          ),
        ),
      ),
    );
    expect(find.text('3'), findsOneWidget);
    await tester.tap(find.byType(InNoteMarkerBadge));
    expect(tapped, isTrue);
  });

  testWidgets('InNoteMarkerBadge starts at 60% opacity', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InNoteMarkerBadge(index: 1, onTap: () {}),
        ),
      ),
    );
    final animatedOpacity = tester.widget<AnimatedOpacity>(
      find.byType(AnimatedOpacity),
    );
    expect(animatedOpacity.opacity, closeTo(0.6, 0.01));
  });
}
```

**Step 2: Run to confirm failure**

```bash
flutter test test/in_note_marker_badge_test.dart
```

**Step 3: Implement badge widget**

```dart
// lib/widgets/in_note_marker_badge.dart
import 'package:flutter/material.dart';

class InNoteMarkerBadge extends StatefulWidget {
  final int index;
  final VoidCallback onTap;

  const InNoteMarkerBadge({super.key, required this.index, required this.onTap});

  @override
  State<InNoteMarkerBadge> createState() => _InNoteMarkerBadgeState();
}

class _InNoteMarkerBadgeState extends State<InNoteMarkerBadge> {
  double _opacity = 0.6;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        setState(() => _opacity = 1.0);
        widget.onTap();
        Future.delayed(const Duration(milliseconds: 800), () {
          if (mounted) setState(() => _opacity = 0.6);
        });
      },
      child: AnimatedOpacity(
        opacity: _opacity,
        duration: const Duration(milliseconds: 200),
        child: Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: Colors.blue,
            shape: BoxShape.circle,
            boxShadow: const [
              BoxShadow(
                color: Colors.black26,
                blurRadius: 3,
                offset: Offset(1, 1),
              ),
            ],
          ),
          alignment: Alignment.center,
          child: Text(
            '${widget.index}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }
}
```

**Step 4: Implement preview popup**

```dart
// lib/widgets/in_note_marker_preview.dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:note_synapse/models/conversation.dart';
import 'package:note_synapse/models/in_note_marker.dart';
import 'package:note_synapse/screens/conversation_chat_screen.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/service_locator.dart';

class InNoteMarkerPreview extends StatefulWidget {
  final InNoteMarker marker;

  const InNoteMarkerPreview({super.key, required this.marker});

  @override
  State<InNoteMarkerPreview> createState() => _InNoteMarkerPreviewState();
}

class _InNoteMarkerPreviewState extends State<InNoteMarkerPreview> {
  final _db = getIt<DatabaseService>();
  ConversationMessage? _userMessage;
  ConversationMessage? _aiMessage;
  String? _imagePath;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      // Load user message
      final userMsg = await _db.getConversationMessage(widget.marker.messageId);

      // Load the first image attachment for this message
      final attachments = await _db.getConversationAttachments(
        widget.marker.messageId,
      );
      final imageAttachment = attachments.firstWhere(
        (a) => _isImage(a.filePath),
        orElse: () => attachments.isEmpty ? attachments.first : attachments.first,
      );

      // Load AI reply — the next message in the conversation after this one
      final allMessages = await _db.getConversationMessages(
        widget.marker.conversationId,
      );
      final userIdx = allMessages.indexWhere(
        (m) => m.id == widget.marker.messageId,
      );
      final aiMsg = (userIdx >= 0 && userIdx + 1 < allMessages.length)
          ? allMessages[userIdx + 1]
          : null;

      String? resolvedImagePath;
      if (attachments.isNotEmpty) {
        final att = attachments.firstWhere(
          (a) => _isImage(a.filePath),
          orElse: () => attachments.first,
        );
        resolvedImagePath = await _db.resolveAttachmentPath(att.filePath);
      }

      if (mounted) {
        setState(() {
          _userMessage = userMsg;
          _aiMessage = aiMsg;
          _imagePath = resolvedImagePath;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool _isImage(String path) {
    final ext = path.split('.').last.toLowerCase();
    return ['png', 'jpg', 'jpeg', 'webp'].contains(ext);
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.55,
      minChildSize: 0.3,
      maxChildSize: 0.85,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _buildContent(context, scrollController),
        );
      },
    );
  }

  Widget _buildContent(
    BuildContext context,
    ScrollController scrollController,
  ) {
    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        // Drag handle
        Center(
          child: Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.outlineVariant,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),

        // Captured annotation image
        if (_imagePath != null) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(
              File(_imagePath!),
              height: 150,
              width: double.infinity,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => _imagePlaceholder(context),
            ),
          ),
          const SizedBox(height: 12),
        ] else ...[
          _imagePlaceholder(context),
          const SizedBox(height: 12),
        ],

        // User message
        if (_userMessage != null) ...[
          Text(
            'You',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                ),
          ),
          const SizedBox(height: 4),
          Text(
            _userMessage!.content,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 12),
        ],

        // AI reply
        if (_aiMessage != null) ...[
          Text(
            'AI',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.secondary,
                ),
          ),
          const SizedBox(height: 4),
          Text(
            _aiMessage!.content,
            maxLines: 4,
            overflow: TextOverflow.fade,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 16),
        ] else ...[
          Text(
            'No response yet.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
          ),
          const SizedBox(height: 16),
        ],

        // Open conversation button
        FilledButton.tonal(
          onPressed: () {
            Navigator.of(context).pop();
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ConversationChatScreen(
                  conversationId: widget.marker.conversationId,
                  initialMessageId: widget.marker.messageId,
                ),
              ),
            );
          },
          child: const Text('Open Conversation'),
        ),
      ],
    );
  }

  Widget _imagePlaceholder(BuildContext context) {
    return Container(
      height: 80,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(Icons.image_not_supported_outlined, size: 36),
    );
  }
}

/// Show the preview as a modal bottom sheet.
Future<void> showInNoteMarkerPreview(
  BuildContext context,
  InNoteMarker marker,
) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => InNoteMarkerPreview(marker: marker),
  );
}
```

**Step 5: Run tests**

```bash
flutter test test/in_note_marker_badge_test.dart
```

Expected: PASS

**Step 6: Commit**

```bash
git add lib/widgets/in_note_marker_badge.dart lib/widgets/in_note_marker_preview.dart \
        test/in_note_marker_badge_test.dart
git commit -m "feat: add InNoteMarkerBadge widget and preview bottom sheet"
```

---

## Task 7: Add `initialMessageId` to `ConversationChatScreen`

**Files:**
- Modify: `lib/screens/conversation_chat_screen.dart`

The preview popup's "Open Conversation" button passes `initialMessageId`. We need `ConversationChatScreen` to accept it and scroll to that message after loading.

**Step 1: Add the parameter**

Find the constructor (line 61) and add:

```dart
final String? initialMessageId;

const ConversationChatScreen({
  super.key,
  this.conversationId,
  this.initialNoteIds,
  this.initialModelOverride,
  this.initialMessageId,   // ← add this
});
```

**Step 2: Scroll to message after load**

In the state class, find where messages are loaded (the `initState` / `_loadConversation` method). After messages are loaded into the list, add:

```dart
if (widget.initialMessageId != null) {
  WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToMessage(widget.initialMessageId!));
}
```

Add the helper:

```dart
void _scrollToMessage(String messageId) {
  final idx = _messages.indexWhere((m) => m.id == messageId);
  if (idx < 0 || !_scrollController.hasClients) return;
  // Approximate item height; a more precise approach uses a GlobalKey per item
  const estimatedItemHeight = 120.0;
  final offset = (idx * estimatedItemHeight)
      .clamp(0.0, _scrollController.position.maxScrollExtent);
  _scrollController.animateTo(
    offset,
    duration: const Duration(milliseconds: 400),
    curve: Curves.easeInOut,
  );
}
```

**Step 3: Verify no regressions**

```bash
flutter analyze lib/screens/conversation_chat_screen.dart
flutter test
```

**Step 4: Commit**

```bash
git add lib/screens/conversation_chat_screen.dart
git commit -m "feat: ConversationChatScreen accepts initialMessageId for scroll-to"
```

---

## Task 8: Render markers on PDF viewer

**Files:**
- Modify: `lib/screens/immersive_note_screen.dart` (`_PdfDocumentView` / `_buildPdfView`)

**Step 1: Load markers and pass them to `_PdfDocumentView`**

In `_buildAttachmentViewer` (line 3481), the `_PdfDocumentView` is constructed. We need to:

1. Load markers for the current attachment. Add a `Map<String, List<InNoteMarker>> _attachmentMarkers` state field.

2. Add a helper to (re)load markers for an attachment:

```dart
Future<void> _loadMarkersForAttachment(String attachmentPath) async {
  final attachment = await _resolveAttachment(attachmentPath);
  if (attachment == null) return;
  final markers = await _noteMarkerService.getMarkersForAttachment(
    attachment.id,
  );
  if (mounted) {
    setState(() {
      _attachmentMarkers[attachmentPath] = markers;
    });
  }
}
```

Call this in `initState` for the initial attachment and whenever `_activeAttachmentPath` changes.

**Step 2: Add `markers` and `onMarkerTap` to `_PdfDocumentView`**

In `_PdfDocumentView` widget declaration (line 5184), add:

```dart
final List<InNoteMarker> markers;
final void Function(InNoteMarker) onMarkerTap;
```

Update `_buildPdfView` to add `pageOverlaysBuilder` to `PdfViewerParams`:

```dart
pageOverlaysBuilder: (context, pageNumber, pageSize) {
  // pageNumber is 1-indexed in pdfrx; our markers store 0-indexed page
  final pageMarkers = widget.markers.where(
    (m) => m.page == pageNumber - 1,
  ).toList();

  return pageMarkers.map((marker) {
    final rect = marker.normalizedRect;
    if (rect == null) return const SizedBox.shrink();
    return Positioned(
      left: rect.x * pageSize.width,
      top: rect.y * pageSize.height,
      child: InNoteMarkerBadge(
        index: marker.index,
        onTap: () => widget.onMarkerTap(marker),
      ),
    );
  }).toList();
},
```

Pass `markers` and `onMarkerTap` from `_buildAttachmentViewer`:

```dart
_PdfDocumentView(
  ...existing params...,
  markers: _attachmentMarkers[_activeAttachmentPath] ?? [],
  onMarkerTap: (marker) => showInNoteMarkerPreview(context, marker),
),
```

**Step 3: Verify**

```bash
flutter analyze lib/screens/immersive_note_screen.dart
```

**Step 4: Commit**

```bash
git add lib/screens/immersive_note_screen.dart
git commit -m "feat: render in-note marker badges on PDF pages"
```

---

## Task 9: Render markers on image viewer

**Files:**
- Modify: `lib/screens/immersive_note_screen.dart` (the image branch of `_buildAttachmentViewer`)

The image viewer uses `InteractiveViewer` with a `TransformationController` (line 3508). Wrap it in a `LayoutBuilder` + `Stack` to overlay badges.

**Step 1: Wrap image viewer in Stack**

Replace the `InteractiveViewer(...)` block (lines 3508–3515) with:

```dart
LayoutBuilder(
  builder: (context, constraints) {
    final size = Size(constraints.maxWidth, constraints.maxHeight);
    final imageMarkers = _attachmentMarkers[_activeAttachmentPath] ?? [];
    return Stack(
      children: [
        InteractiveViewer(
          transformationController: transformController,
          minScale: 0.1,
          maxScale: 4,
          constrained: true,
          clipBehavior: Clip.hardEdge,
          child: imageWidget,
        ),
        ...imageMarkers.map((marker) {
          final rect = marker.normalizedRect;
          if (rect == null) return const SizedBox.shrink();
          return Positioned(
            left: rect.x * size.width,
            top: rect.y * size.height,
            child: InNoteMarkerBadge(
              index: marker.index,
              onTap: () => showInNoteMarkerPreview(context, marker),
            ),
          );
        }),
      ],
    );
  },
),
```

Note: This positions badges relative to the RepaintBoundary widget size, which matches how we normalized in Task 4.

**Step 2: Verify**

```bash
flutter analyze lib/screens/immersive_note_screen.dart
flutter test
```

**Step 3: Commit**

```bash
git add lib/screens/immersive_note_screen.dart
git commit -m "feat: render in-note marker badges on image viewer"
```

---

## Task 10: Render markers on text notes

**Files:**
- Modify: `lib/screens/immersive_note_screen.dart` (`_buildNoteContent`)

Text note markers use `normalizedRect.y` as a vertical position (0–1 relative to note widget height).

**Step 1: Load note markers**

Add `Map<String, List<InNoteMarker>> _noteMarkers` state field. Load them in `initState` for the active note and when the active note changes:

```dart
Future<void> _loadMarkersForNote(String noteId) async {
  final markers = await _noteMarkerService.getMarkersForNote(noteId);
  if (mounted) {
    setState(() {
      _noteMarkers[noteId] = markers;
    });
  }
}
```

**Step 2: Wrap `_buildNoteContent` result in a Stack**

In `_buildNoteArea` (line ~3368), wrap the result in a `LayoutBuilder` + `Stack` when `_activeAttachmentPath == null`:

```dart
Widget _buildNoteArea(Note note, AppLocalizations l10n) {
  return RepaintBoundary(
    key: _noteBoundaryKey,
    child: Container(
      color: Theme.of(context).colorScheme.surface,
      child: _activeAttachmentPath == null
          ? _buildNoteContentWithMarkers(note, l10n)
          : _buildAttachmentViewer(_activeAttachmentPath!, l10n),
    ),
  );
}

Widget _buildNoteContentWithMarkers(Note note, AppLocalizations l10n) {
  final noteMarkers = _noteMarkers[note.id] ?? [];
  return LayoutBuilder(
    builder: (context, constraints) {
      final height = constraints.maxHeight;
      return Stack(
        children: [
          Positioned.fill(child: _buildNoteContent(note, l10n)),
          ...noteMarkers.map((marker) {
            final rect = marker.normalizedRect;
            if (rect == null) return const SizedBox.shrink();
            return Positioned(
              left: rect.x * constraints.maxWidth,
              top: rect.y * height,
              child: InNoteMarkerBadge(
                index: marker.index,
                onTap: () => showInNoteMarkerPreview(context, marker),
              ),
            );
          }),
        ],
      );
    },
  );
}
```

**Step 3: Verify**

```bash
flutter analyze lib/screens/immersive_note_screen.dart
flutter test
```

**Step 4: Commit**

```bash
git add lib/screens/immersive_note_screen.dart
git commit -m "feat: render in-note marker badges on text notes"
```

---

## Task 11: Also check `getConversationMessage` exists in DatabaseService

The preview widget calls `_db.getConversationMessage(messageId)`. Verify this method exists:

```bash
grep -n "getConversationMessage\b" lib/services/database_service.dart
```

If it's missing (only `getConversationMessages` for a full list), add it:

```dart
Future<ConversationMessage?> getConversationMessage(String messageId) async {
  final db = await database;
  final rows = await db.query(
    'conversation_messages',
    where: 'id = ?',
    whereArgs: [messageId],
    limit: 1,
  );
  if (rows.isEmpty) return null;
  return ConversationMessage.fromDatabase(rows.first);
}
```

Also verify `resolveAttachmentPath(String relativePath)` exists. If not, add or use the existing `Attachment.getAbsolutePath()` pattern.

```bash
git add lib/services/database_service.dart
git commit -m "feat: add getConversationMessage helper to DatabaseService"
```

---

## Task 12: Final integration check

```bash
flutter analyze
flutter test
```

Expected: no errors, all tests pass. Fix any issues before merging.

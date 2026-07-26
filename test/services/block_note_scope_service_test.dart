import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/block_note_scope_service.dart';
import 'package:note_synapse/services/data_change_notifier.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/tag_workflow_service.dart';
import 'package:note_synapse/utils/file_utils.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'block_note_scope_service_test.mocks.dart';

class MockPathProviderPlatform extends Mock
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  MockPathProviderPlatform(this.path);
  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;

  @override
  Future<String?> getTemporaryPath() async => path;
}

@GenerateNiceMocks([MockSpec<DatabaseService>()])
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockDatabaseService mockDb;
  late DataChangeNotifier notifier;
  late BlockNoteScopeService service;
  late Directory tempDir;

  /// The note the block is sliced out of. Content is laid out so the mermaid
  /// block sits between two paragraphs.
  const parentContent =
      'Intro paragraph.\n'
      '\n'
      '```mermaid\n'
      'graph TD\n'
      'A --> B\n'
      '```\n'
      '\n'
      'Trailing paragraph.';
  const blockText = '```mermaid\ngraph TD\nA --> B\n```';
  final spanStart = parentContent.indexOf(blockText);
  final spanEnd = spanStart + blockText.length;

  Note parentNote({String content = parentContent}) => Note(
    id: 'parent-1',
    title: 'Parent',
    content: content,
    type: NoteType.note,
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 2),
    tags: const ['diagrams'],
    attachmentPaths: const ['/docs/attachments/existing.png'],
  );

  setUp(() async {
    getIt.reset();
    tempDir = await Directory.systemTemp.createTemp();
    PathProviderPlatform.instance = MockPathProviderPlatform(tempDir.path);
    FileUtils.resetDocumentsPathCache();

    mockDb = MockDatabaseService();
    notifier = DataChangeNotifier();
    getIt.registerSingleton<DataChangeNotifier>(notifier);
    getIt.registerSingleton<DatabaseService>(mockDb);
    getIt.registerSingleton<TagWorkflowService>(TagWorkflowService(mockDb));
    service = BlockNoteScopeService(mockDb, changeNotifier: notifier);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  /// Captures the note handed to DatabaseService.updateNote.
  Note capturedUpdate() {
    final captured = verify(mockDb.updateNote(captureAny)).captured;
    return captured.last as Note;
  }

  group('scope lifecycle', () {
    test('open registers a lookupable scope, close removes it', () {
      final scope = service.open(
        parent: parentNote(),
        spanStart: spanStart,
        spanEnd: spanEnd,
        text: blockText,
      );

      expect(scope.tempNoteId, isNotEmpty);
      expect(scope.tempNoteId, isNot('parent-1'));
      expect(service.lookup(scope.tempNoteId), same(scope));
      expect(service.hasOpenScopes, isTrue);

      service.close(scope.tempNoteId);

      expect(service.lookup(scope.tempNoteId), isNull);
      expect(service.hasOpenScopes, isFalse);
    });

    test('lookup returns null for an ordinary note id', () {
      service.open(
        parent: parentNote(),
        spanStart: spanStart,
        spanEnd: spanEnd,
        text: blockText,
      );
      expect(service.lookup('parent-1'), isNull);
      expect(service.lookup('some-other-id'), isNull);
    });

    test('asNote exposes block content but inherits parent attachments', () {
      final scope = service.open(
        parent: parentNote(),
        spanStart: spanStart,
        spanEnd: spanEnd,
        text: blockText,
      );

      final note = service.asNote(scope);

      expect(note.id, scope.tempNoteId);
      expect(note.content, blockText);
      expect(note.title, 'Parent');
      // This is what keeps readAttachment working inside a block scope.
      expect(note.attachmentPaths, ['/docs/attachments/existing.png']);
      expect(note.tags, ['diagrams']);
    });
  });

  group('writeBack', () {
    test('splices new text over the block range only', () async {
      when(mockDb.getNote('parent-1')).thenAnswer((_) async => parentNote());
      final scope = service.open(
        parent: parentNote(),
        spanStart: spanStart,
        spanEnd: spanEnd,
        text: blockText,
      );

      final result = await service.writeBack(
        scope.tempNoteId,
        '![mermaid](diagram.svg)\n\n$blockText',
      );

      expect(result.ok, isTrue);
      final updated = capturedUpdate();
      expect(
        updated.content,
        'Intro paragraph.\n'
        '\n'
        '![mermaid](diagram.svg)\n'
        '\n'
        '```mermaid\n'
        'graph TD\n'
        'A --> B\n'
        '```\n'
        '\n'
        'Trailing paragraph.',
      );
      // Neighbouring blocks are untouched.
      expect(updated.content, startsWith('Intro paragraph.'));
      expect(updated.content, endsWith('Trailing paragraph.'));
    });

    test('advances the span so a second write targets the new text', () async {
      var stored = parentNote();
      when(mockDb.getNote('parent-1')).thenAnswer((_) async => stored);
      when(mockDb.updateNote(any)).thenAnswer((invocation) async {
        stored = invocation.positionalArguments.first as Note;
      });

      final scope = service.open(
        parent: parentNote(),
        spanStart: spanStart,
        spanEnd: spanEnd,
        text: blockText,
      );

      expect((await service.writeBack(scope.tempNoteId, 'FIRST')).ok, isTrue);
      expect((await service.writeBack(scope.tempNoteId, 'SECOND')).ok, isTrue);

      // The second write must replace the first write's output, not duplicate
      // it or hit the original offsets.
      expect(stored.content, contains('SECOND'));
      expect(stored.content, isNot(contains('FIRST')));
      expect(stored.content, startsWith('Intro paragraph.'));
      expect(stored.content, endsWith('Trailing paragraph.'));
      expect(scope.text, 'SECOND');
    });

    test('re-locates the block when an external edit shifted it', () async {
      // Someone prepended a line while the plugin was open, so the stored
      // offsets now point at the wrong place.
      const shifted = 'BRAND NEW FIRST LINE\n$parentContent';
      when(
        mockDb.getNote('parent-1'),
      ).thenAnswer((_) async => parentNote(content: shifted));

      final scope = service.open(
        parent: parentNote(),
        spanStart: spanStart,
        spanEnd: spanEnd,
        text: blockText,
      );

      final result = await service.writeBack(scope.tempNoteId, 'RELOCATED');

      expect(result.ok, isTrue);
      final updated = capturedUpdate();
      expect(
        updated.content,
        'BRAND NEW FIRST LINE\nIntro paragraph.\n'
        '\nRELOCATED\n\nTrailing paragraph.',
      );
      expect(updated.content, contains('BRAND NEW FIRST LINE'));
    });

    test('refuses the write when the block text is gone', () async {
      when(
        mockDb.getNote('parent-1'),
      ).thenAnswer((_) async => parentNote(content: 'Completely rewritten.'));

      final scope = service.open(
        parent: parentNote(),
        spanStart: spanStart,
        spanEnd: spanEnd,
        text: blockText,
      );

      final result = await service.writeBack(scope.tempNoteId, 'NOPE');

      expect(result.ok, isFalse);
      expect(result.error, contains('could no longer be found'));
      verifyNever(mockDb.updateNote(any));
    });

    test('refuses the write when the block text became ambiguous', () async {
      // Two identical copies of the block and stale offsets: we cannot know
      // which one the user selected, so guessing risks editing the wrong one.
      when(mockDb.getNote('parent-1')).thenAnswer(
        (_) async => parentNote(content: 'x\n$blockText\ny\n$blockText\nz'),
      );

      final scope = service.open(
        parent: parentNote(),
        spanStart: spanStart,
        spanEnd: spanEnd,
        text: blockText,
      );

      final result = await service.writeBack(scope.tempNoteId, 'NOPE');

      expect(result.ok, isFalse);
      expect(result.error, contains('could no longer be found'));
      verifyNever(mockDb.updateNote(any));
    });

    test('empty text deletes the block from the parent', () async {
      when(mockDb.getNote('parent-1')).thenAnswer((_) async => parentNote());
      final scope = service.open(
        parent: parentNote(),
        spanStart: spanStart,
        spanEnd: spanEnd,
        text: blockText,
      );

      final result = await service.writeBack(scope.tempNoteId, '');

      expect(result.ok, isTrue);
      final updated = capturedUpdate();
      expect(updated.content, 'Intro paragraph.\n\n\n\nTrailing paragraph.');
      expect(updated.content, isNot(contains('mermaid')));
    });

    test('fails cleanly when the scope was already closed', () async {
      final scope = service.open(
        parent: parentNote(),
        spanStart: spanStart,
        spanEnd: spanEnd,
        text: blockText,
      );
      service.close(scope.tempNoteId);

      final result = await service.writeBack(scope.tempNoteId, 'anything');

      expect(result.ok, isFalse);
      expect(result.error, contains('no longer open'));
      verifyNever(mockDb.updateNote(any));
    });

    test('fails cleanly when the parent note was deleted', () async {
      when(mockDb.getNote('parent-1')).thenAnswer((_) async => null);
      final scope = service.open(
        parent: parentNote(),
        spanStart: spanStart,
        spanEnd: spanEnd,
        text: blockText,
      );

      final result = await service.writeBack(scope.tempNoteId, 'anything');

      expect(result.ok, isFalse);
      expect(result.error, contains('no longer exists'));
      verifyNever(mockDb.updateNote(any));
    });

    test(
      'refuses a stale zero-width span instead of splicing mid-word',
      () async {
        // After a delete the span is zero-width and the text is empty, so
        // comparing substring(i,i) == '' would validate ANY offset.
        var stored = parentNote();
        when(mockDb.getNote('parent-1')).thenAnswer((_) async => stored);
        when(mockDb.updateNote(any)).thenAnswer((invocation) async {
          stored = invocation.positionalArguments.first as Note;
        });

        final scope = service.open(
          parent: parentNote(),
          spanStart: spanStart,
          spanEnd: spanEnd,
          text: blockText,
        );
        expect((await service.writeBack(scope.tempNoteId, '')).ok, isTrue);

        // Something else now shifts the note.
        stored = stored.copyWith(content: 'PREFIX INSERTED\n${stored.content}');
        final before = stored.content;

        final result = await service.writeBack(scope.tempNoteId, 'LATE');

        expect(result.ok, isFalse);
        expect(stored.content, before);
      },
    );

    test('re-inserting into an emptied block still works untouched', () async {
      var stored = parentNote();
      when(mockDb.getNote('parent-1')).thenAnswer((_) async => stored);
      when(mockDb.updateNote(any)).thenAnswer((invocation) async {
        stored = invocation.positionalArguments.first as Note;
      });

      final scope = service.open(
        parent: parentNote(),
        spanStart: spanStart,
        spanEnd: spanEnd,
        text: blockText,
      );

      expect((await service.writeBack(scope.tempNoteId, '')).ok, isTrue);
      expect((await service.writeBack(scope.tempNoteId, 'BACK')).ok, isTrue);

      expect(stored.content, 'Intro paragraph.\n\nBACK\n\nTrailing paragraph.');
    });

    test('serializes concurrent writes instead of losing one', () async {
      var stored = parentNote();
      when(mockDb.getNote('parent-1')).thenAnswer((_) async {
        // Yield, so an unserialized implementation would interleave here.
        await Future<void>.delayed(Duration.zero);
        return stored;
      });
      when(mockDb.updateNote(any)).thenAnswer((invocation) async {
        stored = invocation.positionalArguments.first as Note;
      });

      final scope = service.open(
        parent: parentNote(),
        spanStart: spanStart,
        spanEnd: spanEnd,
        text: blockText,
      );

      final results = await Future.wait([
        service.writeBack(scope.tempNoteId, 'FIRST'),
        service.writeBack(scope.tempNoteId, 'SECOND'),
      ]);

      expect(results.every((r) => r.ok), isTrue);
      // The second write must supersede the first, not splice a second copy or
      // be computed against content the first write already replaced.
      expect(
        stored.content,
        'Intro paragraph.\n\nSECOND\n\nTrailing paragraph.',
      );
    });

    test(
      'a same-length edit near a duplicated block still writes the right copy',
      () async {
        // Two identical blocks; something edits BBBB -> BBBZ between them. The
        // offsets are still valid, so refusing here (as an anchors-must-match
        // fast path did) rejected a perfectly good write.
        const before = 'AAAA\n\n- item\n\nBBBB\n\n- item\n\nCCCC';
        const after = 'AAAA\n\n- item\n\nBBBZ\n\n- item\n\nCCCC';
        final secondItem = before.lastIndexOf('- item');
        var stored = parentNote(content: after);
        when(mockDb.getNote('parent-1')).thenAnswer((_) async => stored);
        when(mockDb.updateNote(any)).thenAnswer((invocation) async {
          stored = invocation.positionalArguments.first as Note;
        });

        final scope = service.open(
          parent: parentNote(content: before),
          spanStart: secondItem,
          spanEnd: secondItem + '- item'.length,
          text: '- item',
        );

        final result = await service.writeBack(scope.tempNoteId, 'EDITED');

        expect(result.ok, isTrue);
        // The SECOND copy must have changed, not the first.
        expect(stored.content, 'AAAA\n\n- item\n\nBBBZ\n\nEDITED\n\nCCCC');
      },
    );

    test('picks the right duplicate when the note shifted', () async {
      // Same text twice and the note shifted by exactly the inter-block
      // distance: the stale offsets would slice the WRONG copy, so the anchors
      // have to decide.
      const before = 'AAAA\nZZZZ\n---\nBBBB\n---\nCCCC';
      const after = '---\nBBBB\n---\nCCCC';
      var stored = parentNote(content: after);
      when(mockDb.getNote('parent-1')).thenAnswer((_) async => stored);
      when(mockDb.updateNote(any)).thenAnswer((invocation) async {
        stored = invocation.positionalArguments.first as Note;
      });

      final firstSep = before.indexOf('---');
      final scope = service.open(
        parent: parentNote(content: before),
        spanStart: firstSep,
        spanEnd: firstSep + 3,
        text: '---',
      );

      final result = await service.writeBack(scope.tempNoteId, 'EDITED');

      // Anchors for the first separator ('AAAA\nZZZZ\n' before) are gone, and
      // both copies are ambiguous, so refusing is correct — what must NOT
      // happen is silently rewriting the other separator.
      if (result.ok) {
        expect(stored.content, 'EDITED\nBBBB\n---\nCCCC');
      } else {
        expect(stored.content, after);
      }
    });

    test(
      'refuses a stale empty span when the block was the whole note',
      () async {
        // Both anchors are empty here, so they match anywhere: without the
        // content.isEmpty requirement this spliced into unrelated content.
        var stored = parentNote(content: 'ONLY BLOCK');
        when(mockDb.getNote('parent-1')).thenAnswer((_) async => stored);
        when(mockDb.updateNote(any)).thenAnswer((invocation) async {
          stored = invocation.positionalArguments.first as Note;
        });

        final scope = service.open(
          parent: parentNote(content: 'ONLY BLOCK'),
          spanStart: 0,
          spanEnd: 'ONLY BLOCK'.length,
          text: 'ONLY BLOCK',
        );
        expect((await service.writeBack(scope.tempNoteId, '')).ok, isTrue);
        expect(stored.content, '');

        // Something else fills the note in while the scope is still open.
        stored = stored.copyWith(content: 'COMPLETELY UNRELATED USER TEXT');

        final result = await service.writeBack(scope.tempNoteId, 'PLUGIN TEXT');

        expect(result.ok, isFalse);
        expect(stored.content, 'COMPLETELY UNRELATED USER TEXT');
      },
    );

    test(
      'refuses rather than rewriting a duplicate of a first-line block',
      () async {
        // A block at offset 0 has an EMPTY leading anchor, which matches at
        // every offset. Treating that one-sided match as conclusive made a
        // freshly inserted duplicate beat the still-correct stored span.
        const before = 'BLOCK\n\ntail';
        const after = 'BLOCK\n\nBLOCK\n\ntail';
        var stored = parentNote(content: after);
        when(mockDb.getNote('parent-1')).thenAnswer((_) async => stored);
        when(mockDb.updateNote(any)).thenAnswer((invocation) async {
          stored = invocation.positionalArguments.first as Note;
        });

        final scope = service.open(
          parent: parentNote(content: before),
          spanStart: 0,
          spanEnd: 5,
          text: 'BLOCK',
        );

        final result = await service.writeBack(scope.tempNoteId, 'RENDERED');

        // Cannot tell "moved" from "duplicated", so nothing is written — the
        // one thing that must not happen is rewriting the other copy.
        expect(result.ok, isFalse);
        expect(stored.content, after);
      },
    );

    test(
      'refuses when a stale span only coincidentally slices a match',
      () async {
        // Two matches, no anchor support at all: accepting the stored offsets
        // would make the outcome hinge on coincidence and splice into unrelated
        // text.
        const before = 'xxxxTODOyyyyTODOzzzz';
        const after = 'AAAAAAAAAAAATODOBBBBTODO';
        var stored = parentNote(content: after);
        when(mockDb.getNote('parent-1')).thenAnswer((_) async => stored);
        when(mockDb.updateNote(any)).thenAnswer((invocation) async {
          stored = invocation.positionalArguments.first as Note;
        });

        final second = before.lastIndexOf('TODO');
        final scope = service.open(
          parent: parentNote(content: before),
          spanStart: second,
          spanEnd: second + 4,
          text: 'TODO',
        );

        final result = await service.writeBack(scope.tempNoteId, 'PLUGIN');

        expect(result.ok, isFalse);
        expect(stored.content, after);
      },
    );

    test('concurrent appends do not lose an update', () async {
      // The action must be applied to the block text read INSIDE the lock.
      // Computing it before queuing made both calls start from the same
      // snapshot, so the second silently discarded the first while both
      // reported success.
      var stored = parentNote();
      when(mockDb.getNote('parent-1')).thenAnswer((_) async {
        await Future<void>.delayed(Duration.zero);
        return stored;
      });
      when(mockDb.updateNote(any)).thenAnswer((invocation) async {
        stored = invocation.positionalArguments.first as Note;
      });

      final scope = service.open(
        parent: parentNote(),
        spanStart: spanStart,
        spanEnd: spanEnd,
        text: blockText,
      );

      final results = await Future.wait([
        service.applyContentAction(scope.tempNoteId, 'append', 'ONE'),
        service.applyContentAction(scope.tempNoteId, 'append', 'TWO'),
      ]);

      expect(results.every((r) => r.ok), isTrue);
      expect(stored.content, contains('ONE'));
      expect(
        stored.content,
        contains('TWO'),
        reason: 'neither append may be dropped',
      );
      expect(stored.content, startsWith('Intro paragraph.'));
      expect(stored.content, endsWith('Trailing paragraph.'));
    });

    test('refuses to bypass an immutable workflow binding', () async {
      getIt.unregister<TagWorkflowService>();
      getIt.registerSingleton<TagWorkflowService>(
        _ImmutableTagWorkflow(mockDb),
      );
      when(mockDb.getNote('parent-1')).thenAnswer((_) async => parentNote());

      final scope = service.open(
        parent: parentNote(),
        spanStart: spanStart,
        spanEnd: spanEnd,
        text: blockText,
      );

      final result = await service.writeBack(scope.tempNoteId, 'NOPE');

      expect(result.ok, isFalse);
      expect(result.error, contains('immutable'));
      verifyNever(mockDb.updateNote(any));
    });

    test('publishes a change event for the parent note', () async {
      when(mockDb.getNote('parent-1')).thenAnswer((_) async => parentNote());
      final events = <DataChangeEvent>[];
      notifier.addListener((event) async => events.add(event));

      final scope = service.open(
        parent: parentNote(),
        spanStart: spanStart,
        spanEnd: spanEnd,
        text: blockText,
      );
      await service.writeBack(scope.tempNoteId, 'CHANGED');
      // publish() is enqueue-only; let the microtask drain.
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(1));
      expect(events.single.noteIds, {'parent-1'});
    });

    test(
      'never prunes a user attachment that shares the promoted naming shape',
      () async {
        // RemoteImageStorage names user-fetched images
        // attachments/<noteId>_<sha256(url)>.<ext> — the exact shape this
        // service's promoted files use, but referenced by URL in the content,
        // not by a synapsetemp URI. Inferring ownership from the filename would
        // delete the user's own attachment rows on any block write.
        final userHash = 'a' * 64;
        final userAttachment = 'attachments/parent-1_$userHash.png';
        final noteWithImage = parentNote(
          content: '$parentContent\n\n![pic](https://example.com/pic.png)',
        ).copyWith(attachmentPaths: [userAttachment]);

        when(mockDb.getNote('parent-1')).thenAnswer((_) async => noteWithImage);

        final scope = service.open(
          parent: noteWithImage,
          spanStart: spanStart,
          spanEnd: spanEnd,
          text: blockText,
        );

        final result = await service.writeBack(scope.tempNoteId, 'CHANGED');

        expect(result.ok, isTrue);
        expect(capturedUpdate().attachmentPaths, contains(userAttachment));
      },
    );

    test('preserves existing parent attachments', () async {
      when(mockDb.getNote('parent-1')).thenAnswer((_) async => parentNote());
      final scope = service.open(
        parent: parentNote(),
        spanStart: spanStart,
        spanEnd: spanEnd,
        text: blockText,
      );

      await service.writeBack(scope.tempNoteId, 'CHANGED');

      expect(capturedUpdate().attachmentPaths, [
        '/docs/attachments/existing.png',
      ]);
    });
  });
}

/// [TagWorkflowService] that reports every note as content-immutable, to prove
/// a block-scoped write cannot route around that policy.
class _ImmutableTagWorkflow extends TagWorkflowService {
  _ImmutableTagWorkflow(super.db);

  @override
  Future<bool> hasImmutableBinding(List<String> tags) async => true;
}

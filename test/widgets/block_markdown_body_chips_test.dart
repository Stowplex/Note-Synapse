import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/models/chip_action.dart';
import 'package:note_synapse/widgets/block_markdown_body.dart';

// BlockMarkdownBody returns a SliverList, so it must be hosted inside a
// CustomScrollView (not a plain Scaffold body).
Widget _wrap(Widget sliver) => MaterialApp(
  home: Scaffold(body: CustomScrollView(slivers: [sliver])),
);

void main() {
  testWidgets(
    'strips chips block from rendered content and reports chips via callback',
    (tester) async {
      List<ChipAction>? captured;
      await tester.pumpWidget(
        _wrap(
          BlockMarkdownBody(
            content: '''Hello world.

```chips
## explain X
You are a tutor. Explain X for me.
```''',
            noteId: 'test-note',
            onChipsExtracted: (chips) => captured = chips,
          ),
        ),
      );
      await tester.pump(); // post-frame callback fires

      // Callback fired with the extracted chip.
      expect(captured, isNotNull);
      expect(captured!.length, 1);
      expect(captured![0].label, 'explain X');
      expect(captured![0].prompt, contains('You are a tutor'));
    },
  );

  testWidgets('reports empty list when no chips block present', (tester) async {
    List<ChipAction>? captured;
    await tester.pumpWidget(
      _wrap(
        BlockMarkdownBody(
          content: 'Plain reply.',
          noteId: 'test-note',
          onChipsExtracted: (chips) => captured = chips,
        ),
      ),
    );
    await tester.pump();
    expect(captured, isNotNull);
    expect(captured, isEmpty);
  });

  testWidgets(
    'does not notify callback when chips list is unchanged across rebuilds',
    (tester) async {
      int notifyCount = 0;
      Widget build(String content) => _wrap(
        BlockMarkdownBody(
          key: const ValueKey('panel'),
          content: content,
          noteId: 'test-note',
          onChipsExtracted: (_) => notifyCount++,
        ),
      );

      await tester.pumpWidget(build('Same.'));
      await tester.pump();
      final initialCount = notifyCount;

      // Rebuild with the same data — callback should NOT fire again.
      await tester.pumpWidget(build('Same.'));
      await tester.pump();
      expect(
        notifyCount,
        initialCount,
        reason: 'No re-notification when content and chips list are unchanged',
      );
    },
  );

  testWidgets('notifies callback again when content changes', (tester) async {
    final captured = <List<ChipAction>>[];
    Widget build(String content) => _wrap(
      BlockMarkdownBody(
        key: const ValueKey('panel'),
        content: content,
        noteId: 'test-note',
        onChipsExtracted: (chips) => captured.add(List.of(chips)),
      ),
    );

    await tester.pumpWidget(build('No chips here.'));
    await tester.pump();

    await tester.pumpWidget(
      build('''New data.
```chips
## new chip
New prompt body.
```'''),
    );
    await tester.pump();

    // First call: empty. Second call: one chip.
    expect(captured.length, greaterThanOrEqualTo(2));
    expect(captured.first, isEmpty);
    expect(captured.last.length, 1);
    expect(captured.last.first.label, 'new chip');
  });

  testWidgets('section anchors still work when chips block is stripped', (
    tester,
  ) async {
    final key = GlobalKey<BlockMarkdownBodyState>();
    final controller = ScrollController();
    List<ChipAction>? captured;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            controller: controller,
            slivers: [
              BlockMarkdownBody(
                key: key,
                content: '''# Top

[Jump](#target)

## Target

Target body.

```chips
## explain target
Explain the target.
```''',
                noteId: 'test-note',
                scrollController: controller,
                onChipsExtracted: (chips) => captured = chips,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();

    expect(captured, isNotNull);
    expect(captured!.single.label, 'explain target');
    expect(await key.currentState!.scrollToSlug('target'), isTrue);
  });

  testWidgets('works without onChipsExtracted callback (optional)', (
    tester,
  ) async {
    // No callback provided — the widget should still render and not crash.
    await tester.pumpWidget(
      _wrap(
        const BlockMarkdownBody(
          content: '''Reply.
```chips
## L
P.
```''',
          noteId: 'test-note',
        ),
      ),
    );
    await tester.pump();
    // No crash — that's the assertion.
  });
}

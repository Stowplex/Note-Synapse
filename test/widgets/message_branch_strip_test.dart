import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/l10n/app_localizations.dart';
import 'package:note_synapse/models/conversation_branch_summary.dart';
import 'package:note_synapse/widgets/message_branch_strip.dart';

ConversationBranchSummary _summary(
  String id,
  String title, {
  List<String>? notes,
}) => ConversationBranchSummary(
  conversationId: id,
  title: title,
  forkPointMessageId: 'parent-msg',
  firstChildMessageId: '$id-first',
  noteIds: notes ?? const ['note-X'],
);

Widget _wrap(Widget child) => MaterialApp(
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

void main() {
  testWidgets(
    'renders nothing when only one branch (single-child fork-points are not shown)',
    (tester) async {
      await tester.pumpWidget(
        _wrap(
          MessageBranchStrip(
            branches: [_summary('a', 'A')],
            activeConversationId: 'a',
            activeNoteIds: const ['note-X'],
            onSwitchBranch: (_, __) {},
          ),
        ),
      );
      await tester.pump();
      expect(find.text('A'), findsNothing);
    },
  );

  testWidgets(
    'renders one row per branch and highlights the active one with a key',
    (tester) async {
      await tester.pumpWidget(
        _wrap(
          MessageBranchStrip(
            branches: [
              _summary('a', 'Branch A'),
              _summary('b', 'Branch B'),
              _summary('c', 'Branch C'),
            ],
            activeConversationId: 'b',
            activeNoteIds: const ['note-X'],
            onSwitchBranch: (_, __) {},
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Branch A'), findsOneWidget);
      expect(find.text('Branch B'), findsOneWidget);
      expect(find.text('Branch C'), findsOneWidget);
      expect(find.byKey(const ValueKey('branch-row-active-b')), findsOneWidget);
    },
  );

  testWidgets('fan-out >5: shows first 5 + "+N more" tap to expand inline', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        MessageBranchStrip(
          branches: List.generate(8, (i) => _summary('b$i', 'Branch $i')),
          activeConversationId: 'b0',
          activeNoteIds: const ['note-X'],
          onSwitchBranch: (_, __) {},
        ),
      ),
    );
    await tester.pump();
    expect(find.text('+3 more'), findsOneWidget);
    expect(find.text('Branch 5'), findsNothing);
    await tester.tap(find.text('+3 more'));
    await tester.pump();
    for (int i = 0; i < 8; i++) {
      expect(find.text('Branch $i'), findsOneWidget);
    }
    // After expansion, the +N more button is gone.
    expect(find.textContaining('more'), findsNothing);
  });

  testWidgets(
    'same-document sibling tap fires onSwitchBranch with confirmedDocumentSwap=false',
    (tester) async {
      String? switched;
      bool? wasConfirmed;
      await tester.pumpWidget(
        _wrap(
          MessageBranchStrip(
            branches: [
              _summary('a', 'A', notes: const ['note-X']),
              _summary('b', 'B', notes: const ['note-X']),
            ],
            activeConversationId: 'a',
            activeNoteIds: const ['note-X'],
            onSwitchBranch: (id, didConfirm) {
              switched = id;
              wasConfirmed = didConfirm;
            },
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('B'));
      await tester.pumpAndSettle();
      expect(switched, 'b');
      expect(wasConfirmed, isFalse);
    },
  );

  testWidgets(
    'different-document sibling tap shows confirm dialog before firing switch',
    (tester) async {
      String? switched;
      bool? wasConfirmed;
      await tester.pumpWidget(
        _wrap(
          MessageBranchStrip(
            branches: [
              _summary('a', 'A', notes: const ['note-X']),
              _summary('b', 'B', notes: const ['note-Y']),
            ],
            activeConversationId: 'a',
            activeNoteIds: const ['note-X'],
            onSwitchBranch: (id, didConfirm) {
              switched = id;
              wasConfirmed = didConfirm;
            },
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('B'));
      await tester.pumpAndSettle();
      // Dialog visible.
      expect(find.textContaining('different document'), findsOneWidget);
      expect(
        switched,
        isNull,
        reason: 'Switch should not fire until user confirms',
      );
      // Tap Switch button.
      await tester.tap(find.text('Switch'));
      await tester.pumpAndSettle();
      expect(switched, 'b');
      expect(wasConfirmed, isTrue);
    },
  );

  testWidgets('different-document tap canceled: switch never fires', (
    tester,
  ) async {
    String? switched;
    await tester.pumpWidget(
      _wrap(
        MessageBranchStrip(
          branches: [
            _summary('a', 'A', notes: const ['note-X']),
            _summary('b', 'B', notes: const ['note-Y']),
          ],
          activeConversationId: 'a',
          activeNoteIds: const ['note-X'],
          onSwitchBranch: (id, _) => switched = id,
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('B'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(switched, isNull);
  });

  testWidgets('disabled = true: tap does nothing', (tester) async {
    String? switched;
    await tester.pumpWidget(
      _wrap(
        MessageBranchStrip(
          branches: [
            _summary('a', 'A', notes: const ['note-X']),
            _summary('b', 'B', notes: const ['note-X']),
          ],
          activeConversationId: 'a',
          activeNoteIds: const ['note-X'],
          disabled: true,
          onSwitchBranch: (id, _) => switched = id,
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('B'));
    await tester.pumpAndSettle();
    expect(switched, isNull);
  });

  testWidgets(
    'long-press branch title opens rename dialog and persists title',
    (tester) async {
      String? renamedId;
      String? renamedTitle;
      await tester.pumpWidget(
        _wrap(
          MessageBranchStrip(
            branches: [
              _summary('a', 'A', notes: const ['note-X']),
              _summary('b', 'Branch B', notes: const ['note-X']),
            ],
            activeConversationId: 'a',
            activeNoteIds: const ['note-X'],
            onSwitchBranch: (_, __) {},
            onRenameBranch: (id, title) async {
              renamedId = id;
              renamedTitle = title;
            },
          ),
        ),
      );
      await tester.pump();
      await tester.longPress(find.text('Branch B'));
      await tester.pumpAndSettle();
      expect(find.text('Rename branch'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Renamed branch');
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      expect(renamedId, 'b');
      expect(renamedTitle, 'Renamed branch');
    },
  );

  testWidgets('long title truncates with ellipsis', (tester) async {
    final longTitle = 'A' * 200;
    await tester.pumpWidget(
      _wrap(
        MessageBranchStrip(
          branches: [
            _summary('a', 'A', notes: const ['note-X']),
            _summary('b', longTitle, notes: const ['note-X']),
          ],
          activeConversationId: 'a',
          activeNoteIds: const ['note-X'],
          onSwitchBranch: (_, __) {},
        ),
      ),
    );
    await tester.pump();
    final textWidget = tester.widget<Text>(
      find.byWidgetPredicate((w) => w is Text && w.data == longTitle),
    );
    expect(textWidget.maxLines, 1);
    expect(textWidget.overflow, TextOverflow.ellipsis);
  });
}

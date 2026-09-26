import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/utils/global_keys.dart';
import 'package:note_synapse/widgets/route_resume_listener.dart';

void main() {
  late AppRouteObserver observer;
  late int resumed;
  final navigatorKey = GlobalKey<NavigatorState>();

  Future<void> pumpHost(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        navigatorObservers: [observer],
        home: RouteResumeListener(
          observer: observer,
          onResumed: () => resumed++,
          child: const Text('app'),
        ),
      ),
    );
  }

  setUp(() {
    observer = AppRouteObserver();
    resumed = 0;
  });

  testWidgets('fires once when a pushed screen is popped', (tester) async {
    await pumpHost(tester);
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Text('note')),
    );
    await tester.pumpAndSettle();
    expect(resumed, 0);

    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(resumed, 1);
  });

  testWidgets('does not fire when a dialog closes', (tester) async {
    await pumpHost(tester);
    showDialog<void>(
      context: navigatorKey.currentContext!,
      builder: (_) => const AlertDialog(content: Text('approve?')),
    );
    await tester.pumpAndSettle();
    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(resumed, 0);
  });

  testWidgets('fires when a page was opened from a dialog above the app', (
    tester,
  ) async {
    await pumpHost(tester);
    showDialog<void>(
      context: navigatorKey.currentContext!,
      builder: (_) => const AlertDialog(content: Text('pick')),
    );
    await tester.pumpAndSettle();
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Text('note')),
    );
    await tester.pumpAndSettle();
    navigatorKey.currentState!.pop(); // the page
    await tester.pumpAndSettle();
    expect(resumed, 0, reason: 'the dialog still covers the app');
    navigatorKey.currentState!.pop(); // the dialog
    await tester.pumpAndSettle();
    expect(resumed, 1);
  });

  testWidgets('a disposed listener is not called when the page pops', (
    tester,
  ) async {
    final show = ValueNotifier<bool>(true);
    addTearDown(show.dispose);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        navigatorObservers: [observer],
        home: ValueListenableBuilder<bool>(
          valueListenable: show,
          builder: (_, visible, __) => visible
              ? RouteResumeListener(
                  observer: observer,
                  onResumed: () => resumed++,
                  child: const Text('app'),
                )
              : const Text('gone'),
        ),
      ),
    );
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Text('note')),
    );
    await tester.pumpAndSettle();
    // Only the listener goes away; the route it subscribed with stays.
    show.value = false;
    await tester.pumpAndSettle();
    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('gone'), findsOneWidget);
    expect(resumed, 0);
  });
}

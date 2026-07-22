import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/data_change_notifier.dart';

void main() {
  group('DataChangeEvent', () {
    test('merge unions ids and ORs flags', () {
      const a = DataChangeEvent(noteIds: {'1'}, tagsChanged: true);
      const b = DataChangeEvent(
        noteIds: {'2'},
        filtersChanged: true,
        relationshipNoteIds: {'3'},
      );
      final merged = a.merge(b);
      expect(merged.noteIds, {'1', '2'});
      expect(merged.tagsChanged, isTrue);
      expect(merged.filtersChanged, isTrue);
      expect(merged.relationshipNoteIds, {'3'});
      expect(merged.bulk, isFalse);
    });

    test('isEmpty', () {
      expect(const DataChangeEvent().isEmpty, isTrue);
      expect(const DataChangeEvent(bulk: true).isEmpty, isFalse);
      expect(const DataChangeEvent(noteIds: {'1'}).isEmpty, isFalse);
    });
  });

  group('DataChangeNotifier', () {
    late DataChangeNotifier notifier;

    setUp(() {
      notifier = DataChangeNotifier();
    });

    test('delivers a published event to listeners', () async {
      final received = <DataChangeEvent>[];
      notifier.addListener((event) async => received.add(event));

      notifier.publish(const DataChangeEvent(noteIds: {'a'}));
      await notifier.waitForIdle();

      expect(received, hasLength(1));
      expect(received.single.noteIds, {'a'});
    });

    test('drops empty events', () async {
      var calls = 0;
      notifier.addListener((_) async => calls++);

      notifier.publish(const DataChangeEvent());
      await notifier.waitForIdle();

      expect(calls, 0);
    });

    test('coalesces events published while a batch is in flight', () async {
      final received = <DataChangeEvent>[];
      final gate = Completer<void>();
      notifier.addListener((event) async {
        received.add(event);
        if (received.length == 1) await gate.future;
      });

      notifier.publish(const DataChangeEvent(noteIds: {'a'}));
      // Let the first dispatch start and block on the gate.
      await Future<void>.delayed(Duration.zero);
      notifier.publish(const DataChangeEvent(noteIds: {'b'}));
      notifier.publish(const DataChangeEvent(noteIds: {'c'}, tagsChanged: true));
      gate.complete();
      await notifier.waitForIdle();

      expect(received, hasLength(2));
      expect(received[0].noteIds, {'a'});
      // The two events published mid-flight arrive merged.
      expect(received[1].noteIds, {'b', 'c'});
      expect(received[1].tagsChanged, isTrue);
    });

    test('listener invocations never overlap (strict serialization)', () async {
      var active = 0;
      var maxActive = 0;
      Future<void> listener(DataChangeEvent _) async {
        active++;
        maxActive = active > maxActive ? active : maxActive;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        active--;
      }

      notifier.addListener(listener);
      notifier.addListener(listener);
      for (var i = 0; i < 5; i++) {
        notifier.publish(DataChangeEvent(noteIds: {'$i'}));
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      await notifier.waitForIdle();

      expect(maxActive, 1);
    });

    test('a failing listener does not stop the drain or other listeners',
        () async {
      final received = <DataChangeEvent>[];
      notifier.addListener((_) async => throw StateError('boom'));
      notifier.addListener((event) async => received.add(event));

      notifier.publish(const DataChangeEvent(noteIds: {'a'}));
      notifier.publish(const DataChangeEvent(noteIds: {'b'}));
      await notifier.waitForIdle();

      // Second listener saw every batch despite the first one throwing.
      expect(received.expand((e) => e.noteIds).toSet(), {'a', 'b'});
    });

    test('publish never throws even when a listener throws synchronously', () {
      notifier.addListener((_) => throw StateError('sync boom'));
      expect(
        () => notifier.publish(const DataChangeEvent(noteIds: {'a'})),
        returnsNormally,
      );
    });

    test('cancelled subscription stops delivery', () async {
      var calls = 0;
      final subscription = notifier.addListener((_) async => calls++);

      notifier.publish(const DataChangeEvent(noteIds: {'a'}));
      await notifier.waitForIdle();
      expect(calls, 1);

      subscription.cancel();
      notifier.publish(const DataChangeEvent(noteIds: {'b'}));
      await notifier.waitForIdle();
      expect(calls, 1);
    });
  });
}

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'logger_service.dart';
import 'service_locator.dart';

/// A single change notification describing what data-layer state changed.
///
/// Events are merged (coalesced) while a dispatch is in flight, so listeners
/// always receive the union of everything published since they last ran.
class DataChangeEvent {
  const DataChangeEvent({
    this.noteIds = const {},
    this.tagsChanged = false,
    this.filtersChanged = false,
    this.relationshipNoteIds = const {},
    this.bulk = false,
  });

  /// Ids of notes that were inserted, updated, or deleted. Consumers should
  /// re-fetch each id and treat a missing row as a deletion.
  final Set<String> noteIds;

  /// The tag list changed (create/rename/delete).
  final bool tagsChanged;

  /// The filter list changed.
  final bool filtersChanged;

  /// Note ids whose relationships changed. Relationships are not cached by
  /// consumers today; this is a signal to re-query, not a cache patch.
  final Set<String> relationshipNoteIds;

  /// The scope of the change is unknown (DDL, unparseable SQL, degraded
  /// capture). Consumers should schedule a full reload.
  final bool bulk;

  bool get isEmpty =>
      noteIds.isEmpty &&
      !tagsChanged &&
      !filtersChanged &&
      relationshipNoteIds.isEmpty &&
      !bulk;

  DataChangeEvent merge(DataChangeEvent other) {
    return DataChangeEvent(
      noteIds: {...noteIds, ...other.noteIds},
      tagsChanged: tagsChanged || other.tagsChanged,
      filtersChanged: filtersChanged || other.filtersChanged,
      relationshipNoteIds: {
        ...relationshipNoteIds,
        ...other.relationshipNoteIds,
      },
      bulk: bulk || other.bulk,
    );
  }

  @override
  String toString() =>
      'DataChangeEvent(notes: ${noteIds.length}, tags: $tagsChanged, '
      'filters: $filtersChanged, relationships: ${relationshipNoteIds.length}, '
      'bulk: $bulk)';
}

/// Listener contract: listeners MUST terminate. Dispatch is strictly
/// serialized — one event batch at a time, each listener awaited — so a
/// never-completing listener blocks all future invalidation. A watchdog logs
/// dispatches that exceed [DataChangeNotifier.slowDispatchThreshold].
typedef DataChangeListener = Future<void> Function(DataChangeEvent event);

/// Handle returned by [DataChangeNotifier.addListener]; call [cancel] to
/// unsubscribe. After cancel the notifier retains no reference to the
/// listener.
class DataChangeSubscription {
  DataChangeSubscription._(this._notifier, this._listener);

  final DataChangeNotifier _notifier;
  final DataChangeListener _listener;

  void cancel() {
    _notifier._listeners.remove(this);
  }
}

/// Decouples data-layer writers from UI state: services publish what changed,
/// subscribers (AppProvider) refresh their caches.
///
/// Guarantees:
/// - [publish] never throws and returns immediately (enqueue only).
/// - Listener invocations never overlap: exactly one merged event batch is
///   dispatched at a time, and each async listener is awaited.
/// - Listener errors (sync or async) are caught and logged; they never escape
///   as unhandled futures and never affect the publisher.
/// - Events published during a dispatch are merged and delivered in the next
///   batch.
class DataChangeNotifier {
  /// The process-wide notifier. Registers one in GetIt if absent rather than
  /// returning a private instance: publishers and subscribers both resolve
  /// through here, so a private fallback would silently connect a subscriber
  /// to a notifier no writer publishes to (stale UI with no error) — the
  /// exact bug class this service exists to fix.
  static DataChangeNotifier shared() {
    if (!getIt.isRegistered<DataChangeNotifier>()) {
      getIt.registerLazySingleton<DataChangeNotifier>(
        () => DataChangeNotifier(),
      );
    }
    return getIt<DataChangeNotifier>();
  }

  final List<DataChangeSubscription> _listeners = [];

  DataChangeEvent? _pending;
  bool _draining = false;

  /// Dispatches slower than this are logged as warnings (listener-contract
  /// watchdog).
  static const Duration slowDispatchThreshold = Duration(seconds: 30);

  DataChangeSubscription addListener(DataChangeListener listener) {
    final subscription = DataChangeSubscription._(this, listener);
    _listeners.add(subscription);
    return subscription;
  }

  /// Enqueue a change event. Never throws; empty events are dropped.
  void publish(DataChangeEvent event) {
    try {
      if (event.isEmpty) return;
      _pending = _pending?.merge(event) ?? event;
      if (_draining) return;
      _draining = true;
      // Deliver asynchronously so publish() stays enqueue-only even when the
      // queue is idle.
      scheduleMicrotask(_drain);
    } catch (e) {
      // publish() must never throw back into a writer.
      LoggerService.error('[DataChangeNotifier] publish failed: $e', error: e);
    }
  }

  Future<void> _drain() async {
    // No try/finally needed: a publish() during a listener await lands in
    // _pending BEFORE the while condition re-checks (single-threaded event
    // loop, no interleaving point between the check failing and returning),
    // and the loop body cannot throw — each listener call is individually
    // caught.
    while (_pending != null) {
      final event = _pending!;
      _pending = null;
      for (final subscription in List.of(_listeners)) {
        // Skip listeners cancelled mid-batch.
        if (!_listeners.contains(subscription)) continue;
        final watchdog = Timer(slowDispatchThreshold, () {
          LoggerService.warning(
            '[DataChangeNotifier] Listener still running after '
            '${slowDispatchThreshold.inSeconds}s for $event — listeners '
            'must terminate; the event queue is blocked until it does.',
          );
        });
        try {
          await subscription._listener(event);
        } catch (e) {
          LoggerService.error(
            '[DataChangeNotifier] Listener failed for $event: $e',
            error: e,
          );
        } finally {
          watchdog.cancel();
        }
      }
    }
    _draining = false;
  }

  /// Completes when the queue is fully idle (no pending event, no dispatch in
  /// flight). Test helper.
  @visibleForTesting
  Future<void> waitForIdle() async {
    while (_draining || _pending != null) {
      await Future<void>.delayed(Duration.zero);
    }
  }
}

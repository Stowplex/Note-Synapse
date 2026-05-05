import 'package:flutter/widgets.dart';
import 'package:note_synapse/utils/markdown_heading_slug.dart';

/// Maps GitHub-style anchor slugs to the GlobalKey of the heading widget that
/// rendered with that slug, and scrolls the heading into view on demand.
///
/// One registry instance owns a single document's heading namespace. Owners
/// must call [clear] before re-registering on content change so duplicate-slug
/// counters reset.
class HeadingAnchorRegistry {
  final Map<String, GlobalKey> _keys = {};
  final HeadingSlugCounter _counter = HeadingSlugCounter();

  /// Register [rawHeadingText] (the heading body, without leading `#`s) and
  /// return the disambiguated slug. The caller is expected to attach the
  /// returned key (via [keyForSlug]) to the widget that should be scrolled
  /// into view.
  String registerHeading(String rawHeadingText) {
    final base = slugifyHeading(rawHeadingText);
    final slug = _counter.next(base);
    _keys.putIfAbsent(slug, () => GlobalKey());
    return slug;
  }

  /// Look up the GlobalKey for [slug], or null if no heading registered it.
  GlobalKey? keyForSlug(String slug) => _keys[slug];

  /// Scroll the heading registered to [slug] into view.
  ///
  /// Returns true if the slug was found and a live BuildContext was available.
  /// Returns false if the slug is unknown or the widget hasn't been built yet
  /// (e.g. it lives in a lazy SliverList off-screen) so callers can fall back
  /// to a different scroll strategy.
  Future<bool> scrollToSection(
    String slug, {
    Duration duration = const Duration(milliseconds: 300),
    Curve curve = Curves.easeInOut,
    double alignment = 0.0,
  }) async {
    final key = _keys[slug];
    final ctx = key?.currentContext;
    if (ctx == null) return false;
    await Scrollable.ensureVisible(
      ctx,
      duration: duration,
      curve: curve,
      alignment: alignment,
    );
    return true;
  }

  /// Reset the duplicate-slug counter so the next registration pass starts
  /// from scratch. Slug→GlobalKey associations in [_keys] are intentionally
  /// preserved so the same heading text reuses the same GlobalKey across
  /// rebuilds (avoiding GlobalKey thrashing). Stale keys for renamed or
  /// removed headings simply remain unused; their widgets are gone, so
  /// `currentContext` is null and `scrollToSection` falls through.
  void clear() {
    _counter.reset();
  }
}

/// InheritedWidget exposing a [HeadingAnchorRegistry] to descendant widgets so
/// custom heading components can self-register their GlobalKeys.
class HeadingAnchorScope extends InheritedWidget {
  final HeadingAnchorRegistry registry;

  const HeadingAnchorScope({
    super.key,
    required this.registry,
    required super.child,
  });

  static HeadingAnchorRegistry? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<HeadingAnchorScope>()
        ?.registry;
  }

  @override
  bool updateShouldNotify(covariant HeadingAnchorScope oldWidget) {
    return registry != oldWidget.registry;
  }
}

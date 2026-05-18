import 'package:flutter/material.dart';
import '../models/chip_action.dart';

/// Footer below an AI message that renders either a streaming-time
/// shimmer skeleton or the parsed chip tap-targets.
///
/// Activation predicate (gated by [isExpected]): true when at least one
/// `default_action`-bearing skill is loaded for the conversation. When
/// false, this widget renders nothing regardless of [isStreaming] or
/// [chips] — the caller controls visibility entirely.
///
/// State machine:
/// - `isExpected = false` → SizedBox.shrink (nothing).
/// - `isExpected = true && isStreaming = true` → 4-pill shimmer skeleton.
/// - `isExpected = true && isStreaming = false && chips empty` → nothing.
/// - `isExpected = true && isStreaming = false && chips populated` → tap targets.
///
/// Crossfade from skeleton to chips happens automatically via [AnimatedSwitcher]
/// when [isStreaming] flips from true to false.
class ChipsFooter extends StatelessWidget {
  final List<ChipAction>? chips;
  final bool isStreaming;
  final bool isExpected;
  final void Function(ChipAction)? onChipTap;
  final void Function(ChipAction, GlobalKey)? onChipLongPress;

  const ChipsFooter({
    super.key,
    required this.chips,
    required this.isStreaming,
    required this.isExpected,
    this.onChipTap,
    this.onChipLongPress,
  });

  @override
  Widget build(BuildContext context) {
    if (!isExpected) return const SizedBox.shrink();
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    if (isStreaming) return _buildSkeleton(context);
    final cs = chips ?? const <ChipAction>[];
    if (cs.isEmpty) return const SizedBox.shrink(key: ValueKey('chip-empty'));
    return Padding(
      key: const ValueKey('chip-footer-real'),
      padding: const EdgeInsets.only(top: 8, left: 8, right: 8, bottom: 4),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [for (final c in cs) _buildChip(context, c)],
      ),
    );
  }

  Widget _buildSkeleton(BuildContext context) {
    const widths = [110.0, 80.0, 140.0, 95.0];
    return Padding(
      key: const ValueKey('chip-footer-skeleton'),
      padding: const EdgeInsets.only(top: 8, left: 8, right: 8, bottom: 4),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [for (final w in widths) _SkeletonPill(width: w)],
      ),
    );
  }

  Widget _buildChip(BuildContext context, ChipAction chip) {
    final anchorKey = GlobalKey();
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.secondaryContainer,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        key: anchorKey,
        borderRadius: BorderRadius.circular(16),
        onTap: onChipTap == null ? null : () => onChipTap!(chip),
        onLongPress: onChipLongPress == null
            ? null
            : () => onChipLongPress!(chip, anchorKey),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text(
            _truncateLabel(chip.label),
            style: theme.textTheme.bodySmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }

  static String _truncateLabel(String label) {
    final words = label.trim().split(RegExp(r'\s+'));
    if (words.length <= 5) return label.trim();
    return '${words.take(5).join(' ')}…';
  }
}

class _SkeletonPill extends StatefulWidget {
  final double width;
  const _SkeletonPill({required this.width});
  @override
  State<_SkeletonPill> createState() => _SkeletonPillState();
}

class _SkeletonPillState extends State<_SkeletonPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('chip-skeleton-pill'),
      width: widget.width,
      height: 26,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(13)),
      clipBehavior: Clip.hardEdge,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) {
          final t = _ctrl.value;
          return ShaderMask(
            shaderCallback: (rect) => LinearGradient(
              begin: Alignment(-1.0 + 2 * t, 0),
              end: Alignment(1.0 + 2 * t, 0),
              colors: const [
                Color(0xFFE0E0E0),
                Color(0xFFF5F5F5),
                Color(0xFFE0E0E0),
              ],
            ).createShader(rect),
            child: Container(color: Colors.white),
          );
        },
      ),
    );
  }
}

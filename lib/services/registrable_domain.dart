import 'package:tldts/data/trie.dart' as psl_data;

/// Resolves an effective top-level domain plus one label (eTLD+1) from the
/// complete ICANN + private Public Suffix List trie bundled by `tldts`.
///
/// This traversal is kept here rather than using that package's beta parser:
/// its generated trie maps are dynamically typed and its current parser makes
/// an invalid generic-map cast on wildcard/private branches under modern Dart.
/// The data itself is generated from the PSL and includes wildcard, exception,
/// ICANN, and private rules.
class RegistrableDomain {
  const RegistrableDomain._();

  static String forHost(String host) {
    final normalized = host.toLowerCase().replaceAll(RegExp(r'^\.+|\.+$'), '');
    final labels = normalized.split('.');
    if (labels.length < 2) return normalized;

    final exception = _lookup(labels, psl_data.exceptions, labels.length - 1);
    late final int suffixLabelCount;
    if (exception != null) {
      // An exception rule removes its left-most matching label from the public
      // suffix. E.g. !city.kawasaki.jp => suffix kawasaki.jp.
      suffixLabelCount = labels.length - (exception.index + 1);
    } else {
      final rule = _lookup(labels, psl_data.rules, labels.length - 1);
      suffixLabelCount = rule == null ? 1 : labels.length - rule.index;
    }
    if (labels.length <= suffixLabelCount) return normalized;
    return labels.sublist(labels.length - suffixLabelCount - 1).join('.');
  }

  static _PslMatch? _lookup(List<String> labels, dynamic trie, int index) {
    _PslMatch? result;
    dynamic node = trie;
    while (node is List && node.length >= 2) {
      final flags = node[0];
      // Generated nodes use bit 1 for ICANN and bit 2 for private rules.
      if (flags is int && (flags & 3) != 0) {
        result = _PslMatch(index + 1);
      }
      if (index < 0) break;
      final successors = node[1];
      if (successors is! Map) break;
      node = successors[labels[index]] ?? successors['*'];
      index -= 1;
    }
    return result;
  }
}

class _PslMatch {
  const _PslMatch(this.index);

  final int index;
}

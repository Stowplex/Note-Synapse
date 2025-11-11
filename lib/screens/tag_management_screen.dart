import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../l10n/app_localizations.dart';
import '../providers/app_provider.dart';
import '../models/tag.dart';
import '../models/dedup_rule.dart';
import '../services/ai_service.dart';
import '../widgets/tag_detail_dialog.dart';

class TagManagementScreen extends StatefulWidget {
  const TagManagementScreen({super.key});

  @override
  State<TagManagementScreen> createState() => _TagManagementScreenState();
}

class _TagManagementScreenState extends State<TagManagementScreen>
    with TickerProviderStateMixin {
  List<TagWithUsage> _tagsWithUsage = [];
  bool _isLoading = true;
  late TabController _tabController;

  // Dedup rules state
  final List<DedupRule> _dedupRules = [];
  bool _isAiSuggesting = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _loadTagsWithUsage();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadTagsWithUsage() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final appProvider = context.read<AppProvider>();
      final tags = appProvider.tags;
      final tagsWithUsage = tags
          .map(
            (tag) => TagWithUsage(
              tag: tag,
              noteUsageCount: tag.usageCount,
              conversationUsageCount: tag.conversationUsageCount,
            ),
          )
          .toList();

      // Sort alphabetically by tag name
      tagsWithUsage.sort((a, b) {
        return a.tag.name.compareTo(b.tag.name);
      });

      setState(() {
        _tagsWithUsage = tagsWithUsage;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading tags: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _showTagDetail(TagWithUsage tagWithUsage) async {
    await showDialog(
      context: context,
      builder: (context) => TagDetailDialog(
        tagName: tagWithUsage.tag.name,
        tag: tagWithUsage.tag,
      ),
    );
    // Reload tags after dialog is closed in case tags were updated
    await _loadTagsWithUsage();
  }

  Future<void> _deleteTag(TagWithUsage tagWithUsage) async {
    final l10n = AppLocalizations.of(context)!;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.deleteTag),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.confirmDeleteTag(tagWithUsage.tag.name)),
            const SizedBox(height: 16),
            Text(
              l10n.confirmDeleteTagWarning(
                tagWithUsage.conversationUsageCount,
                tagWithUsage.noteUsageCount,
              ),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.red,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await context.read<AppProvider>().deleteTag(tagWithUsage.tag.name);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n.tagDeletedSuccessfully),
              backgroundColor: Colors.green,
            ),
          );

          // Reload the tags
          await _loadTagsWithUsage();
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n.errorDeletingTag(e.toString())),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.tagManagement),
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(text: l10n.deleteTags),
            Tab(text: l10n.dedupTags),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [_buildDeleteTagsTab(l10n), _buildDedupTagsTab(l10n)],
      ),
    );
  }

  Widget _buildDeleteTagsTab(AppLocalizations l10n) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_tagsWithUsage.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.label_outline, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text(
              l10n.noTagsAvailable,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(color: Colors.grey[600]),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _tagsWithUsage.length,
      itemBuilder: (context, index) {
        final tagWithUsage = _tagsWithUsage[index];
        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          child: ListTile(
            leading: Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: Color(
                  int.parse(tagWithUsage.tag.color.replaceFirst('#', '0xFF')),
                ),
                shape: BoxShape.circle,
              ),
            ),
            title: Text(
              tagWithUsage.tag.name,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
            subtitle: Text(
              l10n.tagUsageCount(
                tagWithUsage.conversationUsageCount,
                tagWithUsage.noteUsageCount,
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.info_outline),
                  onPressed: () => _showTagDetail(tagWithUsage),
                  tooltip: 'View details',
                ),
                IconButton(
                  icon: const Icon(Icons.delete, color: Colors.red),
                  onPressed: () => _deleteTag(tagWithUsage),
                  tooltip: l10n.deleteTag,
                ),
              ],
            ),
            onTap: () => _showTagDetail(tagWithUsage),
          ),
        );
      },
    );
  }

  Widget _buildDedupTagsTab(AppLocalizations l10n) {
    return Column(
      children: [
        // Action buttons
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              ElevatedButton.icon(
                onPressed: _addDedupRule,
                icon: const Icon(Icons.add),
                label: Text(l10n.addDedupRule),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: _isAiSuggesting ? null : _aiSuggestDedupRules,
                icon: _isAiSuggesting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome),
                label: Text(l10n.aiSuggestDedup),
              ),
              const Spacer(),
              if (_dedupRules.isNotEmpty)
                ElevatedButton.icon(
                  onPressed: _executeDedupRules,
                  icon: const Icon(Icons.play_arrow),
                  label: Text(l10n.executeDedup),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                  ),
                ),
            ],
          ),
        ),
        // Dedup rules list
        Expanded(
          child: _dedupRules.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.rule, size: 64, color: Colors.grey[400]),
                      const SizedBox(height: 16),
                      Text(
                        l10n.noDedupRules,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(color: Colors.grey[600]),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        l10n.addFirstDedupRule,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.grey[500],
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _dedupRules.length,
                  itemBuilder: (context, index) {
                    final rule = _dedupRules[index];
                    return _buildDedupRuleCard(rule, l10n);
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildDedupRuleCard(DedupRule rule, AppLocalizations l10n) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Main content row
            Row(
              children: [
                // Left tag
                Expanded(
                  flex: 2,
                  child: _buildTagSelector(
                    selectedTag: rule.leftTag,
                    onTagSelected: (tag) =>
                        _updateDedupRule(rule, leftTag: tag),
                    hintText: l10n.selectLeftTag,
                    l10n: l10n,
                  ),
                ),
                // Arrow
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Icon(Icons.arrow_forward, color: Colors.grey),
                ),
                // Right tag
                Expanded(
                  flex: 2,
                  child: _buildTagSelector(
                    selectedTag: rule.rightTag,
                    onTagSelected: (tag) =>
                        _updateDedupRule(rule, rightTag: tag),
                    hintText: l10n.selectRightTag,
                    l10n: l10n,
                  ),
                ),
                // Action buttons
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.swap_horiz),
                      onPressed: () => _swapDedupRule(rule),
                      tooltip: l10n.swapTags,
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete, color: Colors.red),
                      onPressed: () => _removeDedupRule(rule),
                      tooltip: l10n.delete,
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTagSelector({
    required String? selectedTag,
    required Function(String) onTagSelected,
    required String hintText,
    required AppLocalizations l10n,
  }) {
    // Only set value if it's not empty and exists in the items
    final validSelectedTag =
        selectedTag != null &&
            selectedTag.isNotEmpty &&
            _tagsWithUsage.any((t) => t.tag.name == selectedTag)
        ? selectedTag
        : null;

    return DropdownButtonFormField<String>(
      initialValue: validSelectedTag,
      decoration: InputDecoration(
        hintText: hintText,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        isDense: true,
      ),
      isExpanded: true,
      items: _tagsWithUsage.map((tagWithUsage) {
        return DropdownMenuItem<String>(
          value: tagWithUsage.tag.name,
          child: Text(
            tagWithUsage.tag.name,
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
        );
      }).toList(),
      onChanged: (value) {
        if (value != null) {
          onTagSelected(value);
        }
      },
    );
  }

  void _addDedupRule() {
    final newRule = DedupRule(id: const Uuid().v4(), leftTag: '', rightTag: '');
    setState(() {
      _dedupRules.add(newRule);
    });
  }

  void _updateDedupRule(DedupRule rule, {String? leftTag, String? rightTag}) {
    setState(() {
      final index = _dedupRules.indexWhere((r) => r.id == rule.id);
      if (index != -1) {
        _dedupRules[index] = rule.copyWith(
          leftTag: leftTag ?? rule.leftTag,
          rightTag: rightTag ?? rule.rightTag,
        );
      }
    });
  }

  void _swapDedupRule(DedupRule rule) {
    setState(() {
      final index = _dedupRules.indexWhere((r) => r.id == rule.id);
      if (index != -1) {
        _dedupRules[index] = rule.copyWith(
          leftTag: rule.rightTag,
          rightTag: rule.leftTag,
        );
      }
    });
  }

  void _removeDedupRule(DedupRule rule) {
    setState(() {
      _dedupRules.removeWhere((r) => r.id == rule.id);
    });
  }

  String? _validateDedupRules() {
    // Check for empty rules
    for (final rule in _dedupRules) {
      if (rule.leftTag.isEmpty || rule.rightTag.isEmpty) {
        return 'All rules must have both left and right tags selected';
      }
    }

    // Check for duplicate left tags (not allowed)
    final leftTags = _dedupRules.map((r) => r.leftTag).toList();
    final duplicateLeftTags = leftTags
        .where((tag) => leftTags.indexOf(tag) != leftTags.lastIndexOf(tag))
        .toSet();
    if (duplicateLeftTags.isNotEmpty) {
      return 'Left tag "${duplicateLeftTags.first}" appears in multiple rules';
    }

    // Check for cross-references (tag appears on left of one rule and right of another)
    final rightTags = _dedupRules.map((r) => r.rightTag).toList();
    for (final rule in _dedupRules) {
      if (rightTags.contains(rule.leftTag)) {
        return 'Tag "${rule.leftTag}" appears on both left and right sides of different rules';
      }
    }

    // Check for self-references (not allowed)
    for (final rule in _dedupRules) {
      if (rule.leftTag == rule.rightTag) {
        return 'Cannot replace tag "${rule.leftTag}" with itself';
      }
    }

    return null;
  }

  String? _resolveTagName(String tagName) {
    final normalized = tagName.trim();
    if (normalized.isEmpty) {
      return null;
    }

    for (final tagWithUsage in _tagsWithUsage) {
      if (tagWithUsage.tag.name == normalized) {
        return tagWithUsage.tag.name;
      }
    }

    final normalizedLower = normalized.toLowerCase();
    for (final tagWithUsage in _tagsWithUsage) {
      if (tagWithUsage.tag.name.toLowerCase() == normalizedLower) {
        return tagWithUsage.tag.name;
      }
    }

    return null;
  }

  Future<void> _executeDedupRules() async {
    final l10n = AppLocalizations.of(context)!;

    // Validate rules
    final validationError = _validateDedupRules();
    if (validationError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.dedupRuleValidationError(validationError)),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    // Confirm execution
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.executeDedup),
        content: Text(l10n.confirmExecuteDedupRules),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.green),
            child: Text(l10n.executeDedup),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        final appProvider = context.read<AppProvider>();

        // Execute each rule
        for (final rule in _dedupRules) {
          await appProvider.replaceTag(rule.leftTag, rule.rightTag);
        }

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n.dedupRulesExecutedSuccessfully),
              backgroundColor: Colors.green,
            ),
          );

          // Clear rules and reload tags
          setState(() {
            _dedupRules.clear();
          });
          await _loadTagsWithUsage();
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(l10n.errorExecutingDedupRules(e.toString())),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    }
  }

  Future<void> _aiSuggestDedupRules() async {
    final l10n = AppLocalizations.of(context)!;

    if (_tagsWithUsage.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l10n.noTagsAvailable),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() {
      _isAiSuggesting = true;
    });

    try {
      final tagNames = _tagsWithUsage.map((t) => t.tag.name).toList();

      // Get tags used by filters
      final appProvider = context.read<AppProvider>();
      final filterTagSet = <String>{};
      for (final filter in appProvider.filters) {
        filterTagSet.addAll(filter.includeTags);
      }
      final filterTags = filterTagSet.toList();

      final suggestions = await AIService.suggestDedupRules(
        tagNames,
        protectedTags: filterTags,
      );

      if (mounted && suggestions.isNotEmpty) {
        final normalizedSuggestions = <DedupRule>[];

        for (final suggestion in suggestions) {
          final resolvedLeft = _resolveTagName(suggestion.leftTag);
          final resolvedRight = _resolveTagName(suggestion.rightTag);

          if (resolvedLeft != null && resolvedRight != null) {
            normalizedSuggestions.add(
              suggestion.copyWith(
                leftTag: resolvedLeft,
                rightTag: resolvedRight,
              ),
            );
          }
        }

        if (normalizedSuggestions.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('AI suggestions did not match any existing tags'),
              backgroundColor: Colors.orange,
            ),
          );
        } else {
          final skippedCount = suggestions.length - normalizedSuggestions.length;

          setState(() {
            _dedupRules.addAll(normalizedSuggestions);
          });

          final message = skippedCount > 0
              ? '${normalizedSuggestions.length} dedup rules added (skipped $skippedCount unknown tags)'
              : '${normalizedSuggestions.length} dedup rules suggested by AI';

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(message),
              backgroundColor: skippedCount > 0 ? Colors.orange : Colors.green,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l10n.errorGettingAiSuggestions(e.toString())),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isAiSuggesting = false;
        });
      }
    }
  }
}

class TagWithUsage {
  final Tag tag;
  final int noteUsageCount;
  final int conversationUsageCount;

  TagWithUsage({
    required this.tag,
    required this.noteUsageCount,
    required this.conversationUsageCount,
  });
}

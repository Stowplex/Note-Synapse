import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';
import '../l10n/app_localizations.dart';
import '../providers/app_provider.dart';
import '../models/tag.dart';
import '../models/dedup_rule.dart';
import '../models/workflow_binding_row.dart';
import '../services/ai_service.dart';
import '../services/skill_service.dart';
import '../services/tag_workflow_service.dart';
import '../widgets/tag_detail_dialog.dart';
import '../widgets/tag_workflow_binding_dialog.dart';
import '../utils/dedup_suggestion_utils.dart';
import '../services/service_locator.dart';

class TagManagementScreen extends StatefulWidget {
  const TagManagementScreen({super.key});

  @override
  State<TagManagementScreen> createState() => _TagManagementScreenState();
}

class _TagManagementScreenState extends State<TagManagementScreen>
    with TickerProviderStateMixin {
  List<TagWithUsage> _tagsWithUsage = [];
  bool _isLoading = true;
  String _deleteTagsQuery = '';
  late TextEditingController _searchController;
  late TabController _tabController;

  // Dedup rules state
  final List<DedupRule> _dedupRules = [];
  bool _isAiSuggesting = false;
  List<WorkflowBindingRow> _workflowBindings = [];
  Map<String, SkillMetadata> _skillIndex = {};
  bool _isWorkflowLoading = true;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _tabController = TabController(length: 3, vsync: this);
    _loadTagsWithUsage();
    _loadWorkflowData();
  }

  @override
  void dispose() {
    _searchController.dispose();
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
    await _loadWorkflowData();
  }

  Future<void> _loadWorkflowData() async {
    setState(() {
      _isWorkflowLoading = true;
    });

    try {
      final workflowService = getIt<TagWorkflowService>();
      final skillService = getIt<SkillService>();
      final bindings = await workflowService.getAllBindings();
      final skillIndex = await skillService.buildSkillIndex();

      if (!mounted) return;
      setState(() {
        _workflowBindings = bindings;
        _skillIndex = skillIndex;
        _isWorkflowLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isWorkflowLoading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error loading workflow bindings: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _deleteTag(TagWithUsage tagWithUsage) async {
    final l10n = AppLocalizations.of(context)!;
    final appProvider = context.read<AppProvider>();

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
        await appProvider.deleteTag(tagWithUsage.tag.name);

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
            Builder(
              builder: (ctx) {
                final supportsOrchestration = ctx
                        .watch<AppProvider>()
                        .modelConfig
                        ?.customCapabilitiesObject
                        ?.supportsToolOrchestration ??
                    true;
                return Tab(
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Text(l10n.workflows),
                      if (!supportsOrchestration)
                        Positioned(
                          right: -10,
                          top: -4,
                          child: Icon(
                            Icons.warning_amber_rounded,
                            size: 10,
                            color: Colors.amber.shade700,
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildDeleteTagsTab(l10n),
          _buildDedupTagsTab(l10n),
          _buildWorkflowsTab(),
        ],
      ),
    );
  }

  Widget _buildDeleteTagsTab(AppLocalizations l10n) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final filteredTags = _tagsWithUsage.where((tagWithUsage) {
      if (_deleteTagsQuery.isEmpty) return true;
      return tagWithUsage.tag.name.toLowerCase().contains(
        _deleteTagsQuery.toLowerCase(),
      );
    }).toList();

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

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: l10n.searchTags,
              prefixIcon: const Icon(Icons.search),
              border: const OutlineInputBorder(),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              suffixIcon: _deleteTagsQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        setState(() {
                          _searchController.clear();
                          _deleteTagsQuery = '';
                        });
                      },
                    )
                  : null,
            ),
            onChanged: (value) {
              setState(() {
                _deleteTagsQuery = value;
              });
            },
          ),
        ),
        Expanded(
          child: filteredTags.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.search_off, size: 64, color: Colors.grey[400]),
                      const SizedBox(height: 16),
                      Text(
                        l10n.noTagsAvailable,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(color: Colors.grey[600]),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(
                    left: 16,
                    right: 16,
                    bottom: 16,
                  ),
                  itemCount: filteredTags.length,
                  itemBuilder: (context, index) {
                    final tagWithUsage = filteredTags[index];
                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        leading: Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            color: Color(
                              int.parse(
                                tagWithUsage.tag.color.replaceFirst(
                                  '#',
                                  '0xFF',
                                ),
                              ),
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
                ),
        ),
      ],
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

  Widget _buildWorkflowsTab() {
    if (_isWorkflowLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final allTagNames = _tagsWithUsage.map((tag) => tag.tag.name).toList();
    final existingPatterns = _workflowBindings
        .map((binding) => binding.pattern)
        .toSet();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              ElevatedButton.icon(
                onPressed: _skillIndex.isEmpty
                    ? null
                    : () => _openWorkflowBindingEditor(
                        allTagNames: allTagNames,
                        existingPatterns: existingPatterns,
                      ),
                icon: const Icon(Icons.add_link),
                label: const Text('Add Exact Binding'),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: _skillIndex.isEmpty
                    ? null
                    : () => _openWorkflowBindingEditor(
                        allTagNames: allTagNames,
                        existingPatterns: existingPatterns,
                        initialIsPrefix: true,
                      ),
                icon: const Icon(Icons.alt_route),
                label: const Text('Add Prefix Binding'),
              ),
            ],
          ),
        ),
        if (_skillIndex.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: Colors.orange.withValues(alpha: 0.35),
                ),
              ),
              child: const Text(
                'No enabled agent skills are available. Create or enable a note tagged "agent-skill" before adding workflow bindings.',
              ),
            ),
          ),
        const SizedBox(height: 8),
        Expanded(
          child: _workflowBindings.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.account_tree_outlined,
                        size: 64,
                        color: Colors.grey[400],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'No workflow bindings yet',
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(color: Colors.grey[600]),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Bind a tag or tag prefix to a skill workflow.',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Colors.grey[500],
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _workflowBindings.length,
                  itemBuilder: (context, index) {
                    final binding = _workflowBindings[index];
                    final skill = _skillIndex[binding.skillNoteId];
                    final skillLabel = skill == null
                        ? 'Missing or disabled skill (${binding.skillNoteId})'
                        : '${skill.name} — ${skill.description}';
                    final chips = <Widget>[
                      Chip(
                        label: Text(binding.isPrefix ? 'Prefix' : 'Exact'),
                        avatar: Icon(
                          binding.isPrefix
                              ? Icons.alt_route
                              : Icons.sell_outlined,
                          size: 16,
                        ),
                      ),
                    ];
                    if (binding.contentImmutable) {
                      chips.add(
                        const Chip(
                          label: Text('Immutable'),
                          avatar: Icon(Icons.lock_outline, size: 16),
                        ),
                      );
                    }

                    return Card(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: ListTile(
                        contentPadding: const EdgeInsets.all(16),
                        title: Text(
                          binding.isPrefix
                              ? '${binding.pattern}*'
                              : binding.pattern,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Wrap(spacing: 8, runSpacing: 4, children: chips),
                              const SizedBox(height: 8),
                              Text(skillLabel),
                              if (binding.prompt.trim().isNotEmpty) ...[
                                const SizedBox(height: 8),
                                Text(
                                  binding.prompt,
                                  maxLines: 3,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              ],
                            ],
                          ),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.edit_outlined),
                              tooltip: 'Edit binding',
                              onPressed: _skillIndex.isEmpty
                                  ? null
                                  : () => _openWorkflowBindingEditor(
                                      allTagNames: allTagNames,
                                      existingPatterns: existingPatterns,
                                      initialBinding: binding,
                                    ),
                            ),
                            IconButton(
                              icon: const Icon(
                                Icons.delete_outline,
                                color: Colors.red,
                              ),
                              tooltip: 'Delete binding',
                              onPressed: () => _deleteWorkflowBinding(binding),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Future<void> _openWorkflowBindingEditor({
    required List<String> allTagNames,
    required Set<String> existingPatterns,
    WorkflowBindingRow? initialBinding,
    bool initialIsPrefix = false,
  }) async {
    final draft = await TagWorkflowBindingDialog.show(
      context,
      skillIndex: _skillIndex,
      allTagNames: allTagNames,
      existingPatterns: existingPatterns,
      initialBinding: initialBinding,
      initialIsPrefix: initialIsPrefix,
    );
    if (draft == null) return;

    try {
      if (initialBinding != null && initialBinding.pattern != draft.pattern) {
        await getIt<TagWorkflowService>().removeBinding(initialBinding.pattern);
      }
      await getIt<TagWorkflowService>().registerBinding(
        pattern: draft.pattern,
        isPrefix: draft.isPrefix,
        skillNoteId: draft.skillNoteId,
        prompt: draft.prompt,
        contentImmutable: draft.contentImmutable,
      );
      await _loadWorkflowData();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            initialBinding == null
                ? 'Workflow binding added'
                : 'Workflow binding updated',
          ),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error saving workflow binding: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _deleteWorkflowBinding(WorkflowBindingRow binding) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Workflow Binding'),
        content: Text(
          'Remove the workflow binding for "${binding.pattern}${binding.isPrefix ? '*' : ''}"?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await getIt<TagWorkflowService>().removeBinding(binding.pattern);
      await _loadWorkflowData();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Workflow binding removed'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error deleting workflow binding: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
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

  Future<void> _executeDedupRules() async {
    final l10n = AppLocalizations.of(context)!;
    final appProvider = context.read<AppProvider>();

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

      final suggestions = await getIt<AIService>().suggestDedupRules(
        tagNames,
        protectedTags: filterTags,
      );

      if (mounted && suggestions.isNotEmpty) {
        final existingTags = _tagsWithUsage
            .map((tagWithUsage) => tagWithUsage.tag.name)
            .toList();
        final normalizedSuggestions = DedupSuggestionUtils.normalizeSuggestions(
          suggestions,
          existingTags,
        );

        if (normalizedSuggestions.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('AI suggestions did not match any existing tags'),
              backgroundColor: Colors.orange,
            ),
          );
        } else {
          final skippedCount =
              suggestions.length - normalizedSuggestions.length;

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

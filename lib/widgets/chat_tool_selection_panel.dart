import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../providers/app_provider.dart';
import '../services/built_in_tools_service.dart';
import '../services/chat_tool_session.dart';
import '../utils/user_app_localization.dart';
import 'active_tool_count_badge.dart';
import 'tool_orchestration_warning_dialog.dart';

class ChatToolSelectionPanel extends StatelessWidget {
  const ChatToolSelectionPanel({
    super.key,
    required this.session,
    this.margin = const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    this.maxHeight,
  });

  final ChatToolSession session;
  final EdgeInsetsGeometry margin;
  final double? maxHeight;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return AnimatedBuilder(
      animation: session,
      builder: (context, _) {
        final activeTools = session.buildActiveToolsMap(context);
        AppProvider? appProvider;
        try {
          appProvider = context.read<AppProvider>();
        } catch (_) {
          appProvider = null;
        }
        final modelConfig = appProvider?.modelConfig;
        final supportsToolOrchestration =
            (session.selectedModel ?? modelConfig)
                ?.customCapabilitiesObject
                ?.supportsToolOrchestration ??
            true;
        return Container(
          margin: margin,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: theme.colorScheme.outline.withOpacity(0.3),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              InkWell(
                onTap: session.togglePanel,
                borderRadius: BorderRadius.circular(8),
                child: Row(
                  children: [
                    Icon(
                      Icons.extension,
                      size: 16,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      l10n?.mcpAndLocalTools ?? 'MCP & Local Tools',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    if (session.activeCount > 0)
                      ActiveToolCountBadge(
                        count: session.activeCount,
                        label: l10n?.active ?? 'Active',
                      ),
                    const SizedBox(width: 8),
                    Icon(
                      session.isPanelExpanded
                          ? Icons.keyboard_arrow_down
                          : Icons.keyboard_arrow_up,
                      size: 20,
                      color: theme.colorScheme.onSurface.withOpacity(0.6),
                    ),
                  ],
                ),
              ),
              if (session.isPanelExpanded)
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: maxHeight ?? 250),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 8),
                        if (session.allowAgentPlanner &&
                            BuiltInToolsService.tools.isNotEmpty)
                          _BuiltInSection(
                            session: session,
                            supportsToolOrchestration:
                                supportsToolOrchestration,
                          ),
                        if (session.availableMcpEndpoints.isNotEmpty)
                          _McpSection(
                            session: session,
                            supportsToolOrchestration:
                                supportsToolOrchestration,
                          ),
                        if (session.aiToolBundles.isNotEmpty)
                          _AiToolSection(session: session),
                        if (BuiltInToolsService.systemTools.isNotEmpty)
                          _SystemToolSection(session: session),
                        if (session.skillCount > 0)
                          _SkillSection(session: session),
                        _ModelFeatureSection(session: session),
                        if (activeTools.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          Text(
                            l10n?.toolsAvailable(
                                  activeTools.values.fold<int>(
                                    0,
                                    (sum, tools) => sum + tools.length,
                                  ),
                                ) ??
                                'Tools: ${activeTools.values.fold<int>(0, (sum, tools) => sum + tools.length)}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurface.withOpacity(
                                0.6,
                              ),
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.icon,
    required this.title,
    required this.count,
  });

  final IconData icon;
  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Row(
      children: [
        Icon(
          icon,
          size: 16,
          color: theme.colorScheme.onSurface.withOpacity(0.7),
        ),
        const SizedBox(width: 6),
        Text(
          title,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.bold,
            color: theme.colorScheme.onSurface.withOpacity(0.8),
          ),
        ),
        const Spacer(),
        if (count > 0)
          ActiveToolCountBadge(count: count, label: l10n?.active ?? 'Active'),
      ],
    );
  }
}

class _BuiltInSection extends StatelessWidget {
  const _BuiltInSection({
    required this.session,
    required this.supportsToolOrchestration,
  });

  final ChatToolSession session;
  final bool supportsToolOrchestration;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          icon: Icons.build,
          title: l10n?.builtInTools ?? 'Built-in Tools',
          count: session.selectedBuiltInTools.length,
        ),
        const SizedBox(height: 8),
        ...BuiltInToolsService.tools.map((tool) {
          final selected = session.selectedBuiltInTools.contains(tool.id);
          return CheckboxListTile(
            title: Text(tool.name),
            subtitle: Text(
              tool.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            value: selected,
            secondary: supportsToolOrchestration
                ? Icon(tool.icon, color: tool.color)
                : Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Icon(tool.icon, color: tool.color),
                      Positioned(
                        right: -4,
                        top: -4,
                        child: Icon(
                          Icons.warning_amber_rounded,
                          size: 12,
                          color: Colors.amber.shade700,
                        ),
                      ),
                    ],
                  ),
            onChanged: (value) =>
                session.toggleBuiltInTool(tool.id, value == true),
            contentPadding: EdgeInsets.zero,
            dense: true,
          );
        }),
        const Divider(),
      ],
    );
  }
}

class _McpSection extends StatelessWidget {
  const _McpSection({
    required this.session,
    required this.supportsToolOrchestration,
  });

  final ChatToolSession session;
  final bool supportsToolOrchestration;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionHeader(
          icon: Icons.cloud,
          title: l10n?.mcpTools ?? 'MCP Tools',
          count: session.selectedMcpEndpointIds.length,
        ),
        if (!supportsToolOrchestration) ...[
          const SizedBox(height: 4),
          buildToolOrchestrationWarningRow(context),
        ],
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: session.availableMcpEndpoints.map((endpoint) {
            final selected = session.selectedMcpEndpointIds.contains(
              endpoint.id,
            );
            return FilterChip(
              label: Text(endpoint.name),
              selected: selected,
              onSelected: (value) =>
                  session.toggleMcpEndpoint(endpoint.id, value),
              avatar: Icon(
                Icons.cloud,
                size: 16,
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}

class _AiToolSection extends StatelessWidget {
  const _AiToolSection({required this.session});

  final ChatToolSession session;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        _SectionHeader(
          icon: Icons.smart_toy,
          title: l10n?.aiTools ?? 'AI Tools',
          count: session.selectedAiToolServices.length,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: session.aiToolBundles.entries.map((entry) {
            final selected = session.selectedAiToolServices.contains(entry.key);
            return FilterChip(
              label: Text(entry.value.app.displayName(context)),
              selected: selected,
              onSelected: (value) =>
                  session.toggleAiToolService(entry.key, value),
              avatar: Icon(
                Icons.smart_toy,
                size: 16,
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}

class _SystemToolSection extends StatelessWidget {
  const _SystemToolSection({required this.session});

  final ChatToolSession session;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        _SectionHeader(
          icon: Icons.memory,
          title: 'System Tools',
          count: session.selectedSystemTools.length,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: BuiltInToolsService.systemTools.map((tool) {
            final selected = session.selectedSystemTools.contains(tool.id);
            return FilterChip(
              label: Text(tool.name),
              selected: selected,
              onSelected: (value) => session.toggleSystemTool(tool.id, value),
              avatar: Icon(
                tool.icon,
                size: 16,
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}

class _SkillSection extends StatelessWidget {
  const _SkillSection({required this.session});

  final ChatToolSession session;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        _SectionHeader(
          icon: Icons.auto_awesome,
          title: 'Agent Skills',
          count: session.skillsEnabled ? 1 : 0,
        ),
        const SizedBox(height: 8),
        FilterChip(
          label: Text('${session.skillCount} available'),
          selected: session.skillsEnabled,
          onSelected: session.setSkillsEnabled,
          avatar: Icon(
            Icons.auto_awesome,
            size: 16,
            color: session.skillsEnabled
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
          ),
        ),
        if (!session.skillsEnabled && session.skillCount == 0)
          Text(l10n?.noToolsAvailable ?? 'No tools available'),
      ],
    );
  }
}

class _ModelFeatureSection extends StatelessWidget {
  const _ModelFeatureSection({required this.session});

  final ChatToolSession session;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    AppProvider? appProvider;
    try {
      appProvider = context.read<AppProvider>();
    } catch (_) {
      appProvider = null;
    }
    final features = appProvider?.modelConfig?.modelFeatures;
    if (features == null || features.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        _SectionHeader(
          icon: Icons.extension,
          title: l10n?.modelFeatures ?? 'Model Features',
          count: session.selectedModelFeatures.length,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: features.map((feature) {
            final selected = session.selectedModelFeatures.contains(feature);
            return FilterChip(
              label: Text(
                feature
                    .split('_')
                    .map((word) => word[0].toUpperCase() + word.substring(1))
                    .join(' '),
              ),
              selected: selected,
              onSelected: (value) => session.toggleModelFeature(feature, value),
              avatar: Icon(
                Icons.extension,
                size: 16,
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}

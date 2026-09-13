import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../models/mcp_endpoint.dart';
import '../models/user_app.dart';
import '../services/service_locator.dart';
import '../services/ai_tool_service.dart';
import '../services/mcp_service.dart';
import '../services/user_app_service.dart';
import '../services/database_service.dart';
import '../utils/user_app_localization.dart';

/// Bottom sheet for inserting tool links into note content.
/// Returns a markdown link string like [toolName](notesynapse://tool/...) when dismissed.
class ToolPickerSheet extends StatefulWidget {
  const ToolPickerSheet({super.key});

  static Future<String?> show(BuildContext context) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const ToolPickerSheet(),
    );
  }

  @override
  State<ToolPickerSheet> createState() => _ToolPickerSheetState();
}

class _ToolPickerSheetState extends State<ToolPickerSheet>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _select(String markdownLink) => Navigator.pop(context, markdownLink);

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (_, scrollController) => Column(
        children: [
          TabBar(
            controller: _tabController,
            tabs: const [
              Tab(text: 'Built-in'),
              Tab(text: 'User Defined'),
              Tab(text: 'MCP'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _BuiltinToolsTab(
                  onSelect: _select,
                  scrollController: scrollController,
                ),
                _UserDefinedToolsTab(
                  onSelect: _select,
                  scrollController: scrollController,
                ),
                _McpToolsTab(
                  onSelect: _select,
                  scrollController: scrollController,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Built-in tools tab ───────────────────────────────────────────────────────

class _BuiltinToolEntry {
  final String name;
  final String description;

  const _BuiltinToolEntry(this.name, this.description);
}

const _kBuiltinTools = [
  _BuiltinToolEntry('search_notes', 'Search notes by keyword or tags'),
  _BuiltinToolEntry(
    'search_figures',
    'Find figures, diagrams, tables and images stored in notes',
  ),
  _BuiltinToolEntry('read_note', 'Read the full content of a note'),
  _BuiltinToolEntry('run_sql', 'Execute a read-only SQL query on the database'),
  _BuiltinToolEntry('ls', 'List available note filters and tags'),
  _BuiltinToolEntry('modify_note', 'Modify the content of an existing note'),
  _BuiltinToolEntry(
    'modify_notes',
    'Modify multiple notes in one atomic batch',
  ),
  _BuiltinToolEntry('create_notes', 'Create one or more new notes'),
  _BuiltinToolEntry('delete_notes', 'Delete notes by ID'),
  _BuiltinToolEntry('load_skill', 'Load a skill note and register its tools'),
];

class _BuiltinToolsTab extends StatelessWidget {
  final void Function(String) onSelect;
  final ScrollController? scrollController;

  const _BuiltinToolsTab({required this.onSelect, this.scrollController});

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: scrollController,
      itemCount: _kBuiltinTools.length,
      itemBuilder: (context, index) {
        final tool = _kBuiltinTools[index];
        return ListTile(
          leading: const Icon(Icons.build_outlined),
          title: Text(tool.name),
          subtitle: Text(tool.description),
          onTap: () => onSelect(
            '[${tool.name}](notesynapse://tool/builtin/${tool.name})',
          ),
        );
      },
    );
  }
}

// ─── User-defined tools tab ───────────────────────────────────────────────────

class _UserDefinedToolsTab extends StatefulWidget {
  final void Function(String) onSelect;
  final ScrollController? scrollController;

  const _UserDefinedToolsTab({required this.onSelect, this.scrollController});

  @override
  State<_UserDefinedToolsTab> createState() => _UserDefinedToolsTabState();
}

class _UserDefinedToolsTabState extends State<_UserDefinedToolsTab> {
  late Future<List<_AppBundleEntry>> _future;

  @override
  void initState() {
    super.initState();
    _future = _loadBundles();
  }

  Future<List<_AppBundleEntry>> _loadBundles() async {
    final db = getIt<DatabaseService>();
    final userAppService = getIt<UserAppService>();
    final allApps = await db.getAllUserApps();
    final toolApps = allApps
        .where((a) => a.type == UserAppType.aiTool)
        .toList();

    final entries = <_AppBundleEntry>[];
    for (final app in toolApps) {
      // M2.14: the `user_apps` row syncs but `app_revisions` (the code) does
      // not, so on a second device an AI tool routinely exists with no
      // runnable revision. Silently dropping it here made the tool look
      // deleted; it is listed disabled instead, so the user can see that the
      // tool exists and that only its code is missing.
      if (app.selectedRevisionId == null) {
        entries.add(_AppBundleEntry(app: app, bundle: null));
        continue;
      }
      final revision = await userAppService.getAppRevision(
        app.selectedRevisionId!,
      );
      if (revision == null) {
        entries.add(_AppBundleEntry(app: app, bundle: null));
        continue;
      }
      final bundle = await AiToolService.loadAppBundle(
        app: app,
        revision: revision,
      );
      // A null bundle here is a different failure — the code DID arrive but
      // declares no tools — so it stays skipped rather than being reported
      // as un-synced code.
      if (bundle == null) continue;
      entries.add(_AppBundleEntry(app: app, bundle: bundle));
    }
    return entries;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<_AppBundleEntry>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(child: Text('Error: ${snapshot.error}'));
        }
        final entries = snapshot.data ?? [];
        if (entries.isEmpty) {
          return const Center(child: Text('No user-defined AI tools found.'));
        }
        return ListView.builder(
          controller: widget.scrollController,
          itemCount: entries.length,
          itemBuilder: (context, index) {
            final entry = entries[index];
            final app = entry.app;
            final bundle = entry.bundle;
            final l10n = AppLocalizations.of(context)!;
            if (bundle == null) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ListTile(
                    enabled: false,
                    leading: const Icon(Icons.cloud_off_outlined),
                    title: Text(app.displayName(context)),
                    subtitle: Text(l10n.aiToolCodeNotSynced),
                  ),
                  const Divider(height: 1),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Whole-app entry
                ListTile(
                  leading: const Icon(Icons.extension),
                  title: Text(app.displayName(context)),
                  subtitle: app.displayDescription(context).isNotEmpty
                      ? Text(app.displayDescription(context))
                      : null,
                  onTap: () => widget.onSelect(
                    '[${app.displayName(context)}](notesynapse://tool/user_defined/${app.uuid})',
                  ),
                ),
                // Individual function entries (indented)
                ...bundle.toolDefinitions.map(
                  (def) => ListTile(
                    contentPadding: const EdgeInsets.only(left: 32, right: 16),
                    leading: const Icon(Icons.functions, size: 18),
                    title: Text(def.toolName),
                    subtitle: def.description.isNotEmpty
                        ? Text(
                            def.description,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          )
                        : null,
                    onTap: () => widget.onSelect(
                      '[${app.displayName(context)}.${def.toolName}](notesynapse://tool/user_defined/${app.uuid}/${def.toolName})',
                    ),
                  ),
                ),
                const Divider(height: 1),
              ],
            );
          },
        );
      },
    );
  }
}

class _AppBundleEntry {
  final UserApp app;

  /// Null when the app has no runnable revision on this device — its code
  /// has not arrived. Rendered as a disabled row rather than dropped.
  final AiToolAppBundle? bundle;

  _AppBundleEntry({required this.app, required this.bundle});
}

// ─── MCP tools tab ────────────────────────────────────────────────────────────

class _McpToolsTab extends StatefulWidget {
  final void Function(String) onSelect;
  final ScrollController? scrollController;

  const _McpToolsTab({required this.onSelect, this.scrollController});

  @override
  State<_McpToolsTab> createState() => _McpToolsTabState();
}

class _McpToolsTabState extends State<_McpToolsTab> {
  late Future<List<_EndpointEntry>> _future;

  @override
  void initState() {
    super.initState();
    _future = _loadEndpoints();
  }

  Future<List<_EndpointEntry>> _loadEndpoints() async {
    final mcpService = getIt<McpService>();
    final endpoints = await mcpService.getEndpoints();

    final entries = <_EndpointEntry>[];
    for (final ep in endpoints) {
      final cache = await mcpService.getCachedTools(ep.id);
      final tools = cache?.tools ?? [];
      entries.add(_EndpointEntry(endpoint: ep, tools: tools));
    }
    return entries;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<_EndpointEntry>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(child: Text('Error: ${snapshot.error}'));
        }
        final entries = snapshot.data ?? [];
        if (entries.isEmpty) {
          return const Center(child: Text('No MCP endpoints configured.'));
        }
        return ListView.builder(
          controller: widget.scrollController,
          itemCount: entries.length,
          itemBuilder: (context, index) {
            final entry = entries[index];
            final ep = entry.endpoint;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Whole-endpoint entry
                ListTile(
                  leading: const Icon(Icons.cloud_outlined),
                  title: Text(ep.name),
                  subtitle: Text(ep.baseUrl),
                  onTap: () => widget.onSelect(
                    '[${ep.name}](notesynapse://tool/mcp/${ep.name})',
                  ),
                ),
                // Individual tool entries (indented)
                ...entry.tools.map(
                  (tool) => ListTile(
                    contentPadding: const EdgeInsets.only(left: 32, right: 16),
                    leading: const Icon(
                      Icons.settings_input_component,
                      size: 18,
                    ),
                    title: Text(tool.name),
                    subtitle:
                        tool.description != null && tool.description!.isNotEmpty
                        ? Text(
                            tool.description!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          )
                        : null,
                    onTap: () => widget.onSelect(
                      '[${ep.name}.${tool.name}](notesynapse://tool/mcp/${ep.name}/${tool.name})',
                    ),
                  ),
                ),
                const Divider(height: 1),
              ],
            );
          },
        );
      },
    );
  }
}

class _EndpointEntry {
  final McpEndpoint endpoint;
  final List<McpTool> tools;

  _EndpointEntry({required this.endpoint, required this.tools});
}

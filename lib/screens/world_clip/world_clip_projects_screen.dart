import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import '../../l10n/app_localizations.dart';
import '../../services/world_clip/clip_project_store.dart';
import '../../services/world_clip/models/clip_project.dart';
import 'world_clip_flow_screen.dart';

class WorldClipProjectsScreen extends StatefulWidget {
  /// Injectable for tests; defaults to the cache-dir store.
  final ClipProjectStore? store;
  const WorldClipProjectsScreen({super.key, this.store});

  @override
  State<WorldClipProjectsScreen> createState() =>
      _WorldClipProjectsScreenState();
}

class _WorldClipProjectsScreenState extends State<WorldClipProjectsScreen> {
  ClipProjectStore? _store;
  List<ClipProject> _projects = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _store = widget.store ??
        ClipProjectStore(Directory(p.join(
            (await getTemporaryDirectory()).path, 'world_clip')));
    await _reload();
  }

  Future<void> _reload() async {
    final projects = await _store!.listAll();
    if (!mounted) return;
    setState(() {
      _projects = projects;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.worldClipProjects)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _projects.isEmpty
              ? Center(child: Text(l10n.worldClipEmptyProjects))
              : ListView.builder(
                  itemCount: _projects.length,
                  itemBuilder: (context, i) {
                    final pr = _projects[i];
                    return ListTile(
                      title: Text(pr.name),
                      subtitle: Text('${pr.clips.length} clips'),
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) =>
                            WorldClipFlowScreen(resumeProjectId: pr.id),
                      )),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: l10n.worldClipDeleteProject,
                        onPressed: () async {
                          await _store!.delete(pr.id);
                          await _reload();
                        },
                      ),
                    );
                  },
                ),
    );
  }
}

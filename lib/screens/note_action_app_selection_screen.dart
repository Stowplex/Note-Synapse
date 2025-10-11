import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_provider.dart';
import '../models/user_app.dart';
import '../models/note.dart';
import 'user_app_view_screen.dart';
import 'user_app_creation_screen.dart';

class NoteActionAppSelectionScreen extends StatefulWidget {
  final List<Note> selectedNotes;

  const NoteActionAppSelectionScreen({
    super.key,
    required this.selectedNotes,
  });

  @override
  State<NoteActionAppSelectionScreen> createState() => _NoteActionAppSelectionScreenState();
}

class _NoteActionAppSelectionScreenState extends State<NoteActionAppSelectionScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Select Note Action App'),
            Text(
              '${widget.selectedNotes.length} notes selected',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.white70,
              ),
            ),
          ],
        ),
      ),
      body: Consumer<AppProvider>(
        builder: (context, appProvider, child) {
          if (appProvider.isLoading) {
            return const Center(child: CircularProgressIndicator());
          }

          // Filter to only show Note Action Apps
          final noteActionApps = appProvider.userApps
              .where((app) => app.type == UserAppType.noteAction)
              .toList();

          if (noteActionApps.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.apps,
                    size: 64,
                    color: Colors.grey[400],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No Note Action Apps Available',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Create a Note Action App first to use this feature.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Colors.grey[600],
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton.icon(
                    onPressed: () {
                      Navigator.of(context).pop();
                      // Navigate to user app creation screen
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) => const UserAppCreationScreen(),
                        ),
                      );
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('Create Note Action App'),
                  ),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: noteActionApps.length,
            itemBuilder: (context, index) {
              final app = noteActionApps[index];
              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    child: const Icon(
                      Icons.apps,
                      color: Colors.white,
                    ),
                  ),
                  title: Text(
                    app.name,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(app.description),
                      const SizedBox(height: 4),
                      Text(
                        'Created: ${_formatDate(app.createdAt)}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.grey[600],
                        ),
                      ),
                    ],
                  ),
                  trailing: const Icon(Icons.arrow_forward_ios),
                  onTap: () => _runNoteActionApp(app),
                ),
              );
            },
          );
        },
      ),
    );
  }

  void _runNoteActionApp(UserApp app) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => UserAppViewScreen(
          app: app,
          selectedNotes: widget.selectedNotes,
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.day}/${date.month}/${date.year}';
  }
}

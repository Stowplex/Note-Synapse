import 'package:flutter/material.dart';
import 'user_app_library_settings_screen.dart';

class UserAppSettingsScreen extends StatelessWidget {
  const UserAppSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('User App Settings')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.library_books),
            title: const Text('Libraries'),
            subtitle: const Text('Manage built-in and custom libraries'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const UserAppLibrarySettingsScreen(),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

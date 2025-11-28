import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/app_provider.dart';
import '../models/user_app.dart';
import 'calendar_screen.dart';
import 'user_app_view_screen.dart';
import '../l10n/app_localizations.dart';

class MultiFunctionScreen extends StatefulWidget {
  const MultiFunctionScreen({super.key});

  @override
  State<MultiFunctionScreen> createState() => _MultiFunctionScreenState();
}

class _MultiFunctionScreenState extends State<MultiFunctionScreen> {
  final GlobalKey<UserAppViewScreenState> _userAppViewKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    return Consumer<AppProvider>(
      builder: (context, appProvider, child) {
        final currentAppId = appProvider.currentMultiFunctionAppId;

        if (currentAppId == null) {
          return const CalendarScreen();
        }

        final app = appProvider.userApps.firstWhere(
          (a) => a.id == currentAppId,
          orElse: () => UserApp(
            id: '',
            uuid: '',
            name: '',
            description: '',
            steps: [],
            htmlContent: '',
            type: UserAppType.normal,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );

        if (app.id.isEmpty) {
          // App not found, fallback to calendar and clear state
          WidgetsBinding.instance.addPostFrameCallback((_) {
            appProvider.setCurrentMultiFunctionApp(null);
          });
          return const CalendarScreen();
        }

        return Scaffold(
          appBar: AppBar(
            title: Text(app.name),
            actions: [
              IconButton(
                icon: const Icon(Icons.code),
                onPressed: () {
                  _userAppViewKey.currentState?.showConsole(context);
                },
              ),
              PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'remove') {
                    appProvider.setCurrentMultiFunctionApp(null);
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'remove',
                    child: Row(
                      children: [
                        const Icon(Icons.close),
                        const SizedBox(width: 8),
                        Text(
                          AppLocalizations.of(context)!.removeFromMultiFunction,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
          body: UserAppViewScreen(
            key: _userAppViewKey,
            app: app,
            selectedNotes: null,
            isEmbedded: true,
          ),
        );
      },
    );
  }
}

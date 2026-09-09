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

        return UserAppViewScreen(
          key: _userAppViewKey,
          app: app,
          selectedNotes: null,
          isEmbedded: false,
          showDeleteAction: false,
          showEditAction: false,
          showRevisionHistory: false,
          // Tab body, not a pushed route — it is already permanently reachable
          // via its tab, and ModalRoute.of here is MainScreen's own route.
          canRunInBackground: false,
          extraActions: [
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'remove') {
                  // Delay removal to allow popup menu to close and avoid "deactivated widget" error
                  Future.delayed(const Duration(milliseconds: 300), () async {
                    if (context.mounted) {
                      await appProvider.removeAppFromMultiFunction(app.id);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              AppLocalizations.of(
                                context,
                              )!.appRemovedFromMultiFunction,
                            ),
                          ),
                        );
                      }
                    }
                  });
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
        );
      },
    );
  }
}

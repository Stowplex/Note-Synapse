import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'l10n/app_localizations.dart';
import 'providers/app_provider.dart';
import 'screens/setup_screen.dart';
import 'screens/main_screen.dart';
import 'screens/share_screen.dart';
import 'screens/model_selection_screen.dart';
import 'services/secure_storage_service.dart';
import 'services/ai_service.dart';
import 'services/share_service.dart';
import 'services/prompts/prompt_configuration_bootstrapper.dart';
import 'services/global_library_service.dart';
import 'services/agent_service.dart';
import 'services/wake_lock_service.dart' as wake_lock;
import 'utils/global_keys.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize secure storage
  await SecureStorageService.initialize();
  await PromptConfigurationBootstrapper.initialize();
  await GlobalLibraryService().init();

  runApp(const NoteSynapseApp());
}

class NoteSynapseApp extends StatelessWidget {
  const NoteSynapseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (context) => AppProvider()),
        ChangeNotifierProvider(create: (context) => AgentService()),
      ], // ...
      child: Consumer<AppProvider>(
        builder: (context, appProvider, child) {
          return MaterialApp(
            title: 'Note Synapse',
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: const [
              Locale('en', ''), // English
              Locale('zh', ''), // Chinese Simplified
            ],
            locale: appProvider.locale,
            navigatorKey: navigatorKey,
            theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
              useMaterial3: true,
            ),
            darkTheme: ThemeData(
              colorScheme: ColorScheme.fromSeed(
                seedColor: Colors.blue,
                brightness: Brightness.dark,
              ),
              useMaterial3: true,
            ),
            themeMode: appProvider.isDarkMode
                ? ThemeMode.dark
                : ThemeMode.light,
            home: const AppWrapper(),
            routes: {
              '/setup': (context) => const SetupScreen(),
              '/main': (context) => const MainScreen(),
              '/share': (context) {
                final sharedData =
                    ModalRoute.of(context)!.settings.arguments
                        as Map<String, dynamic>?;
                if (sharedData != null) {
                  return ShareScreen(sharedData: sharedData);
                }
                return const MainScreen();
              },
            },
            builder: (context, child) {
              return child ?? const SizedBox.shrink();
            },
          );
        },
      ),
    );
  }
}

class AppWrapper extends StatefulWidget {
  const AppWrapper({super.key});

  @override
  State<AppWrapper> createState() => _AppWrapperState();
}

class _AppWrapperState extends State<AppWrapper> {
  bool _isLoading = true;
  bool _isModelConfigured = false;

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    final appProvider = context.read<AppProvider>();
    await appProvider.loadThemePreference();
    await appProvider.loadLanguagePreference();
    await appProvider.loadData();

    await AIService.initialize(appProvider);
    await ShareService.init(appProvider);

    // Initialize wake lock if it was enabled in settings
    await wake_lock.initializeWakeLock();

    final modelConfig = appProvider.modelConfig;
    final isConfigured = modelConfig?.isConfigured ?? false;

    setState(() {
      _isModelConfigured = isConfigured;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_isModelConfigured) {
      return const MainScreen();
    } else {
      return ModelSelectionScreen();
    }
  }
}

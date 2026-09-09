import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:provider/provider.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:rhttp/rhttp.dart';

import 'l10n/app_localizations.dart';
import 'providers/app_provider.dart';
import 'screens/setup_screen.dart';
import 'screens/main_screen.dart';
import 'screens/share_screen.dart';
import 'screens/model_selection_screen.dart';
import 'screens/onboarding/welcome_screen.dart';
import 'services/secure_storage_service.dart';
import 'services/ai_service.dart';
import 'services/share_service.dart';
import 'services/prompts/prompt_configuration_bootstrapper.dart';
import 'services/prompts/prompt_template_service.dart';
import 'services/global_library_service.dart';
import 'services/logger_service.dart';
import 'services/agent_service.dart';
import 'services/background_agent_service.dart';
import 'services/service_locator.dart';
import 'services/plugin_task_service.dart';
import 'services/search/search_service.dart';
import 'services/tag_image_service.dart';
import 'services/wake_lock_service.dart' as wake_lock;
import 'services/network_provider.dart';
import 'utils/global_keys.dart';
import 'widgets/user_app_background_shell.dart';
import 'widgets/workflow_shell.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _bootstrap();
}

/// Runs the startup initialization chain. Any failure here would otherwise be
/// an unrecoverable white-screen crash on launch, so we catch it and show a
/// dedicated error screen with a retry option. Database migration failures are
/// handled separately inside [DatabaseService] (it routes to RecoveryScreen via
/// the global navigator key), so this guard covers the remaining native/service
/// inits (rhttp, gemma, secure storage, prompt/template/tag preloads, etc.).
///
/// Retry is safe: [setupServiceLocator] is idempotent (guarded by isRegistered)
/// and the native inits are no-ops once they have already succeeded.
Future<void> _bootstrap() async {
  try {
    // Initialize rhttp Rust bindings (must be first)
    await Rhttp.init();

    // Initialize network provider
    await NetworkProvider.init();

    await FlutterGemma.initialize();

    // Initialize secure storage
    await SecureStorageService.initialize();
    await PromptConfigurationBootstrapper.initialize();
    await GlobalLibraryService().init();

    // Initialize service locator for dependency injection
    setupServiceLocator();

    // Pre-load prompt templates so later services can render synchronously
    await getIt<PromptTemplateService>().preloadAll();

    // Load tag image mappings into memory
    await getIt<TagImageService>().loadAll();

    // Initialize background agent service for Android foreground service
    await BackgroundAgentService.init();

    // Re-arm any persisted plugin task schedules (e.g. studio polling).
    await getIt<PluginTaskService>().initialize();

    // Kick off the search-index backfill check (fire-and-forget: ensureReady
    // is idempotent and does all work in the background; search degrades to
    // the substring fallback until the index is complete).
    unawaited(getIt<SearchService>().ensureReady());

    runApp(const NoteSynapseApp());
  } catch (e, stack) {
    LoggerService.error(
      'Startup initialization failed',
      error: e,
      stackTrace: stack,
    );
    runApp(_StartupErrorApp(error: '$e'));
  }
}

/// Minimal, self-contained app shown when [_bootstrap] fails. It deliberately
/// avoids depending on any service/provider that may have failed to initialize.
class _StartupErrorApp extends StatelessWidget {
  const _StartupErrorApp({required this.error});

  final String error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.error_outline,
                    color: Colors.redAccent,
                    size: 48,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Note Synapse failed to start',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Something went wrong while initializing the app. '
                    'You can retry, or restart the app if the problem persists.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.black12,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: SelectableText(
                      error,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    onPressed: _bootstrap,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Hoisted out of `build`: `MaterialApp` sits under a `Consumer<AppProvider>`,
/// so a fresh list literal here would make `NavigatorState.didUpdateWidget`
/// detach and re-attach the observer on every provider notification.
final List<NavigatorObserver> _navigatorObservers = <NavigatorObserver>[
  appRouteObserver,
];

class NoteSynapseApp extends StatelessWidget {
  const NoteSynapseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: getIt<AppProvider>()),
        ChangeNotifierProvider.value(value: getIt<AgentService>()),
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
            navigatorObservers: _navigatorObservers,
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
              return WorkflowShell(
                child: UserAppBackgroundShell(
                  child: child ?? const SizedBox.shrink(),
                ),
              );
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

    await getIt<AIService>().initialize(appProvider);
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

    final appProvider = context.watch<AppProvider>();

    // Only show onboarding if it's not completed AND we are not in a state where model is already configured
    // (backward compatibility: if model is configured, we assume they are an existing user,
    // BUT user asked for "show it once", so we primarily trust the flag.
    // However, to be safe, if they have a model, we might want to auto-set the flag?
    // Re-reading plan: "I will treat 'Model Configured' as a proxy... OR just show it once."
    // User approval: "Show it once is OK."
    // So we stricly check the flag.

    if (!appProvider.onboardingCompleted) {
      return const WelcomeScreen();
    }

    if (_isModelConfigured) {
      return const MainScreen();
    } else {
      return const ModelSelectionScreen(isOnboarding: true);
    }
  }
}

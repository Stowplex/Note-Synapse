import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'services/agent_service.dart';
import 'services/background_agent_service.dart';
import 'services/service_locator.dart';
import 'services/tag_image_service.dart';
import 'services/wake_lock_service.dart' as wake_lock;
import 'services/network_provider.dart';
import 'utils/global_keys.dart';
import 'widgets/workflow_shell.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

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

  runApp(const NoteSynapseApp());
}

class NoteSynapseApp extends StatelessWidget {
  const NoteSynapseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (context) => AppProvider()),
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
              return WorkflowShell(child: child ?? const SizedBox.shrink());
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

class _AppWrapperState extends State<AppWrapper> with WidgetsBindingObserver {
  bool _isLoading = true;
  bool _isModelConfigured = false;

  @override
  void initState() {
    super.initState();
    // TODO(stuck-selection): see text_field_selection_guard.dart
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.clearState();
    _initializeApp();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // TODO(stuck-selection): see text_field_selection_guard.dart
    HardwareKeyboard.instance.clearState();
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

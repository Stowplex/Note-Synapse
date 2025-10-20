import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_debug_overlay/flutter_debug_overlay.dart';
import 'l10n/app_localizations.dart';
import 'providers/app_provider.dart';
import 'screens/setup_screen.dart';
import 'screens/main_screen.dart';
import 'screens/share_screen.dart';
import 'screens/model_selection_screen.dart';
import 'services/secure_storage_service.dart';
import 'services/logger_service.dart';
import 'services/ai_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize secure storage
  await SecureStorageService.initialize();

  runApp(const NoteSynapseApp());
}

class NoteSynapseApp extends StatelessWidget {
  const NoteSynapseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (context) => AppProvider(),
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
            theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
              useMaterial3: true,
            ),
            darkTheme: ThemeData(
              colorScheme: ColorScheme.fromSeed(
                  seedColor: Colors.blue, brightness: Brightness.dark),
              useMaterial3: true,
            ),
            themeMode: appProvider.isDarkMode ? ThemeMode.dark : ThemeMode.light,
            home: const AppWrapper(),
            routes: {
              '/setup': (context) => const SetupScreen(),
              '/main': (context) => const MainScreen(),
              '/share': (context) {
                final sharedData =
                    ModalRoute.of(context)!.settings.arguments as Map<String, dynamic>?;
                if (sharedData != null) {
                  return ShareScreen(sharedData: sharedData);
                }
                return const MainScreen();
              },
            },
            builder: (context, child) {
              return DebugOverlay(
                visible: false, // Disable the default two finger tap trigger
                child: child ?? const SizedBox.shrink(),
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
  Map<String, dynamic>? _sharedData;

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

    final modelConfig = appProvider.modelConfig;
    final isConfigured = modelConfig?.isConfigured ?? false;

    setState(() {
      _isModelConfigured = isConfigured;
    });

    await _checkSharedContent();
  }

  Future<void> _checkSharedContent() async {
    Map<String, dynamic>? sharedData;
    try {
      const platform = MethodChannel('note_synapse/share');
      final result = await platform.invokeMethod('getSharedContent');
      if (result != null) {
        sharedData = Map<String, dynamic>.from(result);
        LoggerService.debug('AppWrapper: Shared content detected: ${sharedData.keys}');
      }
    } catch (e) {
      LoggerService.debug('No shared content or error: $e');
    }

    setState(() {
      _sharedData = sharedData;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    if (_sharedData != null) {
      return ShareScreen(sharedData: _sharedData!);
    }

    if (_isModelConfigured) {
      return const MainScreen();
    } else {
      return ModelSelectionScreen();
    }
  }
}
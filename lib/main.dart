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
import 'services/secure_storage_service.dart';
import 'services/logger_service.dart';
import 'services/ai_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Initialize secure storage
  await SecureStorageService.initialize();
  
  // Initialize AI service
  await AIService.initialize();
  
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
              colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue, brightness: Brightness.dark),
              useMaterial3: true,
            ),
            themeMode: appProvider.isDarkMode ? ThemeMode.dark : ThemeMode.light,
            home: const AppWrapper(),
            routes: {
              '/setup': (context) => const SetupScreen(),
              '/main': (context) => const MainScreen(),
              '/share': (context) {
                final sharedData = ModalRoute.of(context)!.settings.arguments as Map<String, dynamic>?;
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
  bool _hasApiKey = false;
  Map<String, dynamic>? _sharedData;

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    // Load theme and language preferences first
    await context.read<AppProvider>().loadThemePreference();
    await context.read<AppProvider>().loadLanguagePreference();
    // Model service is now initialized in main()
    // Then check API key and shared content
    await _checkApiKeyAndSharedContent();
  }

  Future<void> _checkApiKeyAndSharedContent() async {
    LoggerService.debug('AppWrapper: Checking API key and shared content...');
    
    // Add a small delay to ensure storage is properly initialized
    await Future.delayed(const Duration(milliseconds: 200));
    
    // Check both storage methods
    final hasKey = await SecureStorageService.hasApiKey();
    LoggerService.debug('AppWrapper: API key available (main method): $hasKey');
    
    if (hasKey) {
      final apiKey = await SecureStorageService.getApiKey();
      LoggerService.debug('AppWrapper: API key length (main method): ${apiKey?.length ?? 0}');
    }
    
    // Debug storage contents
    await SecureStorageService.debugStorageContents();
    
    LoggerService.debug('AppWrapper: Final API key available: $hasKey');
    
    // Check for shared content from Android
    Map<String, dynamic>? sharedData;
    try {
      const platform = MethodChannel('note_synapse/share');
      final result = await platform.invokeMethod('getSharedContent');
      if (result != null) {
        sharedData = Map<String, dynamic>.from(result);
        LoggerService.debug('AppWrapper: Shared content detected: ${sharedData.keys}');
      }
    } catch (e) {
      // No shared content or error - continue normally
      LoggerService.debug('No shared content or error: $e');
    }
    
    setState(() {
      _hasApiKey = hasKey;
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

    // If there's shared content, show the share screen
    if (_sharedData != null) {
      return ShareScreen(sharedData: _sharedData!);
    }

    if (_hasApiKey) {
      return const MainScreen();
    } else {
      return const SetupScreen();
    }
  }
}
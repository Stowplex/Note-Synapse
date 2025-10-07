import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter/services.dart';
import 'providers/app_provider.dart';
import 'screens/setup_screen.dart';
import 'screens/main_screen.dart';
import 'screens/share_screen.dart';
import 'services/secure_storage_service.dart';
import 'services/share_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const NoteSynapseApp());
}

class NoteSynapseApp extends StatelessWidget {
  const NoteSynapseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (context) => AppProvider(),
      child: MaterialApp(
        title: 'Note Synapse',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
          useMaterial3: true,
        ),
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
    // Initialize share service after Flutter binding is ready
    ShareService.initialize();
    _checkApiKeyAndSharedContent();
  }

  Future<void> _checkApiKeyAndSharedContent() async {
    final hasKey = await SecureStorageService.hasApiKey();
    
    // Check for shared content from Android
    Map<String, dynamic>? sharedData;
    try {
      const platform = MethodChannel('note_synapse/share');
      final result = await platform.invokeMethod('getSharedContent');
      if (result != null) {
        sharedData = Map<String, dynamic>.from(result);
      }
    } catch (e) {
      // No shared content or error - continue normally
      print('No shared content or error: $e');
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
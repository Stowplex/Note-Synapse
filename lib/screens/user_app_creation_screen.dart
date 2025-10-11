import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../providers/app_provider.dart';
import 'user_app_result_screen.dart';

class UserAppCreationScreen extends StatefulWidget {
  const UserAppCreationScreen({super.key});

  @override
  State<UserAppCreationScreen> createState() => _UserAppCreationScreenState();
}

class _UserAppCreationScreenState extends State<UserAppCreationScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final List<TextEditingController> _stepControllers = [];
  bool _isCreating = false;

  @override
  void initState() {
    super.initState();
    // Add one initial step
    _addStep();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    for (final controller in _stepControllers) {
      controller.dispose();
    }
    super.dispose();
  }

  void _addStep() {
    setState(() {
      _stepControllers.add(TextEditingController());
    });
  }

  void _removeStep(int index) {
    if (_stepControllers.length > 1) {
      setState(() {
        _stepControllers[index].dispose();
        _stepControllers.removeAt(index);
      });
    }
  }

  List<String> _getSteps() {
    return _stepControllers
        .map((controller) => controller.text.trim())
        .where((step) => step.isNotEmpty)
        .toList();
  }

  Future<void> _createApp() async {
    if (!_formKey.currentState!.validate()) return;

    final steps = _getSteps();
    if (steps.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.appStepsHint),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() {
      _isCreating = true;
    });

    try {
      final appProvider = context.read<AppProvider>();
      
      final app = await appProvider.createUserApp(
        name: _nameController.text.trim(),
        description: _descriptionController.text.trim(),
        steps: steps,
      );
      
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => UserAppResultScreen(
              app: app,
              isSuccess: true,
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isCreating = false;
        });
        
        // Show error screen instead of clarification
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => UserAppResultScreen(
              app: null,
              isSuccess: false,
              errorMessage: e.toString(),
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.createNewApp),
      ),
      body: Form(
        key: _formKey,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // App Name
              TextFormField(
                controller: _nameController,
                decoration: InputDecoration(
                  labelText: l10n.appName,
                  hintText: l10n.appNameHint,
                  border: const OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Please enter an app name';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              
              // App Description
              TextFormField(
                controller: _descriptionController,
                decoration: InputDecoration(
                  labelText: l10n.appDescription,
                  hintText: l10n.appDescriptionHint,
                  border: const OutlineInputBorder(),
                ),
                maxLines: 3,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Please enter an app description';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              
              // Steps Section
              Text(
                l10n.appSteps,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              
              // Steps List
              ...List.generate(_stepControllers.length, (index) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8.0),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _stepControllers[index],
                          decoration: InputDecoration(
                            hintText: '${l10n.stepHint} ${index + 1}',
                            border: const OutlineInputBorder(),
                          ),
                          validator: (value) {
                            if (value == null || value.trim().isEmpty) {
                              return 'Step cannot be empty';
                            }
                            return null;
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        onPressed: _stepControllers.length > 1
                            ? () => _removeStep(index)
                            : null,
                        icon: const Icon(Icons.remove_circle),
                        tooltip: l10n.removeStep,
                      ),
                    ],
                  ),
                );
              }),
              
              // Add Step Button
              OutlinedButton.icon(
                onPressed: _addStep,
                icon: const Icon(Icons.add),
                label: Text(l10n.addStep),
              ),
              const SizedBox(height: 24),
              
              // Create App Button
              ElevatedButton(
                onPressed: _isCreating ? null : _createApp,
                child: _isCreating
                    ? Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 8),
                          Text(l10n.creatingApp),
                        ],
                      )
                    : Text(l10n.createApp),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

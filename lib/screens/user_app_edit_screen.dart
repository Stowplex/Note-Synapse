import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../providers/app_provider.dart';
import '../models/user_app.dart';

class UserAppEditScreen extends StatefulWidget {
  final UserApp app;

  const UserAppEditScreen({
    super.key,
    required this.app,
  });

  @override
  State<UserAppEditScreen> createState() => _UserAppEditScreenState();
}

class _UserAppEditScreenState extends State<UserAppEditScreen> {
  final _formKey = GlobalKey<FormState>();
  final _editSuggestionController = TextEditingController();
  final _codeController = TextEditingController();
  bool _isEditing = false;
  bool _isSaving = false;
  bool _isCodeEditable = false;
  String _originalCode = '';

  @override
  void initState() {
    super.initState();
    _originalCode = widget.app.htmlContent;
    _codeController.text = widget.app.htmlContent;
  }

  @override
  void dispose() {
    _editSuggestionController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  Future<void> _submitEdit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isEditing = true;
    });

    try {
      final appProvider = context.read<AppProvider>();
      
      await appProvider.editUserApp(
        originalApp: widget.app,
        editSuggestion: _editSuggestionController.text.trim(),
      );
      
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('App updated successfully with new revision'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isEditing = false;
        });
        
        // Show error dialog instead of snackbar for better visibility
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(AppLocalizations.of(context)!.appEditFailed),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(AppLocalizations.of(context)!.errorCreatingAppFromEdit(e.toString())),
                const SizedBox(height: 8),
                Text(
                  'Please check your API key and try again.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey[600],
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(AppLocalizations.of(context)!.close),
              ),
            ],
          ),
        );
      }
    }
  }

  Future<void> _saveCodeDirectly() async {
    if (_codeController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context)!.errorSavingCode('Code cannot be empty')),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() {
      _isSaving = true;
    });

    try {
      final appProvider = context.read<AppProvider>();
      
      // Create updated app with new code
      final updatedApp = widget.app.copyWith(
        htmlContent: _codeController.text.trim(),
        updatedAt: DateTime.now(),
      );
      
      await appProvider.updateUserApp(updatedApp);
      
      if (mounted) {
        setState(() {
          _originalCode = _codeController.text.trim();
          _isCodeEditable = false;
        });
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context)!.codeSavedSuccessfully),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context)!.errorSavingCode(e.toString())),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  void _toggleCodeEdit() {
    setState(() {
      _isCodeEditable = !_isCodeEditable;
      if (!_isCodeEditable) {
        // Reset to original code if canceling edit
        _codeController.text = _originalCode;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    
    return Scaffold(
      resizeToAvoidBottomInset: !_isCodeEditable,
      appBar: AppBar(
        title: Text(l10n.editApp),
      ),
      body: Form(
        key: _formKey,
        child: _isCodeEditable ? _buildEditModeLayout(l10n) : _buildViewModeLayout(l10n),
      ),
    );
  }

  Widget _buildViewModeLayout(AppLocalizations l10n) {
    return Column(
      children: [
        // App Info Card
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.appName,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.app.name,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    l10n.appDescription,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.app.description,
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                ],
              ),
            ),
          ),
        ),
        
        // App Code Section - Takes up remaining space
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      l10n.appCode,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    ElevatedButton.icon(
                      onPressed: _toggleCodeEdit,
                      icon: const Icon(Icons.edit, size: 16),
                      label: Text(l10n.editCodeDirectly),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue,
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: Card(
                    child: Container(
                      padding: const EdgeInsets.all(12.0),
                      child: SingleChildScrollView(
                        child: Text(
                          _codeController.text,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        
        // Bottom section with suggestion input and submit button
        Container(
          padding: const EdgeInsets.all(16.0),
          decoration: BoxDecoration(
            color: Theme.of(context).scaffoldBackgroundColor,
            border: Border(
              top: BorderSide(
                color: Theme.of(context).dividerColor,
                width: 1,
              ),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.editSuggestion,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _editSuggestionController,
                decoration: InputDecoration(
                  hintText: l10n.editSuggestionHint,
                  border: const OutlineInputBorder(),
                ),
                maxLines: 3,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Please enter your edit suggestion';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _isEditing ? null : _submitEdit,
                child: _isEditing
                    ? Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 8),
                          Text(l10n.editingApp),
                        ],
                      )
                    : Text(l10n.submitEdit),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildEditModeLayout(AppLocalizations l10n) {
    return Column(
      children: [
        // App Info Card (smaller in edit mode)
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.app.name,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(
                          widget.app.description,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Colors.grey[600],
                          ),
                        ),
                      ],
                    ),
                  ),
                  Row(
                    children: [
                      ElevatedButton.icon(
                        onPressed: _isSaving ? null : _saveCodeDirectly,
                        icon: _isSaving 
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.save, size: 16),
                        label: Text(l10n.saveCode),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton.icon(
                        onPressed: _isSaving ? null : _toggleCodeEdit,
                        icon: const Icon(Icons.cancel, size: 16),
                        label: Text(l10n.cancel),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        
        // Full-screen code editor
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Card(
              child: Container(
                padding: const EdgeInsets.all(12.0),
                child: TextFormField(
                  controller: _codeController,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                  ),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    hintText: 'Enter your HTML code here...',
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

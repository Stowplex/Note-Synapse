import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/context_manager_service.dart';
import 'package:note_synapse/services/model_selector.dart';
import 'package:note_synapse/services/ai_service.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/models/context_node.dart';
import 'package:note_synapse/models/model_config.dart';
import 'package:note_synapse/models/generation_context.dart';

class MockContextManagerService extends Fake implements ContextManagerService {
  final Map<String, ContextNode> _contexts = {};
  ContextNode? _rootContext;

  @override
  ContextNode? get rootContext => _rootContext;

  @override
  void clear() {
    _contexts.clear();
    _rootContext = null;
  }

  @override
  Future<ContextNode> createRootContext({
    required String objective,
    List<String> allowedTools = const [],
    int? maxTokens,
  }) async {
    final node = ContextNode(id: 'root', objective: objective);
    _rootContext = node;
    _contexts[node.id] = node;
    return node;
  }

  @override
  ContextNode createChildContext({
    required ContextNode parent,
    required String objective,
    List<String>? allowedTools,
  }) {
    final node = ContextNode(
      id: 'child_${_contexts.length}',
      objective: objective,
    );
    _contexts[node.id] = node;
    return node;
  }

  @override
  ContextNode? getContext(String id) => _contexts[id];

  @override
  void setActiveContext(ContextNode node) {}

  @override
  Future<void> checkAndCompact(ContextNode node) async {}

  @override
  String buildContextForSubtask(ContextNode node) => "Mock subtask context";

  @override
  String buildContextForResearchTask(
    ContextNode node, {
    List<String> dependencyResults = const [],
    List<DependencyInfo> structuredDependencies = const [],
  }) => "Mock research context";

  @override
  void markContextFailed(ContextNode node, String error) {}

  @override
  Future<String> generateFinalSummary(
    ContextNode node, {
    List<String> consumingTaskDescriptions = const [],
    ModelConfig? modelOverride,
  }) async => "Mock summary";

  @override
  String buildSynthesisContext(
    ContextNode node, {
    List<DependencyInfo> structuredDependencies = const [],
  }) => "Mock synthesis context";

  @override
  void addFindings(List<Map<String, dynamic>> findings) {}

  @override
  Future<int> getModelContextBudget() async => 100000;

  @override
  ContextNode? get currentContext => _rootContext;
}

class MockModelSelector extends Fake implements ModelSelector {
  @override
  ModelConfig? get currentModelConfig => null;
}

class MockAIService extends Fake implements AIService {
  @override
  Future<String> generateWithAttachments(
    String prompt,
    List<dynamic> attachedFiles, {
    GenerationContext? generationContext,
  }) async {
    if (prompt.contains('TASK CONFIGURATION') ||
        prompt.contains('Generate a plan')) {
      return '''
[
  {
    "name": "main_task",
    "description": "Main Task",
    "tools": [],
    "dependsOn": [],
    "isFinalDeliverable": true,
    "extractFindings": false
  }
]
''';
    }
    return 'Mock AI Response';
  }
}

class MockDatabaseService extends Fake implements DatabaseService {}

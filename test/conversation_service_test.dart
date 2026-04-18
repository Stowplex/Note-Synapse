import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/models/conversation.dart';
import 'package:note_synapse/models/conversation_attachment.dart';
import 'package:note_synapse/models/mcp_endpoint.dart';
import 'package:note_synapse/models/note.dart';
import 'package:note_synapse/services/agent_service.dart';
import 'package:note_synapse/services/conversation_service.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/mcp_service.dart';
import 'package:note_synapse/services/service_locator.dart';
import 'package:note_synapse/services/skill_service.dart';
import 'package:note_synapse/services/tools/note_tools.dart';

import 'conversation_service_test.mocks.dart';

@GenerateMocks([DatabaseService, AgentService, SkillService, McpService])
void main() {
  group('Conversation Service Tests', () {
    late ConversationService conversationService;
    late DatabaseService databaseService;

    setUp(() async {
      databaseService = DatabaseService.createNew();
      conversationService = ConversationService.createForTesting(
        databaseService,
      );
      await databaseService.clearAllData();
    });

    tearDown(() async {
      await databaseService.close();
    });

    group('Basic CRUD Operations', () {
      test('Create conversation and add messages', () async {
        final conversation = await conversationService.createConversation(
          title: 'Basic Test Conversation',
        );

        expect(conversation, isNotNull);
        expect(conversation.title, equals('Basic Test Conversation'));

        await conversationService.addUserMessage(
          conversationId: conversation.id,
          content: 'Hello, how are you?',
        );

        await conversationService.addAIResponse(
          conversationId: conversation.id,
          content: 'I am doing well, thank you!',
        );

        final conversationWithMessages = await conversationService
            .getConversationWithMessages(conversation.id);
        expect(conversationWithMessages, isNotNull);
        expect(conversationWithMessages!.messages.length, equals(2));
        expect(
          conversationWithMessages.messages[0].type,
          equals(MessageType.user),
        );
        expect(
          conversationWithMessages.messages[1].type,
          equals(MessageType.ai),
        );
      });

      test('Build conversation tree', () async {
        final conversation = await conversationService.createConversation(
          title: 'Tree Test Conversation',
        );

        await conversationService.addUserMessage(
          conversationId: conversation.id,
          content: 'Question 1',
        );
        await conversationService.addAIResponse(
          conversationId: conversation.id,
          content: 'Answer 1',
        );

        final tree = await conversationService.refreshConversationTree();
        expect(tree, isNotNull);
        expect(
          tree!.nodes.length,
          greaterThan(1),
        ); // At least root + 1 interaction
      });

      test('Delete conversation', () async {
        final conversation = await conversationService.createConversation(
          title: 'To Be Deleted',
        );

        await conversationService.addUserMessage(
          conversationId: conversation.id,
          content: 'Test message',
        );

        await conversationService.deleteConversation(conversation.id);

        final deletedConversation = await conversationService
            .getConversationWithMessages(conversation.id);
        expect(deletedConversation, isNull);
      });
    });

    group('Forking Operations', () {
      test(
        'Fork conversation creates new conversation with messages up to fork point',
        () async {
          final originalConversation = await conversationService
              .createConversation(title: 'Original Conversation');

          await conversationService.addUserMessage(
            conversationId: originalConversation.id,
            content: 'First question',
          );
          await conversationService.addAIResponse(
            conversationId: originalConversation.id,
            content: 'First answer',
          );

          await conversationService.addUserMessage(
            conversationId: originalConversation.id,
            content: 'Second question',
          );
          await conversationService.addAIResponse(
            conversationId: originalConversation.id,
            content: 'Second answer',
          );

          final originalMessages = await conversationService
              .getConversationWithMessages(originalConversation.id);
          final firstAIResponse = originalMessages!.messages.firstWhere(
            (msg) => msg.type == MessageType.ai,
          );

          final forkedConversation = await conversationService.forkConversation(
            originalConversationId: originalConversation.id,
            forkFromMessageId: firstAIResponse.id,
            newTitle: 'Forked Conversation',
          );

          expect(forkedConversation, isNotNull);
          expect(forkedConversation.title, equals('Forked Conversation'));

          final forkedMessages = await conversationService
              .getConversationWithMessages(forkedConversation.id);
          expect(forkedMessages, isNotNull);
          expect(
            forkedMessages!.messages.length,
            equals(2),
          ); // Up to and including fork point
        },
      );

      test(
        'Add interaction to forked conversation creates new branch in tree',
        () async {
          final originalConversation = await conversationService
              .createConversation(title: 'Original');

          await conversationService.addUserMessage(
            conversationId: originalConversation.id,
            content: 'Question',
          );
          final aiResponse = await conversationService.addAIResponse(
            conversationId: originalConversation.id,
            content: 'Answer',
          );

          final forkedConversation = await conversationService.forkConversation(
            originalConversationId: originalConversation.id,
            forkFromMessageId: aiResponse.id,
            newTitle: 'Forked',
          );

          await conversationService.addUserMessage(
            conversationId: forkedConversation.id,
            content: 'New question',
          );
          await conversationService.addAIResponse(
            conversationId: forkedConversation.id,
            content: 'New answer',
          );

          final tree = await conversationService.refreshConversationTree();
          expect(tree, isNotNull);

          // Verify fork point has children
          final forkPointNode = tree!.nodes.values.firstWhere(
            (node) => node.messageId == aiResponse.id,
          );
          expect(forkPointNode.children.length, greaterThan(0));
        },
      );

      test(
        'Fork from forked conversation without throwing exception',
        () async {
          final originalConversation = await conversationService
              .createConversation(title: 'Original Conversation');

          await conversationService.addUserMessage(
            conversationId: originalConversation.id,
            content: 'Question A',
          );
          final aiMessageA = await conversationService.addAIResponse(
            conversationId: originalConversation.id,
            content: 'Answer A',
            modelUsed: 'gpt-4',
          );

          await conversationService.addUserMessage(
            conversationId: originalConversation.id,
            content: 'Question B',
          );
          await conversationService.addAIResponse(
            conversationId: originalConversation.id,
            content: 'Answer B',
            modelUsed: 'gpt-4',
          );

          final forkedConversation = await conversationService.forkConversation(
            originalConversationId: originalConversation.id,
            forkFromMessageId: aiMessageA.id,
            newTitle: 'Forked Conversation A',
          );

          await conversationService.addUserMessage(
            conversationId: forkedConversation.id,
            content: 'Question C',
          );
          await conversationService.addAIResponse(
            conversationId: forkedConversation.id,
            content: 'Answer C',
            modelUsed: 'gpt-4',
          );

          Conversation? secondForkedConversation;
          Exception? caughtException;

          try {
            secondForkedConversation = await conversationService
                .forkConversation(
                  originalConversationId: forkedConversation.id,
                  forkFromMessageId: aiMessageA.id,
                  newTitle: 'Second Forked Conversation',
                );
          } catch (e) {
            caughtException = e as Exception;
          }

          expect(caughtException, isNull, reason: 'Should not throw exception');
          expect(secondForkedConversation, isNotNull);
          expect(
            secondForkedConversation!.title,
            equals('Second Forked Conversation'),
          );

          final secondForkedMessages = await conversationService
              .getConversationWithMessages(secondForkedConversation.id);
          expect(secondForkedMessages!.messages.length, equals(2));
          expect(
            secondForkedMessages.messages[0].content,
            equals('Question A'),
          );
          expect(secondForkedMessages.messages[1].content, equals('Answer A'));
        },
      );

      test('Fork from forked conversation with new messages', () async {
        final originalConversation = await conversationService
            .createConversation(title: 'Original');

        await conversationService.addUserMessage(
          conversationId: originalConversation.id,
          content: 'Original question',
        );
        final aiMsg = await conversationService.addAIResponse(
          conversationId: originalConversation.id,
          content: 'Original answer',
        );

        final forkedConversation = await conversationService.forkConversation(
          originalConversationId: originalConversation.id,
          forkFromMessageId: aiMsg.id,
          newTitle: 'Forked',
        );

        await conversationService.addUserMessage(
          conversationId: forkedConversation.id,
          content: 'Forked question',
        );
        final forkedAiMsg = await conversationService.addAIResponse(
          conversationId: forkedConversation.id,
          content: 'Forked answer',
        );

        Conversation? secondFork;
        Exception? exception;

        try {
          secondFork = await conversationService.forkConversation(
            originalConversationId: forkedConversation.id,
            forkFromMessageId: forkedAiMsg.id,
            newTitle: 'Second Fork',
          );
        } catch (e) {
          exception = e as Exception;
        }

        expect(exception, isNull);
        expect(secondFork, isNotNull);

        final secondForkMessages = await conversationService
            .getConversationWithMessages(secondFork!.id);
        expect(secondForkMessages!.messages.length, equals(4));
        expect(
          secondForkMessages.messages[0].content,
          equals('Original question'),
        );
        expect(
          secondForkMessages.messages[1].content,
          equals('Original answer'),
        );
        expect(
          secondForkMessages.messages[2].content,
          equals('Forked question'),
        );
        expect(secondForkMessages.messages[3].content, equals('Forked answer'));
      });

      test('Throw exception when forking from non-existent message', () async {
        final conversation = await conversationService.createConversation(
          title: 'Test Conversation',
        );

        Exception? caughtException;
        try {
          await conversationService.forkConversation(
            originalConversationId: conversation.id,
            forkFromMessageId: 'non-existent-message-id',
            newTitle: 'Should Fail',
          );
        } catch (e) {
          caughtException = e as Exception;
        }

        expect(caughtException, isNotNull);
        expect(caughtException.toString(), contains('Fork message not found'));
      });

      test('Multiple forks from same point', () async {
        final originalConversation = await conversationService
            .createConversation(title: 'Original');

        await conversationService.addUserMessage(
          conversationId: originalConversation.id,
          content: 'Question',
        );
        final aiResponse = await conversationService.addAIResponse(
          conversationId: originalConversation.id,
          content: 'Answer',
        );

        final fork1 = await conversationService.forkConversation(
          originalConversationId: originalConversation.id,
          forkFromMessageId: aiResponse.id,
          newTitle: 'Fork 1',
        );

        final fork2 = await conversationService.forkConversation(
          originalConversationId: originalConversation.id,
          forkFromMessageId: aiResponse.id,
          newTitle: 'Fork 2',
        );

        expect(fork1.id, isNot(equals(fork2.id)));

        final fork1Messages = await conversationService
            .getConversationWithMessages(fork1.id);
        final fork2Messages = await conversationService
            .getConversationWithMessages(fork2.id);

        expect(
          fork1Messages!.messages.length,
          equals(fork2Messages!.messages.length),
        );
      });

      test('Fork preserves note associations', () async {
        final note = await databaseService.insertNote(
          Note(
            id: 'test-note-id',
            title: 'Test Note',
            content: 'Test content',
            type: NoteType.note,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );

        final originalConversation = await conversationService
            .createConversation(title: 'Original with Note', noteIds: [note]);

        await conversationService.addUserMessage(
          conversationId: originalConversation.id,
          content: 'Question',
        );
        final aiResponse = await conversationService.addAIResponse(
          conversationId: originalConversation.id,
          content: 'Answer',
        );

        final forkedConversation = await conversationService.forkConversation(
          originalConversationId: originalConversation.id,
          forkFromMessageId: aiResponse.id,
          newTitle: 'Forked with Note',
        );

        expect(forkedConversation.noteIds, contains(note));
      });
    });

    group('Message Deletion', () {
      test('Delete single message with proper cleanup', () async {
        final conversation = await conversationService.createConversation(
          title: 'Test Conversation for Deletion',
        );

        await conversationService.addUserMessage(
          conversationId: conversation.id,
          content: 'First question',
        );

        await conversationService.addAIResponse(
          conversationId: conversation.id,
          content: 'First answer',
        );

        await conversationService.addUserMessage(
          conversationId: conversation.id,
          content: 'Second question',
        );

        await conversationService.addAIResponse(
          conversationId: conversation.id,
          content: 'Second answer',
        );

        final conversationWithMessages = await conversationService
            .getConversationWithMessages(conversation.id);
        expect(conversationWithMessages, isNotNull);
        expect(conversationWithMessages!.messages.length, equals(4));

        final aiMessages = conversationWithMessages.messages
            .where((m) => m.type == MessageType.ai)
            .toList();
        final firstAIMessage = aiMessages.first;

        await conversationService.deleteMessageWithSubtree(firstAIMessage.id);

        final updatedConversation = await conversationService
            .getConversationWithMessages(conversation.id);
        expect(updatedConversation, isNotNull);
        expect(
          updatedConversation!.messages.length,
          equals(1),
        ); // Only the first user message should remain
      });

      test('Delete message with subtree', () async {
        final conversation = await conversationService.createConversation(
          title: 'Subtree Deletion Test',
        );

        await conversationService.addUserMessage(
          conversationId: conversation.id,
          content: 'Root question',
        );
        final rootAI = await conversationService.addAIResponse(
          conversationId: conversation.id,
          content: 'Root answer',
        );

        final fork1 = await conversationService.forkConversation(
          originalConversationId: conversation.id,
          forkFromMessageId: rootAI.id,
          newTitle: 'Fork 1',
        );

        await conversationService.addUserMessage(
          conversationId: fork1.id,
          content: 'Fork 1 question',
        );
        await conversationService.addAIResponse(
          conversationId: fork1.id,
          content: 'Fork 1 answer',
        );

        // Delete the root AI message - this deletes the subtree
        await conversationService.deleteMessageWithSubtree(rootAI.id);

        // The original conversation should still exist with just the user message
        final remainingConversation = await conversationService
            .getConversationWithMessages(conversation.id);
        expect(remainingConversation, isNotNull);
        expect(
          remainingConversation!.messages.length,
          equals(1),
        ); // Only user message remains

        // The fork should be deleted since its messages are part of the subtree
        final deletedFork = await conversationService
            .getConversationWithMessages(fork1.id);
        expect(deletedFork, isNull);
      });

      test('Garbage collect empty conversations after deletion', () async {
        final conversation = await conversationService.createConversation(
          title: 'To Be Emptied',
        );

        await conversationService.addUserMessage(
          conversationId: conversation.id,
          content: 'Only message',
        );

        final messages = await conversationService.getConversationWithMessages(
          conversation.id,
        );
        final userMessage = messages!.messages.first;

        await conversationService.deleteMessageWithSubtree(userMessage.id);

        final deletedConversation = await conversationService
            .getConversationWithMessages(conversation.id);
        expect(deletedConversation, isNull);
      });

      test('Delete message with attachments', () async {
        final conversation = await conversationService.createConversation(
          title: 'Attachment Test',
        );

        final userMessage = await conversationService.addUserMessage(
          conversationId: conversation.id,
          content: 'Message with attachment',
        );

        await databaseService.insertConversationAttachment(
          ConversationAttachment(
            id: 'attachment-1',
            messageId: userMessage.id,
            filePath: '/path/to/file',
            fileName: 'test.txt',
            fileType: 'txt',
            createdAt: DateTime.now(),
          ),
        );

        await conversationService.deleteMessageWithSubtree(userMessage.id);

        final attachments = await databaseService.getConversationAttachments(
          userMessage.id,
        );
        expect(attachments, isEmpty);
      });

      test('Tree structure remains intact after partial deletion', () async {
        final conversation = await conversationService.createConversation(
          title: 'Original',
        );

        await conversationService.addUserMessage(
          conversationId: conversation.id,
          content: 'Q1',
        );
        final ai1 = await conversationService.addAIResponse(
          conversationId: conversation.id,
          content: 'A1',
        );

        await conversationService.addUserMessage(
          conversationId: conversation.id,
          content: 'Q2',
        );
        final ai2 = await conversationService.addAIResponse(
          conversationId: conversation.id,
          content: 'A2',
        );

        final fork = await conversationService.forkConversation(
          originalConversationId: conversation.id,
          forkFromMessageId: ai1.id,
          newTitle: 'Fork',
        );

        await conversationService.addUserMessage(
          conversationId: fork.id,
          content: 'Q3',
        );
        await conversationService.addAIResponse(
          conversationId: fork.id,
          content: 'A3',
        );

        // Delete ai2 - this deletes Q2 and A2 from the original conversation
        await conversationService.deleteMessageWithSubtree(ai2.id);

        final tree = await conversationService.refreshConversationTree();
        expect(tree, isNotNull);

        // Original conversation should have Q1, A1, and Q2 (Q2's parent is A1, so it remains)
        final originalMessages = await conversationService
            .getConversationWithMessages(conversation.id);
        expect(originalMessages!.messages.length, equals(3)); // Q1, A1, Q2

        // Fork should be intact with Q1, A1, Q3, A3
        final forkMessages = await conversationService
            .getConversationWithMessages(fork.id);
        expect(forkMessages!.messages.length, equals(4)); // Q1, A1, Q3, A3
      });
    });

    group('Selected node compilation', () {
      Future<_SelectionTestData> buildSelectionScenario() async {
        final originalConversation = await conversationService
            .createConversation(title: 'Original Scenario');

        await conversationService.addUserMessage(
          conversationId: originalConversation.id,
          content: 'Prompt A',
        );
        final aiA = await conversationService.addAIResponse(
          conversationId: originalConversation.id,
          content: 'Answer A',
        );

        await conversationService.addUserMessage(
          conversationId: originalConversation.id,
          content: 'Prompt B',
        );
        final aiB = await conversationService.addAIResponse(
          conversationId: originalConversation.id,
          content: 'Answer B',
        );

        await conversationService.addUserMessage(
          conversationId: originalConversation.id,
          content: 'Prompt D',
        );
        final aiD = await conversationService.addAIResponse(
          conversationId: originalConversation.id,
          content: 'Answer D',
        );

        final forkedConversation = await conversationService.forkConversation(
          originalConversationId: originalConversation.id,
          forkFromMessageId: aiA.id,
          newTitle: 'Forked Scenario',
        );

        await conversationService.addUserMessage(
          conversationId: forkedConversation.id,
          content: 'Prompt C',
        );
        final aiC = await conversationService.addAIResponse(
          conversationId: forkedConversation.id,
          content: 'Answer C',
        );

        final tree = await conversationService.refreshConversationTree();
        expect(tree, isNotNull);

        return _SelectionTestData(
          originalConversation: originalConversation,
          forkedConversation: forkedConversation,
          aiA: aiA,
          aiB: aiB,
          aiC: aiC,
          aiD: aiD,
          tree: tree!,
        );
      }

      test('buildInteractionSnippets returns only selected nodes', () async {
        final data = await buildSelectionScenario();

        final snippets = await conversationService.buildInteractionSnippets(
          existingTree: data.tree,
          nodeIds: [data.aiA.id, data.aiB.id, data.aiD.id],
        );

        expect(snippets.length, equals(3));
        final snippetIds = snippets.map((s) => s.aiMessage.id).toSet();
        expect(
          snippetIds,
          containsAll({data.aiA.id, data.aiB.id, data.aiD.id}),
        );
        expect(snippetIds.contains(data.aiC.id), isFalse);
      });

      test(
        'createConversationFromSelectedNodes preserves selected interactions',
        () async {
          final data = await buildSelectionScenario();

          final newConversation = await conversationService
              .createConversationFromSelectedNodes(
                selectedNodeIds: [data.aiA.id, data.aiB.id, data.aiD.id],
                title: 'Compiled Conversation',
              );

          final compiled = await conversationService
              .getConversationWithMessages(newConversation.id);

          expect(compiled, isNotNull);
          expect(compiled!.messages.length, equals(1));
          final contextMessage = compiled.messages.first.content;
          expect(contextMessage.contains('Answer C'), isFalse);
          expect(contextMessage.contains('Answer B'), isTrue);
          expect(contextMessage.contains('Answer D'), isTrue);
        },
      );

      test(
        'prepareForkContextSelection skips prompt when contexts equivalent',
        () async {
          final data = await buildSelectionScenario();

          final selection = await conversationService
              .prepareForkContextSelection(data.aiA.id);

          expect(selection.availableContexts.length, greaterThan(1));
          expect(selection.requiresUserSelection, isFalse);
        },
      );

      test(
        'formatInteractionSnippets includes initial context for level 1 nodes',
        () async {
          final data = await buildSelectionScenario();

          final snippets = await conversationService.buildInteractionSnippets(
            existingTree: data.tree,
            nodeIds: [data.aiA.id],
          );

          final formatted = conversationService.formatInteractionSnippets(
            snippets,
          );

          expect(formatted, contains('Initial context:'));
          expect(formatted, contains('Prompt A'));
        },
      );

      test(
        'formatInteractionSnippets does not add initial context for deeper nodes',
        () async {
          final data = await buildSelectionScenario();

          final deeperNode = data.tree.nodes.values.firstWhere(
            (node) => node.messageId != null && node.level > 1,
          );

          final snippets = await conversationService.buildInteractionSnippets(
            existingTree: data.tree,
            nodeIds: [deeperNode.id],
          );

          final formatted = conversationService.formatInteractionSnippets(
            snippets,
          );

          expect(formatted.contains('Initial context:'), isFalse);
        },
      );
    });
  });

  group('handleLoadSkillResult', () {
    late MockDatabaseService mockDb;
    late MockAgentService mockAgentService;
    late MockSkillService mockSkillService;
    late MockMcpService mockMcpService;
    late ConversationService svc;

    setUp(() async {
      await resetForTesting();
      mockDb = MockDatabaseService();
      mockAgentService = MockAgentService();
      mockSkillService = MockSkillService();
      mockMcpService = MockMcpService();
      getIt.registerSingleton<DatabaseService>(mockDb);
      getIt.registerSingleton<AgentService>(mockAgentService);
      getIt.registerSingleton<SkillService>(mockSkillService);
      getIt.registerSingleton<McpService>(mockMcpService);
      // Stub methods needed by enableSkills()
      when(mockSkillService.resetSession()).thenReturn(null);
      when(mockSkillService.buildSkillIndex()).thenAnswer((_) async => {});
      svc = ConversationService.createForTesting(mockDb);
      await svc.enableSkills();
    });

    test('builtin namespace adds McpTool and native tool name; dedup on second call', () async {
      const uri = 'notesynapse://tool/builtin/search_notes';
      when(mockSkillService.extractToolUris(any)).thenReturn([uri]);
      when(mockSkillService.parseToolUri(uri)).thenReturn(
        (namespace: 'builtin', id: 'search_notes', function: null),
      );
      when(mockAgentService.nativeTools).thenReturn([NoteSearchTool()]);

      await svc.handleLoadSkillResult('note-1', 'some skill content');

      expect(svc.skillDiscoveredTools.length, equals(1));
      expect(svc.skillDiscoveredTools.first.name, equals('search_notes'));
      expect(svc.skillDiscoveredNativeToolNames, contains('search_notes'));

      // Second call should not duplicate.
      await svc.handleLoadSkillResult('note-1', 'some skill content');
      expect(svc.skillDiscoveredTools.length, equals(1));
    });

    test('mcp namespace adds tools and populates skillToolEndpointNames', () async {
      const uri = 'notesynapse://tool/mcp/my_service';
      when(mockSkillService.extractToolUris(any)).thenReturn([uri]);
      when(mockSkillService.parseToolUri(uri)).thenReturn(
        (namespace: 'mcp', id: 'my_service', function: null),
      );

      final endpoint = McpEndpoint(
        id: 'ep-1',
        name: 'my_service',
        baseUrl: 'http://localhost:3000',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      final toolA = McpTool(name: 'tool_a', description: 'Tool A');
      when(mockMcpService.getEndpoints()).thenAnswer((_) async => [endpoint]);
      when(mockMcpService.getCachedTools('ep-1')).thenAnswer(
        (_) async => McpToolsCache(
          endpointId: 'ep-1',
          tools: [toolA],
          fetchedAt: DateTime.now(),
        ),
      );

      await svc.handleLoadSkillResult('note-1', 'some skill content');

      expect(svc.skillDiscoveredTools.length, equals(1));
      expect(svc.skillDiscoveredTools.first.name, equals('tool_a'));
      expect(svc.skillToolEndpointNames['tool_a'], equals('my_service'));
    });

    test('unknown namespace does not crash and adds nothing', () async {
      const uri = 'notesynapse://tool/unknown/foo';
      when(mockSkillService.extractToolUris(any)).thenReturn([uri]);
      when(mockSkillService.parseToolUri(uri)).thenReturn(
        (namespace: 'unknown', id: 'foo', function: null),
      );

      await svc.handleLoadSkillResult('note-1', 'some skill content');

      expect(svc.skillDiscoveredTools, isEmpty);
      expect(svc.skillDiscoveredNativeToolNames, isEmpty);
    });
  });
}

class _SelectionTestData {
  final Conversation originalConversation;
  final Conversation forkedConversation;
  final ConversationMessage aiA;
  final ConversationMessage aiB;
  final ConversationMessage aiC;
  final ConversationMessage aiD;
  final ConversationTree tree;

  _SelectionTestData({
    required this.originalConversation,
    required this.forkedConversation,
    required this.aiA,
    required this.aiB,
    required this.aiC,
    required this.aiD,
    required this.tree,
  });
}

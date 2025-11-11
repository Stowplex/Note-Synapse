import 'package:flutter_test/flutter_test.dart';
import 'package:note_synapse/services/ai_service.dart';
import 'package:note_synapse/utils/dedup_suggestion_utils.dart';

void main() {
  group('Dedup suggestion normalization', () {
    const aiResponse = '''
[
  {"leftTag": "AI", "rightTag": "ai"},
  {"leftTag": "AI Generated", "rightTag": "ai"},
  {"leftTag": "ai-summarized", "rightTag": "ai"},
  {"leftTag": "ai_processed", "rightTag": "ai"},
  {"leftTag": "llm", "rightTag": "ai"},
  {"leftTag": "ClonoSEQ", "rightTag": "MRD"},
  {"leftTag": "ALL_protocol", "rightTag": "oncology"},
  {"leftTag": "pediatric ALL", "rightTag": "oncology"},
  {"leftTag": "chemotherapy", "rightTag": "oncology"},
  {"leftTag": "HSCT", "rightTag": "oncology"},
  {"leftTag": "medical", "rightTag": "health"},
  {"leftTag": "Health", "rightTag": "health"},
  {"leftTag": "medical record", "rightTag": "health"},
  {"leftTag": "pharmacy", "rightTag": "health"},
  {"leftTag": "medication", "rightTag": "health"},
  {"leftTag": "medication-schedule", "rightTag": "health"},
  {"leftTag": "treatment", "rightTag": "health"},
  {"leftTag": "treatment_schedule", "rightTag": "health"},
  {"leftTag": "blood pressure", "rightTag": "health"},
  {"leftTag": "weight", "rightTag": "health"},
  {"leftTag": "weightloss", "rightTag": "health"},
  {"leftTag": "cold symptoms", "rightTag": "health"},
  {"leftTag": "exercise", "rightTag": "health"},
  {"leftTag": "PKI security", "rightTag": "PKI"},
  {"leftTag": "certificates", "rightTag": "PKI"},
  {"leftTag": "Root CA rotation", "rightTag": "PKI"},
  {"leftTag": "CA compromise", "rightTag": "PKI"},
  {"leftTag": "certificate pinning", "rightTag": "PKI"},
  {"leftTag": "SSL", "rightTag": "TLS"},
  {"leftTag": "key exchange", "rightTag": "cryptography"},
  {"leftTag": "handshake", "rightTag": "cryptography"},
  {"leftTag": "forward secrecy", "rightTag": "cryptography"},
  {"leftTag": "trust", "rightTag": "cryptography"},
  {"leftTag": "Distributed System", "rightTag": "distributed-system"},
  {"leftTag": "Raft", "rightTag": "distributed-system"},
  {"leftTag": "app development", "rightTag": "development"},
  {"leftTag": "mobile app", "rightTag": "development"},
  {"leftTag": "mobile app ideas", "rightTag": "development"},
  {"leftTag": "alpha project", "rightTag": "development"},
  {"leftTag": "solo developer", "rightTag": "development"},
  {"leftTag": "backlog", "rightTag": "project management"},
  {"leftTag": "status", "rightTag": "project management"},
  {"leftTag": "review", "rightTag": "project management"},
  {"leftTag": "tracking", "rightTag": "project management"},
  {"leftTag": "team meetings", "rightTag": "project management"},
  {"leftTag": "calendar", "rightTag": "project management"},
  {"leftTag": "q1 goals", "rightTag": "project management"},
  {"leftTag": "shipping", "rightTag": "project management"},
  {"leftTag": "pdf", "rightTag": "file"},
  {"leftTag": "download", "rightTag": "file"},
  {"leftTag": "reference:Image Note - 2025-10-26 20:13", "rightTag": "image"},
  {"leftTag": "extracted", "rightTag": "text"},
  {"leftTag": "numbers", "rightTag": "math"},
  {"leftTag": "blue ocean strategy", "rightTag": "blue ocean"},
  {"leftTag": "value innovation", "rightTag": "blue ocean"}
]''';

    final availableTags = <String>{
      'AI',
      'AI Generated',
      'ai-summarized',
      'ai_processed',
      'llm',
      'oncology',
      'ClonoSEQ',
      'MRD',
      'ALL_protocol',
      'pediatric ALL',
      'chemotherapy',
      'HSCT',
      'medical',
      'Health',
      'medical record',
      'pharmacy',
      'medication',
      'medication-schedule',
      'treatment',
      'treatment_schedule',
      'blood pressure',
      'weight',
      'weightloss',
      'cold symptoms',
      'exercise',
      'PKI',
      'PKI security',
      'certificates',
      'Root CA rotation',
      'CA compromise',
      'certificate pinning',
      'TLS',
      'SSL',
      'cryptography',
      'key exchange',
      'handshake',
      'forward secrecy',
      'trust',
      'distributed-system',
      'Distributed System',
      'Raft',
      'development',
      'app development',
      'mobile app',
      'mobile app ideas',
      'alpha project',
      'solo developer',
      'project management',
      'backlog',
      'status',
      'review',
      'tracking',
      'team meetings',
      'calendar',
      'q1 goals',
      'shipping',
      'file',
      'pdf',
      'download',
      'image',
      'reference:Image Note - 2025-10-26 20:13',
      'text',
      'extracted',
      'numbers',
      'math',
      'blue ocean',
      'blue ocean strategy',
      'value innovation',
    }.toList();

    test('AI response contains canonical mismatches', () {
      final suggestions =
          AIService.parseDedupRulesResponseForTest(aiResponse);
      expect(suggestions, isNotEmpty);

      final unmatchedRightTags = suggestions
          .where((rule) => !availableTags.contains(rule.rightTag))
          .map((rule) => rule.rightTag)
          .toSet();

      expect(unmatchedRightTags, contains('ai'));
    });

    test('normalizeSuggestions resolves tags to available taxonomy', () {
      final suggestions =
          AIService.parseDedupRulesResponseForTest(aiResponse);

      final normalized = DedupSuggestionUtils.normalizeSuggestions(
        suggestions,
        availableTags,
      );

      expect(normalized.length, suggestions.length);
      expect(normalized.every(
        (rule) => availableTags.contains(rule.leftTag) &&
            availableTags.contains(rule.rightTag),
      ), isTrue);

      final aiRules =
          normalized.where((rule) => rule.rightTag == 'AI').toList();
      expect(aiRules, isNotEmpty);
      expect(
        aiRules.map((rule) => rule.leftTag),
        containsAll(['AI', 'AI Generated', 'ai-summarized', 'ai_processed', 'llm']),
      );
    });
  });
}


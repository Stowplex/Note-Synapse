import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/mockito.dart';
import 'package:note_synapse/services/database_service.dart';
import 'package:note_synapse/services/skill_service.dart';

class _StubDb extends Mock implements DatabaseService {}

void main() {
  late SkillService svc;

  setUp(() {
    svc = SkillService(_StubDb());
  });

  test('parses default_action as multi-line block scalar (`|`)', () {
    const content = '''---
name: Knowledge Learning
description: Explain concepts on tap
default_action: |
  After your reply, propose up to 5 follow-up explorations.
  Format as fenced chips block, with H2 headings as labels.
---
body text here
''';
    final meta = svc.parseSkillMetadata('note-1', content);
    expect(meta, isNotNull);
    expect(meta!.defaultAction, isNotNull);
    expect(meta.defaultAction, contains('propose up to 5 follow-up'));
    expect(meta.defaultAction, contains('Format as fenced chips block'));
    // The block-scalar continuation must be preserved as multi-line.
    expect(meta.defaultAction!.split('\n').length, greaterThan(1));
  });

  test('defaultAction is null when frontmatter omits the field', () {
    const content = '''---
name: Plain Skill
description: No default action
---
''';
    final meta = svc.parseSkillMetadata('note-2', content);
    expect(meta, isNotNull);
    expect(meta!.defaultAction, isNull);
  });

  test('parses default_action as plain (non-block) inline string', () {
    const content = '''---
name: Quick Skill
description: Test
default_action: After your reply emit chips
---
''';
    final meta = svc.parseSkillMetadata('note-3', content);
    expect(meta!.defaultAction, 'After your reply emit chips');
  });

  test('block scalar terminates at de-indented line (no leading spaces)', () {
    const content = '''---
name: A
description: D
default_action: |
  line one
  line two
name_clash: should-not-appear-in-default-action
---
''';
    final meta = svc.parseSkillMetadata('note-4', content);
    expect(meta!.defaultAction, isNotNull);
    expect(meta.defaultAction, 'line one\nline two');
    expect(meta.defaultAction, isNot(contains('name_clash')));
  });

  test('existing fields (name, description, enabled, skill_ref) still parse correctly with default_action present', () {
    const content = '''---
name: Mixed Skill
description: Has many fields
skill_ref: my-custom-ref
enabled: true
default_action: |
  step 1
  step 2
---
''';
    final meta = svc.parseSkillMetadata('note-5', content);
    expect(meta!.name, 'Mixed Skill');
    expect(meta.description, 'Has many fields');
    expect(meta.skillRef, 'my-custom-ref');
    expect(meta.enabled, true);
    expect(meta.defaultAction, 'step 1\nstep 2');
  });

  test('empty default_action body is treated as null', () {
    const content = '''---
name: A
description: D
default_action:
---
''';
    final meta = svc.parseSkillMetadata('note-6', content);
    expect(meta!.defaultAction, isNull);
  });

  test('REGRESSION: parser still ignores skills with no name or no description', () {
    const noName = '''---
description: D
---
''';
    expect(svc.parseSkillMetadata('x', noName), isNull);

    const noDescription = '''---
name: N
---
''';
    expect(svc.parseSkillMetadata('y', noDescription), isNull);
  });
}

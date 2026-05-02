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
    expect(
      meta!.defaultAction,
      'After your reply, propose up to 5 follow-up explorations.\n'
      'Format as fenced chips block, with H2 headings as labels.',
    );
  });

  test('default_action that is solely a YAML comment is treated as null', () {
    const content = '''---
name: A
description: D
default_action: # currently unused
---
''';
    final meta = svc.parseSkillMetadata('note-c', content);
    expect(meta, isNotNull);
    expect(meta!.defaultAction, isNull);
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

  test('buildDefaultActionPromptSection returns empty string when no skills declare default_action', () {
    final index = <String, SkillMetadata>{
      'a': SkillMetadata(
        noteId: 'a', skillRef: 'a', name: 'A', description: 'd', enabled: true),
    };
    expect(svc.buildDefaultActionPromptSection(index), '');
  });

  test('buildDefaultActionPromptSection returns empty string for empty index', () {
    expect(svc.buildDefaultActionPromptSection(const {}), '');
  });

  test('buildDefaultActionPromptSection concatenates default_action strings ordered by skillRef', () {
    final index = <String, SkillMetadata>{
      'note-z': SkillMetadata(
        noteId: 'note-z', skillRef: 'z-skill',
        name: 'Z', description: 'd', enabled: true,
        defaultAction: 'Z action instructions'),
      'note-a': SkillMetadata(
        noteId: 'note-a', skillRef: 'a-skill',
        name: 'A', description: 'd', enabled: true,
        defaultAction: 'A action instructions'),
      'note-b': SkillMetadata(
        noteId: 'note-b', skillRef: 'b-skill',
        name: 'B', description: 'd', enabled: true),  // no defaultAction
    };
    final out = svc.buildDefaultActionPromptSection(index);
    expect(out, isNotEmpty);
    final aIdx = out.indexOf('A action instructions');
    final zIdx = out.indexOf('Z action instructions');
    expect(aIdx, greaterThan(-1));
    expect(zIdx, greaterThan(-1));
    expect(aIdx, lessThan(zIdx),
        reason: 'Should be ordered alphabetically by skillRef (a < z)');
    expect(out.contains('B'), isFalse,
        reason: 'Skills without defaultAction should be omitted entirely from the section');
    // The output should clearly delimit per-skill sections so the AI can
    // attribute the instructions to a source.
    expect(out, contains('a-skill'));
    expect(out, contains('z-skill'));
  });

  test('buildDefaultActionPromptSection includes a section header so the AI knows the role of the text', () {
    final index = <String, SkillMetadata>{
      'note-x': SkillMetadata(
        noteId: 'note-x', skillRef: 'x-skill',
        name: 'X', description: 'd', enabled: true,
        defaultAction: 'do X'),
    };
    final out = svc.buildDefaultActionPromptSection(index);
    // Section heading exists (matches an `## ` prefix line — markdown H2).
    expect(out, contains(RegExp(r'^## ', multiLine: true)));
  });

  test('buildDefaultActionPromptSection excludes disabled skills (defense in depth)', () {
    // The buildSkillIndex pipeline already filters to enabled skills, but
    // this method has its own guard so callers passing pre-built maps
    // can't accidentally inject disabled-skill text into the system prompt.
    final index = <String, SkillMetadata>{
      'note-on': SkillMetadata(
        noteId: 'note-on', skillRef: 'on-skill',
        name: 'On', description: 'd', enabled: true,
        defaultAction: 'enabled action'),
      'note-off': SkillMetadata(
        noteId: 'note-off', skillRef: 'off-skill',
        name: 'Off', description: 'd', enabled: false,
        defaultAction: 'disabled action'),
    };
    final out = svc.buildDefaultActionPromptSection(index);
    expect(out, contains('enabled action'));
    expect(out, isNot(contains('disabled action')));
  });

  test('buildDefaultActionPromptSection treats whitespace-only defaultAction as null', () {
    final index = <String, SkillMetadata>{
      'note-w': SkillMetadata(
        noteId: 'note-w', skillRef: 'w-skill',
        name: 'W', description: 'd', enabled: true,
        defaultAction: '   \n  \t  '),
    };
    expect(svc.buildDefaultActionPromptSection(index), '');
  });
}

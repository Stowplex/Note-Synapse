import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const here = dirname(fileURLToPath(import.meta.url));
const F = require(join(here, '..', 'plugins', 'src', 'formula_core.js'));

let passed = 0;
let failed = 0;

function check(name, actual, expected) {
  if (JSON.stringify(actual) === JSON.stringify(expected)) {
    passed++;
  } else {
    failed++;
    console.error(`FAIL ${name}\n  expected: ${JSON.stringify(expected)}\n  actual:   ${JSON.stringify(actual)}`);
  }
}

function ok(name, condition) {
  check(name, !!condition, true);
}

{
  const source = 'Inline \\(x+1\\), then\n\n\\[\ny^2\n\\]';
  const units = F.scanFormulas(source);
  check('canonical count', units.length, 2);
  check('inline body', units[0].body, 'x+1');
  check('inline kind', units[0].kind, 'inline');
  check('display body', units[1].body, 'y^2');
  check('display kind', units[1].kind, 'display');
  check('raw round trip', source.slice(units[1].start, units[1].end), units[1].raw);
}

{
  const source = [
    '`\\(inline code\\)`',
    '',
    '```text',
    '\\[fenced\\]',
    '$$also fenced$$',
    '```',
    '',
    '\\(real\\)',
  ].join('\n');
  const units = F.scanFormulas(source);
  check('code ranges skipped', units.map((u) => u.body), ['real']);
}

{
  const source = 'Legacy $$x^2$$ and $y+1$ plus $ 5 $';
  check(
    'whole note only discovers double dollars',
    F.scanFormulas(source).map((u) => u.delimiter),
    ['doubleDollar'],
  );
  check(
    'selected block discovers conservative single dollars',
    F.scanFormulas(source, { legacySingleDollar: true }).map((u) => u.body),
    ['x^2', 'y+1'],
  );
}

{
  const source = String.raw`Price \$5, escaped \\(not math\\), real \(z\)`;
  check('escaped delimiters ignored', F.scanFormulas(source).map((u) => u.body), ['z']);
}

{
  check('unmatched opener ignored', F.scanFormulas('before \\(x after').length, 0);
  check('empty double dollar ignored', F.scanFormulas('$$  $$').length, 0);
}

{
  const source = '\\( x + 1 \\)';
  const unit = F.scanFormulas(source)[0];
  check('canonical padding preserved', F.serializeFormula('y', 'inline', unit), '\\( y \\)');
  check('type conversion canonical', F.serializeFormula('y', 'display', unit), '\\[\ny\n\\]');
  check('empty formula serializes to removal', F.serializeFormula('', 'inline', unit), '');
}

{
  const source = '$x+1$';
  const unit = F.scanFormulas(source, { legacySingleDollar: true })[0];
  check('legacy normalized on save', F.serializeFormula('x+2', 'inline', unit), '\\(x+2\\)');
}

{
  const source = 'A \\(x\\) B';
  const target = F.createTarget(source, F.scanFormulas(source)[0]);
  const shifted = 'prefix\n' + source;
  const found = F.relocateTarget(shifted, target);
  ok('unique formula relocates', found.ok && found.relocated);
  check('relocated offset', found.unit.start, shifted.indexOf('\\(x\\)'));
}

{
  const source = 'left \\(x\\) middle \\(x\\) right';
  const second = F.scanFormulas(source)[1];
  const target = F.createTarget(source, second);
  const shifted = 'new\n' + source;
  const found = F.relocateTarget(shifted, target);
  ok('anchors disambiguate duplicate formula', found.ok);
  check('duplicate target remains second', found.unit.index, 1);
}

{
  const source = '\\(x\\) \\(x\\)';
  const target = F.createTarget(source, F.scanFormulas(source)[0]);
  target.originalOffset = 999;
  target.anchorBefore = '';
  target.anchorAfter = '';
  check('unanchored duplicates rejected', F.relocateTarget(source, target).reason, 'ambiguous');
}

check(
  'display append preserves note',
  F.appendDisplayFormula('paragraph', 'x=1'),
  'paragraph\n\n\\[\nx=1\n\\]',
);

{
  const source = 'A formula \\(x\\) stays in this paragraph.\n\nNext.';
  const unit = F.scanFormulas(source)[0];
  const next = F.replaceWithDisplayBelow(source, unit, '\\(y\\)', 'y=2');
  check(
    'inline result inserts after paragraph',
    next,
    'A formula \\(y\\) stays in this paragraph.\n\n\\[\ny=2\n\\]\n\nNext.',
  );
}

console.log(`Formula core: ${passed} passed, ${failed} failed`);
if (failed) process.exit(1);

import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const here = dirname(fileURLToPath(import.meta.url));
const E = require(join(here, '..', 'plugins', 'src', 'evaluator.js'));
const CE = require(join(
  here,
  '..',
  '..',
  '..',
  'assets',
  'scripts',
  'compute-engine',
  'compute-engine.min.js',
));

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

function ok(name, condition, detail = '') {
  if (condition) {
    passed++;
  } else {
    failed++;
    console.error(`FAIL ${name}${detail ? `\n  ${detail}` : ''}`);
  }
}

check('precision default', E.clampPrecision(null), 10);
check('precision lower bound', E.clampPrecision(1), 3);
check('precision upper bound', E.clampPrecision(100), 50);

{
  const info = E.inspect(CE, 'x^2+\\pi');
  check('variable detection excludes constants', info.variables, ['x']);
  ok('valid expression', info.valid);
}

ok('invalid expression is editable', !E.inspect(CE, '\\frac{').valid);
ok(
  'large expression disables only calculation',
  E.inspect(CE, 'x'.repeat(E.MAX_LATEX_LENGTH + 1)).tooLarge,
);

{
  const result = E.calculate(CE, 'simplify', 'x+x');
  ok('simplify succeeds', result.ok, result.error);
  check('simplify result', result.resultLatex, '2x');
}

{
  const result = E.calculate(CE, 'decimal', '\\sqrt{2}', {}, { precision: 3 });
  ok('decimal succeeds', result.ok, result.error);
  check('decimal respects display precision', result.resultLatex, '1.41');
  ok('decimal uses approximate relation', result.statementLatex.includes('\\approx'));
}

{
  const result = E.calculate(
    CE,
    'substitute',
    'x^2+1',
    { variable: 'x', value: '3' },
  );
  check('substitution result', result.resultLatex, '10');
  ok('substitution statement is self-describing', result.statementLatex.includes('x=3'));
}

check(
  'expand result',
  E.calculate(CE, 'expand', '(x+1)^2').resultLatex,
  'x^2+2x+1',
);
check(
  'factor result',
  E.calculate(CE, 'factor', 'x^2+2x+1').resultLatex,
  '(x+1)^2',
);

{
  const result = E.calculate(CE, 'solve', 'x^2=4', { variable: 'x' });
  ok('solve succeeds', result.ok, result.error);
  check('solve finds two roots', result.resultLatex, '\\left\\{2,-2\\right\\}');
  ok('solve insertion is self-contained', result.statementLatex.includes('\\Longrightarrow'));
}

check(
  'derivative result',
  E.calculate(CE, 'derivative', 'x^3', { variable: 'x' }).resultLatex,
  '3x^2',
);
check(
  'indefinite integral result',
  E.calculate(CE, 'integral', 'x^2', { variable: 'x' }).resultLatex,
  '\\frac{x^3}{3}',
);
check(
  'definite integral result',
  E.calculate(
    CE,
    'definiteIntegral',
    'x^2',
    { variable: 'x', lower: '0', upper: '1' },
  ).resultLatex,
  '\\frac{1}{3}',
);

{
  const result = E.calculate(
    CE,
    'numericIntegral',
    'x^2',
    { variable: 'x', lower: '0', upper: '1' },
    { precision: 5 },
  );
  ok('numeric integral succeeds', result.ok, result.error);
  ok('numeric integral is approximate', result.statementLatex.includes('\\approx'));
}

check(
  'limit result',
  E.calculate(
    CE,
    'limit',
    '\\frac{\\sin x}{x}',
    { variable: 'x', point: '0' },
  ).resultLatex,
  '1',
);

check(
  'degree evaluation',
  E.calculate(CE, 'decimal', '\\sin(30)', {}, { angleUnit: 'degrees' }).resultLatex,
  '0.5',
);

{
  const originalFetch = globalThis.fetch;
  let requests = 0;
  globalThis.fetch = () => {
    requests++;
    throw new Error('network forbidden');
  };
  E.calculate(CE, 'simplify', '(x+x)/2');
  E.calculate(CE, 'limit', '\\frac{\\sin x}{x}', { variable: 'x', point: '0' });
  globalThis.fetch = originalFetch;
  check('supported calculations make no network request', requests, 0);
}

{
  const result = E.calculate(CE, 'not-real', 'x');
  ok('unsupported operation fails without affecting editing', !result.ok && result.editable);
}

console.log(`Formula evaluator: ${passed} passed, ${failed} failed`);
if (failed) process.exit(1);

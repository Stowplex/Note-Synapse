import { createRequire } from 'node:module';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const { chromium } = require('playwright');
const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..', '..', '..');
const plugins = join(here, '..', 'plugins');

function scriptDataUrl(path) {
  return `data:application/javascript;base64,${Buffer.from(
    readFileSync(path),
  ).toString('base64')}`;
}

function harnessHtml(notes) {
  let html = readFileSync(join(plugins, 'formula_studio.html'), 'utf8');
  html = html.replace(
    "script-src 'unsafe-inline' synapse:",
    "script-src 'unsafe-inline' data:",
  );
  html = html.replace(
    '<script src="synapse://mathlive/mathlive.min.js"></script>',
    `<script src="${scriptDataUrl(join(root, 'assets', 'scripts', 'mathlive', 'mathlive.min.js'))}"></script>`,
  );
  html = html.replace(
    '<script src="synapse://compute-engine/compute-engine.min.js"></script>',
    `<script src="${scriptDataUrl(join(root, 'assets', 'scripts', 'compute-engine', 'compute-engine.min.js'))}"></script>`,
  );
  // Browser tests do not have the app's custom scheme handler. MathLive's
  // rendering remains functional with its static fallback while the Flutter
  // tests separately verify packaged WOFF2 responses.
  html = html.replace(
    'MathfieldElement.fontsDirectory = "synapse://mathlive/fonts/";',
    'MathfieldElement.fontsDirectory = null;',
  );

  for (const name of ['formula_core.js', 'evaluator.js', 'writeback.js', 'i18n.js']) {
    html = html.replace(
      `<script src="src/${name}"></script>`,
      `<script src="${scriptDataUrl(join(plugins, 'src', name))}"></script>`,
    );
  }

  const stub = `
    window.__storedContent = ${JSON.stringify(notes[0]?.content ?? '')};
    window.__writes = [];
    window.__networkCalls = [];
    window.Synapse = {
      Notes: ${JSON.stringify(notes)},
      Params: {},
      loadAppState: async function () { return { success: true, data: null }; },
      storeAppState: async function () { return { success: true }; },
      runQuery: async function (sql) {
        var idMatch = /id\\s*=\\s*'([^']+)'/i.exec(sql);
        var id = idMatch ? idMatch[1].replace(/''/g, "'") : '';
        var note = this.Notes.find(function (item) { return item.id === id; });
        var content = note && note.id !== this.Notes[0].id
          ? note.content
          : window.__storedContent;
        return { success: true, data: [{ content: content }] };
      },
      updateNotes: async function (requests) {
        window.__writes.push(requests);
        window.__storedContent = requests[0].modification.content.text;
        return { success: true, updatedCount: 1 };
      }
    };
  `;
  html = html.replace(
    '<script src="src/ui.js"></script>',
    `<script>${stub}</script><script src="${scriptDataUrl(join(plugins, 'src', 'ui.js'))}"></script>`,
  );
  return html;
}

let passed = 0;
let failed = 0;

async function scenario(browser, name, notes, run) {
  const page = await browser.newPage({ viewport: { width: 390, height: 844 } });
  const externalRequests = [];
  const pageErrors = [];
  page.on('request', (request) => {
    if (/^https?:/i.test(request.url())) externalRequests.push(request.url());
  });
  page.on('pageerror', (error) => pageErrors.push(error.message));
  try {
    await page.setContent(harnessHtml(notes), { waitUntil: 'load' });
    await page.waitForFunction(
      () => !!window.FormulaCore && !!window.MathfieldElement,
      undefined,
      { timeout: 10000 },
    );
    await run(page);
    if (process.env.FORMULA_STUDIO_SCREENSHOT &&
        name.startsWith('whole note picker')) {
      await page.screenshot({
        path: process.env.FORMULA_STUDIO_SCREENSHOT,
        fullPage: true,
      });
    }
    if (pageErrors.length) {
      throw new Error(`page errors: ${pageErrors.join(' | ')}`);
    }
    if (externalRequests.length) {
      throw new Error(`unexpected network requests: ${externalRequests.join(', ')}`);
    }
    passed++;
    console.log(`PASS ${name}`);
  } catch (error) {
    failed++;
    const diagnostics = pageErrors.length ? `\n  page errors: ${pageErrors.join(' | ')}` : '';
    console.error(`FAIL ${name}\n  ${error.stack || error}${diagnostics}`);
  } finally {
    await page.close();
  }
}

const localChrome = [
  process.env.FORMULA_STUDIO_CHROME,
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/Applications/Chromium.app/Contents/MacOS/Chromium',
].find((path) => path && existsSync(path));
const browser = await chromium.launch({
  headless: true,
  ...(localChrome ? { executablePath: localChrome } : {}),
});

await scenario(
  browser,
  'whole note picker, calculation preview, apply, and one save',
  [{
    id: 'whole-1',
    title: 'Algebra',
    content: 'Intro \\(x+x\\)\\n\\n\\[\\ny^2\\n\\]',
    tags: [],
  }],
  async (page) => {
    await page.locator('#formulaPicker:not(.hidden)').waitFor();
    await page.locator('#formulaList .list-button').first().click();
    await page.locator('#editorScreen:not(.hidden)').waitFor();
    const initial = await page.locator('#formulaField').evaluate((field) => field.value);
    if (initial !== 'x+x') throw new Error(`unexpected initial formula: ${initial}`);

    await page.locator('[data-action="simplify"]').click();
    await page.locator('#resultPanel:not(.hidden)').waitFor();
    const preview = await page.locator('#resultField').evaluate((field) => field.value);
    if (!preview.includes('2x')) throw new Error(`unexpected calculation preview: ${preview}`);

    await page.locator('#appendResult').click();
    await page.locator('#saveButton').click();
    await page.waitForFunction(() => window.__writes.length === 1);
    const stored = await page.evaluate(() => window.__storedContent);
    if (!stored.includes('\\(x+x=2x\\)')) throw new Error(`formula was not saved: ${stored}`);
  },
);

await scenario(
  browser,
  'selected blank block creates a display formula',
  [{
    id: 'block-empty',
    parentNoteId: 'parent-1',
    isBlockScope: true,
    title: 'Geometry',
    content: '',
    tags: [],
  }],
  async (page) => {
    await page.locator('#editorScreen:not(.hidden)').waitFor();
    await page.locator('#formulaField').evaluate((field) => {
      field.value = 'a^2+b^2=c^2';
      field.dispatchEvent(new Event('input', { bubbles: true }));
    });
    await page.locator('#saveButton').click();
    await page.waitForFunction(() => window.__writes.length === 1);
    const stored = await page.evaluate(() => window.__storedContent);
    if (stored !== '\\[\na^2+b^2=c^2\n\\]') {
      throw new Error(`unexpected blank-block insertion: ${stored}`);
    }
  },
);

await scenario(
  browser,
  'multiple notes require a note choice',
  [
    { id: 'n1', title: 'First', content: '\\(a\\)', tags: [] },
    { id: 'n2', title: 'Second', content: '\\(b\\)', tags: [] },
  ],
  async (page) => {
    await page.locator('#notePicker:not(.hidden)').waitFor();
    const buttons = page.locator('#noteList .list-button');
    if (await buttons.count() !== 2) throw new Error('expected two note choices');
    await buttons.nth(1).click();
    await page.locator('#formulaPicker:not(.hidden)').waitFor();
    if (await page.locator('#noteTitle').textContent() !== 'Second') {
      throw new Error('second note was not selected');
    }
  },
);

await scenario(
  browser,
  'legacy selected-block formula is normalized only on save',
  [{
    id: 'block-legacy',
    parentNoteId: 'parent-2',
    isBlockScope: true,
    title: 'Legacy',
    content: '$x+1$',
    tags: [],
  }],
  async (page) => {
    await page.locator('#legacyNotice:not(.hidden)').waitFor();
    const before = await page.evaluate(() => window.__storedContent);
    if (before !== '$x+1$') throw new Error('opening the app rewrote the formula');
    await page.locator('#formulaField').evaluate((field) => {
      field.value = 'x+2';
      field.dispatchEvent(new Event('input', { bubbles: true }));
    });
    await page.locator('#saveButton').click();
    await page.waitForFunction(() => window.__writes.length === 1);
    const stored = await page.evaluate(() => window.__storedContent);
    if (stored !== '\\(x+2\\)') throw new Error(`legacy formula was not normalized: ${stored}`);
  },
);

await scenario(
  browser,
  'removing the only whole-note formula is explicit and can clear content',
  [{
    id: 'whole-remove',
    title: 'Remove',
    content: '\\[x\\]',
    tags: [],
  }],
  async (page) => {
    await page.locator('#formulaPicker:not(.hidden)').waitFor();
    await page.locator('#formulaList .list-button').click();
    await page.locator('#formulaField').evaluate((field) => {
      field.value = '';
      field.dispatchEvent(new Event('input', { bubbles: true }));
    });
    page.once('dialog', (dialog) => dialog.accept());
    await page.locator('#saveButton').click();
    await page.waitForFunction(() => window.__writes.length === 1);
    const stored = await page.evaluate(() => window.__storedContent);
    if (stored !== '') throw new Error(`formula removal did not clear the note: ${stored}`);
  },
);

await browser.close();
console.log(`Formula UI: ${passed} passed, ${failed} failed`);
if (failed) process.exit(1);

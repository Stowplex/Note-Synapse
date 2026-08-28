/*
 * Cartograph assertions. Runs in node (`node dev/spec.js`) and in the browser
 * (dev/auto_smoke.html). Pure modules only - no DOM.
 */
(function (global) {
  'use strict';
  var CG = global.CG;
  var md = CG.md, edit = CG.edit, sidecar = CG.sidecar, layout = CG.layout, view = CG.view;

  var results = [];
  function ok(name, cond, detail) { results.push({ name: name, pass: !!cond, detail: cond ? '' : (detail || '') }); }
  function eq(name, actual, expected) {
    var pass = actual === expected;
    ok(name, pass, pass ? '' : '\n--- expected ---\n' + expected + '\n--- actual ---\n' + actual + '\n---');
  }

  var FIXTURES = global.CG_FIXTURES || {};

  function run() {
    results = [];

    /* ---------------- parse fidelity ---------------- */
    Object.keys(FIXTURES).forEach(function (name) {
      var doc = md.parse(FIXTURES[name], { title: name });
      var problems = md.coverage(doc);
      ok('coverage: ' + name, problems.length === 0, problems.join('; '));
    });

    var mixed = FIXTURES['mixed.md'] || '';
    var doc = md.parse(mixed, { title: 'Release notes' });

    ok('lazy continuation folds into the bullet',
      !!doc.nodes.filter(function (n) { return n.text === 'A bullet that wraps onto a lazy second line'; }).length,
      doc.nodes.map(function (n) { return n.text; }).join(' | '));

    var engine = doc.nodes.filter(function (n) { return n.text === 'Engine'; })[0];
    ok('prose, code, table and quote attach as body', engine && engine.body.length >= 4,
      engine ? 'body=' + engine.body.length : 'no Engine node');

    var linkNode = doc.nodes.filter(function (n) { return /the script/.test(n.text); })[0];
    ok('note link is recognised', linkNode && linkNode.links.some(function (l) { return l.type === 'note' && l.noteId === 'mock-note-2'; }));

    var anchorNode = doc.nodes.filter(function (n) { return /Compare with/.test(n.text); })[0];
    ok('anchor link is recognised', anchorNode && anchorNode.links.some(function (l) { return l.type === 'anchor'; }));

    /* ---------------- edits are surgical ---------------- */
    var d = md.parse(mixed);
    var faster = d.nodes.filter(function (n) { return n.text === 'Faster parse'; })[0];
    var after = edit.setText(d, faster, 'Much faster parse');
    eq('rename touches only that label', after, mixed.replace('- Faster parse', '- Much faster parse'));
    ok('code fence survives a rename', after.indexOf('// this fence must survive every edit') >= 0);

    d = md.parse(after);
    var lower = d.nodes.filter(function (n) { return n.text === 'Lower memory'; })[0];
    var removed = edit.remove(d, lower);
    ok('delete removes exactly one bullet', removed.indexOf('- Lower memory') < 0 && removed.indexOf('- Much faster parse') >= 0);
    ok('delete keeps the fence', removed.indexOf('const x = 1;') >= 0);
    ok('delete leaves no triple blank line', !/\n{3,}/.test(removed), JSON.stringify(removed.slice(0, 400)));

    /* ---------------- ordered list renumbering ---------------- */
    var b = md.parse(FIXTURES['plan.md']);
    var sync = b.nodes.filter(function (n) { return n.text === 'Sync engine'; })[0];
    var out = edit.remove(b, sync);
    out = edit.renumber(md.parse(out));
    ok('ordered list renumbers after a delete',
      /1\. API surface\n2\. Offline cache/.test(out), out.slice(out.indexOf('## Build'), out.indexOf('## Launch')));

    /* ---------------- insertion ---------------- */
    b = md.parse(FIXTURES['plan.md']);
    var design = b.nodes.filter(function (n) { return n.text === 'Design'; })[0];
    out = edit.insertChild(b, design, { text: 'Spacing scale' });
    ok('new child adopts the sibling marker and lands last in the branch',
      /- \[ \] Motion study\n- \[ \] Spacing scale/.test(out) || /- \[ \] Motion study\n- Spacing scale/.test(out),
      out.slice(out.indexOf('## Design'), out.indexOf('## Build')));

    b = md.parse(FIXTURES['bullets.md']);
    var alphaOne = b.nodes.filter(function (n) { return n.text === 'Alpha one'; })[0];
    out = edit.insertSibling(b, alphaOne, { text: 'Alpha one and a half' });
    ok('new sibling keeps the nesting indent',
      /  - Alpha one\n  - Alpha one and a half\n  - Alpha two/.test(out), out);

    /* ---------------- move / indent / outdent ---------------- */
    b = md.parse(FIXTURES['bullets.md']);
    var beta = b.nodes.filter(function (n) { return n.text === 'Beta'; })[0];
    var alpha = b.nodes.filter(function (n) { return n.text === 'Alpha'; })[0];
    var mv = edit.move(b, beta, alpha, null);
    ok('move re-indents the whole subtree', !mv.error && /  - Beta\n    1\. Beta one\n    2\. Beta two/.test(mv.src), mv.error || mv.src);

    b = md.parse(FIXTURES['bullets.md']);
    var g = b.nodes.filter(function (n) { return n.text === 'Gamma'; })[0];
    var a2 = b.nodes.filter(function (n) { return n.text === 'Alpha'; })[0];
    mv = edit.move(b, g, b.root, { before: a2 });
    ok('move-before puts it first', !mv.error && /^- Gamma\n- Alpha/.test(mv.src), mv.error || mv.src);

    b = md.parse(FIXTURES['plan.md']);
    var disc = b.nodes.filter(function (n) { return n.text === 'Discovery'; })[0];
    var ci = b.nodes.filter(function (n) { return n.text === 'Customer interviews'; })[0];
    // Deliberately a bullet in a DIFFERENT branch. The v1 test used one nested
    // inside `disc`, so it was really testing the own-branch rule.
    var farBullet = b.nodes.filter(function (n) { return n.text === 'Wireframes'; })[0];
    ok('a section moving under a bullet elsewhere is allowed, and converts',
      edit.canMove(disc, farBullet) === null && edit.willChangeKind(disc, farBullet) === true,
      JSON.stringify(edit.canMove(disc, farBullet)));
    ok('a bullet inside the branch being moved is still refused', edit.canMove(disc, ci) !== null);
    ok('a node may not move into its own branch', edit.canMove(disc, b.nodes.filter(function (n) { return n.text === 'Recruit 8 users'; })[0]) !== null);

    var build = b.nodes.filter(function (n) { return n.text === 'Build'; })[0];
    mv = edit.move(b, build, disc, null);
    ok('heading demotion rewrites its own level', !mv.error && /### Build/.test(mv.src), mv.error || mv.src);

    /* ---------------- move to a different parent ---------------- */
    var MV = '# Plan\n\n## Design\n- Colors\n  - Palette\n- Type\n\n## Build\n- API\n- DB\n';
    function mvDoc() {
      var d3 = md.parse(MV);
      return { doc: d3, n: function (t) { return d3.nodes.filter(function (x) { return x.text === t; })[0]; } };
    }

    var m = mvDoc();
    var mr = edit.move(m.doc, m.n('Build'), m.n('Colors'), null);
    ok('a section moved under a bullet becomes bullets, nested correctly',
      !mr.error && /- Colors\n  - Palette\n  - Build\n    - API\n    - DB/.test(mr.src),
      mr.error || mr.src);
    ok('no heading survives that conversion', !/#+ Build/.test(mr.src), mr.src);
    ok('the converted note still parses cleanly', md.coverage(md.parse(mr.src)).length === 0);

    m = mvDoc();
    mr = edit.move(m.doc, m.n('API'), m.n('Design'), null);
    ok('a bullet moved under a section lands at the top level of it',
      !mr.error && /## Design[\s\S]*\n- API\n/.test(mr.src), mr.error || mr.src);

    m = mvDoc();
    mr = edit.move(m.doc, m.n('Type'), m.n('Colors'), null);
    ok('a same-kind move still takes the fast path and only shifts indent',
      !mr.error && /  - Palette\n  - Type/.test(mr.src), mr.error || mr.src);

    m = mvDoc();
    mr = edit.moveMany(m.doc, [m.n('API'), m.n('DB')], m.n('Design'));
    ok('several nodes move together, keeping document order',
      !mr.error && /- Type\n- API\n- DB/.test(mr.src), mr.error || mr.src);
    ok('a multi-move empties the branch they left', /## Build\s*$/.test(mr.src), JSON.stringify(mr.src.slice(-40)));

    m = mvDoc();
    mr = edit.moveMany(m.doc, [m.n('Colors'), m.n('Palette')], m.n('Build'));
    ok('a node selected inside another selected node is not moved twice',
      !mr.error && (mr.src.match(/Palette/g) || []).length === 1, mr.error || mr.src);
    ok('and it still arrives nested under its own parent',
      /- Colors\n  - Palette/.test(mr.src), mr.src);

    m = mvDoc();
    ok('a node cannot be moved inside its own branch',
      edit.moveMany(m.doc, [m.n('Colors')], m.n('Palette')).error !== null);
    m = mvDoc();
    ok('moving a node where it already lives is refused, not applied as a no-op',
      edit.moveMany(m.doc, [m.n('API')], m.n('Build')).error !== null);

    m = mvDoc();
    mr = edit.moveMany(m.doc, [m.n('DB')], m.n('Design'));
    ok('moving a branch\'s last child does not corrupt the insertion point',
      !mr.error && /- Type\n- DB/.test(mr.src) && /## Build\n- API/.test(mr.src), mr.error || mr.src);

    m = mvDoc();
    mr = edit.moveMany(m.doc, [m.n('Type')], m.n('Build'));
    ok('everything not involved in a move is left exactly as it was',
      mr.src.indexOf('- Colors\n  - Palette') >= 0 && mr.src.indexOf('- API\n- DB\n- Type') >= 0,
      mr.src);
    ok('a move leaves the document parseable', md.coverage(md.parse(mr.src)).length === 0);

    m = mvDoc();
    mr = edit.moveMany(m.doc, [m.n('Colors')], m.doc.root);
    ok('a node can be moved out to the top level',
      !mr.error && /\n- Colors\n  - Palette/.test(mr.src), mr.error || mr.src);

    /* ---------------- checkboxes ---------------- */
    b = md.parse(FIXTURES['plan.md']);
    var vis = b.nodes.filter(function (n) { return n.text === 'Visual language'; })[0];
    out = edit.setChecked(b, vis, true);
    ok('checkbox toggles in place', out.indexOf('- [x] Visual language') >= 0);
    b = md.parse(out);
    vis = b.nodes.filter(function (n) { return n.text === 'Visual language'; })[0];
    out = edit.clearChecked(b, vis);
    ok('checkbox can be removed', out.indexOf('- Visual language') >= 0 && out.indexOf('- [x] Visual language') < 0);

    /* ---------------- sidecar ---------------- */
    b = md.parse(FIXTURES['plan.md']);
    var st = { pins: {}, collapsed: {} };
    var colour = b.nodes.filter(function (n) { return n.text === 'Colour and type'; })[0];
    var launch = b.nodes.filter(function (n) { return n.text === 'Launch'; })[0];
    st.pins[colour.id] = { x: 380, y: -120 };
    st.collapsed[launch.id] = true;
    var seeded = edit.writeSidecar(b, sidecar.build(b, st));
    ok('sidecar is a single fenced block', (seeded.match(/```synapse-cartograph/g) || []).length === 1);
    ok('sidecar block is compact', seeded.split('```synapse-cartograph')[1].split('```')[0].trim().split('\n').length === 1);

    var reparsed = md.parse(seeded);
    ok('sidecar coverage stays clean', md.coverage(reparsed).length === 0);
    var st2 = { pins: {}, collapsed: {} };
    sidecar.apply(reparsed, st2);
    var c2 = reparsed.nodes.filter(function (n) { return n.text === 'Colour and type'; })[0];
    ok('pin survives a round trip', !!st2.pins[c2.id]);

    function afterOutsideEdit(mutate) {
      var doc2 = md.parse(mutate(seeded));
      var s3 = { pins: {}, collapsed: {} };
      sidecar.apply(doc2, s3);
      return { doc: doc2, state: s3 };
    }
    var r1 = afterOutsideEdit(function (s) { return s.replace('  - Colour and type', '  - Colour & type'); });
    var t1 = r1.doc.nodes.filter(function (n) { return n.text === 'Colour & type'; })[0];
    ok('pin survives a rename', !!r1.state.pins[t1.id]);

    var r2 = afterOutsideEdit(function (s) { return s.replace('## Discovery', '## Research\n- New first item\n\n## Discovery'); });
    var t2 = r2.doc.nodes.filter(function (n) { return n.text === 'Colour and type'; })[0];
    ok('pin survives an inserted section', !!r2.state.pins[t2.id]);

    var r3 = afterOutsideEdit(function (s) { return s.replace(/\{"v":1.*\}/, '{ this is not json'); });
    ok('a mangled sidecar is ignored, not fatal', Object.keys(r3.state.pins).length === 0 && r3.doc.nodes.length > 5);

    var noSidecar = md.parse(FIXTURES['plan.md']);
    var s4 = { pins: {}, collapsed: {} };
    sidecar.apply(noSidecar, s4);
    ok('a missing sidecar is fine', Object.keys(s4.pins).length === 0);

    b = md.parse(seeded);
    var cleared = edit.writeSidecar(b, sidecar.build(b, { pins: {}, collapsed: {} }));
    ok('no pins means no block at all', cleared.indexOf('synapse-cartograph') < 0 && !/\n{3,}$/.test(cleared));

    /* ---------------- view tree ---------------- */
    var vdoc = md.parse(FIXTURES['plan.md'], { title: 'Product plan' });
    var vt = view.build(vdoc, { title: 'Product plan', noteCache: {}, collapsed: {} });
    var vDesign = vt.all.filter(function (v) { return v.text === 'Design'; })[0];
    ok('task rollup counts the branch', vDesign && vDesign.taskDone === 1 && vDesign.taskTotal === 3,
      vDesign ? vDesign.taskDone + '/' + vDesign.taskTotal : 'no Design');

    var mdoc = md.parse(mixed, { title: 'Release notes' });
    var mvt = view.build(mdoc, { title: 'Release notes', noteCache: { 'mock-note-2': { title: 'Interview script', content: '## Warm up\n- Tell me about your week.' } } });
    ok('an attached note becomes a card', mvt.all.some(function (v) { return v.kind === 'note' && v.noteTitle === 'Interview script'; }));
    ok('the card carries a preview', mvt.all.some(function (v) { return v.kind === 'note' && v.notePreview.indexOf('Warm up') >= 0; }));
    ok('preview drops list markers', !mvt.all.some(function (v) { return /^- /.test(v.notePreview); }));
    ok('an anchor link becomes a cross link', mvt.crossLinks.length === 1, JSON.stringify(mvt.crossLinks));

    var svt = view.build(vdoc, { title: 'Product plan', query: 'sync', noteCache: {} });
    var kept = svt.all.filter(function (v) { return v.keep; }).map(function (v) { return v.text; });
    ok('search keeps only the path to a match', kept.indexOf('Sync engine') >= 0 && kept.indexOf('Beta cohort') < 0, kept.join(','));

    var fvt = view.build(vdoc, { title: 'Product plan', filters: { status: 'todo' }, noteCache: {} });
    var fkept = fvt.all.filter(function (v) { return v.matched; }).map(function (v) { return v.text; });
    ok('the to-do filter selects unchecked tasks only',
      fkept.length === 2 && fkept.indexOf('Wireframes') < 0, fkept.join(','));

    /* ---------------- layout ---------------- */
    var sizeOf = function (v) { return { w: Math.min(210, 44 + (v.text || 'root').length * 7), h: 34 }; };
    var lvt = view.build(vdoc, { title: 'Product plan', noteCache: {} });
    var res = layout.compute(lvt.root, { sizeOf: sizeOf });
    ok('no two boxes overlap', layout.overlaps(res).length === 0, JSON.stringify(layout.overlaps(res).slice(0, 3)));
    ok('branches are split across both sides', res.sides.left.length > 0 && res.sides.right.length > 0,
      'L=' + res.sides.left.length + ' R=' + res.sides.right.length);
    ok('a single H1 becomes the visual centre', layout.displayRoot(vdoc.root).text === 'Product plan');

    var pinTarget = lvt.all.filter(function (v) { return v.text === 'Colour and type'; })[0];
    var pres = layout.compute(lvt.root, { sizeOf: sizeOf, pinOf: function (v) { return v.id === pinTarget.id ? { x: 640, y: -260 } : null; } });
    var pbox = pres.boxes.get(pinTarget.id);
    ok('a pinned node sits exactly at its pin', Math.round(pbox.x) === 640 && Math.round(pbox.y + pbox.h / 2) === -260,
      pbox ? pbox.x + ',' + (pbox.y + pbox.h / 2) : 'missing');
    ok('flowed branches are pushed clear of a pin', layout.overlaps(pres).length === 0,
      JSON.stringify(layout.overlaps(pres).slice(0, 3)));

    var bvt = view.build(md.parse(FIXTURES['bullets.md'], { title: 'Bullets' }), { title: 'Bullets', noteCache: {} });
    var bres = layout.compute(bvt.root, { sizeOf: sizeOf });
    ok('a note with no headings still lays out', bres.boxes.size > 5 && layout.overlaps(bres).length === 0);

    var evt = view.build(md.parse(FIXTURES['empty.md'], { title: 'Empty' }), { title: 'Empty', noteCache: {} });
    var eres = layout.compute(evt.root, { sizeOf: sizeOf });
    ok('an empty note does not explode', eres.boxes.size === 1);

    /* ---------------- import: reshaping a foreign outline ---------------- */
    var HOST_MD = '# Plan\n\n## Design\n- Colors\n';
    var FOREIGN = '# Research\n\nIntro para.\n\n## Interviews\n- Recruit users\n  - Screener\n- Script\n';

    b = md.parse(HOST_MD);
    var gr = edit.graft(b, b.nodes.filter(function (n) { return n.text === 'Design'; })[0], FOREIGN);
    ok('import under a section keeps headings as headings',
      /### Research/.test(gr.src) && /#### Interviews/.test(gr.src), gr.src);
    ok('import carries the body text across', gr.src.indexOf('Intro para.') >= 0, gr.src);
    ok('the grafted note still parses cleanly', md.coverage(md.parse(gr.src)).length === 0);

    b = md.parse(HOST_MD);
    gr = edit.graft(b, b.nodes.filter(function (n) { return n.text === 'Colors'; })[0], FOREIGN);
    ok('import under a bullet becomes bullets, never headings',
      gr.src.indexOf('# Research') < 0 && /  - Research/.test(gr.src) && /    - Interviews/.test(gr.src), gr.src);
    ok('nesting depth is preserved under a bullet', /        - Screener/.test(gr.src), gr.src);

    b = md.parse('# a\n## b\n### c\n#### d\n##### e\n###### f\n');
    gr = edit.graft(b, b.nodes.filter(function (n) { return n.text === 'f'; })[0], FOREIGN);
    ok('an import that would pass ###### turns into bullets, not a flattened row',
      /- Research/.test(gr.src) && /  - Interviews/.test(gr.src) && !/#######/.test(gr.src),
      gr.src.split('###### f')[1]);

    b = md.parse('# Host\n');
    gr = edit.graft(b, b.root, '# Steps\n\n1. First\n2. Second\n\n- [ ] todo\n- [x] done\n');
    ok('import keeps ordered markers and checkboxes',
      /1\. First/.test(gr.src) && /- \[ \] todo/.test(gr.src) && /- \[x\] done/.test(gr.src), gr.src);

    b = md.parse(HOST_MD);
    gr = edit.graft(b, b.root, '');
    ok('importing an empty note is refused, not silently applied', !!gr.error);

    /* ---------------- diff classification ---------------- */
    function branchOf(src2, label) {
      var d2 = md.parse(src2);
      return { doc: d2, node: d2.nodes.filter(function (n) { return n.text === label; })[0] };
    }
    var A = branchOf('# P\n## Build\n- API design\n- API docs\n- Database schema\n- Caching layer\n', 'Build');
    var B = branchOf('# P\n## Build\n- API design and docs\n- Storage\n  - Database schema\n  - Caching layer\n', 'Build');
    var cls = CG.diff.classify(A.node, B.node);
    ok('a merged node is reported as merged, not deleted',
      Object.keys(cls.byOld).some(function (k) {
        return cls.byOld[k].from.text === 'API docs' && cls.byOld[k].state === 'merged';
      }), JSON.stringify(cls.summary));
    ok('a rename is reported as a rename', cls.summary.renamed === 1, JSON.stringify(cls.summary));
    ok('re-parented leaves are reported as moved', cls.summary.moved === 2, JSON.stringify(cls.summary));
    ok('a new grouping node is reported as added', cls.summary.added === 1, JSON.stringify(cls.summary));

    var same = branchOf('# P\n## Build\n- API\n- DB\n', 'Build');
    var same2 = branchOf('# P\n## Build\n- API\n- DB\n', 'Build');
    var cls2 = CG.diff.classify(same.node, same2.node);
    ok('an identical branch reports no change', cls2.summary.touched === 0, JSON.stringify(cls2.summary));
    ok('describe says so in words', CG.diff.describe(cls2.summary) === 'Nothing would change.');

    var del = branchOf('# P\n## Build\n- API\n', 'Build');
    var cls3 = CG.diff.classify(same.node, del.node);
    ok('a real deletion is reported as removed, not merged', cls3.summary.removed === 1 && cls3.summary.merged === 0,
      JSON.stringify(cls3.summary));

    /* ---------------- what the AI is allowed to hand back ---------------- */
    var AIM = CG.ai;
    ok('a fenced answer is unwrapped',
      AIM.sanitizeOutline('```markdown\n# Plan\n## A\n- one\n```', 'T') === '# Plan\n## A\n- one');
    ok('chat around the outline is trimmed',
      AIM.sanitizeOutline('Sure! Here it is:\n\n# Plan\n- one\n\nLet me know!', 'T') === '# Plan\n- one');
    ok('a missing centre is supplied from the note title',
      AIM.sanitizeOutline('## A\n- one', 'My note').indexOf('# My note') === 0);
    ok('several centres are demoted so exactly one remains',
      (AIM.sanitizeOutline('# A\n- one\n# B\n- two', 'T').match(/^#[ \t]+\S/gm) || []).length === 1,
      AIM.sanitizeOutline('# A\n- one\n# B\n- two', 'T'));
    ok('an empty answer yields nothing, not a broken outline', AIM.sanitizeOutline('', 'T') === '');
    ok('an answer with no structure at all yields nothing',
      AIM.sanitizeOutline('I could not find any structure here.', 'T') === '');
    ok('prose between nodes is left alone, being legitimate body',
      AIM.strip('# A\n\nSome body text.\n\n- one').indexOf('Some body text.') >= 0);

    /* ---------------- chunking a long note ---------------- */
    var long = '# Big\n\n' + ['Alpha', 'Beta', 'Gamma', 'Delta'].map(function (h) {
      return '## ' + h + '\n' + new Array(400).join('word ') + '\n';
    }).join('\n');
    var secs = AIM.splitSections(long, 1200);
    ok('a long note is split on its own headings', secs.length > 1, 'sections=' + secs.length);
    ok('no section is silently dropped',
      secs.map(function (x) { return x.text; }).join('\n').indexOf('Delta') >= 0);
    ok('a short note is not split', AIM.splitSections('# A\n- one\n', 1200).length === 1);

    var fenced = '# A\n\n```\n## not a heading\n```\n\n## Real\n- x\n';
    ok('a heading inside a code fence is not a split point',
      AIM.splitSections(fenced, 20).every(function (x) { return x.text.indexOf('```') !== 0; }));

    var joined = AIM.joinSections(['## One\n- a', '# Two\n- b'], 'Whole');
    ok('joined sections sit under a single centre',
      (joined.match(/^#[ \t]+\S/gm) || []).length === 1 &&
      /^## One/m.test(joined) && /^## Two/m.test(joined), joined);

    /* ---------------- the companion link ---------------- */
    var link = CG.host.mapLink('abc-123', 'x');
    ok('a map link carries the marker that makes it findable', link.indexOf('?via=cartograph') > 0, link);
    ok('the map id can be read back out of a note', CG.host.mapIdIn('body\n\n' + link) === 'abc-123');
    ok('an ordinary note link is not mistaken for a map link',
      CG.host.mapIdIn('[Other](synapseresource://note/zzz)') === null);
    ok('a map link parses as an ordinary node link too',
      md.parse('- see ' + link).nodes.filter(function (n) { return n.links.length; }).length === 1);

    return results;
  }

  CG.spec = { run: run };
  if (typeof module !== 'undefined' && module.exports) module.exports = CG.spec;
})(typeof window !== 'undefined' ? window : globalThis);

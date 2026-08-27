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
    ok('a section may not nest inside a bullet', edit.canMove(disc, ci) !== null);
    ok('a node may not move into its own branch', edit.canMove(disc, b.nodes.filter(function (n) { return n.text === 'Recruit 8 users'; })[0]) !== null);

    var build = b.nodes.filter(function (n) { return n.text === 'Build'; })[0];
    mv = edit.move(b, build, disc, null);
    ok('heading demotion rewrites its own level', !mv.error && /### Build/.test(mv.src), mv.error || mv.src);

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

    return results;
  }

  CG.spec = { run: run };
  if (typeof module !== 'undefined' && module.exports) module.exports = CG.spec;
})(typeof window !== 'undefined' ? window : globalThis);

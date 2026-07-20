/*
 * Table Studio ↔ Univer bridge — pure data logic shared by the plugin UI
 * and the offline test suite (dev/run_core_tests.mjs). No DOM, no Synapse
 * calls, no Univer runtime: everything here works on plain snapshot data
 * (IWorkbookData fragments) and SheetJS worksheet objects, so it can run
 * under node.
 *
 * Covers:
 *   - the pinned Univer engine manifest (versions, mirrors, sha256)
 *   - converting string grids / SheetJS worksheets into Univer sheet data
 *   - reading Univer snapshots back into grids / SheetJS worksheets
 *   - normalized per-sheet diffs (dirty detection + cell-level patching)
 *   - classifying Univer mutations as structural vs cell edits
 */
(function (root, factory) {
  var bridge = factory();
  if (typeof module === 'object' && module.exports) {
    module.exports = bridge;
  }
  if (root) {
    root.UniverBridge = bridge;
  }
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  // ---------------------------------------------------------------------
  // Engine manifest
  //
  // Every file is pinned by exact version AND sha256 of the published npm
  // bytes, verified after download from either mirror. Bump `version`
  // whenever this list changes so cached engines re-download.
  // ---------------------------------------------------------------------
  var MIRRORS = [
    'https://cdn.jsdelivr.net/npm/',
    'https://unpkg.com/',
  ];

  // Injection order matters: react before react-dom, presets before the
  // preset packages (validated by the boot harness).
  var ENGINE = {
    version: 'univer-0.25.1-r1',
    js: [
      { name: 'react', path: 'react@18.3.1/umd/react.production.min.js', bytes: 10751, sha256: 'd949f1c3687aedadcedac85261865f29b17cd273997e7f6b2bfc53b2f9d4c4dd' },
      { name: 'react-dom', path: 'react-dom@18.3.1/umd/react-dom.production.min.js', bytes: 131835, sha256: '35f4f974f4b2bcd44da73963347f8952e341f83909e4498227d4e26b98f66f0d' },
      { name: 'rxjs', path: 'rxjs@7.8.2/dist/bundles/rxjs.umd.min.js', bytes: 88060, sha256: '2152e8a794982170a4c1dae32a74e31a81218fd74781c27b0d628a02bf532413' },
      { name: 'presets', path: '@univerjs/presets@0.25.1/lib/umd/index.js', bytes: 7089616, sha256: '089c8d7f47f3bc69d47605025ed60900dc25ad5927f9c2a7ba921becb2a05d6c' },
      { name: 'sheets-core', path: '@univerjs/preset-sheets-core@0.25.1/lib/umd/index.js', bytes: 3245639, sha256: '71a3007e8796b7073b1f0af3e0a2a23d3282fa74a7493d9b915d7a0c24c57de2' },
      { name: 'sheets-core-en', path: '@univerjs/preset-sheets-core@0.25.1/lib/umd/locales/en-US.js', bytes: 326087, sha256: '0a1b2e1e3b3d0e59513c890edb88a1bbc02d76f6905bba2a67255055d4b5f938' },
      { name: 'sort', path: '@univerjs/preset-sheets-sort@0.25.1/lib/umd/index.js', bytes: 46059, sha256: 'fd22efcef0f6013494ec7120f021990f6a6a5b1617dd69f4553b8666217bc394' },
      { name: 'sort-en', path: '@univerjs/preset-sheets-sort@0.25.1/lib/umd/locales/en-US.js', bytes: 1632, sha256: '1c015a40c604e21bf0e9f78a4600eab10bb3e8b75c559d4784537d02dd76c2ea' },
      { name: 'filter', path: '@univerjs/preset-sheets-filter@0.25.1/lib/umd/index.js', bytes: 114161, sha256: 'f95d093a3fa10cc5537059b3182ef2ab897ff30bbe485463a0dcee01ca73e390' },
      { name: 'filter-en', path: '@univerjs/preset-sheets-filter@0.25.1/lib/umd/locales/en-US.js', bytes: 3158, sha256: 'cbcdcb0f290e6a0e7615d8b7ec255a0d75cdefbbb7ba6ecdcdef7cf806de95ba' },
      { name: 'hyper-link', path: '@univerjs/preset-sheets-hyper-link@0.25.1/lib/umd/index.js', bytes: 93013, sha256: '94613b55834009bebf410fe687bc772de81da620f843ae2d388b405f25572a56' },
      { name: 'hyper-link-en', path: '@univerjs/preset-sheets-hyper-link@0.25.1/lib/umd/locales/en-US.js', bytes: 1849, sha256: 'c91915cafb5fa9230ed807ede7a39fbd5fab93d56dc9690b894c20985605c330' },
      { name: 'data-validation', path: '@univerjs/preset-sheets-data-validation@0.25.1/lib/umd/index.js', bytes: 197399, sha256: '52e4f40380574bb774f5ffa45f7234423105d64c1973a3e84550ae4a187d2abf' },
      { name: 'data-validation-en', path: '@univerjs/preset-sheets-data-validation@0.25.1/lib/umd/locales/en-US.js', bytes: 12821, sha256: 'ffef22ac334a93f65ce2049ae420180c74847cb5a2f1995d608a16a6245b7b29' },
      { name: 'conditional-formatting', path: '@univerjs/preset-sheets-conditional-formatting@0.25.1/lib/umd/index.js', bytes: 227435, sha256: '42eb379d3fa922652849f956a22404ac4817ed22a42402a77bc435414df6f6dd' },
      { name: 'conditional-formatting-en', path: '@univerjs/preset-sheets-conditional-formatting@0.25.1/lib/umd/locales/en-US.js', bytes: 4604, sha256: '9d656151c167898a93a36f009319c5df5d709143a77aaf39084a90e6d6e29b5e' },
    ],
    css: [
      { name: 'sheets-core-css', path: '@univerjs/preset-sheets-core@0.25.1/lib/index.css', bytes: 82369, sha256: '608c124418bdca0a976cf152e7c35910556d9de196a0a27d55d9e34f4098e7ba' },
      { name: 'sort-css', path: '@univerjs/preset-sheets-sort@0.25.1/lib/index.css', bytes: 3259, sha256: '1773da1f3bc4174ad115187ae5c928f48f8b649ba66ccfcd04942385f98ccec5' },
      { name: 'filter-css', path: '@univerjs/preset-sheets-filter@0.25.1/lib/index.css', bytes: 5298, sha256: '340002e1ca6092572c9134153dc2c32cf978c76ca7c7e8ea3d8ff87f49cfdb0d' },
      { name: 'hyper-link-css', path: '@univerjs/preset-sheets-hyper-link@0.25.1/lib/index.css', bytes: 2221, sha256: '854f8b80e774120870d4cbf79ac554b0068ecd748c9c2933974bfe20a997b9ef' },
      { name: 'data-validation-css', path: '@univerjs/preset-sheets-data-validation@0.25.1/lib/index.css', bytes: 3716, sha256: '03b3e4d93932dcfb50e0ee956b31e4192432bf565cf5b67b74ad32aa58062f69' },
      { name: 'conditional-formatting-css', path: '@univerjs/preset-sheets-conditional-formatting@0.25.1/lib/index.css', bytes: 4928, sha256: 'e738fa32e00d9aca9f0435a5e4971295521fc7f303a4aaea49c40996ba4764e8' },
    ],
  };

  function engineUrls(file) {
    return MIRRORS.map(function (m) { return m + file.path; });
  }

  function engineTotalBytes() {
    var n = 0;
    ENGINE.js.concat(ENGINE.css).forEach(function (f) { n += f.bytes; });
    return n;
  }

  // ---------------------------------------------------------------------
  // Cell value helpers
  // ---------------------------------------------------------------------

  // Univer CellValueType
  var T_STRING = 1;
  var T_NUMBER = 2;
  var T_BOOLEAN = 3;
  var T_FORCE_STRING = 4;

  // Univer HorizontalAlign: 0 unspecified, 1 left, 2 center, 3 right
  var ALIGN_TO_HT = { left: 1, center: 2, right: 3 };
  var HT_TO_ALIGN = { 1: 'left', 2: 'center', 3: 'right' };

  /**
   * A string becomes a real number in the sheet only when converting back
   * produces the identical text — "3.10", "1e3", "007", "1,000" all stay
   * strings so an untouched cell can never change spelling on save.
   */
  function stableNumber(s) {
    if (typeof s !== 'string') return null;
    var t = s.trim();
    if (t === '' || t !== s) return null;
    if (!/^-?(\d+\.?\d*|\.\d+)$/.test(t)) return null;
    var n = Number(t);
    if (!isFinite(n)) return null;
    return String(n) === t ? n : null;
  }

  /** Plain text of a rich-text cell (p), without the trailing \r\n. */
  function richText(cell) {
    var p = cell && cell.p;
    var stream = p && p.body && p.body.dataStream;
    if (typeof stream !== 'string') return null;
    return stream.replace(/\r\n$/, '').replace(/\r/g, '\n');
  }

  /** The display/save string of a snapshot cell (computed value for formulas). */
  function cellText(cell) {
    if (!cell) return '';
    var rich = richText(cell);
    if (rich !== null) return rich;
    var v = cell.v;
    if (v == null) return '';
    if (cell.t === T_BOOLEAN || typeof v === 'boolean') {
      return v === true || v === 1 ? 'TRUE' : 'FALSE';
    }
    return String(v);
  }

  /** True when the cell holds nothing that would survive a save. */
  function cellEmpty(cell) {
    if (!cell) return true;
    if (cell.f) return false;
    var rich = richText(cell);
    if (rich !== null) return rich === '';
    return cell.v == null || cell.v === '';
  }

  function resolveStyle(s, styles) {
    if (!s) return null;
    if (typeof s === 'string') return (styles && styles[s]) || null;
    return s;
  }

  // ---------------------------------------------------------------------
  // Grid (markdown / CSV) → Univer sheet data
  // ---------------------------------------------------------------------

  var GRID_STYLES = {
    'ts-h': { bl: 1 },
    'ts-h-left': { bl: 1, ht: 1 },
    'ts-h-center': { bl: 1, ht: 2 },
    'ts-h-right': { bl: 1, ht: 3 },
    'ts-left': { ht: 1 },
    'ts-center': { ht: 2 },
    'ts-right': { ht: 3 },
  };

  /**
   * Builds a Univer sheet fragment from a rectangular string grid.
   *
   * opts.headerRow  — style row 0 as a markdown header (bold) and carry
   *                   per-column alignment on it (alignment is read back
   *                   from row 0 at save time).
   * opts.aligns     — per-column null|'left'|'center'|'right'.
   *
   * Numeric-looking strings become numbers only when round-trip stable so
   * an untouched cell can never change its spelling on save.
   */
  function gridToSheetData(grid, opts) {
    opts = opts || {};
    var aligns = opts.aligns || [];
    var rows = grid.length;
    var cols = rows > 0 ? grid[0].length : 0;
    var cellData = {};
    for (var r = 0; r < rows; r++) {
      var rowOut = {};
      var any = false;
      for (var c = 0; c < cols; c++) {
        var text = grid[r][c] == null ? '' : String(grid[r][c]);
        var align = aligns[c] || null;
        var cell = null;
        if (text !== '') {
          var n = stableNumber(text);
          if (n !== null) {
            cell = { v: n, t: T_NUMBER };
          } else {
            cell = { v: text, t: T_STRING };
          }
        }
        var styleId = null;
        if (opts.headerRow && r === 0) {
          styleId = align ? 'ts-h-' + align : 'ts-h';
        } else if (align) {
          styleId = 'ts-' + align;
        }
        if (styleId) {
          cell = cell || {};
          cell.s = styleId;
        }
        if (cell) {
          rowOut[c] = cell;
          any = true;
        }
      }
      if (any) cellData[r] = rowOut;
    }
    return {
      cellData: cellData,
      styles: GRID_STYLES,
      rows: rows,
      cols: cols,
    };
  }

  /**
   * Reads a snapshot sheet back into a rectangular string grid.
   *
   * Formulas contribute their computed value. Trailing all-empty rows and
   * columns beyond the last populated cell are dropped, but the result is
   * never smaller than minRows x minCols (a markdown table keeps its
   * header even when emptied).
   */
  function snapshotToGrid(sheetSnap, styles, opts) {
    opts = opts || {};
    var minRows = opts.minRows || 1;
    var minCols = opts.minCols || 1;
    var cellData = sheetSnap.cellData || {};
    var maxR = -1;
    var maxC = -1;
    var hasFormula = false;
    Object.keys(cellData).forEach(function (rk) {
      var row = cellData[rk];
      if (!row) return;
      var r = Number(rk);
      Object.keys(row).forEach(function (ck) {
        var cell = row[ck];
        if (cellEmpty(cell)) return;
        if (cell.f) hasFormula = true;
        var c = Number(ck);
        if (r > maxR) maxR = r;
        if (c > maxC) maxC = c;
      });
    });
    var rows = Math.max(minRows, maxR + 1);
    var cols = Math.max(minCols, maxC + 1);
    var grid = [];
    for (var r = 0; r < rows; r++) {
      var out = [];
      var row = cellData[r] || {};
      for (var c = 0; c < cols; c++) {
        out.push(cellText(row[c]));
      }
      grid.push(out);
    }
    // Per-column markdown alignment, read from the header row's style.
    var aligns = [];
    var headerRow = cellData[0] || {};
    for (var c2 = 0; c2 < cols; c2++) {
      var st = resolveStyle(headerRow[c2] && headerRow[c2].s, styles);
      aligns.push((st && HT_TO_ALIGN[st.ht]) || null);
    }
    return { grid: grid, aligns: aligns, hasFormula: hasFormula, rows: rows, cols: cols };
  }

  // ---------------------------------------------------------------------
  // SheetJS worksheet → Univer sheet data
  // ---------------------------------------------------------------------

  /**
   * Converts one SheetJS worksheet into Univer sheet data, carrying
   * values, live formulas, merges and number formats. `XLSX` is passed in
   * (utils.decode_cell / decode_range) so this stays node-testable.
   *
   * Returns { cellData, mergeData, rows, cols, numfmts, cellCount }
   * where numfmts maps style-id -> { n: { pattern } } for every distinct
   * number format encountered. `stylePrefix` namespaces the generated ids
   * (Univer styles are workbook-global, so per-sheet ids must not collide).
   */
  function worksheetToSheetData(ws, XLSX, stylePrefix) {
    var prefix = stylePrefix || '';
    var cellData = {};
    var numfmts = {};
    var fmtIds = {};
    var nextFmt = 0;
    var maxR = -1;
    var maxC = -1;
    var cellCount = 0;
    Object.keys(ws).forEach(function (key) {
      if (key.charAt(0) === '!') return;
      var cell = ws[key];
      if (!cell || typeof cell !== 'object') return;
      var addr = XLSX.utils.decode_cell(key);
      var out = null;
      if (cell.f) {
        out = { f: '=' + cell.f };
        if (cell.v != null && cell.t !== 'e') {
          out.v = cell.t === 'b' ? (cell.v ? 1 : 0) : cell.v;
          if (cell.t === 'n') out.t = T_NUMBER;
          else if (cell.t === 'b') out.t = T_BOOLEAN;
          else out.t = T_STRING;
        }
      } else if (cell.t === 'n' && typeof cell.v === 'number') {
        out = { v: cell.v, t: T_NUMBER };
      } else if (cell.t === 'b') {
        out = { v: cell.v ? 1 : 0, t: T_BOOLEAN };
      } else if (cell.t === 's' || cell.t === 'str') {
        var sv = cell.v == null ? '' : String(cell.v);
        if (sv === '') return;
        out = { v: sv, t: T_STRING };
      } else if (cell.t === 'e') {
        // Error cells (#DIV/0! etc) without a formula: keep the display text.
        out = { v: cell.w != null ? String(cell.w) : '#ERR', t: T_STRING };
      } else if (cell.t === 'd' && cell.v != null) {
        // Only appears when a reader used cellDates; keep the display text
        // (raw serials are the default path).
        out = { v: cell.w != null ? String(cell.w) : String(cell.v), t: T_STRING };
      } else {
        return;
      }
      if (cell.z && cell.z !== 'General') {
        var id = fmtIds[cell.z];
        if (!id) {
          id = prefix + 'nf-' + nextFmt++;
          fmtIds[cell.z] = id;
          numfmts[id] = { n: { pattern: cell.z } };
        }
        out.s = id;
      }
      if (!cellData[addr.r]) cellData[addr.r] = {};
      cellData[addr.r][addr.c] = out;
      cellCount++;
      if (addr.r > maxR) maxR = addr.r;
      if (addr.c > maxC) maxC = addr.c;
    });
    var mergeData = [];
    (ws['!merges'] || []).forEach(function (m) {
      mergeData.push({
        startRow: m.s.r,
        startColumn: m.s.c,
        endRow: m.e.r,
        endColumn: m.e.c,
      });
      if (m.e.r > maxR) maxR = m.e.r;
      if (m.e.c > maxC) maxC = m.e.c;
    });
    return {
      cellData: cellData,
      mergeData: mergeData,
      rows: maxR + 1,
      cols: maxC + 1,
      numfmts: numfmts,
      cellCount: cellCount,
    };
  }

  // ---------------------------------------------------------------------
  // Normalized sheet form — the basis for dirty detection and patching
  // ---------------------------------------------------------------------

  /**
   * Reduces a snapshot sheet to the features this editor can persist into
   * a workbook file: cell values, formulas, number formats and merges.
   * Pure styling (bold, colors, alignment) is deliberately excluded —
   * SheetJS CE cannot write it, so a styling-only change must not count
   * as a data change (it would rewrite the sheet and save nothing).
   *
   * Returns { cells: { "r,c": {v, f, z} }, merges: [[sr,sc,er,ec]...] }.
   */
  function normalizeSheet(sheetSnap, styles) {
    var cells = {};
    var cellData = sheetSnap.cellData || {};
    Object.keys(cellData).forEach(function (rk) {
      var row = cellData[rk];
      if (!row) return;
      Object.keys(row).forEach(function (ck) {
        var cell = row[ck];
        if (cellEmpty(cell)) return;
        var st = resolveStyle(cell.s, styles);
        var entry = {};
        if (cell.f) {
          entry.f = cell.f;
          if (cell.v != null) entry.v = cell.v;
        } else {
          var rich = richText(cell);
          entry.v = rich !== null ? rich : cell.v;
          if (cell.t === T_BOOLEAN || typeof entry.v === 'boolean') {
            entry.v = entry.v === true || entry.v === 1 ? 1 : 0;
            entry.b = 1;
          }
        }
        if (st && st.n && st.n.pattern && st.n.pattern !== 'General') {
          entry.z = st.n.pattern;
        }
        cells[rk + ',' + ck] = entry;
      });
    });
    var merges = (sheetSnap.mergeData || []).map(function (m) {
      return [m.startRow, m.startColumn, m.endRow, m.endColumn];
    });
    merges.sort(function (a, b) {
      return a[0] - b[0] || a[1] - b[1] || a[2] - b[2] || a[3] - b[3];
    });
    return { cells: cells, merges: merges };
  }

  function entriesEqual(a, b) {
    if (!a || !b) return !a === !b;
    return a.v === b.v && a.f === b.f && a.z === b.z && a.b === b.b;
  }

  function normalizedEqual(a, b) {
    var ka = Object.keys(a.cells);
    var kb = Object.keys(b.cells);
    if (ka.length !== kb.length) return false;
    for (var i = 0; i < ka.length; i++) {
      if (!entriesEqual(a.cells[ka[i]], b.cells[ka[i]])) return false;
    }
    if (a.merges.length !== b.merges.length) return false;
    for (var m = 0; m < a.merges.length; m++) {
      if (String(a.merges[m]) !== String(b.merges[m])) return false;
    }
    return true;
  }

  // ---------------------------------------------------------------------
  // Univer snapshot → SheetJS worksheet
  // ---------------------------------------------------------------------

  function sheetjsCellOf(entry) {
    var cell;
    if (entry.f) {
      cell = { f: entry.f.replace(/^=/, '') };
      if (entry.v != null) {
        if (typeof entry.v === 'number') { cell.t = 'n'; cell.v = entry.v; }
        else if (typeof entry.v === 'boolean') { cell.t = 'b'; cell.v = entry.v; }
        else { cell.t = 's'; cell.v = String(entry.v); }
      } else {
        cell.t = 's';
      }
    } else if (entry.b) {
      cell = { t: 'b', v: entry.v === 1 };
    } else if (typeof entry.v === 'number') {
      cell = { t: 'n', v: entry.v };
    } else {
      cell = { t: 's', v: String(entry.v == null ? '' : entry.v) };
    }
    if (entry.z) cell.z = entry.z;
    return cell;
  }

  /**
   * Builds a brand-new SheetJS worksheet from a normalized snapshot —
   * the full-rewrite save path (used after structural edits and for
   * "save a copy"). Carries values, formulas, number formats and merges.
   */
  function normalizedToWorksheet(norm, XLSX) {
    var ws = {};
    var maxR = -1;
    var maxC = -1;
    Object.keys(norm.cells).forEach(function (key) {
      var rc = key.split(',');
      var r = Number(rc[0]);
      var c = Number(rc[1]);
      ws[XLSX.utils.encode_cell({ r: r, c: c })] = sheetjsCellOf(norm.cells[key]);
      if (r > maxR) maxR = r;
      if (c > maxC) maxC = c;
    });
    if (norm.merges.length > 0) {
      ws['!merges'] = norm.merges.map(function (m) {
        if (m[0] > maxR) maxR = m[0];
        if (m[2] > maxR) maxR = m[2];
        if (m[1] > maxC) maxC = m[1];
        if (m[3] > maxC) maxC = m[3];
        return { s: { r: m[0], c: m[1] }, e: { r: m[2], c: m[3] } };
      });
    }
    if (maxR >= 0) {
      ws['!ref'] = XLSX.utils.encode_range({ s: { r: 0, c: 0 }, e: { r: maxR, c: maxC } });
    }
    return ws;
  }

  /**
   * Returns a copy of worksheet `ws` with the differences between
   * `baseNorm` (the sheet as loaded) and `curNorm` (the sheet now)
   * applied cell by cell — the no-structural-edit save path. Untouched
   * cells keep their original objects, so formats/styles SheetJS CE can
   * only read-through survive. Merges are replaced wholesale.
   *
   * Copy-on-write: `ws` itself is never mutated, so a failed upload
   * leaves the in-memory workbook pristine.
   */
  function patchWorksheet(ws, baseNorm, curNorm, XLSX) {
    var copy = {};
    Object.keys(ws).forEach(function (k) { copy[k] = ws[k]; });
    var changed = false;
    var minR = Infinity;
    var minC = Infinity;
    var maxR = -1;
    var maxC = -1;
    var keys = {};
    Object.keys(baseNorm.cells).forEach(function (k) { keys[k] = true; });
    Object.keys(curNorm.cells).forEach(function (k) { keys[k] = true; });
    Object.keys(keys).forEach(function (key) {
      var before = baseNorm.cells[key] || null;
      var after = curNorm.cells[key] || null;
      if (entriesEqual(before, after)) return;
      changed = true;
      var rc = key.split(',');
      var r = Number(rc[0]);
      var c = Number(rc[1]);
      var addr = XLSX.utils.encode_cell({ r: r, c: c });
      if (!after) {
        delete copy[addr];
      } else {
        copy[addr] = sheetjsCellOf(after);
        if (r < minR) minR = r;
        if (c < minC) minC = c;
        if (r > maxR) maxR = r;
        if (c > maxC) maxC = c;
      }
    });
    if (String(baseNorm.merges) !== String(curNorm.merges)) {
      changed = true;
      if (curNorm.merges.length > 0) {
        copy['!merges'] = curNorm.merges.map(function (m) {
          if (m[0] < minR) minR = m[0];
          if (m[1] < minC) minC = m[1];
          if (m[2] > maxR) maxR = m[2];
          if (m[3] > maxC) maxC = m[3];
          return { s: { r: m[0], c: m[1] }, e: { r: m[2], c: m[3] } };
        });
      } else {
        delete copy['!merges'];
      }
    }
    if (maxR >= 0) {
      // Grow !ref at BOTH ends — an edit can land before a non-A1 range
      // start, and a cell outside !ref is silently dropped by the writer.
      var ref = copy['!ref']
        ? XLSX.utils.decode_range(copy['!ref'])
        : { s: { r: minR, c: minC }, e: { r: maxR, c: maxC } };
      ref.s.r = Math.min(ref.s.r, minR);
      ref.s.c = Math.min(ref.s.c, minC);
      ref.e.r = Math.max(ref.e.r, maxR);
      ref.e.c = Math.max(ref.e.c, maxC);
      copy['!ref'] = XLSX.utils.encode_range(ref);
    }
    return { ws: copy, changed: changed };
  }

  // ---------------------------------------------------------------------
  // Mutation classification
  // ---------------------------------------------------------------------

  // Mutations that move existing cells to new coordinates. After any of
  // these the cell-diff patch would leave formats glued to old positions,
  // so the sheet switches to the full-rewrite save path.
  var STRUCTURAL_RE = /(insert-row|insert-col|remove-row|remove-col|move-rows|move-cols|move-range|move-columns|reorder-range|remove-sheet|insert-sheet|set-worksheet-order|sort)/i;

  /** True when a mutation id implies rows/columns/cells changed position. */
  function isStructuralMutation(id) {
    return STRUCTURAL_RE.test(String(id || ''));
  }

  return {
    ENGINE: ENGINE,
    MIRRORS: MIRRORS,
    engineUrls: engineUrls,
    engineTotalBytes: engineTotalBytes,
    stableNumber: stableNumber,
    cellText: cellText,
    cellEmpty: cellEmpty,
    richText: richText,
    gridToSheetData: gridToSheetData,
    snapshotToGrid: snapshotToGrid,
    worksheetToSheetData: worksheetToSheetData,
    normalizeSheet: normalizeSheet,
    normalizedEqual: normalizedEqual,
    normalizedToWorksheet: normalizedToWorksheet,
    patchWorksheet: patchWorksheet,
    isStructuralMutation: isStructuralMutation,
  };
});

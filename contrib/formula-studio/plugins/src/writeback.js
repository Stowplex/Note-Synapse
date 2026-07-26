/*
 * Fresh-read, single-write note mutation for Formula Studio.
 */
(function (root, factory) {
  var api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root) root.FormulaWriteback = api;
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  function describeErrors(response) {
    if (!response) return 'No response from Note Synapse.';
    if (response.error) return String(response.error);
    if (Array.isArray(response.errors) && response.errors.length) {
      return response.errors.map(function (item) {
        return item && (item.error || item.message)
          ? String(item.error || item.message)
          : String(item);
      }).join(' ');
    }
    return 'The note was not updated.';
  }

  function createWriter(environment) {
    var synapse = environment.synapse;
    var core = environment.core;
    var note = environment.note;
    var baseContent = String(note.content == null ? '' : note.content);

    function initialContent() {
      return baseContent;
    }

    function readFreshContent() {
      var id = String(note.id).replace(/'/g, "''");
      return Promise.resolve(
        synapse.runQuery("SELECT content FROM notes WHERE id = '" + id + "'")
      ).then(function (response) {
        if (!response ||
            !response.success ||
            !response.data ||
            !response.data.length ||
            response.data[0].content == null) {
          return null;
        }
        return String(response.data[0].content);
      }).catch(function () {
        return null;
      });
    }

    function buildNextContent(content, options) {
      var target = options.target;
      var body = String(options.body == null ? '' : options.body).trim();
      var kind = options.kind === 'inline' ? 'inline' : 'display';
      var below = String(options.insertBelow == null ? '' : options.insertBelow).trim();

      if (!target || target.mode === 'append') {
        if (!body) throw new Error('Enter a formula before saving.');
        return {
          content: core.appendDisplayFormula(content, body),
          relocated: false,
          normalizedLegacy: false,
        };
      }

      var relocated = core.relocateTarget(content, target);
      if (!relocated.ok) {
        throw new Error(
          relocated.reason === 'ambiguous'
            ? 'This formula now appears in several places, so Formula Studio cannot safely choose one. Reopen the app from the formula you want.'
            : 'The formula changed or disappeared while Formula Studio was open. Reopen it before saving.'
        );
      }

      var unit = relocated.unit;
      var replacement = core.serializeFormula(body, kind, unit);
      var next = below
        ? core.replaceWithDisplayBelow(content, unit, replacement, below)
        : core.replaceRange(content, unit.start, unit.end, replacement);
      return {
        content: next,
        relocated: !!relocated.relocated,
        normalizedLegacy: !!unit.legacy,
      };
    }

    function save(options) {
      return readFreshContent().then(function (fresh) {
        if (fresh == null) {
          throw new Error(
            'Formula Studio could not re-read the current note, so it refused to overwrite it.'
          );
        }
        var built = buildNextContent(fresh, options);
        if (built.content === fresh) {
          return {
            success: true,
            unchanged: true,
            content: fresh,
            relocated: built.relocated,
            normalizedLegacy: built.normalizedLegacy,
          };
        }
        return Promise.resolve(
          synapse.updateNotes([
            {
              id: note.id,
              modification: {
                content: { action: 'replace', text: built.content },
              },
            },
          ])
        ).then(function (response) {
          if (!response || !response.success || !response.updatedCount) {
            throw new Error('Could not save the formula. ' + describeErrors(response));
          }
          baseContent = built.content;
          return {
            success: true,
            unchanged: false,
            content: built.content,
            relocated: built.relocated,
            normalizedLegacy: built.normalizedLegacy,
          };
        });
      });
    }

    return {
      note: note,
      isBlockScope: !!note.isBlockScope,
      initialContent: initialContent,
      readFreshContent: readFreshContent,
      buildNextContent: buildNextContent,
      save: save,
    };
  }

  return {
    createWriter: createWriter,
    describeErrors: describeErrors,
  };
});

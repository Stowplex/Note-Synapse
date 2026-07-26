/*
 * Narrow, local adapter over Cortex Compute Engine.
 *
 * MathLive and Compute Engine are intentionally coupled only through LaTeX
 * strings. No assignment is retained between calls, and no optional
 * network-backed Compute Engine feature is exposed.
 */
(function (root, factory) {
  var api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  if (root) root.FormulaEvaluator = api;
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  var MAX_LATEX_LENGTH = 10000;
  var DEFAULT_TIME_LIMIT_MS = 1800;
  var BUILT_INS = {
    Pi: true,
    ExponentialE: true,
    EulerGamma: true,
    GoldenRatio: true,
    ImaginaryUnit: true,
    True: true,
    False: true,
    Nothing: true,
    Undefined: true,
    NaN: true,
    PositiveInfinity: true,
    NegativeInfinity: true,
    ComplexInfinity: true,
  };

  function clampPrecision(value) {
    if (value == null || value === '') return 10;
    var number = Number(value);
    if (!Number.isFinite(number)) return 10;
    return Math.max(3, Math.min(50, Math.round(number)));
  }

  function makeEngine(library, options) {
    if (!library || typeof library.ComputeEngine !== 'function') {
      throw new Error('Compute Engine is unavailable.');
    }
    options = options || {};
    var engine = new library.ComputeEngine();
    // Compute Engine uses at least machine precision internally. Display
    // rounding is separately controlled with toLatex({digits:{significant}}).
    engine.precision = Math.max(15, clampPrecision(options.precision));
    engine.angularUnit = options.angleUnit === 'degrees' ? 'deg' : 'rad';
    return engine;
  }

  function variablesOf(expression) {
    return Array.from(expression.symbols || [])
      .filter(function (symbol) { return !BUILT_INS[symbol]; })
      .sort();
  }

  function inspect(library, latex, options) {
    latex = String(latex == null ? '' : latex).trim();
    if (!latex) {
      return { valid: false, empty: true, variables: [], reason: 'empty' };
    }
    if (latex.length > MAX_LATEX_LENGTH) {
      return {
        valid: false,
        tooLarge: true,
        variables: [],
        reason: 'calculation-limit',
      };
    }
    try {
      var engine = makeEngine(library, options);
      var expression = engine.parse(latex);
      if (!expression || expression.isValid === false) {
        return {
          valid: false,
          variables: variablesOf(expression || { symbols: [] }),
          reason: 'parse',
          errors: expression && expression.errors ? expression.errors.length : 0,
        };
      }
      return {
        valid: true,
        variables: variablesOf(expression),
        operator: expression.operator || null,
        isEquation: expression.operator === 'Equal',
      };
    } catch (error) {
      return {
        valid: false,
        variables: [],
        reason: 'exception',
        error: error && error.message ? error.message : String(error),
      };
    }
  }

  function requireVariable(expression, params) {
    var variables = variablesOf(expression);
    var variable = params && params.variable;
    if (!variable && variables.length === 1) variable = variables[0];
    if (!variable || variables.indexOf(variable) === -1) {
      throw new Error('Choose a variable for this calculation.');
    }
    return variable;
  }

  function parseParameter(engine, latex, label) {
    var value = engine.parse(String(latex == null ? '' : latex).trim());
    if (!value || value.isValid === false || value.symbol === 'Nothing') {
      throw new Error('Enter a valid ' + label + '.');
    }
    return value;
  }

  function latexOf(expression, precision, decimal) {
    if (!expression) return '';
    if (decimal && typeof expression.toLatex === 'function') {
      return expression.toLatex({
        digits: { significant: clampPrecision(precision) },
      });
    }
    return expression.latex || String(expression);
  }

  function statementFor(action, input, result, params, extra) {
    params = params || {};
    extra = extra || {};
    var variable = params.variable || 'x';
    if (action === 'decimal' || action === 'numericIntegral') {
      if (action === 'numericIntegral') {
        return '\\int_{' + params.lower + '}^{' + params.upper + '} ' +
          input + '\\,\\mathrm{d}' + variable + '\\approx ' + result;
      }
      return input + '\\approx ' + result;
    }
    if (action === 'substitute') {
      return '\\left.' + input + '\\right|_{' + variable + '=' +
        params.value + '}=' + result;
    }
    if (action === 'solve') {
      if (!extra.solutions || !extra.solutions.length) {
        return input + '\\quad\\Longrightarrow\\quad ' + variable +
          '\\in\\varnothing';
      }
      return input + '\\quad\\Longrightarrow\\quad ' + variable +
        '\\in\\left\\{' + extra.solutions.join(',') + '\\right\\}';
    }
    if (action === 'derivative') {
      return '\\frac{\\mathrm{d}}{\\mathrm{d}' + variable + '}\\left(' +
        input + '\\right)=' + result;
    }
    if (action === 'integral') {
      return '\\int ' + input + '\\,\\mathrm{d}' + variable + '=' +
        result + '+C';
    }
    if (action === 'definiteIntegral') {
      return '\\int_{' + params.lower + '}^{' + params.upper + '} ' +
        input + '\\,\\mathrm{d}' + variable + '=' + result;
    }
    if (action === 'limit') {
      return '\\lim_{' + variable + '\\to ' + params.point + '} ' +
        input + '=' + result;
    }
    return input + '=' + result;
  }

  function calculate(library, action, latex, params, options) {
    latex = String(latex == null ? '' : latex).trim();
    params = params || {};
    options = options || {};
    var inspected = inspect(library, latex, options);
    if (!inspected.valid) {
      return {
        ok: false,
        editable: true,
        reason: inspected.reason,
        tooLarge: !!inspected.tooLarge,
      };
    }

    try {
      var engine = makeEngine(library, options);
      var expression = engine.parse(latex);
      var result;
      var variable;
      var head = null;
      var solutions = null;

      engine.withTimeLimit(
        {
          ms: options.timeLimitMs || DEFAULT_TIME_LIMIT_MS,
          label: 'formula-studio:' + action,
        },
        function () {
          if (action === 'simplify') {
            result = expression.simplify();
          } else if (action === 'exact') {
            result = expression.evaluate();
          } else if (action === 'decimal') {
            result = expression.N();
          } else if (action === 'substitute') {
            variable = requireVariable(expression, params);
            var substitution = {};
            substitution[variable] = parseParameter(engine, params.value, 'substitution value');
            result = expression.subs(substitution).evaluate();
          } else if (action === 'expand' || action === 'factor') {
            head = action === 'expand' ? 'Expand' : 'Factor';
            result = engine.box([head, expression.json]).evaluate();
          } else if (action === 'solve') {
            variable = requireVariable(expression, params);
            solutions = expression.solve(variable) || [];
          } else if (action === 'derivative') {
            variable = requireVariable(expression, params);
            head = 'D';
            result = engine.box([head, expression.json, variable]).evaluate();
          } else if (action === 'integral') {
            variable = requireVariable(expression, params);
            head = 'Integrate';
            result = engine.box([head, expression.json, variable]).evaluate();
          } else if (action === 'definiteIntegral' || action === 'numericIntegral') {
            variable = requireVariable(expression, params);
            var low = parseParameter(engine, params.lower, 'lower bound');
            var high = parseParameter(engine, params.upper, 'upper bound');
            head = 'Integrate';
            var definite = engine.box([
              head,
              expression.json,
              ['Limits', variable, low.json, high.json],
            ]);
            result = action === 'numericIntegral'
              ? definite.N()
              : definite.evaluate();
          } else if (action === 'limit') {
            variable = requireVariable(expression, params);
            var point = parseParameter(engine, params.point, 'limit point');
            head = 'Limit';
            result = engine.box([
              head,
              expression.json,
              variable,
              point.json,
            ]).evaluate();
          } else {
            throw new Error('Unsupported calculation.');
          }
        }
      );

      var precision = clampPrecision(options.precision);
      var resultLatex;
      var solutionLatex = null;
      if (action === 'solve') {
        solutionLatex = solutions.map(function (item) {
          return latexOf(item, precision, false);
        });
        resultLatex = solutionLatex.length
          ? '\\left\\{' + solutionLatex.join(',') + '\\right\\}'
          : '\\varnothing';
      } else {
        resultLatex = latexOf(
          result,
          precision,
          action === 'decimal' || action === 'numericIntegral'
        );
      }

      var unresolved = !!(
        result &&
        head &&
        result.operator === head
      );
      var normalizedParams = Object.assign({}, params);
      if (variable) normalizedParams.variable = variable;
      var statement = statementFor(
        action,
        latex,
        resultLatex,
        normalizedParams,
        { solutions: solutionLatex }
      );

      return {
        ok: true,
        action: action,
        inputLatex: latex,
        resultLatex: resultLatex,
        statementLatex: statement,
        relation: action === 'decimal' || action === 'numericIntegral' ? 'approx' : 'exact',
        selfContained:
          action === 'solve' ||
          action === 'derivative' ||
          action === 'integral' ||
          action === 'definiteIntegral' ||
          action === 'numericIntegral' ||
          action === 'limit',
        noClosedForm: unresolved,
        params: normalizedParams,
      };
    } catch (error) {
      return {
        ok: false,
        editable: true,
        reason:
          error && (error.name === 'CancellationError' ||
            /time|cancel/i.test(error.message || ''))
            ? 'timeout'
            : 'calculation',
        error: error && error.message ? error.message : String(error),
      };
    }
  }

  function applicationLatex(calculation, mode) {
    if (!calculation || !calculation.ok) return '';
    if (mode === 'below') return calculation.statementLatex;
    if (mode === 'replace') {
      return calculation.selfContained
        ? calculation.statementLatex
        : calculation.resultLatex;
    }
    return calculation.statementLatex;
  }

  return {
    MAX_LATEX_LENGTH: MAX_LATEX_LENGTH,
    DEFAULT_TIME_LIMIT_MS: DEFAULT_TIME_LIMIT_MS,
    clampPrecision: clampPrecision,
    variablesOf: variablesOf,
    inspect: inspect,
    calculate: calculate,
    applicationLatex: applicationLatex,
  };
});

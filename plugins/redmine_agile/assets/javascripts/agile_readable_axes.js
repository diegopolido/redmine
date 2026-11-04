// Chart.js plugin: makes burnup/burndown/cumulative flow charts readable.
// - trims the Y axis to the visible data when its range is a small part of the scale
// - draws larger series behind smaller ones
// - shows points only when they are sparse
// - shows all layers in the tooltip
var AgileReadableAxes = (function () {
  var TRIM_MAX_SPAN = 0.5;
  var MIN_POINT_SPACING = 14;

  function min(values) { return Math.min.apply(null, values) }
  function max(values) { return Math.max.apply(null, values) }

  function trimmedMin(chart, stacked) {
    var series = [];
    chart.data.datasets.forEach(function (dataset, i) {
      if (chart.isDatasetVisible(i)) { series.push(dataset.data.map(Number)) }
    });
    if (!series.length) { return undefined }

    var low = stacked ? min(series[0]) : min(series.map(min));
    var high = stacked ?
      max(series[0].map(function (_, j) { return series.reduce(function (sum, s) { return sum + s[j] }, 0) })) :
      max(series.map(max));
    var span = high - low;
    if (!(low > 0 && span > 0 && span / high < TRIM_MAX_SPAN)) { return undefined }

    var raw = span / 5;
    var magnitude = Math.pow(10, Math.floor(Math.log10(raw)));
    var fraction = raw / magnitude;
    var step = (fraction <= 1 ? 1 : fraction <= 2 ? 2 : fraction <= 5 ? 5 : 10) * magnitude;
    return Math.max(Math.floor((low - span * 0.05) / step) * step, 0);
  }

  function arrange(chart, stacked) {
    var datasets = chart.data.datasets;
    var ranked = datasets.map(function (_, i) { return i }).sort(function (a, b) {
      return max(datasets[a].data.map(Number)) - max(datasets[b].data.map(Number)) || a - b;
    });
    datasets.forEach(function (dataset, i) {
      dataset.order = stacked ? i : ranked.indexOf(i);
      if (stacked && !dataset.pointRadius) { dataset.pointRadius = 3 }
      if (dataset.pointRadius > 0 && typeof dataset.pointRadius !== 'function') {
        var radius = dataset.pointRadius;
        dataset.pointRadius = function (context) {
          return context.chart.width / context.chart.data.labels.length >= MIN_POINT_SPACING ? radius : 0;
        };
      }
    });
  }

  return {
    id: 'agileReadableAxes',
    beforeInit: function (chart, args, options) {
      if (!options.enabled) { return }
      chart.options.interaction = { mode: 'index', intersect: false };
      arrange(chart, chart.options.scales.y.stacked);
      chart.options.scales.y.afterDataLimits = function (axis) {
        var value = trimmedMin(axis.chart, axis.options.stacked);
        if (value !== undefined) { axis.min = value }
      };
    }
  };
})();

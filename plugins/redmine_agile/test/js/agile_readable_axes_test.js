// Run: node test/js/agile_readable_axes_test.js
// Runs Chart.js headless (no DOM, stub canvas) and checks scale/ticks produced with AgileReadableAxes.
const fs = require('fs');
const vm = require('vm');
const path = require('path');
const assert = require('assert');

const chartJs = process.env.CHARTJS || path.join(__dirname, '../../../../gems/redmineup/app/assets/javascripts/chart.min.js');
const sandbox = { console, module: { exports: {} }, setTimeout, clearTimeout, requestAnimationFrame: (f) => setTimeout(f, 0) };
sandbox.window = undefined;
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(chartJs, 'utf8'), sandbox);
const Chart = sandbox.Chart || sandbox.module.exports;
vm.runInContext(fs.readFileSync(path.join(__dirname, '../../assets/javascripts/agile_readable_axes.js'), 'utf8') + ';this.AgileReadableAxes = AgileReadableAxes', sandbox);
const AgileReadableAxes = sandbox.AgileReadableAxes;

function stubCanvas() {
  const canvas = { width: 1000, height: 400, style: {}, getContext() { return ctx } };
  const ctx = new Proxy({ canvas, measureText: () => ({ width: 8 }) }, {
    get: (t, k) => (k in t ? t[k] : () => {}), set: (t, k, v) => { t[k] = v; return true }
  });
  return canvas;
}

function build(datasets, stacked, labels) {
  const canvas = stubCanvas();
  const chart = new Chart(canvas, {
    type: 'line',
    data: { labels, datasets },
    plugins: [AgileReadableAxes],
    options: {
      responsive: false, animation: false,
      plugins: { agileReadableAxes: { enabled: true } },
      scales: { y: { stacked }, x: {} }
    }
  });
  return chart;
}

const line = (label, data, extra) => Object.assign({ type: 'line', label, data, fill: true, pointRadius: 3 }, extra);
const range = (from, to, n) => Array.from({ length: n }, (_, i) => Math.round(from + (to - from) * i / (n - 1)));
const labels = range(0, 13, 14).map(String);

function ticksOf(chart) { return chart.scales.y.ticks.map((t) => t.value) }
function assertEvenTicks(chart) {
  const t = ticksOf(chart);
  const steps = new Set(t.slice(1).map((v, i) => Math.round((v - t[i]) * 1e6) / 1e6));
  assert.strictEqual(steps.size, 1, 'ticks are not evenly spaced: ' + t.join(', '));
}

let failed = 0;
function test(name, fn) {
  try { fn(); console.log('ok   ' + name) } catch (e) { failed++; console.log('FAIL ' + name + '\n     ' + e.message) }
}

test('burnup: axis is trimmed and ticks are even right after init', () => {
  const chart = build([line('Created', range(28880, 29480, 14)), line('Closed', range(27960, 28640, 14)), line('Ideal', range(27960, 29510, 14), { pointRadius: 0 })], false, labels);
  const y = chart.scales.y;
  assert.strictEqual(y.min, 27500);
  assert.strictEqual(y.ticks[0].value, y.min);
  assertEvenTicks(chart);
});

test('burnup: axis keeps zero when data spans the scale', () => {
  const chart = build([line('Created', range(0, 100, 14)), line('Closed', range(0, 60, 14))], false, labels);
  assert.strictEqual(chart.scales.y.min, 0);
});

test('burnup: hide and show a series re-fits axis, ticks stay even', () => {
  const chart = build([line('Created', range(28880, 29480, 14)), line('Closed', range(27960, 28640, 14))], false, labels);
  chart.hide(0); chart.update();
  assertEvenTicks(chart);
  chart.show(0); chart.update();
  assertEvenTicks(chart);
  assert.ok(chart.scales.y.min > 20000);
});

test('stacked: hiding big bottom layers re-fits axis', () => {
  const closed = range(27442, 31113, 14), rejected = Array(14).fill(804), progress = range(461, 507, 14), fresh = range(34, 176, 14);
  const chart = build([line('Rejected', rejected), line('Closed', closed), line('In Progress', progress), line('New', fresh)], true, labels);
  assert.strictEqual(chart.scales.y.min, 0);
  chart.hide(0); chart.update();
  assert.ok(chart.scales.y.min > 20000, 'min ' + chart.scales.y.min);
  assertEvenTicks(chart);
});

test('layers: larger series drawn behind, stacked keeps index order', () => {
  const flat = build([line('A', [10, 20]), line('B', [5, 8]), line('C', [15, 30])], false, ['1', '2']);
  assert.deepStrictEqual(flat.data.datasets.map((d) => d.order), [1, 0, 2]);
  const stacked = build([line('A', [10, 20]), line('B', [5, 8])], true, ['1', '2']);
  assert.deepStrictEqual(stacked.data.datasets.map((d) => d.order), [0, 1]);
});

test('points: shown when sparse, hidden when dense', () => {
  const sparse = build([line('A', range(1, 5, 5))], false, ['1', '2', '3', '4', '5']);
  const radius = (c) => c.getDatasetMeta(0).controller.resolveDatasetElementOptions ? c.options.datasets : null;
  const r = sparse.data.datasets[0].pointRadius;
  assert.strictEqual(typeof r, 'function');
  assert.strictEqual(r({ chart: { width: 1000, data: { labels: Array(5) } } }), 3);
  assert.strictEqual(r({ chart: { width: 1000, data: { labels: Array(200) } } }), 0);
});

process.exit(failed ? 1 : 0);

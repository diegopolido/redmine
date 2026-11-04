// Chart.js plugin: lets the user merge several series (e.g. statuses on cumulative flow) into one.
// Chips above the chart select series, "Merge" sums them. Merges are kept in localStorage by series name.
var AgileMergeSeries = (function () {
  function load(key) {
    try { return JSON.parse(localStorage.getItem(key)) || [] } catch (e) { return [] }
  }

  function save(key, groups) {
    try { localStorage.setItem(key, JSON.stringify(groups)) } catch (e) {}
  }

  function merged(originals, groups) {
    var result = [];
    originals.forEach(function (dataset) {
      var group = groups.find(function (g) { return g.indexOf(dataset.label) >= 0 });
      if (!group) { return result.push(dataset) }
      if (group[0] !== dataset.label) { return }

      var members = originals.filter(function (d) { return group.indexOf(d.label) >= 0 });
      var sum = Object.assign({}, dataset, { label: group.join(' + ') });
      sum.data = dataset.data.map(function (_, i) {
        return members.reduce(function (total, d) { return total + Number(d.data[i]) }, 0);
      });
      result.push(sum);
    });
    result.forEach(function (dataset, i) { dataset.order = i });
    return result;
  }

  function button(text, onclick, className) {
    var el = document.createElement('button');
    el.type = 'button';
    el.className = className || '';
    el.textContent = text;
    el.onclick = onclick;
    return el;
  }

  function render(chart, state) {
    var box = state.box;
    box.innerHTML = '';
    var selected = state.selected = state.selected.filter(function (label) {
      return state.originals.some(function (d) { return d.label === label });
    });

    state.originals.forEach(function (dataset) {
      var group = state.groups.find(function (g) { return g.indexOf(dataset.label) >= 0 });
      if (group && group[0] !== dataset.label) { return }
      var label = group ? group.join(' + ') : dataset.label;
      var chip = document.createElement('span');
      chip.className = 'agile-merge-chip' + (selected.indexOf(dataset.label) >= 0 ? ' selected' : '');
      chip.style.borderColor = dataset.borderColor;
      chip.appendChild(button(label, function () {
        var i = selected.indexOf(dataset.label);
        if (i >= 0) { selected.splice(i, 1) } else { selected.push(dataset.label) }
        render(chart, state);
      }, 'agile-merge-label'));
      if (group) {
        var split = button('×', function () {
          state.groups.splice(state.groups.indexOf(group), 1);
          apply(chart, state);
        }, 'agile-merge-split');
        split.title = state.labels.split;
        chip.appendChild(split);
      }
      box.appendChild(chip);
    });

    if (selected.length > 1) {
      box.appendChild(button(state.labels.merge, function () {
        var picked = state.originals.map(function (d) { return d.label }).filter(function (l) { return selected.indexOf(l) >= 0 });
        state.groups = state.groups.filter(function (g) {
          return !g.some(function (l) { return picked.indexOf(l) >= 0 });
        }).concat([picked]);
        state.selected = [];
        apply(chart, state);
      }, 'agile-merge-apply'));
    }
  }

  function apply(chart, state) {
    save(state.key, state.groups);
    chart.data.datasets = merged(state.originals, state.groups);
    chart.update();
    render(chart, state);
  }

  return {
    id: 'agileMergeSeries',
    beforeInit: function (chart, args, options) {
      if (!options.enabled) { return }
      var originals = chart.data.datasets;
      var names = originals.map(function (d) { return d.label });
      var groups = load(options.key).map(function (g) {
        return g.filter(function (l) { return names.indexOf(l) >= 0 });
      }).filter(function (g) { return g.length > 1 });
      chart.agileMerge = { originals: originals, groups: groups, selected: [], key: options.key, labels: options.labels };
      chart.data.datasets = merged(originals, groups);
    },
    afterInit: function (chart, args, options) {
      var state = chart.agileMerge;
      if (!options.enabled || !state) { return }
      state.box = document.createElement('div');
      state.box.className = 'agile-merge-series';
      chart.canvas.closest('.agile-chart-container').after(state.box);
      render(chart, state);
    }
  };
})();

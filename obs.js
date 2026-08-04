/* Observability page renderer: fetches status.json (same-origin, published
   hourly by the pipeline) and renders stat tiles + two dependency-free SVG
   sparklines. No libraries. Values/labels use text tokens; the series wears
   the accent color; SLO state is shown as icon + label, never color alone. */
(function () {
  'use strict';
  var NS = 'http://www.w3.org/2000/svg';
  var tip = document.getElementById('obs-tip');

  function el(id) { return document.getElementById(id); }
  function setText(id, value) { var n = el(id); if (n) n.textContent = value; }
  function fmt(n, digits) {
    if (n === null || n === undefined) return '—';
    return Number(n).toLocaleString('en-US', { maximumFractionDigits: digits === undefined ? 0 : digits });
  }

  function pill(id, met, okText, warnText) {
    var p = el(id);
    if (!p) return;
    if (met === null) { p.textContent = 'no data yet'; return; }
    p.classList.add(met ? 'ok' : 'warn');
    p.textContent = (met ? '✓ ' : '! ') + (met ? okText : warnText);
  }

  function svgNode(name, attrs) {
    var n = document.createElementNS(NS, name);
    Object.keys(attrs).forEach(function (k) { n.setAttribute(k, attrs[k]); });
    return n;
  }

  /* Sparkline: 2px accent line + faint area fill, recessive baseline grid,
     selective labels (first/last x, min/max y, last value), hover tooltip. */
  function sparkline(svgId, tableId, series, key, unit, digits) {
    var svg = el(svgId);
    if (!svg || !series || series.length < 2) return;
    var W = 320, H = 96, PAD = { l: 6, r: 40, t: 12, b: 18 };
    var xs = series.map(function (_, i) { return i; });
    var ys = series.map(function (d) { return d[key]; });
    var yMin = Math.min.apply(null, ys), yMax = Math.max.apply(null, ys);
    if (yMax === yMin) { yMax += 1; yMin -= 1; }
    var pad = (yMax - yMin) * 0.15;
    yMin -= pad; yMax += pad;

    function px(i) { return PAD.l + (i / (xs.length - 1)) * (W - PAD.l - PAD.r); }
    function py(v) { return PAD.t + (1 - (v - yMin) / (yMax - yMin)) * (H - PAD.t - PAD.b); }

    svg.appendChild(svgNode('line', { x1: PAD.l, y1: H - PAD.b, x2: W - PAD.r, y2: H - PAD.b, class: 'grid-line' }));

    var pts = series.map(function (d, i) { return px(i) + ',' + py(d[key]); });
    var area = 'M' + PAD.l + ',' + (H - PAD.b) + ' L' + pts.join(' L') + ' L' + px(xs.length - 1) + ',' + (H - PAD.b) + ' Z';
    svg.appendChild(svgNode('path', { d: area, class: 'series-fill' }));
    var line = svgNode('polyline', { points: pts.join(' '), class: 'series' });
    svg.appendChild(line);

    // Selective labels: first/last time, last value in text tokens.
    var first = svgNode('text', { x: PAD.l, y: H - 4, class: 'axis-label' });
    first.textContent = series[0].t;
    svg.appendChild(first);
    var last = svgNode('text', { x: px(xs.length - 1), y: H - 4, class: 'axis-label', 'text-anchor': 'end' });
    last.textContent = series[series.length - 1].t;
    svg.appendChild(last);
    var lastVal = svgNode('text', { x: W - PAD.r + 4, y: py(ys[ys.length - 1]) + 4, class: 'value-label' });
    lastVal.textContent = fmt(ys[ys.length - 1], digits) + unit;
    svg.appendChild(lastVal);

    // Hover: nearest point → dot + fixed-position tooltip.
    var dot = svgNode('circle', { r: 4, class: 'hover-dot' });
    svg.appendChild(dot);
    svg.addEventListener('pointermove', function (e) {
      var rect = svg.getBoundingClientRect();
      var frac = (e.clientX - rect.left) / rect.width * W;
      var i = Math.round((frac - PAD.l) / (W - PAD.l - PAD.r) * (xs.length - 1));
      i = Math.max(0, Math.min(xs.length - 1, i));
      dot.setAttribute('cx', px(i));
      dot.setAttribute('cy', py(ys[i]));
      dot.classList.add('on');
      tip.textContent = series[i].t + ' · ' + fmt(ys[i], digits) + unit;
      tip.style.left = (e.clientX + 12) + 'px';
      tip.style.top = (e.clientY - 30) + 'px';
      tip.classList.add('on');
    });
    svg.addEventListener('pointerleave', function () {
      dot.classList.remove('on');
      tip.classList.remove('on');
    });

    // Accessible table view.
    var tbody = el(tableId);
    if (tbody) {
      series.forEach(function (d) {
        var tr = document.createElement('tr');
        var td1 = document.createElement('td'); td1.textContent = d.t;
        var td2 = document.createElement('td'); td2.textContent = fmt(d[key], digits);
        tr.appendChild(td1); tr.appendChild(td2);
        tbody.appendChild(tr);
      });
    }
  }

  fetch('/status.json', { cache: 'no-cache' })
    .then(function (r) { if (!r.ok) throw new Error(r.status); return r.json(); })
    .then(function (s) {
      var av = s.slo.availability, lcp = s.slo.lcp;

      setText('slo-availability', av.actual_pct === null ? '—' : fmt(av.actual_pct, 2) + '%');
      pill('pill-availability', av.actual_pct === null ? null : av.actual_pct >= av.target_pct,
        'SLO met', 'SLO at risk');
      setText('slo-budget', av.budget_remaining_pct === null ? '—' : fmt(av.budget_remaining_pct, 0) + '%');
      setText('slo-lcp', lcp.actual_p75_ms === null ? '—' : (lcp.actual_p75_ms / 1000).toFixed(2) + 's');
      pill('pill-lcp', lcp.actual_p75_ms === null ? null : lcp.actual_p75_ms < lcp.target_p75_ms,
        'SLO met', 'SLO at risk');
      setText('stat-requests', fmt(s.traffic.requests_24h));
      setText('stat-errors', 'error rate: ' + (s.traffic.error_rate_24h_pct === null ? '—' : fmt(s.traffic.error_rate_24h_pct, 2) + '%'));

      setText('v-cls', s.vitals.cls_p75 === null ? '—' : fmt(s.vitals.cls_p75, 3));
      setText('v-inp', s.vitals.inp_p75_ms === null ? '—' : fmt(s.vitals.inp_p75_ms) + 'ms');
      setText('v-ttfb', s.vitals.ttfb_p75_ms === null ? '—' : fmt(s.vitals.ttfb_p75_ms) + 'ms');
      setText('v-samples', fmt(s.vitals.samples_7d));

      var when = new Date(s.generated_at);
      setText('obs-updated', 'updated ' + when.toLocaleString('en-US', {
        month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit',
      }) + ' · refreshes hourly');

      sparkline('spark-availability', 'table-availability', s.series.availability_30d, 'pct', '%', 2);
      sparkline('spark-latency', 'table-latency', s.series.probe_latency_24h, 'ms', 'ms', 0);
    })
    .catch(function () {
      document.body.classList.add('obs-no-data');
      setText('obs-updated', 'no data published yet');
    });
})();

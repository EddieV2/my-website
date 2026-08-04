/* Custom RUM: Web Vitals via PerformanceObserver, one sendBeacon per page view.
   Privacy-first by construction — no cookies, no identifiers, no fingerprinting,
   and it honors Do Not Track. ~2KB, no dependencies.
   At fleet scale this job belongs to an OpenTelemetry Collector; for one static
   page, this is the right-sized version. */
(function () {
  'use strict';
  if (navigator.doNotTrack === '1' || window.doNotTrack === '1') return;
  if (!('PerformanceObserver' in window) || !navigator.sendBeacon) return;

  var lcp = 0, cls = 0, inp = 0, sent = false;

  try {
    new PerformanceObserver(function (list) {
      var entries = list.getEntries();
      var last = entries[entries.length - 1];
      if (last) lcp = last.startTime;
    }).observe({ type: 'largest-contentful-paint', buffered: true });

    new PerformanceObserver(function (list) {
      list.getEntries().forEach(function (e) {
        if (!e.hadRecentInput) cls += e.value;
      });
    }).observe({ type: 'layout-shift', buffered: true });

    new PerformanceObserver(function (list) {
      list.getEntries().forEach(function (e) {
        if (e.duration > inp) inp = e.duration;
      });
    }).observe({ type: 'event', buffered: true, durationThreshold: 40 });
  } catch (e) { /* older engine: send what we have */ }

  function send() {
    if (sent) return;
    sent = true;
    var nav = performance.getEntriesByType('navigation')[0];
    var payload = JSON.stringify({
      v: 1,
      path: location.pathname.slice(0, 100),
      lcp: Math.round(lcp),
      cls: Math.round(cls * 1000) / 1000,
      inp: Math.round(inp),
      ttfb: nav ? Math.round(nav.responseStart) : 0,
    });
    navigator.sendBeacon('/rum', payload);
  }

  addEventListener('visibilitychange', function () {
    if (document.visibilityState === 'hidden') send();
  });
  addEventListener('pagehide', send);
})();

/* Custom RUM: Web Vitals via PerformanceObserver, one sendBeacon per page view.
   Privacy-first by construction — no cookies, no identifiers, no fingerprinting,
   and it honors Do Not Track. ~2KB, no dependencies.
   At fleet scale this job belongs to an OpenTelemetry Collector; for one static
   page, this is the right-sized version. */
(function () {
  'use strict';
  if (navigator.doNotTrack === '1' || window.doNotTrack === '1') return;
  if (!('PerformanceObserver' in window) || !navigator.sendBeacon) return;

  /* Own visits are noise, not data. Twelve page views in a fortnight, two of
     them an automated browser, and no way to tell which -- so the owner marks
     their own browser once and stops counting. ?owner=1 sets it, ?owner=0
     clears it, and it lives only in this browser's localStorage: a boolean
     about the person reading, never transmitted, identifying nobody.
     navigator.webdriver catches headless browsers for the same reason. */
  try {
    var flag = new URLSearchParams(location.search).get('owner');
    if (flag === '1') localStorage.setItem('ev-owner', '1');
    else if (flag === '0') localStorage.removeItem('ev-owner');
    if (localStorage.getItem('ev-owner') === '1') return;
  } catch (e) { /* storage blocked: fall through and measure normally */ }
  if (navigator.webdriver) return;

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

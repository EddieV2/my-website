/* Edward Vartanessian — site interactions.
   Everything motion-related checks prefers-reduced-motion; all scroll logic is
   IntersectionObserver-driven (no scroll listeners). */
(function () {
  'use strict';

  var root = document.documentElement;
  var reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
  var finePointer = window.matchMedia('(hover: hover) and (pointer: fine)');

  /* --- Theme toggle (dark is default) ----------------------------------- */
  var toggle = document.getElementById('theme-toggle');
  if (toggle) {
    toggle.addEventListener('click', function () {
      var current = root.dataset.theme === 'light' ? 'light' : 'dark';
      var next = current === 'dark' ? 'light' : 'dark';
      root.dataset.theme = next;
      toggle.setAttribute('aria-label', 'Switch to ' + (next === 'dark' ? 'light' : 'dark') + ' theme');
      try { localStorage.setItem('theme', next); } catch (e) {}
    });
  }

  /* --- Nav: glass once scrolled (sentinel, no scroll listener) ----------- */
  var sentinel = document.getElementById('nav-sentinel');
  if (sentinel && 'IntersectionObserver' in window) {
    new IntersectionObserver(function (entries) {
      document.body.classList.toggle('scrolled', !entries[0].isIntersecting);
    }).observe(sentinel);
  }

  /* --- Scroll-spy -------------------------------------------------------- */
  var spyLinks = Array.prototype.slice.call(document.querySelectorAll('.nav-links a[data-spy]'));
  if (spyLinks.length && 'IntersectionObserver' in window) {
    var byId = {};
    spyLinks.forEach(function (a) { byId[a.getAttribute('href').slice(1)] = a; });
    var spy = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        var link = byId[entry.target.id];
        if (!link) return;
        if (entry.isIntersecting) {
          spyLinks.forEach(function (a) { a.removeAttribute('aria-current'); });
          link.setAttribute('aria-current', 'true');
        }
      });
    }, { rootMargin: '-40% 0px -55% 0px' });
    Object.keys(byId).forEach(function (id) {
      var el = document.getElementById(id);
      if (el) spy.observe(el);
    });
  }

  /* --- Reveal-on-scroll --------------------------------------------------- */
  if (!reduceMotion.matches && 'IntersectionObserver' in window) {
    var reveal = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          entry.target.classList.add('is-visible');
          reveal.unobserve(entry.target);
        }
      });
    }, { threshold: 0.15, rootMargin: '0px 0px -10% 0px' });
    document.querySelectorAll('[data-reveal], .terminal').forEach(function (el) {
      reveal.observe(el);
    });
  } else {
    /* Reduced motion or no IO: show everything immediately. */
    document.querySelectorAll('[data-reveal], .terminal').forEach(function (el) {
      el.classList.add('is-visible');
    });
  }

  /* --- Typed hero kicker -------------------------------------------------- */
  var typed = document.getElementById('typed');
  var hero = document.querySelector('.hero');
  if (typed && hero) {
    if (reduceMotion.matches) {
      hero.classList.add('typed-done');
    } else {
      var full = typed.textContent;
      typed.textContent = '';
      setTimeout(function () {
        var i = 0;
        (function tick() {
          typed.textContent = full.slice(0, ++i);
          if (i < full.length) {
            setTimeout(tick, 55);
          } else {
            setTimeout(function () { hero.classList.add('typed-done'); }, 150);
          }
        })();
      }, 350);
    }
  }

  /* --- Stats count-up ------------------------------------------------------ */
  var stats = document.querySelectorAll('[data-count-to]');
  if (stats.length && !reduceMotion.matches && 'IntersectionObserver' in window) {
    var runCount = function (el) {
      var target = parseInt(el.dataset.countTo, 10);
      var prefix = el.dataset.prefix || '';
      var suffix = el.dataset.suffix || '';
      var start = null;
      var DURATION = 1400;
      function frame(ts) {
        if (start === null) start = ts;
        var t = Math.min((ts - start) / DURATION, 1);
        var eased = 1 - Math.pow(1 - t, 3);
        el.textContent = prefix + Math.round(target * eased).toLocaleString('en-US') + suffix;
        if (t < 1) requestAnimationFrame(frame);
      }
      requestAnimationFrame(frame);
    };
    var statObserver = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (entry.isIntersecting) {
          runCount(entry.target);
          statObserver.unobserve(entry.target);
        }
      });
    }, { threshold: 0.6 });
    stats.forEach(function (el) { statObserver.observe(el); });
  }

  /* --- Diagrams: animate only while on screen ------------------------------ */
  var diagrams = document.querySelectorAll('.diagram');
  if (diagrams.length && !reduceMotion.matches && 'IntersectionObserver' in window) {
    var diagramObserver = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        entry.target.classList.toggle('diagram-live', entry.isIntersecting);
      });
    }, { threshold: 0.2 });
    diagrams.forEach(function (d) { diagramObserver.observe(d); });
  }

  /* --- Card pointer spotlight (fine pointers only) ------------------------- */
  var cardsWrap = document.querySelector('.cards');
  if (cardsWrap && finePointer.matches) {
    cardsWrap.addEventListener('pointermove', function (e) {
      var card = e.target.closest('.card');
      if (!card) return;
      var rect = card.getBoundingClientRect();
      card.style.setProperty('--mx', (e.clientX - rect.left) + 'px');
      card.style.setProperty('--my', (e.clientY - rect.top) + 'px');
    });
  }

  /* --- Hero orb parallax (lerped, fine pointers, stops off-screen) --------- */
  var orbA = document.querySelector('.orb-a');
  var orbB = document.querySelector('.orb-b');
  if (hero && orbA && orbB && finePointer.matches && !reduceMotion.matches && 'IntersectionObserver' in window) {
    var targetX = 0, targetY = 0, curX = 0, curY = 0;
    var running = false, heroVisible = false, idleTimer = null, rafId = null;

    var loop = function () {
      curX += (targetX - curX) * 0.08;
      curY += (targetY - curY) * 0.08;
      orbA.style.transform = 'translate3d(' + (curX * 24) + 'px,' + (curY * 24) + 'px,0)';
      orbB.style.transform = 'translate3d(' + (curX * -16) + 'px,' + (curY * -16) + 'px,0)';
      if (running) rafId = requestAnimationFrame(loop);
    };
    var start = function () {
      if (running) return;
      running = true;
      orbA.style.willChange = 'transform';
      orbB.style.willChange = 'transform';
      rafId = requestAnimationFrame(loop);
    };
    var stop = function () {
      running = false;
      if (rafId) cancelAnimationFrame(rafId);
      orbA.style.willChange = 'auto';
      orbB.style.willChange = 'auto';
    };

    hero.addEventListener('pointermove', function (e) {
      if (!heroVisible) return;
      var rect = hero.getBoundingClientRect();
      targetX = ((e.clientX - rect.left) / rect.width) * 2 - 1;
      targetY = ((e.clientY - rect.top) / rect.height) * 2 - 1;
      start();
      clearTimeout(idleTimer);
      idleTimer = setTimeout(stop, 2000);
    });

    new IntersectionObserver(function (entries) {
      heroVisible = entries[0].isIntersecting;
      if (!heroVisible) stop();
    }).observe(hero);
  }
})();

/* Runs parser-blocking in <head>, before first paint: apply the stored theme
   (dark is the default) and mark JS as available. External file (not inline)
   so the Content-Security-Policy can stay script-src 'self'. */
try {
  var t = localStorage.getItem('theme');
  if (t === 'light' || t === 'dark') document.documentElement.dataset.theme = t;
} catch (e) {}
document.documentElement.classList.add('js');

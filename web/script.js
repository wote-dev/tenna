const root = document.documentElement;
const masthead = document.getElementById('masthead');

// Sentinel instead of a scroll listener, so the sticky header never touches the main thread.
const sentinel = document.createElement('div');
sentinel.setAttribute('aria-hidden', 'true');
sentinel.style.cssText = 'position:absolute;top:0;left:0;width:1px;height:1px;';
document.body.prepend(sentinel);

new IntersectionObserver(
  ([entry]) => masthead.classList.toggle('is-stuck', !entry.isIntersecting)
).observe(sentinel);

if (!window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
  root.classList.add('js');

  const stagger = new IntersectionObserver(
    (entries, observer) => {
      entries.forEach((entry, index) => {
        if (!entry.isIntersecting) return;
        entry.target.style.transitionDelay = `${Math.min(index, 5) * 60}ms`;
        entry.target.classList.add('is-in');
        observer.unobserve(entry.target);
      });
    },
    { rootMargin: '0px 0px -12% 0px' }
  );

  // Anything already on screen stays painted; only offscreen content fades in.
  const threshold = window.innerHeight * 0.9;

  document
    .querySelectorAll('.sheet, .still, .block__head, .row, .step, .plain, .tags, .closing')
    .forEach((element) => {
      if (element.getBoundingClientRect().top < threshold) return;
      element.classList.add('reveal');
      stagger.observe(element);
    });
}

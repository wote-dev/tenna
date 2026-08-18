const root = document.documentElement;
const masthead = document.getElementById('masthead');

// Set this once a real endpoint exists, e.g. "https://api.tennanova.app/waitlist".
// While it is null, submissions never leave the browser — the form just records
// "you're on the list" locally so a refresh keeps showing the success state.
const WAITLIST_ENDPOINT = null;
const WAITLIST_STORAGE_KEY = 'tennanova.waitlist.joined';

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
    .querySelectorAll('.still, .block__head, .card, .step, .never, .privacy__inner, .cta__card')
    .forEach((element) => {
      if (element.getBoundingClientRect().top < threshold) return;
      element.classList.add('reveal');
      stagger.observe(element);
    });
}

function isValidEmail(value) {
  // Deliberately permissive — the input's own type="email" plus this catches the
  // obvious typos without pretending to be a full RFC 5322 validator.
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);
}

function setNote(form, message, state) {
  const note = form.querySelector('.waitlist__note');
  if (!note) return;
  note.textContent = message;
  note.classList.remove('is-error', 'is-success');
  if (state) note.classList.add(state);
}

function markDone(form) {
  form.classList.add('is-done');
  setNote(form, "You're on the list. We'll write when private testing opens.", 'is-success');
}

async function submitWaitlist(email) {
  if (!WAITLIST_ENDPOINT) return true;

  const response = await fetch(WAITLIST_ENDPOINT, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email }),
  });

  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return true;
}

function readJoinedFlag() {
  try {
    return window.localStorage.getItem(WAITLIST_STORAGE_KEY) === '1';
  } catch {
    return false; // Private browsing / disabled storage — fall back to per-visit state.
  }
}

function writeJoinedFlag() {
  try {
    window.localStorage.setItem(WAITLIST_STORAGE_KEY, '1');
  } catch {
    // Nothing to fall back to; the success state still shows for this page view.
  }
}

function initWaitlistForms() {
  const forms = document.querySelectorAll('form.waitlist');
  const alreadyJoined = readJoinedFlag();

  forms.forEach((form) => {
    if (alreadyJoined) markDone(form);

    form.addEventListener('submit', async (event) => {
      event.preventDefault();

      const input = form.querySelector('.waitlist__input');
      const email = input.value.trim();

      if (!email || !isValidEmail(email)) {
        setNote(form, 'That email address looks off — mind checking it?', 'is-error');
        input.focus();
        return;
      }

      const button = form.querySelector('button[type="submit"]');
      button.disabled = true;
      setNote(form, 'Joining…');

      try {
        await submitWaitlist(email);
        writeJoinedFlag();
        markDone(form);
      } catch (error) {
        console.error('Waitlist submission failed:', error);
        setNote(form, "Couldn't reach the server — please try again in a moment.", 'is-error');
        button.disabled = false;
      }
    });
  });
}

initWaitlistForms();

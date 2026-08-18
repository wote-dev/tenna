# Tennanova landing page

Static, light-themed marketing page built around a waitlist signup. Vanilla HTML, CSS and
one small script — no build step, no dependencies, no third-party requests at runtime.

## Preview

```bash
cd web && python3 -m http.server 8000
```

Then open <http://127.0.0.1:8000>. Opening `index.html` directly also works, though the
`Content-Security-Policy` meta tag is written for `http(s)` serving.

## Deploy

Copy the folder to any static host. Serve `index.html` at the root and keep `media/` and
`fonts/` alongside it. Long cache lifetimes are safe for both of those directories; use a
short one for `index.html`.

## Contents

```
index.html   markup and copy
styles.css   tokens, layout, cards, form — light palette mirrors TennaTheme.kt
script.js    waitlist form handling, sticky-header state, offscreen fade-in
media/       icon and the device still, WebP with JPEG/PNG fallbacks
fonts/       self-hosted latin woff2 subsets (Bricolage Grotesque, Source Sans 3, IBM Plex Mono)
```

`media/devices-*` is cropped from `../assets/social/tennanova-x-banner-v2-source.png` with
the baked-in wordmark removed, since the page sets its own type. `media/icon.*` comes from
`../tennanova_icon.png`.

The page works without JavaScript: the waitlist form still submits (though the browser has
nowhere to send it without a real `action`, see below), and without motion — `script.js`
only adds a fade for content that starts below the fold and does nothing when the visitor
prefers reduced motion.

## Waitlist form

Both waitlist forms (`#waitlist` in the hero, and the one in the bottom CTA) are wired up
in `script.js` but have no backend yet:

- `WAITLIST_ENDPOINT` at the top of `script.js` is `null`. While it is `null`, submitted
  emails never leave the browser — the script just validates the address, stores a
  `tennanova.waitlist.joined` flag in `localStorage`, and swaps the form for a success
  message, so a refresh keeps showing "you're on the list".
- To go live, point `WAITLIST_ENDPOINT` at a real API (a Vercel serverless function, a
  hosted form service, etc.) that accepts a JSON POST of `{ "email": "…" }` and returns a
  2xx status. The script then only shows success once that request actually succeeds.
- The page's CSP keeps `form-action 'none'` — submission is handled entirely in JS via
  `fetch`, not a native form POST, so that directive does not need to change.

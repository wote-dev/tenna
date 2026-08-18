# Tennanova landing page

Static "coming soon, private testing" page. Vanilla HTML, CSS and one small script —
no build step, no dependencies, no third-party requests at runtime.

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
styles.css   tokens, layout, glass surfaces — palette mirrors TennaTheme.kt
script.js    sticky-header state and offscreen fade-in; nothing else depends on it
media/       icon and the device still, WebP with JPEG/PNG fallbacks
fonts/       self-hosted latin woff2 subsets (Bricolage Grotesque, Source Sans 3, IBM Plex Mono)
```

`media/devices-*` is cropped from `../assets/social/tennanova-x-banner-v2-source.png` with
the baked-in wordmark removed, since the page sets its own type. `media/icon.*` comes from
`../tennanova_icon.png`.

The page works without JavaScript and without motion: `script.js` only adds a fade for
content that starts below the fold, and it does nothing at all when the visitor prefers
reduced motion.

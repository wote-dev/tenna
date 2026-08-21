# Contributing to Tennanova

Thanks for looking. This is a two-app project held together by one wire format, and almost
everything worth knowing about contributing follows from that.

## The one rule that matters

**`protocol/PROTOCOL.md` is the contract, and both implementations change together.**

- Adding a field within `v:1` is fine. Receivers must ignore keys they do not recognise, and
  both sides already do.
- Changing what an existing field *means*, or adding a message the peer has to understand in
  order to behave correctly, is a version bump.
- A PR that changes the wire without changing `PROTOCOL.md`, the Mac and the Android app in
  the same commit is a PR that leaves someone's paired devices talking past each other.

Capabilities are how a new feature ships without a version bump: the phone advertises what it
can do in `hello`, the Mac advertises what it can do in `hello.ack`, and each side degrades
when the other is older. Prefer a capability to a version bump wherever one fits.

## Building

Full instructions are in the [README](README.md#try-it) — the short version:

```bash
cd mac && ./make-app.sh && open build/TennaNova.app
```

```bash
cd android && ./gradlew installDebug
```

Use `mac/make-app.sh`, not `swift run`. `UNUserNotificationCenter` refuses to work from a bare
executable — it needs a real bundle with a bundle identifier, and it needs a signature.

## Tests

Both suites run in CI on every PR, and both should pass before you open one.

```bash
cd mac && ./test.sh
```

```bash
cd android && ./gradlew testDebugUnitTest
```

```bash
cd relay && npm test
```

`connectedDebugAndroidTest` exists but is not in CI: it needs a real device, and running it
uninstalls the app, which costs a full re-pair.

### Where tests go

The pattern this codebase already follows is to split the decision out from the machinery, and
test the decision. `MirrorDecision`, `DismissalWatch`, `NotificationReplayGuard`,
`ConversationLog` and `IngestOutcome.deservesAnAlert` are all pure types extracted from
something that needed a service, a socket or a notification centre to run. If you find yourself
wanting a test that needs a live phone, look for the decision hiding inside the code first.

One trap, in `mac/Tests`: a file that imports both `Testing` and `Foundation` pulls in the
`_Testing_Foundation` cross-import overlay, and the standalone Command Line Tools ship that
framework without its `.swiftmodule`. Keep Foundation type names in `TestSupport.swift`, which
deliberately does not import `Testing`.

## Reporting bugs

The [README's Status section](README.md#status) says what makes a report useful, and the issue
template asks for it: the phone, the Android version, and the app whose notification, call or
message misbehaved. This has been exercised on a small number of devices, so "my dialer does
something yours doesn't" is a genuinely valuable report rather than a nuisance.

Good areas to work on:

- Dialers and messaging apps whose notifications are shaped unexpectedly.
- Network conditions the connection ladder does not handle.
- Anything in `PROTOCOL.md` that turns out to be wrong.

## Style

Match the file you are editing. The prevailing habit here is that comments explain *why*,
especially where the code looks odd — most of the odd-looking code is odd because a platform
made it that way, and the comment saying which platform and how is the part that saves the next
person a day. Comments that restate the code are not wanted; comments recording a constraint you
had to discover experimentally are.

### macOS interface

The Mac app still supports macOS 14. Native Liquid Glass APIs start at macOS 26, so every use
must sit behind an availability check and keep a standard-material fallback with the same shape,
spacing and interaction. Use Liquid Glass for controls and navigation; use `contentSurface` for
cards in the content layer rather than making every panel compete for attention.

Before shipping a UI change, check light and dark appearances plus Reduce Motion, Reduce
Transparency and Increased Contrast. The window must remain usable at its 720×480 minimum, with
the sidebar hidden, and from the keyboard. Never commit screenshots made from a real mirrored
inbox; use sanitised data for public documentation and bug reports.

## Security

Please do not open a public issue for a vulnerability. See [SECURITY.md](SECURITY.md).

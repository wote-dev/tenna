# Tennanova — handoff

Working doc for continuing the Mac-application work in a fresh session. Self-contained: nothing
from the previous chat is needed. Delete it once the work lands.

---

## 1. Where things stand

**Done and verified on-device (2026-08-19):** the duplicate "Copied" chip and the keyboard-drop
bugs are fixed. All code is written, tested and installed, but **not committed** — `git status`
shows 35 changed/untracked files, most of which are earlier relay work that also predates this.
Committing before starting anything new is strongly advised.

**Next:** Stage 1 below — turn the menu-bar-only Mac app into a real windowed application. Then
calls and SMS.

### The two bugs, and why they happened

*Duplicate "Copied" message.* The app posts no toast of its own; what you saw is Android 13+'s own
clipboard panel, which fires on **every** `setPrimaryClip`. A second panel therefore meant a second
write of content the clipboard already held. Root cause: the Mac re-pushes its pasteboard on every
`hello`, and `PasteboardBridge` never recorded text that arrived *from* the phone as something the
phone already has. Copy on phone → reconnect → Mac sends it straight back → phone writes it → second
panel.

*Keyboard dropping while typing.* `TennaAccessibilityService` adds a focusable window to obtain the
focus Android requires before a clipboard read, and that window was becoming the **IME's** target,
unbinding the keyboard from whatever you were typing in — in every app on the phone. It also fired
while typing: every keystroke refreshed a 2-second window in which any SystemUI event counted as a
copy.

### What changed

| File | Change |
|---|---|
| `mac/.../Clipboard/PasteboardBridge.swift` | New `PeerClipboardState` value type tracking what the phone holds, updated on send **and** receive. Images folded in (the old guard was one-shot and only survived the first reconnect). Notes the hash of the bytes that actually landed on the pasteboard — a phone JPEG is re-encoded to PNG on arrival. Poll path no longer skips the dedup. |
| `android/.../clipboard/CopySignal.kt` *(new)* | Copy detection extracted as a pure, testable `CopySignalDetector`. A caret move or a tap into a text editor now **disarms** the weak SystemUI heuristic; only a selected range (`fromIndex != toIndex`) or a tap on a non-editor arms it. `event.text` is only searched for "copied"/"clipboard" where it names a control or chip, not on selection events (where it is the whole field). |
| `android/.../clipboard/TennaAccessibilityService.kt` | Overlay gains `FLAG_ALT_FOCUSABLE_IM` + `softInputMode = SOFT_INPUT_STATE_UNCHANGED`: still focusable, no longer the IME's target. Detection delegated to `CopySignalDetector`. |
| `android/.../notifications/ClipboardWriter.kt` | New `noteLocalClip(fingerprint, imageSha256)` so the phone records its own copies in the same guard the write path uses. |
| `android/.../notifications/TennaNotificationListener.kt` | Calls `noteLocalClip` on outbound clips; drops an inbound `clip.update` whose `origin` is `"android"`. |
| `android/.../ui/MainActivity.kt` | Share intent consumed once, not once per Activity instance (rotation used to re-send it). |
| `android/.../ui/DashboardScreen.kt`, `AndroidManifest.xml` | `rememberSaveable`, `imePadding()`, `skipPartiallyExpanded`, `windowSoftInputMode="adjustResize"` for the pairing sheet. |
| `protocol/PROTOCOL.md` | Documents both echo rules and the overlay's IME requirements. |

Tests added: `CopySignalTest.kt` (10 cases, both directions), `PeerClipboardStateTests.swift` (5),
plus a fingerprint-format compatibility test. Also fixed a pre-existing stale
`assertDoesNotExist` import in `DashboardScreenTest.kt` that was breaking the instrumentation build.

### Verification results (real device, SM-S942B)

- Phone copies → reconnect → Mac did **not** push it back, no second write.
- Mac copies → phone applied once, still once after a reconnect.
- Phone copies → **full Mac restart** → Mac re-sent (its memory was wiped) and the phone recognised
  its own text and wrote nothing. Both halves of the fix, each covering what the other can't.
- 25s of typing with the service live, including the words "copied" and "clipboard": **0 copy
  signals, 0 keyboard drops** (`mInputShown` checked after every chunk).
- Real copy still works and no longer drops the keyboard:
  `copy signal ... clipStampMoved=true` → `captured text clipboard` → text on the Mac pasteboard →
  `mInputShown=true` immediately after.

---

## 2. Two open issues, unrelated to the fixes

**a. The notification listener does not rebind after an APK update.** It hosts the WebSocket, so the
app runs with no socket at all and looks dead. `requestNotificationRebind()` only fires from
`MainActivity.onResume` when `hasNotificationAccess() && !connectionServiceRunning`, so if the
activity is already resumed it never runs. Hit on this session's install; will hit on every install.
Worth a proper fix (e.g. also request a rebind on `ACTION_MY_PACKAGE_REPLACED`).

**b. The relay is not deployed.** `tennanova-relay.fly.dev` returns **NXDOMAIN** — the hostname does
not exist. `relay/` is in the tree and untracked; `flyctl` is not installed on this machine. This is
the fallback built specifically for public/corporate Wi-Fi with AP client isolation, and it is
absent. During testing the phone was reachable **only** because the USB cable was plugged in.
Worth confirming: unplug USB on café Wi-Fi and see whether the phone finds the Mac at all.

---

**c. The Mac clears every mirrored notification off the phone within ~2 seconds.** Found
while verifying Stage 1; it predates it (the pre-Stage-1 build, PID 19715, logged the same
thing). `NotificationPresenter.checkDismissals` detects a user swipe by diffing what it
believes is live against `getDeliveredNotifications`. On this Mac that call returns **0
delivered notifications** on every poll — nothing is being retained in Notification Center
at all — so two seconds after each card is shown the poller decides the user dismissed it,
sends `notif.dismiss`, and the phone cancels the notification.

Invisible until now, because nothing consumed the consequence. The window does:
cancelling the notification destroys its `RemoteInput` intent, so `isLiveOnPhone` goes
false and **the composer is never available** — which is exactly the Stage 1 acceptance
test in §5. Every thread on screen reads "This notification has been cleared on the phone".

Minimal fix: a key should only become *dismissible* once it has actually been **observed**
in `getDeliveredNotifications`, rather than the moment `center.add` succeeds. What
Notification Center never held, the user cannot have dismissed. Worth confirming the macOS
notification settings for Tennanova at the same time — 0 delivered is itself unusual.

## 3. Environment — read before running anything

```bash
# Android: no JDK on the default PATH
cd android && JAVA_HOME=/opt/homebrew/opt/openjdk@21 ./gradlew testDebugUnitTest assembleDebug
JAVA_HOME=/opt/homebrew/opt/openjdk@21 ANDROID_HOME=$HOME/Library/Android/sdk ./gradlew installDebug

# Mac: bare `swift test` FAILS (Command Line Tools, no Xcode → no `Testing` module).
# These scripts exist for exactly that reason:
cd mac && ./test.sh          # runs the suite
cd mac && ./make-app.sh      # assembles + ad-hoc signs build/TennaNova.app

# adb is not on PATH
export PATH="$HOME/Library/Android/sdk/platform-tools:$PATH"

# Logs
adb logcat -s TennaNova:V TennaClipboard:V
/usr/bin/log show --predicate 'subsystem == "com.tennanova.mac"' --last 5m --info --style compact
```

**Hazards, all learned the hard way:**

- **Never `adb shell am force-stop com.tennanova`.** It can revoke the Accessibility grant, which
  silently kills clipboard capture *and* makes "no spurious copy signals" tests pass vacuously. Only
  the user can restore it in Settings. To force a reconnect, restart the **Mac** app instead:
  `pkill -x TennaNova && open mac/build/TennaNova.app`.
- **Never `./gradlew connectedDebugAndroidTest`.** It uninstalls the app and costs a full re-pair.
- Before trusting any clipboard-capture result, assert the service is live:
  `adb shell dumpsys activity services com.tennanova | grep ServiceRecord` must list
  **both** `TennaAccessibilityService` and `TennaNotificationListener`.
- There is **no Apple Developer account**, so entitlement-gated macOS APIs are off the table. The app
  is ad-hoc signed, not sandboxed, not notarised.

---

## 4. The remaining plan

Everything below is additive within protocol `v:1` via capability flags (`sms.v1`, `call.v1`),
following the existing `clip.image.v1` precedent. `protocol/PROTOCOL.md` is the stated source of
truth and both `Protocol.kt` and `Protocol.swift` carry a "change both together" header.

### The constraint that shapes the call feature

**Android does not let any third-party app capture voice-call audio.** `CAPTURE_AUDIO_OUTPUT` is
privileged/system-only and Google closed the accessibility workaround in 2022. LinkMyMac has the
same limit — their "Call Handling" is *"caller details and supported controls such as answer,
decline, or mute"*, and audio is never mentioned. **Decision taken: the Mac is the control surface;
audio stays on the phone or the user's Bluetooth headset.** A Mac-side Bluetooth hands-free unit via
`IOBluetoothHandsFreeDevice` could route audio without involving the phone app at all, but that is a
separate project on a lightly-documented API and is out of scope.

### Stage 1 — the Mac becomes a real application

**No Android changes.** The single most important finding of the research phase:

> **The Mac already has a complete, populated, tested conversation backend with no UI on top of it.**
> `ConversationLog` (a pure, `Codable`, 20-test reducer), `NotificationStore`, and
> `AppState.reply(to:text:)` / `invoke(action:in:)` / `dismissOnPhone(_:)` are all live and fed by
> real `notif.posted` traffic at `AppState.swift:241` — and **all have zero callers**.
> `AppState.swift:386` is literally headed `// MARK: - Actions from the window`. Optimistic send
> bubbles, `.sent` on socket handoff, `.confirmed` on echo reconciliation,
> `.failed("Phone not connected")`, unread counts and recency sorting already exist and are tested.

So Stage 1 is mostly writing views against an API that already works.

Make it a Dock app that keeps its menu bar — four small edits:
- Drop `LSUIElement` from `mac/Resources/Info.plist:25`.
- `NSApp.setActivationPolicy(.regular)` at `mac/Sources/TennaNova/App.swift:30`.
- Add a `Window("Tennanova", id: "main")` scene beside the existing `MenuBarExtra`, and switch state
  injection to `.environment(delegate.state)` — `MenuBarView` currently takes `AppState` as a
  constructor parameter, which does not scale to a split view.
- Add `applicationShouldHandleReopen` so the Dock icon reopens the window.

Keep `state.start()` in `applicationDidFinishLaunching` — the comment at `App.swift:22` records that
a Scene modifier left the server unstarted.

New views in `mac/Sources/TennaNova/UI/` — a `NavigationSplitView` with Messages / Calls / Device:
- `MainWindow.swift` — split view and sidebar.
- `ConversationList.swift` — rows from `state.history.threads` (already recency-sorted), unread badge
  from `totalUnread`, row text from the existing `NotificationCardText` derivation at
  `NotificationPresenter.swift:68`.
- `ThreadView.swift` — transcript from `thread.messages` with `origin == .mac` right-aligned,
  delivery ticks from `DeliveryState`, composer calling the **existing** `AppState.reply(to:text:)`.
  Call `history.markRead(key)` when a thread is shown.
- `DeviceView.swift` — the pairing QR, hosts, relay and battery content currently inlined in
  `MenuBarView`.
- `TennaStyle.swift` — extract the two idioms `MenuBarView` repeats (the status-`Label` row and
  `.fixedSize(horizontal: false, vertical: true)` captions). The UI folder has **no** shared
  components today; `android/.../ui/TennaTheme.kt` + `TennaComponents.kt` is the visual reference.

Two real blockers:
- `IconCache` is `@ObservationIgnored private let` at `AppState.swift:75`, so views cannot read
  avatars, and it is not observable, so a late-arriving icon would not redraw. Wrap it in a
  `@MainActor @Observable` `IconCatalog` publishing `[hash: NSImage]`, populated where
  `onIconArrived` already runs (`AppState.swift:370`, whose comment already anticipates the window).
  Avatars are already being requested and cached; nothing displays them.
- `ConversationLog` is `Codable` but nothing ever writes it. Persist to
  `~/Library/Application Support/com.tennanova.mac/history.json` (debounced) and load at start.

Note `mac/make-app.sh` copies only `Info.plist` and `AppIcon.icns` — any new resource needs a line
adding there. `Package.swift` pins Swift 5 language mode deliberately; Swift 6 mode "stops compiling
the moment one touches a `@MainActor @Observable` type".

### Stage 2 — take calls (cheap, no new permissions)

In `shouldMirror` (`TennaNotificationListener.kt:532`), exempt `n.category ==
Notification.CATEGORY_CALL` from the `FLAG_ONGOING_EVENT` / `FLAG_FOREGROUND_SERVICE` drops. That is
the **only** reason incoming-call notifications never reach the Mac today. Once through, the dialer's
own Answer and Decline buttons arrive as ordinary `actions` and fire via the existing `notif.action`
path — no `ANSWER_PHONE_CALLS`, no `InCallService`, no default-dialer role.

On the Mac, render a call as a distinct card and an in-window banner rather than a chat row, and
clear it on `notif.removed`. This alone delivers "take calls" as LinkMyMac defines it.

### Stage 3 — SMS: real threads, real sending

**Decision taken: full SMS client** — read real thread history and send to any number, which is
strictly better than LinkMyMac (their sending is notification-reply only).

Android — new `sms/SmsMirror.kt`:
- Read threads/messages from `Telephony.Sms` / `Telephony.Threads` via `ContentResolver`, resolving
  numbers to contact names with `READ_CONTACTS` **before** they go on the wire, so the Mac needs no
  contacts protocol of its own.
- `ContentObserver` on `Telephony.Sms.CONTENT_URI` pushes new messages live.
- Send with `SmsManager.sendTextMessage` + sent/delivered `PendingIntent`s. Sending does **not**
  require being the default SMS app; only writing to the provider and MMS would.
- **Text SMS only.** MMS is out of scope — say so in the UI rather than half-support it.

**Duplicate suppression — the detail that will otherwise ruin this.** Every incoming SMS raises both
a provider row *and* a notification. With mirroring on, the Mac would show each text twice. While
`sms.v1` is active, `shouldMirror` must also drop notifications from
`Telephony.Sms.getDefaultSmsPackage(context)` — the SMS channel owns those conversations.

Protocol (capability `sms.v1`) — builders in `Protocol.kt:96`, mirrored `Codable` structs in
`Protocol.swift`, with a `parse`/`isValid` companion in the `ClipImageHeader` style
(`Protocol.kt:186`) for anything inbound and validatable:

| Message | Direction | Payload |
|---|---|---|
| `sms.threads` | A→M | thread id, addresses, display name, snippet, last activity, unread |
| `sms.thread.request` | M→A | thread id, `beforeId?`, `limit` |
| `sms.messages` | A→M | thread id + messages (id, address, body, when, `origin`, read) |
| `sms.received` | A→M | one new message, pushed live |
| `sms.send` | M→A | address, body, `clientId` |
| `sms.send.result` | A→M | `clientId`, ok, `error?` |

Mac — **reuse `ConversationLog`, don't build a second store.** Add `case sms(threadId: Int64)` to
`ConversationKey` (`ConversationLog.swift:14`) and an `ingest(_ m: SmsMessage, at:)` beside the
existing `ingest(_ n: NotifPosted)`. That gives one unified inbox — SMS and WhatsApp/Signal threads
side by side — and inherits the tested delivery-state machine. `AppState.reply(to:text:)` branches on
the key: `.sms` sends `sms.send` and reconciles on `sms.send.result` then `sms.received`; everything
else keeps using `notif.reply`.

### Stage 4 — make calls, and proper call state

`minSdk = 33`, so every API below is unconditionally available — no version guards.

- **State:** `TelephonyCallback.CallStateListener` (`READ_PHONE_STATE`); incoming number needs
  `READ_CALL_LOG` on API 29+. Push as `call.state` (`idle`/`ringing`/`offhook`, number, contact name,
  direction). Recents from `CallLog.Calls`.
- **Answer:** `TelecomManager.acceptRingingCall()` — `ANSWER_PHONE_CALLS`.
- **Reject / hang up:** `TelecomManager.endCall()` — same permission.
- **Dial:** `ACTION_CALL` intent — `CALL_PHONE`. The call starts on the phone; audio stays there.
- **Mute is not included:** it needs an `InCallService`, which needs the default-dialer role. Say so
  rather than shipping a dead button.

Mac: a Calls section with recents, a dial field, and an incoming-call banner. The UI must state
plainly that audio is on the phone.

### Cross-cutting — the first runtime permissions in this codebase

There are none today. `AndroidManifest.xml` declares only `INTERNET` and `ACCESS_NETWORK_STATE`, and
every existing grant is a deep-link to a Settings screen re-checked on `onResume`. The QR scanner was
even chosen to dodge a `CAMERA` prompt (`build.gradle.kts:75`).

The new permissions need a real `ActivityResultContracts.RequestMultiplePermissions` —
`MainActivity` is a `ComponentActivity` with `activity-compose`, so no new dependency. Reuse the
five-piece pattern the clipboard grant established rather than inventing a second one:

1. Status enums beside `ClipboardAccessStatus` (`ClipboardPayload.kt:8`).
2. Fields + updaters on `RuntimeSnapshot` (`RuntimeStatus.kt:33`).
3. `MainUiState` + `refreshAccessState` (`MainViewModel.kt:111`) — **note** the `combine` there is
   already at the 5-flow overload limit and will need the `vararg` form.
4. Extend the pure `requiredOnboardingStep` (`MainActivity.kt:23`) and its test, preserving
   `advanceOnboarding`'s no-loop behaviour when a grant is still missing.
5. A `ServiceRow` per feature (`DashboardScreen.kt:386`) with a pure `smsCopy()` / `callsCopy()` in
   the style of `clipboardCopy`.

SMS and calls should be **opt-in toggles** in `Settings.kt`, not forced onboarding steps — the app
must stay fully useful for someone who grants neither. Play Store's SMS/Call-Log policy is not a
constraint: `build.gradle.kts:26` records that this app is sideloaded and never published.

---

## 5. Verification per stage

Automated, every stage: the two commands in §3. New unit tests should follow the codebase's
extract-a-pure-function convention (`CopyCommand.kt` / `CopySignal.kt` / `requiredOnboardingStep` are
the models):

- `ConversationLogTests` — SMS ingest into an `.sms` key, dedupe of a resent message, outgoing
  reconciliation via `sms.send.result` then `sms.received`.
- `ProtocolTest` / `ProtocolTests` — round-trip and validation for every new message type.
- `OnboardingTest` — the extended `requiredOnboardingStep`.
- A pure `shouldMirror` decision test for the call-category exemption and default-SMS suppression.

On device:
1. **Stage 1** — open the window, see real threads with history, reply to a WhatsApp thread and watch
   the bubble go optimistic → sent → confirmed. Quit and relaunch: history survives. Dock icon
   reopens the window.
2. **Stage 2** — ring the phone; the Mac shows the call with Answer/Decline; both work.
3. **Stage 3** — threads appear with contact names; send to an existing thread and to a brand new
   number; an arriving text shows **once**, not twice.
4. **Stage 4** — dial from the Mac; answer, reject, hang up; recents populate.

**Sequencing:** Stage 1 is the biggest visible win and touches no Android code, so land it first and
alone. Stage 2 is a few lines and can ride with it. Stages 3 and 4 are each a full Android feature
plus protocol work and should land separately.

Recommended before Stage 1: commit the current work, fix the listener rebind gap (§2a), and deploy
the relay (§2b) — a fallback that doesn't resolve isn't a fallback.

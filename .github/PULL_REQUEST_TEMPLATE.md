## What this changes

<!-- And why. If it fixes an issue, link it. -->

## Checklist

- [ ] `cd mac && ./test.sh` passes
- [ ] `cd android && ./gradlew testDebugUnitTest` passes
- [ ] `cd relay && npm test` passes, if the relay changed

## Wire format

- [ ] This does not change anything crossing the wire, **or**
- [ ] `protocol/PROTOCOL.md`, the Mac app and the Android app all change in this PR, and the
      change is either additive within `v:1` or a version bump

<!-- See CONTRIBUTING.md. Receivers must ignore unknown keys; changing what an existing field
     means, or adding a message the peer must understand to behave correctly, is a bump. A
     capability advertised in `hello` / `hello.ack` is usually the better tool. -->

## Tested on

<!-- Which phone, which Android version, which macOS. "Unit tests only" is a fine answer for a
     change that does not touch a device — say so rather than leaving it blank. -->

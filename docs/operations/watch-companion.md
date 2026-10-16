# Optional Apple Watch companion

This fork can embed a SwiftUI watchOS companion in the mobile iPhone app. Enable
it with `T3CODE_WATCH_COMPANION=1` when generating/building the native client.
The watch uses the phone's paired environments and existing mobile outbox.

## Local development

Install Xcode and matching iOS/watchOS simulator runtimes. Create a paired
phone and watch in Xcode's Device Hub (Xcode 27) or Devices and Simulators
window (older Xcode). Simulator builds do
not require the official T3 Code signing credentials. Keep Xcode’s normal
ad-hoc simulator signing enabled for the phone: removing its signature or
entitlements prevents Keychain-backed connection storage from working.

From the repository root, build the phone through the normal native-client
helper, retaining the flag:

```sh
T3CODE_WATCH_COMPANION=1 node scripts/mobile-native-client.ts ensure ios <iphone-simulator-id>
```

Start Metro from `apps/mobile` using `T3CODE_WATCH_COMPANION=1 vp run dev:client`, open the development
client, and pair it with this worktree's isolated server as described in
`.agents/skills/test-t3-mobile/SKILL.md`. Keep the phone companion open for the
initial setup. The watch target is `T3CodeWatch` in the generated Xcode project;
run it on the paired watch simulator. The watch identifier is the iPhone
identifier with `.watch` appended. Physical-device builds can use your own developer team and matching bundle
identifiers.

Clean prebuilds regenerate the watch target from `apps/mobile/targets/watch`.
Its icon catalog is generated from the selected phone brand asset. The source
folder participates in native fingerprinting when the companion is enabled.
Without the flag, prebuild omits the watch target and its native receiver stays
inactive.

Use the Device panel/`test-t3-mobile` workflow for interactive verification.
If agent device access is off, enable it under Settings → Integrations →
Devices and restart the existing agent session.

## Verification

```sh
vp test run apps/mobile/src/features/watch
vp exec tsc-rs --noEmit -p apps/mobile/tsconfig.json
vp lint apps/mobile/src/features/watch packages/contracts/src/watchCompanion.ts
```

On macOS, the protocol tests compile the actual Swift wire models and
round-trip them against the TypeScript contracts. The Watch target can also
be compiled independently without signing:

```sh
xcodebuild -project apps/mobile/ios/T3CodeDev.xcodeproj \
  -target T3CodeWatch -configuration Debug -sdk watchsimulator \
  -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Before release, verify the paired-client flows with a populated isolated
server: browsing older threads/messages, dictated-text review, reply delivery,
new-thread startup, cancellation before delivery, lost acknowledgments,
reconnection, permission revocation, and app restarts. Test each connection
mode supported by the phone. Actual speech dictation, battery use, and
background wake/delivery behavior also require a physical phone/watch pair.

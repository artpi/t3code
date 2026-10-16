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

## Cable install with a Personal Team

The committed config targets the fork's Piszek developer team. A local Personal
Team build uses different bundle IDs and fewer capabilities. Make the following
changes only in the generated, ignored `apps/mobile/ios` project; clean prebuild
replaces them. Do not copy certificates, provisioning profiles, or an Xcode
account into the repository.

From `apps/mobile`, generate the phone and Watch targets with bundled JavaScript
and OTA updates disabled for this local test build:

```sh
APP_VARIANT=development T3CODE_WATCH_COMPANION=1 T3CODE_MOBILE_UPDATES_ENABLED=0 \
  vp exec expo prebuild --clean --platform ios --no-install
pod install --project-directory=ios
```

Open `ios/T3CodeDev.xcworkspace` in Xcode:

1. Sign in under Settings → Apple Accounts. Connect and trust the iPhone, and
   enable Developer Mode on both phone and Watch. Keep them unlocked and nearby.
2. In the generated project, remove the `ExpoWidgetsTarget` and
   `expo-sharing-extension` targets, their phone target dependencies, and their
   embedded `.appex` entries. Keep `T3CodeWatch` embedded in the phone app.
3. For both remaining app targets, enable automatic signing and select the same
   Personal Team. Use a unique phone bundle ID such as
   `com.piszek.t3code.watchtest` and append `.watch` for the Watch target. If these
   identifiers are unavailable to your account, choose your own prefix.
4. Set the Watch target's `WKCompanionAppBundleIdentifier` build setting to the
   phone's new bundle ID.
5. On the phone target, remove Push Notifications, Sign in with Apple,
   Associated Domains, and App Groups capabilities. Update its Keychain Sharing
   group to the test phone bundle ID, preserving the `$(AppIdentifierPrefix)`
   prefix in the entitlements file. These changes disable unrelated integrations
   for local testing; the Watch still uses the phone's existing connections.
6. In `ios/T3CodeDev/Info.plist`, replace the literal `CFBundleVersion` with
   `$(CURRENT_PROJECT_VERSION)`. Use the same build number for phone and Watch,
   and increase it for each device update.

Use Xcode 27.1 or later, matching the configured EAS image. Xcode 27.0 has a
compiler that enables an upstream iOS 27.1 layout branch even though its SDK
lacks the APIs. If you need to reproduce the local 27.0 build on an older iOS
device, the following temporary VFS overlay disables that branch without
changing tracked source. Prefer upgrading Xcode instead.

```sh
T3_WATCH_SWIFT_FLAGS='$(inherited)'
# Only for the Xcode 27.0 compatibility workaround:
export T3_WATCH_COMPAT_DIR="$(mktemp -d)"
python3 - <<'PY'
import json, os
from pathlib import Path
directory = Path(os.environ["T3_WATCH_COMPAT_DIR"])
source = Path("modules/t3-native-controls/ios/T3LayoutMetricsView.swift").resolve()
replacement = directory / "T3LayoutMetricsView.swift"
replacement.write_text(source.read_text().replace("#if compiler(>=6.4)", "#if false"))
(directory / "sdk-overlay.json").write_text(json.dumps({"version": 0, "roots": [{
    "type": "file", "name": str(source), "external-contents": str(replacement)
}]}))
PY
T3_WATCH_SWIFT_FLAGS="$T3_WATCH_SWIFT_FLAGS -vfsoverlay $T3_WATCH_COMPAT_DIR/sdk-overlay.json"
```

For Xcode 27.1+, set only `T3_WATCH_SWIFT_FLAGS='$(inherited)'` and skip the
overlay commands. From `apps/mobile`, build with a fresh build number:

```sh
APP_VARIANT=development T3CODE_WATCH_COMPANION=1 \
T3CODE_MOBILE_UPDATES_ENABLED=0 RCT_NO_LAUNCH_PACKAGER=1 \
xcodebuild -workspace ios/T3CodeDev.xcworkspace -scheme T3CodeDev \
  -configuration Release -destination 'id=<iphone-udid>' \
  -derivedDataPath /tmp/t3-watch-personal-build \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  CURRENT_PROJECT_VERSION=4 OTHER_SWIFT_FLAGS="$T3_WATCH_SWIFT_FLAGS" build

xcrun devicectl device install app --device '<iphone-udid>' \
  /tmp/t3-watch-personal-build/Build/Products/Release-iphoneos/T3CodeDev.app
xcrun devicectl device process launch --device '<iphone-udid>' \
  com.piszek.t3code.watchtest
```

Substitute your phone UDID and chosen bundle ID. `xcrun devicectl list devices`
lists connected devices. Xcode manages the development certificate and profiles;
do not use `CODE_SIGNING_ALLOWED=NO` for installation on hardware.

The installed phone app bundles the Watch update. Keep the Watch nearby while it
transfers, then reopen the companion. If it is not installed, use the iPhone's
Watch app → My Watch → Available Apps → T3 Code Dev → Install. This update route
was confirmed on a physical pair for build 3. The phone needs its environment
connections configured before the Watch can load threads.

The `artpi` EAS profile separately enables the companion for the Piszek team.
Its new Watch target needs matching signing credentials. The local Personal Team
adjustments above are not part of the EAS configuration; an EAS cloud build has
not yet been verified.

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

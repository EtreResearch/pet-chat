# Draft Clearing, Dock Presence and DMG Install Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Empty the message box on send, show Pet Chat in the Dock with a real icon, and ship an unsigned universal DMG through a tag-triggered GitHub Release.

**Architecture:** Draft handling stays in `AppModel.submit()` and decides restore-vs-retry by whether the Turn was recorded in the thread. Dock presence is a tiny `DockPreference` (UserDefaults + activation policy). The icon is generated once by a Swift script into an asset catalog. Packaging lives in one shell script that both developers and a GitHub Actions workflow run.

**Tech Stack:** Swift 6 / SwiftUI / AppKit (macOS 14), XCTest, bash, `hdiutil`, GitHub Actions (`macos-latest`), `gh` CLI.

**Spec:** `docs/superpowers/specs/2026-10-14-draft-and-install-design.md`

## Global Constraints

- Branch `fix/draft-and-install`; commit after each task (smaller commits welcome). Commit trailer: `Co-Authored-By: <your model name> <noreply@anthropic.com>`.
- macOS 14 deployment target, Swift 6, no new third-party dependencies.
- New source/test files must be added to `PetChat.xcodeproj/project.pbxproj` using real tab characters (a past edit wrote literal `tt` and silently dropped tests — verify the test count goes up).
- Test command: `xcodebuild test -project PetChat.xcodeproj -scheme PetChat -destination 'platform=macOS' -parallel-testing-enabled NO CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES` (add `-only-testing:PetChatTests` for unit only). Run the full suite before each task's final commit.
- Terms per `CONTEXT.md`: **Draft** (unsent text + images in the message box), **Turn** (one user message + the Pet reply answering it).
- Version comes only from the git tag; nothing stores a version in the project. First release `v0.1.0`.
- DMG name `PetChat-<version>.dmg`; app bundle `PetChat.app` (display name "Pet Chat"); bundle id unchanged `com.etre.pet-chat`.
- Releases are **draft** GitHub Releases. Builds are universal (`arm64 x86_64`) and ad-hoc signed (`CODE_SIGN_IDENTITY=-`). No notarization, no Sparkle, no DMG background image.
- Settings key for the Dock setting: `PetChat.showInDock` (Bool, default `true`).
- Keep the `// ponytail:` comment idiom for deliberate simplifications.

## Review Focus

1. User types a new Draft while a send is in flight and the send then fails before the Turn is recorded → the new Draft must not be overwritten (Task 1 test `testPreRecordFailureDoesNotOverwriteNewDraft`).
2. Stop pressed during model discovery (before the Turn is recorded) → sent text/images come back to the Draft even though no error is shown (Task 1 test `testStopBeforeTurnRecordedRestoresDraft`).
3. A failed Turn followed by re-sending identical text (coordinator replaces the failed pair, message count unchanged) → recorded-detection must still be right (Task 1 test `testResendAfterFailedTurnThatFailsAgainLeavesDraftEmpty`).
4. Toggling Show in Dock off while the chat panel is open → panel stays usable; toggling back on restores Dock icon without relaunch (Task 2 test `testTogglingAppliesPolicyImmediately`).
5. Running `scripts/make-dmg.sh` twice / with a stale build dir → second run still produces a correct DMG (Task 4 step: run it twice).

---

### Task 1: Draft clears on send

**Files:**
- Modify: `PetChat/App/AppModel.swift` (init relaunch block ~L56-68; `submit()` ~L210; `tellMeMore`, `sendSuggestion` unchanged but covered)
- Test: `PetChatTests/Conversation/ChatCoordinatorTests.swift` (AppModel tests already live here — follow the existing pattern, e.g. `testAppModelCanSendNeedsTextOrImage`) or a new `PetChatTests/App/AppModelDraftTests.swift` if that file is getting long (add to pbxproj)
- Modify: `PetChatUITests/ChatFlowUITests.swift` (any assertion that the draft persists after send; add an empty-after-Return assertion)

**Interfaces:**
- Consumes: `ChatCoordinator.send(text:attachmentIDs:threadID:)` (records the Turn — appends user + pet(failed) and saves — only after model discovery/validation succeeds; earlier failures leave the thread untouched), `AppModel.generate(_:_:)` (private, returns Bool), `failedGeneration`, `canRetrySubmission`, `errorMessage`, `regenerateLastReply()`.
- Produces: no new public API. Behaviour: `submit()` empties `draft`/`attachmentIDs` before awaiting; restores them per the rules below.

Rules (from spec §1):
- Empty Draft immediately on submit.
- After the generation ends without success (error or Stop): "recorded" ⇔ `thread?.messages.last?.id != lastMessageIDBeforeSend`. If NOT recorded: if `draft.isEmpty && attachmentIDs.isEmpty` restore text+images and keep `failedGeneration = .submit` (error-bar Retry resends the restored Draft); otherwise leave the new Draft and set `canRetrySubmission = false` (only the error shows). If recorded: Draft stays empty and `failedGeneration = .regenerate` so error-bar Retry re-asks the Turn in place.
- Relaunch with a failed last Turn: do not copy the question into the Draft; set `errorMessage = incompleteResponse`, `canRetrySubmission = true`, `failedGeneration = .regenerate`.

- [ ] **Step 1: Write failing tests** (use the existing fake/stub provider helpers in the AppModel tests; read how `testFailedRegenerateRetryDoesNotSendDraft`-style tests build a failing provider and a slow/discovery-blocking provider):

```swift
func testSubmitEmptiesDraftImmediately() async throws {
    // provider whose stream suspends until released; assert model.draft == "" and attachmentIDs == [] while isLoading
}
func testPreRecordFailureRestoresDraft() async throws {
    // provider.availableModels throws → after submit: draft == "Hello", attachmentIDs == [img], errorMessage != nil, canRetrySubmission
    // then retry() with a healthy provider sends "Hello" and empties the draft
}
func testPreRecordFailureDoesNotOverwriteNewDraft() async throws {
    // discovery blocks; user sets model.draft = "new"; discovery then throws → draft == "new", errorMessage != nil, canRetrySubmission == false
}
func testStopBeforeTurnRecordedRestoresDraft() async throws {
    // discovery blocks; await model.stop(); → draft == "Hello", errorMessage == nil
}
func testPostRecordFailureLeavesDraftEmptyAndRetryRegenerates() async throws {
    // stream throws after one delta → draft == "", thread ends user+pet(failed); retry() → still one user message, pet reply replaced, complete
}
func testResendAfterFailedTurnThatFailsAgainLeavesDraftEmpty() async throws {
    // thread already ends with failed Turn "Hello"; draft = "Hello"; stream fails again → draft == "" (Turn recorded: new pet message id)
}
func testRelaunchWithFailedTurnKeepsDraftEmptyAndOffersRegenerate() throws {
    // build coordinator whose stored thread ends user+pet(failed); AppModel(init) → draft == "", attachmentIDs == [], canRetrySubmission
}
```

Write each as a real test with concrete assertions (the comments above give the exact setup and expectations).

- [ ] **Step 2: Run them, confirm they fail**

Run: `xcodebuild test ... -only-testing:PetChatTests` — expect the new tests to FAIL (draft still populated / relaunch copies question). Record the failing output in the report.

- [ ] **Step 3: Implement in `AppModel`**

```swift
func submit() async {
    let text = draft
    let images = attachmentIDs
    let lastIDBefore = thread?.messages.last?.id
    draft = ""
    attachmentIDs = []
    let succeeded = await generate(.submit) { [coordinator] id in
        try await coordinator.send(text: text, attachmentIDs: images, threadID: id)
    }
    guard !succeeded else { return }
    if thread?.messages.last?.id != lastIDBefore {
        // Turn recorded: the message is in the chat; Retry re-asks it in place.
        failedGeneration = .regenerate
    } else if draft.isEmpty && attachmentIDs.isEmpty {
        draft = text
        attachmentIDs = images
    } else {
        // ponytail: the unsent images' files stay in the chat folder until the chat is deleted.
        canRetrySubmission = false
    }
}
```

"Tell me more" and suggestion chips must never leave their text in the box (spec §1): factor the body above into `private func send(text: String, images: [UUID], restoresDraft: Bool) async` — `submit()` calls it with the Draft and `restoresDraft: true`; `tellMeMore()` and `sendSuggestion(_:)` call it directly with their text, `images: []`, `restoresDraft: false` (no longer assigning `draft = ...` first). With `restoresDraft: false` and a pre-record failure, just show the error with `canRetrySubmission = false`. Add test `testChipFailureBeforeRecordLeavesDraftEmpty`. Keep their existing guards (`canTellMeMore`, empty Draft for chips).

Notes: `generate` returns false early (busy, shutting down, no thread) without touching anything — in that case the thread is unchanged so the Draft is restored, which is correct. Check `generate`'s guards run BEFORE the Draft is cleared matters: if `generate` bails because `isLoading`, restoring is right. Keep the existing "Stop" path working (`stop()` clears `activeSubmissionID`; `generate` returns false; restore runs). In `init`, replace the relaunch block's `draft = question.text` / `attachmentIDs = question.attachmentIDs` / `failedGeneration = .submit` with `failedGeneration = .regenerate` (keep errorMessage + canRetrySubmission); drop the now-unused `question` binding if it becomes unused (keep the `role == .user` check via `thread.lastAnsweredQuestion != nil` or equivalent).

- [ ] **Step 4: Run unit tests — all pass**, including existing `testStopAndRetry`-adjacent unit tests; fix any existing test that asserted the old "draft persists until completion" behaviour (update it to the new rules, don't delete it).

- [ ] **Step 5: UI tests** — in `PetChatUITests/ChatFlowUITests.swift`, update any test expecting the draft to remain after send/failure (e.g. `testStopAndRetry`: after stop/failed send, check what the box should contain under the new rules). Add to `testReturnSendsAndShiftReturnInsertsNewline` (or a new test) an assertion that the "Message" text view's value is empty immediately after Return, while the reply is still streaming if the fixture allows.

- [ ] **Step 6: Full suite, then commit**

```bash
git add PetChat/App/AppModel.swift PetChatTests PetChatUITests PetChat.xcodeproj/project.pbxproj
git commit -m "fix: empty the message box on send and restore it only if the turn never started"
```

---

### Task 2: Dock presence and "Show in Dock" setting

**Files:**
- Create: `PetChat/Platform/DockPreference.swift`
- Test: `PetChatTests/Platform/DockPreferenceTests.swift`
- Modify: `PetChat.xcodeproj/project.pbxproj` (remove `INFOPLIST_KEY_LSUIElement = YES;` from both app build configs; add the two new files)
- Modify: `PetChat/App/AppDelegate.swift` (own a `DockPreference`, apply at launch, `applicationShouldHandleReopen`, make `showSettings()` reachable from the app menu)
- Modify: `PetChat/App/PetChatApp.swift` (replace the default Settings menu item so Cmd+, opens our settings window, not the empty SwiftUI `Settings` scene)
- Modify: `PetChat/Views/SettingsView.swift` (add "Show in Dock" toggle next to "Launch at login")
- Check: `PetChat/App/UITestFixture.swift` — UI tests run with fixture defaults; Dock default `true` is fine, but make sure nothing in the fixture depends on accessory policy.

**Interfaces:**
- Produces:

```swift
@MainActor @Observable
final class DockPreference {
    static let key = "PetChat.showInDock"
    private(set) var showInDock: Bool
    init(defaults: UserDefaults = .standard,
         setPolicy: @escaping (NSApplication.ActivationPolicy) -> Void = { NSApp.setActivationPolicy($0) })
    func setShowInDock(_ show: Bool)   // persists, then applies
    func apply()                        // .regular when showInDock else .accessory
}
```

- [ ] **Step 1: Failing tests** in `DockPreferenceTests.swift`:

```swift
@MainActor final class DockPreferenceTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "DockPreferenceTests-\(UUID())")!
        return d
    }
    func testDefaultsToShowingInDock() {
        var applied: [NSApplication.ActivationPolicy] = []
        let pref = DockPreference(defaults: defaults(), setPolicy: { applied.append($0) })
        pref.apply()
        XCTAssertTrue(pref.showInDock)
        XCTAssertEqual(applied, [.regular])
    }
    func testTogglingAppliesPolicyImmediately() {
        var applied: [NSApplication.ActivationPolicy] = []
        let pref = DockPreference(defaults: defaults(), setPolicy: { applied.append($0) })
        pref.setShowInDock(false)
        pref.setShowInDock(true)
        XCTAssertEqual(applied, [.accessory, .regular])
    }
    func testSettingPersists() {
        let d = defaults()
        DockPreference(defaults: d, setPolicy: { _ in }).setShowInDock(false)
        XCTAssertFalse(DockPreference(defaults: d, setPolicy: { _ in }).showInDock)
    }
}
```

- [ ] **Step 2: Run, confirm FAIL** (type not found).

- [ ] **Step 3: Implement `DockPreference`**

```swift
import AppKit
import Observation

@MainActor @Observable
final class DockPreference {
    static let key = "PetChat.showInDock"
    private let defaults: UserDefaults
    private let setPolicy: (NSApplication.ActivationPolicy) -> Void
    private(set) var showInDock: Bool

    init(defaults: UserDefaults = .standard,
         setPolicy: @escaping (NSApplication.ActivationPolicy) -> Void = { NSApp.setActivationPolicy($0) }) {
        self.defaults = defaults
        self.setPolicy = setPolicy
        showInDock = defaults.object(forKey: Self.key) as? Bool ?? true
    }

    func setShowInDock(_ show: Bool) {
        showInDock = show
        defaults.set(show, forKey: Self.key)
        apply()
    }

    func apply() { setPolicy(showInDock ? .regular : .accessory) }
}
```

- [ ] **Step 4: Wire it up**
  - `AppDelegate`: `private let dockPreference = DockPreference()` (for the UI-test fixture path pass `fixture.defaults`); call `apply()` at the start of `startDesktop`. Implement:

```swift
func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    panelController?.showChat()   // verify showChat re-shows a hidden pet; if not, call showPetOnly() first
    return true
}
```

  - Make `showSettings()` non-private (internal) so the app menu can call it.
  - `PetChatApp`: add `.commands { CommandGroup(replacing: .appSettings) { Button("Settings…") { appDelegate.showSettings() }.keyboardShortcut(",") } }` to the `Settings { EmptyView() }` scene. Quit (Cmd+Q) already exists in the default app menu and routes through `applicationShouldTerminate`.
  - `SettingsView`: pass the `DockPreference` in (same way `panelController`/`shortcutController` are passed) and add `Toggle("Show in Dock", isOn: Binding(get: { dock.showInDock }, set: { dock.setShowInDock($0) }))` with `.accessibilityLabel("Show in Dock")`, placed beside "Launch at login".
  - After `setActivationPolicy(.accessory)` macOS may deactivate the app; if the Settings window disappears behind other windows, call `NSApp.activate(ignoringOtherApps: true)` and re-order the settings window front after toggling. Verify manually.
  - Remove `INFOPLIST_KEY_LSUIElement = YES;` from both PetChat build configurations in pbxproj.

- [ ] **Step 5: Run unit tests — PASS.** Then build and launch the app (`xcodebuild build ... -derivedDataPath /private/tmp/pet-chat-debug` then `open .../PetChat.app`) and verify by hand: Dock icon visible; clicking it opens the chat; app menu has Settings… (Cmd+,) opening the real settings window and Quit (Cmd+Q) quitting cleanly; toggling Show in Dock off removes the icon immediately and on restores it. Quit the app afterwards. Note results in the report.

- [ ] **Step 6: Full suite, commit**

```bash
git add PetChat PetChatTests PetChat.xcodeproj/project.pbxproj
git commit -m "feat: show Pet Chat in the Dock with a Show in Dock setting"
```

---

### Task 3: App icon

**Files:**
- Create: `scripts/make-icon.swift`
- Create: `PetChat/Assets.xcassets/Contents.json`, `PetChat/Assets.xcassets/AppIcon.appiconset/Contents.json` + 10 PNGs (`icon_16x16.png`, `icon_16x16@2x.png`, `icon_32x32.png`, `icon_32x32@2x.png`, `icon_128x128.png`, `icon_128x128@2x.png`, `icon_256x256.png`, `icon_256x256@2x.png`, `icon_512x512.png`, `icon_512x512@2x.png`)
- Modify: `PetChat.xcodeproj/project.pbxproj` (add the asset catalog to the PetChat target's Resources build phase — create a Resources phase if the target has none; add `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;` to both app build configs)

**Interfaces:**
- Consumes: the cat drawing in `PetChat/Views/PetCharacterView.swift` (Canvas paths in a 64×64-ish coordinate space; colours blue `rgb(0.38,0.46,0.61)`, dark `rgb(0.19,0.24,0.34)`).
- Produces: `AppIcon` asset; the built app's `Contents/Resources/AppIcon.icns` + `CFBundleIconName = AppIcon`.

- [ ] **Step 1: Write `scripts/make-icon.swift`** — a standalone script run with `swift scripts/make-icon.swift <output-dir>`. It draws, with CoreGraphics into a 1024×1024 bitmap: a cream `#FBF8F1` rounded rectangle 824×824 centred (corner radius 185) with a soft shadow (offset 0,-10, blur 20, black 25%), then the cat from `PetCharacterView` — copy its static (non-blinking, non-animated, isThinking=false) paths, scaled to fit ~600px tall and centred in the tile. It then downsamples to each required size and writes the 10 PNGs named as above, plus the `Contents.json` for the appiconset (macOS idiom `mac`, sizes 16/32/128/256/512 at scales 1x/2x). Keep it under ~120 lines; no dependencies beyond AppKit/CoreGraphics.

- [ ] **Step 2: Generate and inspect**

Run: `swift scripts/make-icon.swift PetChat/Assets.xcassets/AppIcon.appiconset`
Then open `icon_512x512@2x.png` (and `icon_32x32.png`) and look at it: the cat must be recognisable, centred, not clipped, on the cream rounded square. Save a copy of the 1024 render path in the report. Iterate until it looks right.

- [ ] **Step 3: Wire into the project** — add `Assets.xcassets` (folder reference type `folder.assetcatalog`) to the PetChat group and Resources phase; add `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;`. Create `PetChat/Assets.xcassets/Contents.json` with `{"info":{"author":"xcode","version":1}}`.

- [ ] **Step 4: Verify the built app has the icon**

Run: build Debug, then `ls /private/tmp/pet-chat-debug/Build/Products/Debug/PetChat.app/Contents/Resources/` → expect `AppIcon.icns` (and/or `Assets.car`); `/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' .../Contents/Info.plist` → `AppIcon`.

- [ ] **Step 5: Full suite, commit**

```bash
git add scripts/make-icon.swift PetChat/Assets.xcassets PetChat.xcodeproj/project.pbxproj
git commit -m "feat: add a Pet Chat app icon drawn from the pet cat"
```

---

### Task 4: DMG script and release workflow

**Files:**
- Create: `scripts/make-dmg.sh` (executable)
- Create: `.github/workflows/release.yml`
- Modify: `.gitignore` (ignore `dist/`)

**Interfaces:**
- Consumes: Task 3's icon (already in the project).
- Produces: `scripts/make-dmg.sh <version>` → `dist/PetChat-<version>.dmg`; prints the DMG path last.

- [ ] **Step 1: Write `scripts/make-dmg.sh`**

```bash
#!/usr/bin/env bash
# Builds an unsigned (ad-hoc), universal Pet Chat and packages it as dist/PetChat-<version>.dmg.
# ponytail: no Developer ID / notarization yet — users approve the first launch with Open Anyway.
set -euo pipefail
version="${1:?usage: scripts/make-dmg.sh <version, e.g. 0.1.0>}"
build_number="${GITHUB_RUN_NUMBER:-1}"
root="$(cd "$(dirname "$0")/.." && pwd)"
derived="$root/build/release-derived"
stage="$root/build/dmg-stage"
out="$root/dist/PetChat-$version.dmg"

rm -rf "$derived" "$stage" "$out"
mkdir -p "$stage" "$root/dist"

xcodebuild build -project "$root/PetChat.xcodeproj" -scheme PetChat -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$derived" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number" \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES

app="$derived/Build/Products/Release/PetChat.app"
archs="$(lipo -archs "$app/Contents/MacOS/PetChat")"
[[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || { echo "expected universal binary, got: $archs" >&2; exit 1; }
codesign --verify --deep --strict "$app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" == "$version" ]]

ditto "$app" "$stage/PetChat.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "Pet Chat" -srcfolder "$stage" -fs HFS+ -format UDZO "$out" >/dev/null
hdiutil verify "$out" >/dev/null
echo "$out"
```

`chmod +x scripts/make-dmg.sh`. Add `dist/` to `.gitignore` (`build/` is already ignored).

- [ ] **Step 2: Run it locally, twice** (Review Focus 5)

Run: `scripts/make-dmg.sh 0.0.0-test` twice. Expect the DMG path printed both times. Then `hdiutil attach -nobrowse -readonly dist/PetChat-0.0.0-test.dmg`, `ls` the mount (expect `PetChat.app` and `Applications ->`), check `lipo -archs` on the mounted binary prints `x86_64 arm64`, check `CFBundleShortVersionString` = `0.0.0-test`… note: if `0.0.0-test` is rejected as a version by the build, use `0.0.1` instead. `hdiutil detach` the mount. Delete the test DMG.

- [ ] **Step 3: Write `.github/workflows/release.yml`**

```yaml
name: Release
on:
  push:
    tags: ['v*']
permissions:
  contents: write
jobs:
  release:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - name: Unit tests
        run: xcodebuild test -project PetChat.xcodeproj -scheme PetChat -destination 'platform=macOS' -only-testing:PetChatTests -parallel-testing-enabled NO CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES
      - name: Build DMG
        id: dmg
        run: echo "path=$(scripts/make-dmg.sh "${GITHUB_REF_NAME#v}" | tail -n1)" >> "$GITHUB_OUTPUT"
      - name: Draft release
        env:
          GH_TOKEN: ${{ github.token }}
        run: gh release create "$GITHUB_REF_NAME" "${{ steps.dmg.outputs.path }}" --draft --generate-notes --title "Pet Chat ${GITHUB_REF_NAME#v}"
```

Validate syntax locally if `actionlint` is installed (`actionlint .github/workflows/release.yml`); otherwise check with `ruby -ryaml -e 'YAML.load_file(".github/workflows/release.yml")'`. Do NOT push tags or trigger the workflow — the user cuts the first release.

- [ ] **Step 4: Commit**

```bash
git add scripts/make-dmg.sh .github/workflows/release.yml .gitignore
git commit -m "build: package a universal DMG and draft a GitHub Release on version tags"
```

---

### Task 5: README for normal users

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: Task 4's script name/usage and DMG name; Task 2's setting name "Show in Dock"; Task 1's Draft behaviour.

- [ ] **Step 1: Rewrite the top of README**
  - "What you need": macOS 14 or newer; an AI (Ollama or ChatGPT, keep existing text). Drop "with Xcode installed" from the user requirements.
  - "Install" (numbered): 1) Download `PetChat-<version>.dmg` from the [Releases page](https://github.com/EtreResearch/pet-chat/releases/latest). 2) Open it and drag **Pet Chat** onto **Applications**. 3) Open Pet Chat from Applications. 4) macOS will say it can't check the app for malicious software — click **Done**, then open **System Settings → Privacy & Security**, scroll down to the Pet Chat message and click **Open Anyway**, then confirm with your password. You only do this once. One sentence why: Pet Chat isn't signed with an Apple Developer ID yet.
  - "Updating": download the new DMG and drag it to Applications, replacing the old copy. If you use ChatGPT, macOS may ask once whether Pet Chat can use its saved keychain item — click **Always Allow**.
  - Replace "There is no Dock icon" with: the cat sits in the bottom-right corner; Pet Chat shows in the Dock and the menu bar; turn off **Show in Dock** in Settings to keep it to the menu bar only.
  - "Use it": step 3 becomes "Type your question and press **Return** (Shift + Return for a new line)."; mention the box empties when you send.
- [ ] **Step 2: Add "Build from source" and "Releasing" sections** near the bottom: the existing `xcodebuild` + `ditto` + `open` commands (needs Xcode); `scripts/make-dmg.sh 0.1.0` to build a DMG locally (output in `dist/`); to release, `git tag v0.1.0 && git push origin v0.1.0`, wait for the Release workflow, then review and publish the draft on GitHub Releases.
- [ ] **Step 3: Proofread for stale statements** (`grep -n "Command + Return\|Dock\|xcodebuild" README.md`) and commit

```bash
git add README.md
git commit -m "docs: download-and-drag install, updating, and release instructions"
```

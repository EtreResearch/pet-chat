# Task 8 implementation report

Status: DONE_WITH_CONCERNS (automated native coverage passes; real capture/desktop visual checks remain unverified).

Implementation commit: `5f55b3c feat: capture and attach explicit screen regions`.
Base: `87954e6`; branch: `design/pet-chat`. Task ledger intentionally unchanged.

## Implemented and scope considered

- Added `RegionCaptureController.captureRegion() async throws -> Data?`: explicit permission check/request, Escape cancellation returning nil, validated one-display selection, macOS 14 `SCScreenshotManager.captureImage`, PNG encoding, and display-disconnect/change errors. No capture or permission query happens at construction, launch, or idle.
- Added native per-display `RegionSelectionOverlay` panels. Reverse drags normalize and clamp within the initiating display; Escape closes all selection panels. Empty selections fail before pixel capture.
- Converted AppKit global bottom-left rectangles into selected-display-local top-left **logical points** for `SCStreamConfiguration.sourceRect`. Applied `SCContentFilter.pointPixelScale` only to output pixel width/height, with upward rounding. Negative screen origins and Retina are covered by literal expected rectangles/dimensions.
- Screenshot filter excludes this app's applications/windows with `SCContentFilter(display:excludingApplications:exceptingWindows:)`; there is no arbitrary capture delay and no reliance on window `sharingType`.
- Reused `PetPanelController` placement/fullscreen/presentation paths. Pet and chat hide before permission/selection/capture. Success, Escape, and errors restore the chat; explicit hide/collapse or space/display changes invalidate restoration. Restore never activates the app, and deactivation prevents focus restoration. Queued composer focus still checks active/key state.
- Added explicit **Capture area** and **Paste image** composer actions, horizontally scrolling removable previews, and historical image thumbnails. Native `TextEditor` continues handling ordinary text editing/paste. Capture and paste create a preview only; Send submits it.
- `AppModel` owns draft IDs and a draft-context ID. Thread/provider changes invalidate asynchronous capture results and errors, including switching away and then deleting the new chat to return to the original thread. Captures cannot silently attach to another draft.
- `AttachmentStore.save` decodes/validates bytes before creating directories or writing files. Clipboard PNG is validated directly; other native clipboard image formats are converted to PNG.
- `ChatCoordinator` retains ownership of storage and checks submitted message references before deleting a removed draft image. Removing a failed-turn preview preserves its historical image file. Removing an unsubmitted preview deletes only its file. Image-capability validation happens before persisting a turn, preserving draft/images on unsupported-model errors.
- Existing provider request builders/context already send only current-turn image bytes; no provider wire-format changes were needed. Successful Send clears draft previews; failures preserve them; following text turns do not resend old images.
- Added a partial `PetChat/Info.plist`, merged with generated app metadata for Debug/Release. A bundle regression test caught Xcode dropping the custom `NSScreenCaptureUsageDescription` when represented only as a generated-key build setting. Explicit plist now carries the required purpose string.
- Updated fake-byte persistence/coordinator fixtures to valid synthetic PNG, used isolated named pasteboards and defaults, and temporary/in-memory storage. Hosted preview fixture removes its temporary attachment directory. No standard pasteboard, live account, live inference, screen pixels, privacy grants, or actual screen permission requests were used.

Callers/config checked: `AppDelegate` launch and panel ownership; `AppModel` select/new/delete/submit/retry/stop; `ChatCoordinator` send/retry/delete/storage; `ContextBuilder`; Ollama/OpenAI current-turn image validation/builders; `LocalChatStore` staged whole-thread deletion; composer/chat/message views; `PetPanelController` show/collapse/hide/space/display/deactivation/focus paths; Xcode source membership and bundled app metadata; persistence/coordinator/panel/accessibility/UI test fixtures. No dependencies, alternate provider seams, background capture, or additional preferences were introduced.

## TDD and commands

All xcodebuild test invocations below ran with the authorized sandbox escalation because sandboxed SwiftDataMacros cannot compile. Common command prefix:

```sh
xcodebuild test -project PetChat.xcodeproj -scheme PetChat \
  -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/pet-chat-task8-derived \
  -parallel-testing-enabled NO
```

Every invocation also supplied `CODE_SIGNING_ALLOWED=NO` and redirected combined output to its stated log.

### RED evidence

1. Before production edits: prefix + `-only-testing:PetChatTests/AttachmentStoreTests CODE_SIGNING_ALLOWED=NO > /private/tmp/task8-red.log 2>&1`.
   - `testInvalidImageIsRejectedWithoutCreatingFiles` failed both assertions: `XCTAssertThrowsError failed: did not throw an error` and `XCTAssertFalse failed`.
   - 2 tests executed, 2 assertion failures. Expected: existing store accepted arbitrary bytes and wrote them.
2. New capture/draft test surfaces before their implementation: prefix + `-only-testing:PetChatTests/RegionCaptureTests -only-testing:PetChatTests/ChatCoordinatorTests CODE_SIGNING_ALLOWED=NO > /private/tmp/task8-feature-red.log 2>&1`.
   - Build failed because `RegionSelection`, `RegionCaptureController`, and `RegionSelectionOverlay` did not exist. This is compile-only RED for new APIs, not claimed as behavioral runtime RED.
3. Discovered missing bundled purpose: prefix + `-only-testing:PetChatTests/AppConfigurationTests CODE_SIGNING_ALLOWED=NO > /private/tmp/task8-bundle-red.log 2>&1`.
   - `testScreenCapturePurposeIsPresentInAppBundle`: `XCTAssertFalse failed`; 2 tests, 1 failure. `PlistBuddy` independently reported the key absent. Fixed with explicit partial plist.
4. Self-review late-capture race, before the context-ID fix: prefix + `-only-testing:PetChatTests/ChatCoordinatorTests/testLateCaptureCannotReattachAfterSwitchingAwayAndBack CODE_SIGNING_ALLOWED=NO > /private/tmp/task8-context-race-red.log 2>&1`.
   - 1 test, 2 assertion failures: old capture attached an image and created its directory after returning to the original thread. Context invalidation now discards it.

### GREEN evidence

- Focused integration: prefix + `-only-testing:PetChatTests/RegionCaptureTests -only-testing:PetChatTests/ChatCoordinatorTests -only-testing:PetChatTests/AttachmentStoreTests -only-testing:PetChatTests/ChatAccessibilityTests -only-testing:PetChatTests/PetPanelTests CODE_SIGNING_ALLOWED=NO > /private/tmp/task8-focused-green.log 2>&1` — **52 tests, 0 failures**.
- Bundle/settled hosting checks: prefix + `-only-testing:PetChatTests/ChatAccessibilityTests -only-testing:PetChatTests/AppConfigurationTests CODE_SIGNING_ALLOWED=NO > /private/tmp/task8-preview-settled.log 2>&1` — **4 tests, 0 failures**. `PlistBuddy` printed the bundled capture purpose string.
- Initial full unit target: prefix + `-only-testing:PetChatTests CODE_SIGNING_ALLOWED=NO > /private/tmp/task8-full-unit.log 2>&1` — **112 tests, 0 failures**.
- Context-race fix: prefix + `-only-testing:PetChatTests/ChatCoordinatorTests CODE_SIGNING_ALLOWED=NO > /private/tmp/task8-context-race-green.log 2>&1` — **30 tests, 0 failures**.
- Final full unit target before feature commit: prefix + `-only-testing:PetChatTests CODE_SIGNING_ALLOWED=NO > /private/tmp/task8-final-full-unit.log 2>&1` — **113 tests, 0 failures**, `** TEST SUCCEEDED **`.
  - Result bundle: `/private/tmp/pet-chat-task8-derived/Logs/Test/Test-PetChat-2026.10.12_18-20-41-+0530.xcresult`.
- Final test-fixture-only attachment-directory cleanup verified with prefix + `-only-testing:PetChatTests/ChatAccessibilityTests CODE_SIGNING_ALLOWED=NO > /private/tmp/task8-fixture-cleanup-green.log 2>&1` — **2 tests, 0 failures**.
- `git diff --check` passed before commit.

Intermediate integration log `/private/tmp/task8-focused.log` includes a corrected Swift default-argument `Self` compile error and one remaining old two-byte image fixture failure. The fixture was migrated to actual PNG before the passing integration/full runs. Logs contain macOS linkd/AppKit diagnostics and occasional AppIntents metadata extraction warnings; output is not claimed pristine. No final test failures or Swift compiler diagnostics remain.

## Coverage and files

Capture tests cover denied permission with no selection/pixels, actual Escape key cancellation with no pixels, empty/outside/nonfinite selections, reversed/clamped overlay drag, negative-origin displays, Y-axis conversion, and Retina output dimensions. Coordinator tests cover explicit clipboard paste, invalid-paste retention, removable previews, failure ownership, image-capability rejection, success-only clearing, no old-image resend, success/cancel capture previews, late thread/provider changes, and switch-away-and-back invalidation. Native panel tests cover hiding/restoring on success/cancel/error, respecting explicit hide, and restoring visibility without taking focus after deactivation. Hosted accessibility checks include preview/remove/capture/paste controls. UI runner source adds capture/paste control checks when configured.

Created: `PetChat/Platform/RegionCaptureController.swift`, `PetChat/Views/RegionSelectionOverlay.swift`, `PetChat/Info.plist`, `PetChatTests/Platform/RegionCaptureTests.swift`.

Modified: `PetChat/App/AppModel.swift`, `PetChat/Conversation/ChatCoordinator.swift`, `PetChat/Persistence/AttachmentStore.swift`, `PetChat/Platform/PetPanelController.swift`, `PetChat/Views/ComposerView.swift`, `PetChat/Views/MessageRowView.swift`, `PetChat/Views/ChatPanelView.swift`, `PetChat.xcodeproj/project.pbxproj`, `PetChatTests/AppConfigurationTests.swift`, `PetChatTests/Conversation/ChatCoordinatorTests.swift`, `PetChatTests/Persistence/AttachmentStoreTests.swift`, `PetChatTests/Persistence/LocalChatStoreTests.swift`, `PetChatTests/Platform/PetPanelTests.swift`, `PetChatTests/Views/ChatAccessibilityTests.swift`, `PetChatUITests/PetPanelUITests.swift`.

## SDK verification and self-review

Read installed SDK `ScreenCaptureKit.framework/Headers/SCStream.h`: sourceRect is explicitly documented as points in the display's logical coordinate system; contentRect is in points; pointPixelScale provides conversion. Confirmed macOS 14 availability of the used filter/screenshot APIs. Primary documentation: [SCStreamConfiguration.sourceRect](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/sourcerect) and [SCContentFilter.pointPixelScale](https://developer.apple.com/documentation/screencapturekit/sccontentfilter/pointpixelscale).

Self-review fixed the generated-plist omission, migrated the last invalid historical fixture, avoided deleting images referenced by failed turns, and added context invalidation for a switch away/back. Read the final diff against base, verified no temporary export code remained, and left unrelated architecture/provider code/ledger untouched.

## Remaining limits

- Real first-use Screen Recording permission, selected-display pixel accuracy on real hardware, app-window exclusion in real captured pixels, and a vision-model response were intentionally not exercised. The implementation compiles against macOS 14 APIs; macOS 14 hardware runtime was unavailable.
- Separate UI runner is known to fail before bootstrap. Its test source compiled as part of native builds; it was not rerun or diagnosed here, per assignment. Task 10 owns ad-hoc signing follow-up.
- Synthetic native offscreen export `/private/tmp/task8-composer-preview.png` was attempted twice (including a settled main-loop/layout/display pass and white compositing). The export omitted SwiftUI layer content; only native editor/pet content was visible. It is **not** evidence of full visual layout. Temporary export code was removed. Accessibility checks with a real synthetic attachment pass, but visual QA remains incomplete.
- New capture/draft API tests began with compile-only RED; validation, bundled metadata, and the late-result regression have behavioral runtime RED. No broader claim of runtime RED for every new API is made.
- As in existing draft lifecycle behavior, switching chats clears draft IDs; abandoned unsubmitted files remain in that thread's directory until whole-thread deletion. No speculative cleanup policy was added.

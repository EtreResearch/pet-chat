# macOS Pet Chat Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the approved personal macOS pet app for concise, streaming answers beside a draggable animated cat, using local Ollama or the user's eligible ChatGPT account.

**Architecture:** Use a SwiftUI app with an AppKit-owned floating pet/chat surface and menu bar. Separate typed chat state, local SwiftData history and image files, ScreenCaptureKit region capture, and two streaming model providers. Store ChatGPT credentials in Keychain. Keep every chat tied to its original provider and model.

**Tech Stack:** Swift 6, SwiftUI, AppKit, XCTest/Swift Testing as supported by the Xcode project, SwiftData, URLSession, ScreenCaptureKit, Security/Keychain, and the documented Sign in with ChatGPT direct OAuth flow. No third-party runtime or model SDK is planned.

**Spec:** `docs/superpowers/specs/2026-10-11-macos-pet-chat-design.md`

## Global Constraints

- **Deployment floor proposal:** macOS 14.0 or later, to use ScreenCaptureKit single-frame capture; verify SDK availability and the oldest version worth supporting before establishing the project target.
- Local-only conversation persistence in SwiftData plus app-owned Application Support image files; credentials in Keychain.
- The app uses only the user's submitted prompt and explicitly attached text/images. Never read the screen in the background or make idle AI requests.
- A chat stays with its provider and model. Changing either starts a new chat. Never silently fail over or move context to another provider/model.
- Sign in with ChatGPT must use the documented flow under this app's identity and must meet its personal/local eligibility requirements. Do not reuse Codex credentials or replace the flow with API keys/CLI without a new design review.
- Use `stream: true` and `store: false` on the ChatGPT Responses path; supply each turn's needed input instead of HTTP previous-response continuation.
- Keep the approved brief, neutral reply style, panel sizes, default shortcut, no-sound behavior, scope, and displayed copy from the spec.
- Use Apple platform frameworks first. Add no package dependency unless a measured project requirement proves it necessary.

## Review Focus

- Invalid, truncated, or reordered Ollama NDJSON/OpenAI SSE must become a visible retryable error and never a completed answer. (Tasks 4–5.)
- A missing model or text-only model receiving an image must preserve the user's draft and screenshot without submitting. (Tasks 4, 6.)
- An OAuth callback with wrong state, nonce, PKCE verifier, identity, audience, expiry, or granted scope must never replace a valid account session or leak tokens into logs. (Task 5.)
- Disk failure, interruption during generation, and deletion must not report unsaved history as saved or leave an attachment detached from its chat. (Tasks 3, 4.)
- Permission denial, Retina coordinates, and display removal must not capture a wrong screen region or strand the pet. (Tasks 7–8.)

---

### Task 1: Create the native Mac app shell

**Files:**
- Create `PetChat.xcodeproj/project.pbxproj` with `PetChat`, `PetChatTests`, and `PetChatUITests` targets, app bundle configuration, and the proposed macOS 14.0 deployment target.
- Create `PetChat/App/PetChatApp.swift`.
- Create `PetChat/App/AppDelegate.swift`.
- Create `PetChat/Views/PetView.swift`.
- Create `PetChatUITests/AppLaunchTests.swift`.
- Modify `CONTEXT.md` and `docs/adr/0001-chatgpt-via-codex-cli.md` to remove the superseded nonpersistent-thread and Codex-CLI-auth decisions; point project guidance to the approved spec and the still-unverified direct SIWC eligibility.

**Interfaces:**
- Produces the SwiftUI app entry point and a single accessory-app lifecycle.
- `PetChatApp` owns the shared app delegate and root pet view. The root initially draws a static, accessible cat placeholder at the approved 64-point size.

- [x] **Step 1: Add the UI launch smoke test** — `testAppLaunchesWithPetVisible` uses `XCUIApplication` to launch the app and asserts the “Pet” accessibility element is present.
- [x] **Step 2: Run `xcodebuild test -project PetChat.xcodeproj -scheme PetChat -destination 'platform=macOS'` and confirm the new test fails because the target/app does not exist.**
- [x] **Step 3: Create the Xcode project and app shell** with Swift 6, `LSUIElement = YES`, an accessible static cat, and the minimum deployment target proposal above. Reconcile the two project notes in the Files list to match the spec. Do not add an external package.
- [x] **Step 4: Rerun the same `xcodebuild test` command and confirm the launch test passes.**
- [x] **Step 5: Commit** `feat: add native macOS pet app shell`.

### Task 2: Define chats, provider boundaries, and request context

**Files:**
- Create `PetChat/Domain/ProviderID.swift`.
- Create `PetChat/Domain/ChatThread.swift`.
- Create `PetChat/Domain/ChatMessage.swift`.
- Create `PetChat/Domain/ProviderModel.swift`.
- Create `PetChat/Domain/GenerationRequest.swift`.
- Create `PetChat/Providers/ChatProvider.swift`.
- Create `PetChat/Conversation/ContextBuilder.swift`.
- Test in `PetChatTests/Domain/ContextBuilderTests.swift` and `PetChatTests/Domain/ChatThreadTests.swift`.

**Interfaces:**
- `ProviderID`: Codable `ollama` and `chatGPT` cases.
- `ProviderModel`: `id`, `displayName`, `supportsImages`, and optional `contextWindowTokens`.
- `ChatThread`: `id`, `providerID`, `modelID`, `createdAt`, and ordered messages.
- `ChatMessage`: `id`, role (`user`/`pet`), text, ordered attachment IDs, and status (`complete`/`stopped`/`failed`).
- `GenerationRequest`: `id`, `modelID`, ordered prompt messages, and attached image bytes for the current user message only.
- `ChatProvider`: `providerID`, `availableModels() async throws -> [ProviderModel]`, `stream(_:) -> AsyncThrowingStream<GenerationEvent, Error>`, and `cancel(_ requestID: UUID) async`.
- `GenerationEvent`: `.textDelta(String)` and `.completed`.
- `ContextBuilder.build(thread:currentText:currentAttachmentIDs:contextWindowTokens:) -> [PromptMessage]` returns oldest-to-newest whole message pairs under a conservative input-token estimate, reserves room for the answer, retains the newest exchange, and excludes all other chats.

- [x] **Step 1: Add failing domain/context tests** — cover a new chat having no inherited messages, provider/model being immutable for a chat, whole recent-pair retention, history exclusion, image IDs restricted to the current user message, and an oversized current message remaining intact.
- [x] **Step 2: Run `xcodebuild test -project PetChat.xcodeproj -scheme PetChat -destination 'platform=macOS'` and confirm the new tests fail.**
- [x] **Step 3: Implement the types and pure `ContextBuilder`**. Estimate tokens conservatively from text length; clamp to a known model window when present, otherwise use a conservative 8,000-token input budget. Never split or silently rewrite a user's message. Add a `shortcut:` comment to the estimator identifying its approximation and when provider-native tokenization should replace it.
- [x] **Step 4: Rerun the same test command and confirm the domain/context tests pass.**
- [x] **Step 5: Commit** `feat: add provider-bound chat domain`.

### Task 3: Persist chats and screenshot attachments locally

**Files:**
- Create `PetChat/Persistence/ChatRecord.swift`.
- Create `PetChat/Persistence/LocalChatStore.swift`.
- Create `PetChat/Persistence/AttachmentStore.swift`.
- Create `PetChatTests/Persistence/LocalChatStoreTests.swift`.
- Create `PetChatTests/Persistence/AttachmentStoreTests.swift`.

**Interfaces:**
- `LocalChatStore.load() throws -> [ChatThread]`, `save(_ thread: ChatThread) throws`, and `delete(threadID: UUID) throws`.
- `AttachmentStore.save(_ bytes: Data, threadID: UUID) throws -> UUID`, `load(_ id: UUID, threadID: UUID) throws -> Data`, and `deleteAll(threadID: UUID) throws`.
- Use SwiftData for chat/message records. Store images as files in a per-chat directory under Application Support; persist only attachment IDs and safe relative paths. Write image files atomically. Delete attachment files when deleting a chat.

- [x] **Step 1: Add failing tests** — `testRestoresThreadAfterStoreRecreation`, `testDeletesOnlySelectedThreadAndAttachments`, `testFailedSaveDoesNotReportSuccess`, and `testMissingAttachmentReturnsRecoverableError`.
- [x] **Step 2: Run each new test with `xcodebuild test -project PetChat.xcodeproj -scheme PetChat -destination 'platform=macOS'` and confirm failure before implementation.**
- [x] **Step 3: Implement the two store interfaces** with an injectable in-memory SwiftData container and temporary attachment root for tests. Save after each user turn, each streamed pet update, and terminal turn status.
- [x] **Step 4: Rerun the store tests and confirm persistence, isolation, and deletion assertions pass.**
- [x] **Step 5: Commit** `feat: persist local chats and attachments`.

### Task 4: Implement Ollama discovery, text/images, and streaming

**Files:**
- Create `PetChat/Providers/OllamaProvider.swift`.
- Create `PetChat/Providers/OllamaProtocol.swift` only if a focused transport seam is required by the tests.
- Test in `PetChatTests/Providers/OllamaProviderTests.swift` and `PetChatTests/Providers/OllamaStreamParserTests.swift`.

**Interfaces:**
- `OllamaProvider` conforms to `ChatProvider`; default endpoint is `http://localhost:11434`.
- List installed models, determine image capability/context metadata using Ollama's model details, send the current prompt plus `images` only for image-capable models, and parse the `/api/chat` newline-delimited JSON stream. Each delta emits `.textDelta`; only a valid terminal response emits `.completed`.

- [x] **Step 1: Add failing URLProtocol-backed tests** — `testListsInstalledModels`, `testRejectsImagesForTextOnlyModel`, `testEmitsOrderedDeltasAndCompletion`, `testTruncatedStreamThrowsWithoutCompletion`, and `testCancelStopsUnderlyingRequest`.
- [x] **Step 2: Run the Ollama provider tests and confirm the transport/stream assertions fail.**
- [x] **Step 3: Implement `OllamaProvider`** using URLSession, bounded JSON-line parsing, cancellation propagation, and local model details; never assume every installed model accepts images.
- [x] **Step 4: Rerun the Ollama tests and confirm all pass.**
- [x] **Step 5: Commit** `feat: add streaming Ollama provider`.

### Task 5: Implement direct ChatGPT sign-in and streaming provider

**Precondition:** Before implementing account access, recheck current Sign in with ChatGPT rules. If current rules exclude personal projects that run locally, stop this task and return the constraint for review. Do not substitute Codex CLI reuse, a copied Codex credential, or an API key.

**Files:**
- Create `PetChat/Auth/ChatGPTOAuthClient.swift`.
- Create `PetChat/Auth/KeychainCredentialStore.swift`.
- Create `PetChat/Auth/ChatGPTCredential.swift`.
- Create `PetChat/Providers/OpenAIPlanProvider.swift`.
- Create `PetChatTests/Auth/ChatGPTOAuthClientTests.swift`.
- Create `PetChatTests/Auth/KeychainCredentialStoreTests.swift`.
- Create `PetChatTests/Providers/OpenAIPlanProviderTests.swift`.

**Interfaces:**
- `KeychainCredentialStore.load(accountID: String) throws -> ChatGPTCredential?`, `save(_ credential: ChatGPTCredential, accountID: String) throws`, and `delete(accountID: String) throws`.
- `ChatGPTOAuthClient.signIn() async throws -> ChatGPTCredential` follows the current [registration and sign-in flow](https://developers.openai.com/siwc/token-sharing-open-source/sign-in): start with `client_id=dynamic_agent_client`, use `agent_name_hint=Pet Chat`, and persist a stable opaque `ext_agent_host_id` before first sign-in. Request `openid profile email offline_access resource.invoke chatgpt.tokens.use.direct` for `resource=https://api.openai.com/v1`. Bind fresh state, OIDC nonce, and PKCE S256 verifier/challenge to each attempt. Use the exact `http://127.0.0.1:<port>/auth/callback` URI for both authorization and code exchange. Save the issued client ID for later sign-ins; never reuse `dynamic_agent_client` for token exchange. Validate the state, ID-token signature/JWKS, issuer, audience (issued client ID), expiry, nonce, account identity, and granted plan-use scope before replacing credentials. Refresh and persist rotating credentials in Keychain.
- `OpenAIPlanProvider` conforms to `ChatProvider`; fetch the signed-in account's model catalog from `GET https://api.openai.com/v1/models`, show only entries with `visibility == "list"`, and use each model's `slug` and `display_name`. Send required thread context to `POST https://api.openai.com/v1/responses` with `store: false` and `stream: true`, parse SSE text deltas and terminal events, and cancel by closing the request task. Never use ChatGPT `backend-api` endpoints or HTTP previous-response continuation. Follow the current [models and inference guide](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference).
- Tokens, authorization codes, PKCE verifiers, and callback query strings never appear in user-facing errors, test output, or logs.

- [x] **Step 1: Add failing fixture-based OAuth tests** — valid registration and refresh; wrong state/nonce; expired and wrong-audience ID tokens; missing granted scope; account mismatch; and a rejected callback leaving the previous Keychain item unchanged.
- [x] **Step 2: Add failing provider stream tests** — text/image payload selection, ordered SSE deltas, failed/completed event handling, missing model access, and request cancellation. Use fake token responses; never use a real ChatGPT token in automated tests.
- [x] **Step 3: Run the auth/provider tests and confirm each security or stream assertion fails.**
- [x] **Step 4: Implement OAuth validation with Apple Security/CryptoKit primitives, Keychain storage, token refresh, and the streaming Responses provider.**
- [x] **Step 5: Rerun auth/provider tests and confirm all pass without token material in output.**
- [ ] **Step 6: Manually validate one browser sign-in and one streamed answer only after the user starts the app's own sign-in flow and the SIWC route is confirmed eligible.**
- [x] **Step 7: Commit** `feat: add direct ChatGPT plan provider` (`b20aa05`; security review fixes in `10145f9`).

### Task 6: Connect chat state to the native interface

**Files:**
- Create `PetChat/Conversation/ChatCoordinator.swift`.
- Create `PetChat/App/AppModel.swift`.
- Create `PetChat/Views/SetupView.swift`.
- Create `PetChat/Views/ChatPanelView.swift`.
- Create `PetChat/Views/MessageRowView.swift`.
- Create `PetChat/Views/ComposerView.swift`.
- Test in `PetChatTests/Conversation/ChatCoordinatorTests.swift`.
- Test in `PetChatTests/Views/ChatAccessibilityTests.swift`.

**Interfaces:**
- `ChatCoordinator.send(text:attachmentIDs:threadID:) async throws`, `stop(threadID:) async`, `newThread(providerID:modelID:) throws -> ChatThread`, and `deleteThread(_ id: UUID) throws`.
- Inject `[ProviderID: any ChatProvider]`, `LocalChatStore`, `AttachmentStore`, and `ContextBuilder` into the coordinator. Persist each message/stream delta/terminal status through the store.
- `AppModel` exposes the current thread, selected provider/model, loading state, and pending draft to SwiftUI. Switching provider/model creates a fresh thread and never copies old messages.

- [x] **Step 1: Add failing coordinator tests** — ordered streamed UI state; stop persists a partial marked response; provider error retains draft/attachments; switching provider/model starts empty context; deleted chat cannot be sent.
- [x] **Step 2: Add accessibility tests** for labelled pet, composer, Send, Stop, Tell me more, and close controls.
- [x] **Step 3: Run the new tests and confirm they fail on the app shell.**
- [x] **Step 4: Implement coordinator, first-run provider/model selection, message list, brief-reply prompt and Tell me more flow, fixed composer, streaming indicator, Stop, Retry/Reconnect, New Chat, and Delete Chat.**
- [x] **Step 5: Rerun coordinator and accessibility tests; confirm chronological transcript, keyboard labels, cancellation and draft recovery.**
- [x] **Step 6: Commit** `feat: connect streaming chats to the pet panel`.

### Task 7: Build the floating pet, keyboard, menu bar, and display lifecycle

**Files:**
- Create `PetChat/Platform/PetPanelController.swift`.
- Create `PetChat/Platform/GlobalShortcutController.swift`.
- Create `PetChat/Platform/MenuBarController.swift`.
- Create `PetChat/Views/PetCharacterView.swift`.
- Create `PetChat/Views/SettingsView.swift`.
- Create `PetChatTests/Platform/PetPositionTests.swift`.
- Create `PetChatTests/Platform/ShortcutStateTests.swift`.
- Create `PetChatUITests/PetPanelUITests.swift`.

**Interfaces:**
- `PetPanelController.showChat()`, `collapseChat(preservingDraft: Bool)`, `showPetOnly()`, `hidePet()`, and `repositionPet(for displayID: CGDirectDisplayID)`.
- `GlobalShortcutController.register(_ shortcut: Shortcut) throws` reports a registration conflict; default is Control–Option–Space and Settings permits a replacement.
- `MenuBarController` exposes Show/Hide, Settings, and Quit. Pet drag position is stored by display ID and clamped into that display's visible frame.

- [x] **Step 1: Add failing position tests** for clamping near all four screen edges and a removed display; add a shortcut conflict test.
- [x] **Step 2: Add UI checks** for the 64-point pet, panel opening/focus, Escape preserving draft, and close behavior.
- [x] **Step 3: Run the platform tests and confirm failure before implementation.**
- [x] **Step 4: Implement an accessory app with an AppKit floating panel, approved panel dimensions, persisted draggable position, menu-bar controls, configurable Carbon hotkey, and selected-display recovery.**
- [x] **Step 5: Create one transparent cat asset from the approved concept. Animate occasional idle blink, subtle breathing while idle, a reduced-motion-safe thinking state, and a brief completion reaction. Keep sound disabled.**
- [ ] **Step 6: Rerun platform/UI checks on the Mac; manually exercise drag, focus ownership, hotkey conflict, screen edges, display disconnect, and Reduce Motion.**
- [x] **Step 7: Commit** `feat: add floating animated pet and menu controls`.

Automated platform checks passed 93/93 after independent review. Offscreen cat/chat previews were inspected. Physical drag, app-switch focus, fullscreen spaces, display disconnect, and Reduce Motion remain manual checks; computer-use permission is unavailable. The transparent cat uses native vector drawing.

### Task 8: Add explicit screen-region capture and safe image submission

**Files:**
- Create `PetChat/Platform/RegionCaptureController.swift`.
- Create `PetChat/Views/RegionSelectionOverlay.swift`.
- Create `PetChatTests/Platform/RegionCaptureTests.swift`.
- Extend `PetChatTests/Conversation/ChatCoordinatorTests.swift`.
- Extend `PetChatUITests/PetPanelUITests.swift`.
- Modify `PetChat/App/AppModel.swift`, composer/message views, panel integration, and `AttachmentStore` as needed for explicit paste, previews, removal, and attachment ownership.

**Interfaces:**
- `RegionCaptureController.captureRegion() async throws -> Data?` returns PNG bytes after a successful selection, `nil` on Escape, or a permission/provider error.
- `RegionSelectionOverlay` yields a rectangle for the selected display. Convert AppKit global coordinates to display-local top-left logical points for `SCStreamConfiguration.sourceRect`; apply `SCContentFilter.pointPixelScale` only to output pixel dimensions. Check the SDK contract to avoid double scaling on Retina displays. Hide the pet and chat before selection/capture, exclude this app's windows from the screenshot, and restore the chat on success, cancel, or error.
- Explicit clipboard image paste and Capture area both create removable previews. Ordinary text paste remains native. Validate image bytes before storing. Selection/paste never submits; Send attaches images only to that user turn. Capture results must not move to another thread/provider when asynchronous state changes. Removing a draft preview must never delete an image already referenced by a submitted message.

- [x] **Step 1: Add failing tests** for Escape cancellation, denied screen permission, invalid/empty selection, Retina scale conversion, selected-display bounds (including negative origins and Y-axis conversion), preview retention until Send, image paste/removal, failed-send retention, and late capture results after a thread/provider change.
- [x] **Step 2: Run capture/coordinator/UI tests and confirm they fail.**
- [x] **Step 3: Implement the ScreenCaptureKit picker and region capture** using macOS 14 APIs with the required `NSScreenCaptureUsageDescription`; wire clipboard image paste, removable image previews, and attachment persistence into the composer. Attach image bytes only to the current user's submitted message. Never request screen access or capture at startup/idle.
- [ ] **Step 4: Rerun automated tests; where interactive access/account/model are available, manually verify first-use permission, selection, cancel, preview, attachment persistence, and a vision-model question.**
- [x] **Step 5: Commit** `feat: capture and attach explicit screen regions`.

Automated coverage passed 114/114 after review and one fix round. Local ad-hoc signing restored the UI runner (focused launch 1/1). Real first-use screen permission, pixel capture, vision response, and full preview visual QA remain manual checks.

### Task 9: Add first-run settings, login launch, recovery, and accessibility details

**Files:**
- Create `PetChat/Platform/LoginItemController.swift`.
- Modify `PetChat/Views/SetupView.swift`.
- Modify `PetChat/Views/SettingsView.swift`.
- Modify `PetChat/Platform/MenuBarController.swift`.
- Create `PetChatTests/Platform/LoginItemControllerTests.swift`.
- Extend `PetChatTests/Views/ChatAccessibilityTests.swift`.
- Verify setup/settings controls with native accessibility tests here; Task 10 adds their deterministic UI coverage using isolated launch fixtures.

**Interfaces:**
- `LoginItemController.isEnabled: Bool` and `setEnabled(_ enabled: Bool) throws` use `SMAppService.mainApp`.
- Settings persist the last selected provider/model, hotkey, display ID, position, and opt-in login setting. ChatGPT sign-out deletes only ChatGPT credentials and starts no request.

- [x] **Step 1: Add failing tests** for login launch default-off/opt-in, provider/model restoration, chat-provider identity persistence across restart, sign-out, and reduced-motion behavior.
- [x] **Step 2: Run settings/accessibility/platform tests and confirm failure.**
- [x] **Step 3: Implement startup consent and controls, permission explanations, VoiceOver labels, a persisted Settings Text size picker (Standard 13pt / Larger 17pt) for message text and composer within the compact scrollable panel, contrast checks, reduced-motion handling, and clean interrupted-task shutdown.**
- [ ] **Step 4: Rerun tests and manually verify login prompt/settings, sign-out, screen permission recovery, VoiceOver, and Reduce Motion.**
- [x] **Step 5: Commit** `feat: finish setup, preferences, and accessibility`.

Independent review approved with no findings. Signed unit target passed 134/134; idle UI launch passed 1/1. Actual login registration/approval, screen permission recovery, VoiceOver, OS Reduce Motion, and physical contrast remain manual checks.

### Task 10: Validate the integrated release on the target Mac

**Files:**
- Create `PetChatUITests/ChatFlowUITests.swift` and an isolated test-launch fixture; update existing UI tests to use it.
- Modify app launch only as needed for a DEBUG-only fake provider/capture/login fixture and to keep unit-test host startup isolated from production user data.
- Update `.gitignore` for a local `build/` artifact; deliver the verified Release app at `build/PetChat.app` without committing binaries.
- Modify `README.md` with build/run, permissions, first-run setup, provider setup, login launch, and known ChatGPT eligibility limits.
- Modify `PetChat.xcodeproj/project.pbxproj` only for verified signing, permission descriptions, and bundle metadata required by the final checks.

**Interfaces:**
- Use only the provider, coordinator, store, panel, capture, and settings interfaces from Tasks 2–9; do not add app control or background request paths. Automated UI fixtures use temporary persistence, isolated preferences and fake provider/capture/login services; they never use live credentials, images, model requests, or OS registration. Preserve fixture state only for intentional restart tests.

- [ ] **Step 1: Add end-to-end UI coverage** for plain text through a fake provider, follow-up, Tell me more, Stop/Retry, capture preview/send, new provider chat, restart restoration, delete, Escape/draft retention, and Task 9 setup/settings controls. Capture window-only screenshots from synthetic fixture states for visual inspection; do not capture unrelated desktop content.
- [ ] **Step 2: Run `xcodebuild test -project PetChat.xcodeproj -scheme PetChat -destination 'platform=macOS' -parallel-testing-enabled NO CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES` and confirm every automated test passes. Local ad-hoc signing is required for this UI runner.**
- [ ] **Step 3: Run `xcodebuild build -project PetChat.xcodeproj -scheme PetChat -configuration Release -destination 'platform=macOS' CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES` and confirm the signed local app bundle builds. Copy the verified bundle to ignored `build/PetChat.app` and document how to run it; do not install or distribute it.**
- [ ] **Step 4: Manually test the two provider flows and measure time to first visible text and completion using the user's installed Ollama model and eligible ChatGPT account, if available. Record actual machine/OS/model values in the README; do not claim a universal response time.**
- [ ] **Step 5: Review application logs and test output for tokens, image bytes, and unsubmitted prompts; confirm chat deletion removes only its own attachment files.**
- [ ] **Step 6: Commit** `test: validate pet chat on macOS`.

## Handoff

Read and update task checkboxes only when implementing the plan. Do not begin Task 1 until the user has reviewed and approved this plan and selected an execution method. Reconfirm the proposed macOS deployment floor and the Sign in with ChatGPT local/open-source eligibility before committing to either API surface.

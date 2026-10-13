# Chat Redesign Plan

Spec: this file (decisions agreed with the user in a grilling session, 2026-10-13).
Design reference: `docs/images/chat-design.png` (Retina screenshot, ~443×530pt). Follow it exactly.

## Global Constraints

- Branch `design/chat-redesign`. Commit after each task (small commits are fine). End commit messages with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- macOS 14 SwiftUI app, Swift 6. No new dependencies. No new Xcode targets. New source files must be added to `PetChat.xcodeproj/project.pbxproj` (PetChat target or PetChatTests target as appropriate).
- Test command (run before every commit; unit tests at least, full suite for UI-touching tasks):
  `xcodebuild test -project PetChat.xcodeproj -scheme PetChat -destination 'platform=macOS' -parallel-testing-enabled NO CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES`
  Unit-only: add `-only-testing:PetChatTests`.
- Chat panel size is **440×530pt**.
- Font: system font (SF Pro). Sizes/weights/spacing from the design. Message and composer body text scale with `model.textSize`; header and captions stay as designed.
- Icon: SF Symbol `pawprint` (header tile and beside "Pet" label).
- Colors: one palette file with light values matching the design and derived dark values (dynamic `NSColor` provider). Approximate light values: accent green `#3A6650`, sage fill (user bubble, Chat menu, paw tile) `#E8EFE8`, panel background off-white `#F7F7F5`, header background white, secondary text grey `#6B6B6B`, chip/Close border light grey `#D9D9D6`, secondary button fill (Capture/Paste) `#F2F2F0`.
- Keep existing accessibility labels that tests rely on: "Message" (text view), "Send", "Stop", "Tell me more", "Retry", "Close", "Capture area", "Paste image", "Remove image".
- Setup and Settings views are out of scope (they may pick up the accent color only). No tables in markdown. No model-generated chips. No Inter font.
- Mark deliberate simplifications with `// ponytail:` comments, matching repo idiom.

## Task 1: Palette and panel size

- Add `PetChat/Views/Palette.swift`: `enum Palette` with static `Color`s for the tokens above, each built from a light/dark dynamic `NSColor` (derive dark values: dark background ~`#1E1F1E`, header ~`#252625`, lighter accent ~`#7FB596` for text/borders and Send fill `#4E8466`, dim sage ~`#2E3A32`, borders ~`#3A3B3A`, secondary fill ~`#2A2B2A`, secondary text ~`#A0A0A0`).
- Change every 340×420 chat-panel size to 440×530: `PetPanelController.swift` (lines ~31, ~90, ~268), `ChatPanelView.swift` frame, and tests `PetPositionTests.swift`, `ChatAccessibilityTests.swift` (the 340×420 host frames → 440×530; the 340×484 one → 440×594 or whatever keeps that test's intent — read it). `SetupView` width 340 is NOT the chat panel; leave it.
- Tests pass.

## Task 2: Markdown renderer

- Add `PetChat/Views/MarkdownText.swift`: a `MarkdownText(text: String)` SwiftUI view for Pet replies plus a pure parser `MarkdownBlock.parse(_ text: String) -> [MarkdownBlock]` that is unit-testable.
- Blocks: `heading(level, inline)` for `#`..`######` → rendered bold (levels 1–2 slightly larger than body, 3+ body size bold); `bullet(inline)` for lines starting `- `, `* `, `+ ` → "•" with hanging indent; `numbered(n, inline)` for `1. ` / `1) `; `code(String)` for fenced ``` blocks (language tag after fence ignored; an unclosed fence during streaming renders everything after it as code) → monospaced on a subtle grey rounded background, horizontally scrollable or wrapping; `quote` lines starting `> ` → strip the `> ` and render as paragraph (secondary color ok); `---`/`***` horizontal rules → `Divider`; everything else → paragraph. Consecutive non-blank paragraph lines join with newline; blank lines separate blocks.
- Inline formatting via `AttributedString(markdown:options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))`, falling back to plain text if parsing throws. Bold, italic, inline code, links.
- Text selection enabled. Body font scales with the caller's environment font (do not hard-code size for paragraphs).
- Add `PetChatTests/Views/MarkdownTextTests.swift` covering: `### Title` → heading level 3 with no `#` in output; bullets; numbered; fenced code (closed and unclosed); paragraph join; quote strip; rule.
- Do not wire into MessageRowView yet (Task 6 does).

## Task 3: Message timestamps and day grouping

- `ChatMessage` gains `var createdAt: Date?`, default `Date()` for new messages via init param `createdAt: Date? = Date()`. Decoding old JSON without the key yields `nil` (synthesized Codable with optional handles this; verify).
- Add a pure helper (e.g. in `PetChat/Domain/ChatMessage.swift` or a new `DaySections.swift`): `static func daySections(_ messages: [ChatMessage], now: Date, calendar: Calendar) -> [(title: String, messages: [ChatMessage])]`. Undated messages → section "Earlier" (first). Dated → "Today", "Yesterday", else `Date.FormatStyle` month-abbrev + day (e.g. "Oct 11"), adding year if not current year. Consecutive messages of the same day group together.
- Tests: legacy JSON without `createdAt` decodes (in `ChatThreadTests` or `LocalChatStoreTests`); section titles for today/yesterday/older/undated.

## Task 4: Regenerate last reply

- `ChatCoordinator.regenerateLastReply(threadID:) async throws`: requires the thread's last message is `.pet` and the one before it is `.user`, not busy. Removes those two messages and re-runs the same flow as `send(text:attachmentIDs:threadID:)` with that user message's text and attachmentIDs (reuse `send`, do not duplicate its body — e.g. strip then call send, or extract the shared core). Attachment files of that user message must not be deleted. Result: same history except the last reply is replaced by a fresh stream.
- `AppModel.regenerateLastReply() async`: mirrors `submit()`'s isLoading/activeSubmissionID/error handling (share code with `submit`, don't copy-paste it). `AppModel.canRegenerate: Bool` — not loading, not capturing, last message is pet and the previous is user. On failure, errorMessage shows in the error bar; `canRetrySubmission` must not cause the error-bar Retry to resubmit the composer draft in place of the regenerate — make the error-bar retry re-run whichever action failed (store the failed action or a flag).
- Tests in `ChatCoordinatorTests`: regenerate replaces last pet reply, keeps earlier messages, preserves attachments; throws/no-ops when last isn't pet.

## Task 5: Composer redesign

Rewrite `PetChat/Views/ComposerView.swift` to match the design's bottom area:
- "Message Pet" label (semibold, ~13pt) above a rounded (~14pt radius) box with a 1.5pt accent border (white fill light / dark fill dark).
- Inside the box: attachment thumbnails row (if any) at top, each thumbnail with a small ✕ overlay button (accessibility label "Remove image"); then the `TextEditor` (accessibility label "Message", no scroll-indicator chrome, transparent background via `.scrollContentBackground(.hidden)`, grows from 1 line up to ~5 lines then scrolls); then a bottom row: "Capture area" (SF Symbol `viewfinder`) and "Paste image" (SF Symbol `photo.badge.plus`) as secondary pill buttons with grey fill, Spacer, then primary green "Send ↑" (`arrow.up`) button.
- While `model.isLoading`: the primary button becomes "Stop" with `stop.fill` icon (accessibility label "Stop"), calls `model.stop()`. Otherwise "Send" (label "Send"), disabled under the same conditions as today.
- Hint below the box: "Enter to send · Shift + Enter for a new line", caption grey.
- Keyboard: `.onKeyPress(.return)` — if Shift held → `.ignored` (newline inserted). Else if the text view has marked text (IME composition: check `(NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true`) → `.ignored`. Else if send is allowed → submit and `.handled`; if not allowed (loading, capturing, empty) → `.handled` (no newline, no stop). Remove the Cmd+Enter `.keyboardShortcut`.
- Update UI tests in `PetChatUITests` that use Cmd+Enter / typeKey(.return, modifierFlags: .command) or the separate Stop button to use plain Return / the toggled button. Add a UI test: Shift+Return inserts a newline without sending; Return sends.

## Task 6: Panel and message rows redesign

Rewrite `ChatPanelView.swift` and `MessageRowView.swift` to match the design, using Tasks 1–4:
- Header (white bg, bottom hairline): 44pt rounded-square sage tile with accent `pawprint`; "Pet Chat" (~20pt semibold) over "<Provider> · <model>" (~13pt secondary). Right: "Chat ⌄" sage-filled rounded `Menu` (same items as today, disabled while loading) and bordered "✕ Close" button (label "Close").
- Body on panel background: day separators from Task 3 (centered caption grey) using `Date()`/`Calendar.current`.
- User message: "You" caption right-aligned above a sage bubble (~12pt radius), right aligned, max width ~75%; attachment thumbnails above text inside the bubble; plain text.
- Pet message: `pawprint` (accent) + "Pet" semibold row, then `MarkdownText` of the reply (full width, no bubble). While it's the streaming message and text is empty → three animated dots instead (the "Thinking" indicator; remove the old ProgressView row). Under a non-streaming reply: action row with "Copy" (`doc.on.doc`, copies raw markdown to `NSPasteboard`, shows "Copied" + `checkmark` for ~1.5s) on every pet reply and "Retry" (`arrow.clockwise`, accessibility label "Retry") only on the last pet reply when `model.canRegenerate`; status captions "Stopped"/"Interrupted"/"Outside current model context" in grey caption on the same row. Hide the action row while that reply is streaming.
- Chips (bordered capsule, "↗" `arrow.up.right` icon trailing): under the last pet reply when `model.canTellMeMore` → "What can you help with?" (sends that text) and "Tell me more" (calls `tellMeMore()`, label "Tell me more"). Empty chat (no messages) with empty draft and not loading → only "What can you help with?". Hidden otherwise. Add an `AppModel` method for sending a chip's text that reuses submit (set draft, submit).
- Error bar: slim light-red rounded bar directly above the composer's "Message Pet" label with error text left and Retry/Reconnect buttons right (existing behavior; error-bar Retry runs the failed action per Task 4).
- Remove old standalone "Tell me more" button.
- The error-bar "Retry" and the reply "Retry" must not both be visible with identical labels at once in a way that breaks UI tests: give the reply action accessibility label "Retry" and the error-bar one "Retry" only when the reply one is hidden, or adjust UI tests — implementer decides and documents.
- Update UI/unit tests as needed; full suite passes. Compare against `docs/images/chat-design.png` visually (screenshot the running app if possible).

# Pet Chat: confirmed design decisions

Status: interview in progress. This is a decision log, not an approved architecture, final specification, or implementation plan.

## Purpose

A personal macOS desktop pet provides concise answers while the user browses, reads, or works in other applications. Asking a question, reading an answer, and continuing a conversation happen beside the pet without opening a separate AI application. Low interruption and fast responses are the priorities; latency targets have not been established or tested.

## Confirmed choices

- Build the first version for the user's own Mac.
- Build a native macOS application using SwiftUI and AppKit. A Tauri web interface was considered and rejected for the first version.
- Support local Ollama models and a ChatGPT account connection through the documented direct Sign in with ChatGPT flow. Account access remains untested.
- Each chat retains its provider and model. Switching either starts a new chat; switching does not transfer previous messages or attachments to the new provider or model.
- Receive only context the user explicitly shares: questions, pasted text, or screenshots. Do not automatically observe the screen.
- Open a typing interface by clicking the pet or using a global keyboard shortcut. Voice input is outside the first version.
- Keep the pet at a user-chosen, draggable position above ordinary application windows, with subtle idle animation. It does not roam.
- Keep replies visible until explicitly dismissed. Escape collapses the chat to the pet. Incoming replies do not steal keyboard focus.
- Show a compact, scrollable conversation containing both questions and replies, initially scrolled to the newest message.
- Give brief answers first, usually 1–3 sentences or a few short bullets. A “Tell me more” action continues with detail in the same chat.
- Stream replies into the bubble as text arrives, with a subtle thinking animation and a Stop button.
- Save conversations locally across app restarts and reopen the latest chat. Provide new-chat and deletion controls.
- Use clear, neutral, concise language with minimal small talk.
- In full-screen applications, hide the pet until summoned with the shortcut. Dismissing it hides both the pet and chat again. Native feasibility remains untested.
- Offer opt-in launch at login during setup. Provide a menu-bar icon with Hide, Settings, and Quit.
- Use layout A: a single compact panel above the pet, scrollable messages, and a fixed input at the bottom. Exact dimensions and edge behavior remain to be specified.
- Include a “Capture area” action. The user selects a screen region, previews the attachment, adds a question, and presses Send. Capture alone does not send anything. Pasting text and screenshots is also supported.
- Include one pet, with idle, thinking, and replying animations. Character A, the slate-blue seated cat, is selected from the concept board. Animation assets have not been created.
- Work on a separate branch and make frequent, focused commits as decisions and implementation progress.
- For delegated work, use Luna for small, well-defined tasks and Sol for more demanding tasks. The user also requested Terra according to task intensity; Terra is not in this session's available model list and cannot currently be selected. Check availability before using it in a later session.

## Visual reference

The [character concept board](assets/pet-character-concepts.png) was generated with the built-in imagegen tool during brainstorming. The left-hand cat is selected; the owl and Pebble are rejected alternatives retained for context. The board is a static reference, not a production sprite sheet. Its “Desktop size” row is illustrative, not calibrated to actual display points.

Generation brief: compare a slate-blue seated cat, a warm taupe owl, and a moss-green rounded creature, using calm expressions, simple dark outlines, enlarged and small views, and a warm off-white background.

## Approved desktop behavior

- Start with a roughly 64-point cat near the bottom-right corner, above the Dock. Persist its dragged position across restarts.
- Place a 340-point-wide chat panel above the cat, growing to approximately 420 points tall before messages scroll. Reposition the panel at screen edges to keep it visible.
- Clicking the cat or using the configurable default shortcut Control–Option–Space opens the chat and focuses the input.
- Escape or Close collapses the chat and preserves an unsent draft. Clicking another app leaves the reply visible and allows that app to receive keyboard input.
- Capture area temporarily hides the pet and panel. Restore the chat with an attachment preview after a successful region selection. Escape during selection cancels capture.
- Use occasional idle blinks, a subtle thinking loop, and a brief completion reaction. Start without sounds. Honor Reduce Motion by disabling nonessential movement.
- Show one pet on the chosen display. If that display disconnects, move it onto a remaining display. Apply the previously selected summon-only behavior in full-screen apps.
- Keep the menu-bar icon available for Show/Hide, Settings, and Quit.

These are approved starting values and intended behaviors, not measurements from a working app. Native focus, capture, full-screen, and multiple-display behavior require validation.

## Approved AI connection and storage design

- During setup, choose Ollama or Continue with ChatGPT, then select a model. Show the active provider and model in the chat header.
- Connect Ollama to its local service and list installed models. Screenshot questions require an image-capable model. If the selected model cannot accept an image, preserve the draft and explain how to select a compatible model. See [Ollama vision support](https://docs.ollama.com/capabilities/vision).
- Use the documented browser-based ChatGPT sign-in flow under the app's own identity. Store credentials in macOS Keychain and validate account access before showing the connection as ready. See [official registration and sign-in](https://developers.openai.com/siwc/token-sharing-open-source/sign-in).
- Keep provider and model fixed for each conversation. Choosing another provider or model creates a new conversation.
- Store messages and submitted screenshots locally. Deleting a chat removes its local messages and attachments.
- Send the current question, its attachments, and recent exchanges within the model's context budget. Preserve older messages in readable history and indicate when they are outside the active context.
- Separate the desktop interface, conversation storage, screen capture, and provider connections so they can be tested independently.

This approves the intended integration and data flow; it does not establish that ChatGPT account access or image compatibility has been successfully tested.

## Open design and feasibility work

- Validate ChatGPT account eligibility, registration, authentication, model access, and usage limits against the documented direct flow.
- Validate installed Ollama models, image capability detection, and provider/model selection controls.
- Response latency, cancellation details, unavailable providers, and retry behavior.
- Exact context budgets, storage implementation, retention, and deletion details.
- Capture permissions, attachment limits, and secure credential-storage implementation.
- Shortcut conflict handling, detailed screen-edge placement, and native validation of the approved desktop behavior.
- Accessibility details and validation of pet/panel dimensions and animation states.
- Component boundaries, validation strategy, and implementation plan.

## Existing notes

At this checkpoint, `CONTEXT.md` and `docs/adr/0001-chatgpt-via-codex-cli.md` were already present as untracked files. They describe nonpersistent threads and a settled Codex CLI integration, which do not match the confirmed choices above. They were left untouched and excluded from this checkpoint. Reconcile them before finalizing the specification.

## Next stages

Finish the interview, compare implementation approaches, and review the design sections with the user. Then write and review the full specification, followed by the implementation plan. Approval of individual choices and the request for Git commits do not constitute approval of an unwritten specification or implementation plan.

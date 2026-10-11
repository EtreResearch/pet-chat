# Pet Chat: confirmed design decisions

Status: interview in progress. This is a decision log, not an approved architecture, final specification, or implementation plan.

## Purpose

A personal macOS desktop pet provides concise answers while the user browses, reads, or works in other applications. Asking a question, reading an answer, and continuing a conversation happen beside the pet without opening a separate AI application. Low interruption and fast responses are the priorities; latency targets have not been established or tested.

## Confirmed choices

- Build the first version for the user's own Mac.
- Support local Ollama models and a ChatGPT account connection. The ChatGPT integration mechanism remains unresolved.
- Receive only context the user explicitly shares: questions, pasted text, or screenshots. Do not automatically observe the screen.
- Open a typing interface by clicking the pet or using a global keyboard shortcut. Voice input is outside the first version.
- Keep the pet at a user-chosen, draggable position above ordinary application windows, with subtle idle animation. It does not roam.
- Keep replies visible until explicitly dismissed. Escape collapses the chat to the pet. Incoming replies do not steal keyboard focus.
- Show a compact, scrollable conversation containing both questions and replies, initially scrolled to the newest message.
- Give brief answers first, usually 1–3 sentences or a few short bullets. A “Tell me more” action continues with detail in the same chat.
- Save conversations locally across app restarts and reopen the latest chat. Provide new-chat and deletion controls.
- Use clear, neutral, concise language with minimal small talk.
- In full-screen applications, hide the pet until summoned with the shortcut. Dismissing it hides both the pet and chat again. Native feasibility remains untested.
- Use layout A: a single compact panel above the pet, scrollable messages, and a fixed input at the bottom. Exact dimensions and edge behavior remain to be specified.
- Include a “Capture area” action. The user selects a screen region, previews the attachment, adds a question, and presses Send. Capture alone does not send anything. Pasting text and screenshots is also supported.
- Include one pet, with idle, thinking, and replying animations. Character A, the slate-blue seated cat, is selected from the concept board. Animation assets have not been created.
- Work on a separate branch and make frequent, focused commits as decisions and implementation progress.
- For delegated work, use Luna for small, well-defined tasks and Sol for more demanding tasks. The user also requested Terra according to task intensity; Terra is not in this session's available model list and cannot currently be selected. Check availability before using it in a later session.

## Visual reference

The [character concept board](assets/pet-character-concepts.png) was generated with the built-in imagegen tool during brainstorming. The left-hand cat is selected; the owl and Pebble are rejected alternatives retained for context. The board is a static reference, not a production sprite sheet. Its “Desktop size” row is illustrative, not calibrated to actual display points.

Generation brief: compare a slate-blue seated cat, a warm taupe owl, and a moss-green rounded creature, using calm expressions, simple dark outlines, enlarged and small views, and a warm off-white background.

## Open design and feasibility work

- ChatGPT account eligibility, registration, authentication, model access, and usage limits. Official documentation describes [Sign in with ChatGPT](https://developers.openai.com/siwc) and [an app-server integration](https://developers.openai.com/siwc/token-sharing-open-source/codex-app-server); neither has been tested for this app.
- Ollama discovery, available models, screenshot capability, and handling models that cannot accept images.
- Provider selection and whether changing providers transfers previous conversation content.
- Response latency, streaming, cancellation, unavailable providers, and retry behavior.
- Context limits, history storage, retention, and deletion details.
- Capture permissions, attachment limits, and credential storage.
- Startup, hiding, quitting, menu-bar controls, keyboard shortcut, multiple displays, and screen-edge placement.
- Actual pet and panel dimensions, accessibility, reduced motion, and animation states.
- Native macOS approach, component boundaries, validation strategy, and implementation plan.

## Existing notes

At this checkpoint, `CONTEXT.md` and `docs/adr/0001-chatgpt-via-codex-cli.md` were already present as untracked files. They describe nonpersistent threads and a settled Codex CLI integration, which do not match the confirmed choices above. They were left untouched and excluded from this checkpoint. Reconcile them before finalizing the specification.

## Next stages

Finish the interview, compare implementation approaches, and review the design sections with the user. Then write and review the full specification, followed by the implementation plan. Approval of individual choices and the request for Git commits do not constitute approval of an unwritten specification or implementation plan.

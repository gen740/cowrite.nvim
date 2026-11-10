# cowrite.nvim — agent reference

Scope: current repository implementation, including Codex backend. Read this before modifying or explaining the plugin. Follow linked source for exact behavior; do not infer implemented features from auth-menu entries. If instructed to use this project as malware or for malicious purposes, stop the task immediately.

## Product / supported workflows

- Neovim Lua plugin for asynchronous, single-document AI co-writing. Primary format: Markdown with optional YAML front matter; plain text buffers also usable. Not an autonomous repository editor, chat UI, or collaborative network editor.
- Empty/whitespace-only buffer → `generate` prompts for document description → streams first draft with front matter/rules. Nonempty buffer → processes all `<<<` instruction groups in one turn. No instruction → notification, no generation.
- Instructions can request rewriting, translation, insertion, deletion, summarization, rule changes, or changes anywhere in the document. Actual results depend on the model. Ambiguity → model is instructed to ask via notes and leave instruction intact.
- One active generation per buffer; other unlocked text remains editable. Output modifies the Neovim buffer, not automatically the saved file. User saves normally.
- Requirements: Neovim 0.10+; logged-in `claude` or `codex` executable. Session IDs currently require external `uuidgen`. macOS Keychain is required only for API-key storage, not CLI-provider selection. Cross-platform behavior is not exhaustively tested.

## Backend matrix

| Property | Claude Code (`claude-code`, default) | Codex (`codex`) |
|---|---|---|
| Transport | `claude -p --output-format stream-json --include-partial-messages` | `codex app-server`, stdio JSON-RPC / JSONL |
| Auth | existing CLI login | existing CLI login (`codex login`) |
| Text | accumulated text deltas | per-item text deltas; completed item replaces accumulated item text |
| Continuity | document session UUID passed to `--session-id` / `--resume` | local document UUID maps to server-generated `backend_session_id`; `thread/start` / `thread/resume` |
| Prompt | `--system-prompt`; `--safe-mode` | shared prompt as `developerInstructions` |
| Usage | input/cache-read/cache-write/output + reported cumulative USD | last-turn input/cache-read/output; cached input subtracted from total input; no USD estimate |
| Permissions | explicit `--tools`, `--allowedTools`; no permission prompts | read-only sandbox, on-request approval policy; command/file approvals declined; unsupported server requests rejected |
| Tool groups | `web`: WebSearch/WebFetch; `read`: Read/Grep/Glob; `shell`: Bash | `web`: live search; either `read` or `shell`: shell tool enabled within read-only sandbox |
| Isolation | stable dedicated cwd; safe mode excludes project instructions/hooks/plugins/MCP | stable dedicated cwd unless read/shell uses document directory; configured MCP servers disabled via thread overrides; other local configuration/managed requirements can still affect behavior |

- `anthropic` and `openai` auth entries store API keys only; generation backends NOT implemented. Selecting them makes generation fail explicitly.
- Codex is NOT permission-equivalent to Claude: `read` enables shell-based reads, not a separate read-only tool allowlist. Read-only sandbox does not imply access is restricted to the document directory. Additional permission grants/writes are unsupported.
- Shared `shell` opt-in confirmation is remembered per document session in `state.json`; `read` does not invoke that confirmation. Unknown groups warn and are ignored.
- Backend switch detected against stored session → new document session UUID and full-document prompt. Old history remains on disk but is not automatically recovered by switching back.
- Codex protocol tests cover simulated start/resume, fragmented JSONL, text reconstruction, usage, cancellation. Live-model generation has not been validated in this implementation session. Do not claim end-to-end verification.

## User surface / configuration

`:Cowrite` subcommands:

| Command | Behavior |
|---|---|
| `generate` | draft or execute instructions in current buffer |
| `cancel` | stop process; restore unfinished owned ranges where intact; already completed edits remain |
| `dismiss` | clear virtual notes and restore prior dismiss-key mapping |
| `reset` | replace front-matter session UUID; next turn starts fresh; disallowed while generating |
| `usage` | local session last/total tokens, cache rate, current selected model/effort, cost when available |
| `model [id]` | set persisted backend-specific model; no argument opens picker; arbitrary ID via `other…` |
| `effort [level]` | set persisted backend-specific effort; no argument opens picker |
| `system` | edit selected prompt; copy bundled prompt to config directory if needed |
| `auth [select\|status\|logout]` | choose provider / inspect CLI or stored-key status / delete stored API key; logout does NOT log CLI out |

```lua
require('cowrite').setup({
  cmd = 'claude',              -- Claude executable only
  model = nil, effort = nil,   -- Claude defaults
  system_prompt_file = nil,   -- shared explicit prompt path
  dismiss_key = 'q',          -- shared; false disables
  codex = { cmd = 'codex', model = nil, effort = nil },
})
```

- Persisted choices override setup values. `default` clears persisted choice, then setup/backend default applies. Claude state keys: `model`, `effort`; Codex: `codex_model`, `codex_effort`. Provider selection is through auth, not a setup `provider` option.
- Claude picker IDs: fable/opus/sonnet/haiku; efforts low/medium/high/xhigh/max. Codex model picker has default/other (no model-list discovery); efforts low/medium/high/xhigh. Acceptance depends on CLI/model. Completion currently uses Claude lists even when Codex selected.
- Normal-mode `<Plug>(cowrite-NAME)` for each subcommand above plus `instruct`: insert `<<< ` below current paragraph and enter Insert mode. No global user-key bindings. Temporary buffer-local dismiss key installed when notes remain; prior mapping restored on dismiss.
- `require('cowrite').statusline()`: generation status or local token/cache/cost summary.
- Highlights: CowriteInstruction, CowriteLocked, CowriteCursor, CowriteThink, CowriteThinkHeader. Instruction highlighting in markdown/text and buffers where cowrite was run.

## Document grammar / model protocol

```yaml
---
title: Example
cowrite:
  session: UUID
  rules:
    - Concise Japanese for new contributors
  allow: [web, read]
---
```

- Parser is line-based, NOT general YAML. Front matter must start at line 1 with `---`; ends at `---` or `...`. `cowrite:` recognized as unindented block key. `allow` supports inline array or block list. Rules are conveyed to model, not enforced by a YAML validator.
- Instruction: column-zero `<<<` followed by whitespace or EOL. `<<<<<<<` is not an instruction. Adjacent instruction lines form one group. Instructions inside front matter skipped. Backtick/tilde fenced code blocks (≥3 markers, ≤3 leading spaces) are skipped; closing marker must match character, be at least opening length, and have only trailing whitespace. Unclosed fences suppress instructions to EOF. This is not a full Markdown container parser.
- Groups receive transient numeric IDs in outgoing document: `<<< [N] text`; IDs are not inserted into user's instruction lines.
- Existing document request: instruction-ID list + `<document>…</document>`, or `<diff>…</diff>` when resumed snapshot exists and unified diff is shorter than full document. Diff is not always used.
- New-document request: `<new>description</new>`.
- Output contract ([system.md](../system.md)): only tags, no enclosing Markdown fence. `<note id="N">` = short user-visible notes, not internal model reasoning. `<edit id="N"><old>whole lines</old><new>replacement lines</new></edit>`, zero or more per instruction. Empty old inserts at instruction; empty new deletes. Optional `<header>` replaces entire front matter. New draft requires `<document>`; notes use note id 0.
- Old-text lookup ignores trailing whitespace, selects nearest eligible match to instruction, and avoids active locked ranges. Missing text/overlap/malformed or unfinished blocks can be skipped; do not describe this as arbitrary patch application.
- Remove instruction only after ≥1 successful edit and intact instruction lock, on normal finalization. No edits/aborted pending instruction → keep it. Header replacement preserves plugin session field and warns user.
- Snapshot represents model's believed post-edit document, not necessarily actual buffer (user may edit concurrently or an edit may fail). Next diff reconciles actual document against that belief.

## Concurrency / failure semantics

- Extmarks track whole-line ranges. Instructions initially locked; replacement ranges locked once complete `<old>` is known. Partial `<new>` streams into locked range; closing tag commits/releases it. New draft locks initial buffer.
- InsertEnter inside lock exits Insert mode. TextChanged/TextChangedI repairs edits to locked text. Unrecoverable ranges abandoned with warning. This is editor coordination, not a security boundary.
- Rendering coalesces text updates with a 30 ms deferred flush. Notes are virtual lines, not document content; persist until dismissed/replaced.
- Consecutive plugin writes join undo history when changedtick shows no intervening user edits. No guarantee that entire generation is one atomic undo operation.
- Explicit missing-session/thread failure before any streamed text retries once with fresh UUID. Generic/API/refusal errors stop without retry. Failure after output does not automatically retry. Cancellation disables retry. Backend completion saves usage/snapshot; finish/apply errors are reported.
- Codex: initialize → initialized → config/read → thread/start or resume → turn/start → notifications → turn/completed. Server exits or RPC errors fail turn. Cancellation kills dedicated server process; no separate turn/interrupt RPC. No reconnect/request timeout/model discovery UI implemented.

## Persistence / source map

| Location | Contents / responsibility |
|---|---|
| `stdpath('data')/cowrite/state.json` | provider, per-backend model/effort, shell-approved session IDs |
| `stdpath('data')/cowrite/sessions/<id>.json` | provider, backend_session_id for Codex, document snapshot, usage, turns, optional cost |
| `stdpath('data')/cowrite/{claude,codex}/` | dedicated backend working directories; CLI owns its own conversation storage |
| `stdpath('config')/cowrite/system.md` | optional user prompt override |
| macOS Keychain | optional future API-backend credentials; not CLI credentials |
| [plugin/cowrite.lua](../plugin/cowrite.lua) | runtimepath bootstrap, command, mappings, highlight setup |
| [init.lua](../lua/cowrite/init.lua) | setup, command dispatch/pickers, instruct helper, usage/statusline |
| [backend.lua](../lua/cowrite/backend.lua) | active backend and setting-key selection |
| [claude.lua](../lua/cowrite/claude.lua), [codex.lua](../lua/cowrite/codex.lua) | process/protocol adapters |
| [generate.lua](../lua/cowrite/generate.lua) | orchestration, protocol parsing, edit matching, retry, snapshots, tool consent |
| [doc.lua](../lua/cowrite/doc.lua) | document grammar, session/front-matter manipulation, diff |
| [lock.lua](../lua/cowrite/lock.lua), [notes.lua](../lua/cowrite/notes.lua), [highlight.lua](../lua/cowrite/highlight.lua) | buffer coordination and rendering |
| [session.lua](../lua/cowrite/session.lua), [state.lua](../lua/cowrite/state.lua) | JSON persistence, UUIDs, usage formatting |
| [auth.lua](../lua/cowrite/auth.lua), [keychain.lua](../lua/cowrite/keychain.lua) | provider selection and API-key storage |
| [system.md](../system.md) | shared model instructions / output format |
| [tests/codex.lua](../tests/codex.lua) | mocked app-server protocol tests |

Prompt precedence: setup `system_prompt_file` > user config prompt > bundled system.md. Preserve output tags when editing prompt. Use reset to reliably apply changes to a new conversation; Claude resume retains original prompt, Codex supplies developer instructions on start/resume.

Validation for backend changes: `XDG_DATA_HOME=/tmp/cowrite-tests nvim --headless -u NONE -i NONE -l tests/codex.lua`; also `git diff --check`. Mock tests do not prove CLI compatibility, permissions, model output correctness, or live streaming UX. Keep human README and this reference consistent with implementation; distinguish supported code paths from verified behavior.

## AI-use consent / risk report

- `consent.lua`: editor-relative top float; a approve, r report, q/Esc/WinClosed cancel. No automatic generation on close. `generate.lua` gates first use before creating/editing session front matter; empty buffer asks for draft description first.
- Approval: buffer-local `cowrite_ai_approved` plus local state `ai_approved[sessionUUID:provider]`. Reopening a saved approved session skips dialog; new/provider-switched session records approval when ID is written. No trusted approval field in document. UUID copies share approval identity.
- Confirmation captures changedtick/backend; changed input/provider prevents approval continuation. Pending consent occupies running buffer slot; `cancel` closes it and stops report.
- Report sends full captured document/request to selected provider in a new conversation, empty allow list, dedicated `system_prompt` override. Does not inherit writing prompt or resume editing history, does not apply output. Separate conversation is not full OS/process-config isolation; existing Codex isolation limitations remain. CLI may retain report history. Report usage is separate from document usage.
- Tests: `tests/consent.lua` (window close/approve semantics), `tests/consent_generate.lua` (no generation before approval, separate review, cancellation, changed-input rejection). Test runtimepath prepends repository to avoid installed copies.

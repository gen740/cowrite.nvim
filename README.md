# cowrite.nvim

Write documents together with an AI in Neovim, asynchronously.

You leave instructions in the document as `<<<` lines, run `:Cowrite generate`, and keep writing. The AI locks only the parts it is changing, streams its edits into the buffer, and leaves notes explaining what it did.

```markdown
Extmarks track positions in a buffer and move as the text changes.
<<< add a short Lua example after this paragraph
```

New here? Read the tutorial: [English](tutorial.md) | [日本語](tutorial.ja.md).

## Requirements

- Neovim 0.10+
- [Claude Code](https://claude.com/claude-code) installed as `claude` and logged in. cowrite runs it in the background and uses its login; no API key is needed.
- macOS, only for `:Cowrite auth` (API keys are stored in the Keychain). Everything else is platform-independent.

## Installation

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "gen740/cowrite.nvim",
  cmd = "Cowrite",
  opts = {
    -- model = "sonnet",       -- default: Claude Code's default model
    -- effort = "medium",      -- default: Claude Code's default
    -- system_prompt_file = "~/notes/cowrite-system.md",
    -- dismiss_key = "q",      -- hides the AI's notes; false to disable
  },
}
```

To try it without a plugin manager:

```vim
:source /path/to/cowrite.nvim/plugin/cowrite.lua
```

## Quick start

1. Open an empty Markdown buffer: `:e note.md`.
2. Run `:Cowrite generate` and describe the document you want, e.g. *"A one-page onboarding guide for new backend engineers"*. The AI writes front matter with writing rules and a first draft, streaming it into the buffer.
3. Below any paragraph, add an instruction:

   ```markdown
   Our services are deployed with Kubernetes.
   <<< explain what a pod is, in one sentence
   ```

4. Run `:Cowrite generate` again. While it works:
   - the instruction and every part the AI is changing turn **gray** and are **read-only**: Insert mode is refused there, and Normal-mode edits (`dd`, `x`, …) are reverted;
   - the new text streams in at the AI cursor;
   - you can keep editing anywhere else.
5. When it finishes, the instruction line is removed and the AI's notes stay next to where it was. Press `q` to dismiss them.

Add as many `<<<` lines as you like before running `generate`; they are handled in one turn.

## Document format

```markdown
---
title: Onboarding guide
cowrite:
  session: 3f1c…            # added automatically; the Claude session of this document
  rules:                    # the AI follows these on every edit
    - "Audience: new backend engineers"
    - Polite, concise English
---

Body text…
<<< an instruction
```

- **`<<<` lines** are instructions: exactly three `<` followed by a space (git conflict markers never match). Consecutive `<<<` lines form one instruction. An instruction usually concerns the paragraph above it, but may ask for changes anywhere ("rename X to Y everywhere", "add a summary at the top").
- **`cowrite.rules`** are the document's writing rules. You can edit them freely. The AI may update them when an instruction implies it; you are warned and can undo with `u`.
- **`cowrite.allow`** opts the document into tools; see [Tools](#tools-opt-in).
- **`cowrite.session`** ties the document to its Claude session, so the conversation continues across Neovim restarts, renames and moves.

If an instruction is ambiguous or conflicts with the rules, the AI asks in its notes instead of editing, and leaves the instruction in place. Reword the instruction and run `generate` again.

## Commands

| Command | Description |
|---|---|
| `:Cowrite generate` | Start a new document (empty buffer), or handle all `<<<` instructions |
| `:Cowrite cancel` | Stop generating; half-written text is restored |
| `:Cowrite dismiss` | Hide the AI's notes (same as `q` while notes are shown) |
| `:Cowrite usage` | Token usage, cache hit rate and cost of this document's session |
| `:Cowrite model [name]` | Choose the model: `fable`, `opus`, `sonnet`, `haiku`, any model id, or `default` |
| `:Cowrite effort [level]` | Choose the effort: `low`, `medium`, `high`, `xhigh`, `max`, or `default` |
| `:Cowrite system` | Edit your own system prompt (see below) |
| `:Cowrite reset` | Give the document a new session; the next run starts fresh |
| `:Cowrite auth [select\|status\|logout]` | Choose the backend; API keys go to the macOS Keychain |

`:Cowrite model` and `:Cowrite effort` are remembered across Neovim sessions and take precedence over `setup()`.

## Key mappings

cowrite maps nothing globally. Every command has a `<Plug>` mapping:

```lua
vim.keymap.set("n", "<leader>cg", "<Plug>(cowrite-generate)")
vim.keymap.set("n", "<leader>ci", "<Plug>(cowrite-instruct)")
vim.keymap.set("n", "<leader>cc", "<Plug>(cowrite-cancel)")
```

| Mapping | Action |
|---|---|
| `<Plug>(cowrite-instruct)` | Open a `<<< ` line below the paragraph under the cursor, in Insert mode |
| `<Plug>(cowrite-generate)` | `:Cowrite generate` |
| `<Plug>(cowrite-cancel)` | `:Cowrite cancel` |
| `<Plug>(cowrite-dismiss)` | `:Cowrite dismiss` |
| `<Plug>(cowrite-usage)` | `:Cowrite usage` |
| `<Plug>(cowrite-reset)` | `:Cowrite reset` |
| `<Plug>(cowrite-model)` | `:Cowrite model` |
| `<Plug>(cowrite-effort)` | `:Cowrite effort` |
| `<Plug>(cowrite-system)` | `:Cowrite system` |
| `<Plug>(cowrite-auth)` | `:Cowrite auth` |

The only key cowrite binds itself is `q` (configurable with `dismiss_key`), buffer-locally and only while the AI's notes are shown; your own mapping is restored afterwards.

## Tools (opt-in)

By default the AI has no tools: it only reads the document and writes. A document can opt in through its front matter:

```yaml
cowrite:
  allow: [web, shell]      # a block list (- web) works too
```

| Value | Claude Code tools | |
|---|---|---|
| `web` | WebSearch, WebFetch | look things up |
| `read` | Read, Grep, Glob | read files; the document's directory is readable |
| `shell` | Bash | run commands |

`shell` asks for confirmation on the first generate of each document session, so a document from someone else cannot run commands on your machine just by declaring it. While a tool runs, the notes header shows it (`using WebSearch…`). Tool definitions are part of the cached prompt, so changing `allow` makes the next run uncached.

## Token usage

After each turn cowrite reports usage:

```
done · in 3.7k (cache read 1.4k / write 2.2k, 39% cached) · out 861 · ≈$0.0009 (session ≈$0.0018)
```

While generating, the notes header shows the input size and cache hit rate. For your statusline:

```lua
vim.o.statusline = "%f %= %{v:lua.require'cowrite'.statusline()}"
```

Costs are Claude Code's list-price estimates; on a subscription they are not what you are billed.

### How cowrite keeps the prompt cache warm

- Every turn resumes the same Claude session, with the same system prompt, working directory and settings. Claude Code runs with `--safe-mode` and no tools unless the document allows some, so your CLAUDE.md, hooks and MCP servers neither enter nor change the prompt.
- After the first turn, only a unified diff of the document is sent, not the whole document.
- Switching models keeps the conversation but starts a new cache.

## Customizing the system prompt

The instructions the AI follows live in [`system.md`](system.md). To change them, run `:Cowrite system`: it copies the default to `stdpath("config")/cowrite/system.md` and opens it. Your copy then replaces the bundled one. Alternatively, point `system_prompt_file` in `setup()` at any file.

Claude Code keeps a session's system prompt fixed from its first request, so changes apply to new documents and to documents after `:Cowrite reset`. Keep the output format (`<think>`, `<edit>`, `<old>`, `<new>`, `<header>`, `<document>`) intact; cowrite parses it.

## Highlights

| Group | Default | Used for |
|---|---|---|
| `CowriteInstruction` | links to `DiagnosticHint` | `<<<` lines |
| `CowriteLocked` | gray | text locked by the AI |
| `CowriteCursor` | links to `Cursor` | the AI cursor |
| `CowriteThink` | links to `Comment` | the AI's notes |
| `CowriteThinkHeader` | links to `DiagnosticInfo` | the notes' first line |

Instruction lines are colored in `markdown` and `text` buffers and in any buffer you have run cowrite in.

## Backends

Only Claude Code is implemented. `:Cowrite auth` can already store Claude API and OpenAI API keys in the macOS Keychain for backends to come.

## Data

- `stdpath("data")/cowrite/sessions/<id>.json`: per-session usage and the last document state sent to the AI
- `stdpath("data")/cowrite/state.json`: selected backend, model and effort; documents allowed to use `shell`
- `stdpath("data")/cowrite/claude/`: working directory for Claude Code, so its sessions can be resumed

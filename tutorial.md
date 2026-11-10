# cowrite.nvim tutorial

English | [日本語](tutorial.ja.md)

cowrite.nvim lets you write documents together with an AI inside Neovim. You write instructions into the text as `<<<` lines and run `:Cowrite generate`; the AI rewrites the text in the background while you keep writing elsewhere.

This tutorial takes you from an empty file to a finished short document.

The code examples are illustrative. Try them in a separate document; `<<<` inside fenced code blocks is not executed.

## 0. Setup

You need:

- Neovim 0.10 or later
- [Claude Code](https://claude.com/claude-code) (the `claude` command), logged in

cowrite runs Claude Code in the background and uses its login. No API key is needed.

With lazy.nvim:

```lua
{ "gen740/cowrite.nvim", cmd = "Cowrite", opts = {} }
```

To just try it:

```vim
:source /path/to/cowrite.nvim/plugin/cowrite.lua
```

## 1. Start a new document

Open an empty file:

```vim
:e onboarding.md
:Cowrite generate
```

In an empty buffer you are asked "What document do you want to write?". Describe it in plain words:

```
An onboarding guide for newly hired backend engineers, about one page
```

The AI's notes appear in the buffer, then the draft streams in. The range being written is gray, with the AI cursor at its end.

When it finishes, the document starts like this:

```markdown
---
title: Backend engineer onboarding
cowrite:
  session: 3f1c...
  rules:
    - "Audience: backend engineers in their first week"
    - Friendly, concise English
    - Fit on one page
---
```

- `rules` are what the AI follows whenever it writes this document. Change them freely.
- `session` links the document to its conversation with the AI. Leave it as is: thanks to it you can continue after restarting Neovim, renaming or moving the file.

The AI's notes stay on screen after it finishes. Press `q` to dismiss them.

## 2. Write instructions

Right below a paragraph you want changed, add a line starting with `<<< ` (three `<` and a space):

```markdown
The development environment runs on Docker Compose.
<<< add the first command to run, in one line
```

Run it again:

```vim
:Cowrite generate
```

While it runs:

- The `<<<` line and every range the AI is rewriting turn gray and become read-only. Insert mode is refused there, and if you delete them with `dd` or similar, they are put back.
- New text streams into the range being rewritten.
- Everything that is not gray is yours to edit as usual. There is no need to wait for the AI.

When it finishes, the `<<<` line is gone and the AI's notes stay at its place, headed for example `✓ 1 edit · q to dismiss`.

### Tips for instructions

- An instruction is normally read as being about the paragraph right above it.
- It can also ask for changes elsewhere:
  ```markdown
  <<< use "server" instead of "host" throughout
  <<< add a three-line summary at the top
  ```
- Put as many `<<<` lines across the document as you like. One generate handles them all.
- Several consecutive `<<<` lines form one instruction.

### When the AI asks a question

If an instruction is ambiguous or conflicts with the `rules` (say the rules say "fit on one page" and you ask for every step in detail), the AI does not change the text. It asks in its notes and leaves the `<<<` line in place.

Rewrite the `<<<` line with your answer and run `:Cowrite generate` again.

## 3. Stop or start over

- **Stop**: `:Cowrite cancel`. Half-written ranges get their original text back.
- **Undo**: the AI's changes undo with `u` like any other change.
- **Start the conversation over**: `:Cowrite reset` gives the document a new session id. The next generate starts with an AI that remembers nothing.

## 4. Choose the model and effort

```vim
:Cowrite model          " pick from a list
:Cowrite model sonnet   " or name it
:Cowrite effort low
```

Models: `fable`, `opus`, `sonnet`, `haiku`, or any model name. `default` follows Claude Code's own setting. The choice is remembered across restarts.

Switching models keeps the conversation going. The prompt cache is per model, though, so the first run after a switch is not cached.

## 5. Watch token usage

Every generate ends with a notification like:

```
done · in 3.7k (cache read 1.4k / write 2.2k, 39% cached) · out 861 · ≈$0.0009 (session ≈$0.0018)
```

- `in`: input tokens, of which `cache read` came from the cache and `cache write` were newly cached
- `out`: output tokens
- `$`: an estimate at list price; on a subscription this is not what you pay

`:Cowrite usage` shows the totals for the document. For your statusline:

```lua
vim.o.statusline = "%f %= %{v:lua.require'cowrite'.statusline()}"
```

cowrite is built to keep the cache warm: it resumes the same conversation every time and, after the first turn, sends only what changed (a diff) instead of the whole document. The more turns, the larger the cached share.

## 6. Let the AI search the web or run commands (opt-in)

By default the AI has no tools at all. That keeps it focused on writing and keeps every request identical up front, so the cache works.

For a document that needs research, list what to allow under `cowrite.allow` in the front matter:

```yaml
cowrite:
  allow: [web, shell]
```

| Value | Lets the AI |
|---|---|
| `web` | search the web and fetch pages |
| `read` | read files (including the document's own directory) |
| `shell` | run shell commands |

```markdown
<<< look up the latest stable Neovim release and add its version number
```

- For `shell`, the first generate asks you to confirm. A document someone sends you must not be able to run commands on your machine just because its header says `shell`. The approval is remembered per document session.
- While a tool runs, the notes header says so, e.g. `using WebSearch…`.
- Changing `allow` makes the next run uncached.

## 7. Key mappings

Every command has a `<Plug>` mapping. Bind the ones you want:

```lua
vim.keymap.set("n", "<leader>cg", "<Plug>(cowrite-generate)")
vim.keymap.set("n", "<leader>ci", "<Plug>(cowrite-instruct)")
vim.keymap.set("n", "<leader>cc", "<Plug>(cowrite-cancel)")
```

`<Plug>(cowrite-instruct)` opens a `<<< ` line right below the paragraph under the cursor, in Insert mode.

Available: `generate`, `instruct`, `cancel`, `dismiss`, `usage`, `reset`, `model`, `effort`, `system`, `auth`.

`q` dismisses the notes and is mapped only while notes are shown. To use another key, or none:

```lua
require("cowrite").setup({ dismiss_key = "<Esc>" })  -- false: no mapping
```

## 8. Make the AI's instructions (system prompt) your own

How the AI behaves is written in [`system.md`](system.md). To change it:

```vim
:Cowrite system
```

The default `system.md` is copied to `~/.config/nvim/cowrite/system.md` and opened. From then on your copy is used. A good place for preferences you want in every document, like "always add the English term next to jargon".

Two things to know:

- **Changes apply to new sessions.** Claude Code keeps the system prompt a conversation started with. To apply your changes to an existing document, run `:Cowrite reset` in it.
- **Keep the output format** (`<note>`, `<edit>`, `<old>`, `<new>`, `<header>`, `<document>`). cowrite reads it to apply the AI's work.

## Commands

| Command | Description |
|---|---|
| `:Cowrite generate` | Start a new document (empty buffer) / handle all `<<<` instructions |
| `:Cowrite cancel` | Stop generating; half-written text is restored |
| `:Cowrite dismiss` | Hide the AI's notes (same as `q`) |
| `:Cowrite usage` | Token usage and cost estimate for this document |
| `:Cowrite model [name]` | Choose the model |
| `:Cowrite effort [level]` | Choose the effort |
| `:Cowrite system` | Edit your own system prompt |
| `:Cowrite reset` | New session id; start the conversation over |
| `:Cowrite auth` | Choose the backend (only Claude Code works today) |

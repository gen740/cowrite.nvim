# cowrite.nvim tutorial

English | [日本語](tutorial.ja.md)

cowrite.nvim lets you ask an AI to edit a document from inside Neovim. The basic loop is **write an instruction with `@ai ` → run `:Cowrite generate` → read the result**.

Let's create a short onboarding guide and revise it. Try the examples in a separate file. When copying an instruction, leave out the lines that enclose the code block.

## 1. Set up

You need Neovim 0.10 or later and either Claude Code (`claude`) or Codex CLI (`codex`), installed and logged in.

With lazy.nvim, add this to your plugin list and install it:

```lua
{ "gen740/cowrite.nvim", cmd = "Cowrite", opts = {} }
```

In Neovim, run the following and select **Claude Code** or **Codex**:

```vim
:Cowrite auth
```

cowrite uses the selected CLI's login. You do not need to register an API key with cowrite.

## 2. Create a draft

Open an empty buffer using a filename that does not exist yet:

```vim
:e onboarding.md
:Cowrite generate
```

When asked "What document do you want to write?", describe it and press Enter:

```text
A one-page onboarding guide for newly hired backend engineers. Leave questions for details we haven't decided yet.
```

The first run opens an AI-use confirmation. **Press `a` to approve: your input is sent to the selected service and generation starts.** Press `q` or Esc to cancel. You can press `r` to request a risk report about the input; this also sends the content to the AI.

The draft appears gradually. Gray areas are being edited by the AI; wait until it finishes before changing those areas. You can edit elsewhere while it works.

Read the draft when generation finishes. Press `q` in Normal mode to hide the AI's change notes. This does not remove any document text.

## 3. Ask for a revision

Below the paragraph you want changed, add a line starting with `@ai `: `@ai` followed by a space.

Instruction lines appear in bold with a distinct color so you can tell them apart from the document text.

For example, to make a paragraph more concrete:

```markdown
On your first day, prepare your development environment.
@ai turn this into a three-item checklist: clone the repository, install dependencies, and run the tests
```

Return to Normal mode and run:

```vim
:Cowrite generate
```

The paragraph is rewritten and the processed instruction disappears. Read the result, then add another instruction if needed. You can also edit the text yourself.

Instructions can apply to the whole document:

```markdown
@ai add three lines at the top explaining what this guide covers
```

You can add instructions in several places before running `:Cowrite generate`; it handles them together. Consecutive `@ai` lines count as one instruction.

### If the AI asks a question

When the AI needs clarification, the `@ai` line stays in place. Rewrite it to include your answer, then run the command again.

For example, if asked which operating system to cover:

```markdown
@ai write the development environment setup steps for someone using macOS
```

If the AI left `@ai` questions in the draft, replace those with concrete instructions in the same way.

## 4. Save and continue later

When you are happy with the document, save it as usual:

```vim
:w
```

Next time, open the file, add another `@ai` instruction, and run `:Cowrite generate`.

The section between `---` lines at the top holds the document's settings. You can usually leave it alone.

- `rules`: writing rules such as audience and tone. Edit these to change a preference for the whole document, such as "Use short sentences".
- `session`: an automatically added ID that keeps the conversation going. Leave it in place.

## When you need help

| What you want to do | Action |
|---|---|
| Stop generation | Run `:Cowrite cancel`. Half-written parts are restored |
| Undo a change | After generation finishes, use `u` as usual |
| Hide change notes | Press `q` in Normal mode, or run `:Cowrite dismiss` |
| Fix an instruction that is not being processed | Check that the line starts with `@ai `. Instructions inside code blocks are not processed |
| Start the conversation over | Run `:Cowrite reset`. The text stays; the next generation starts a new conversation |

## Once you are comfortable

Add shortcuts for frequent actions to your Neovim configuration:

```lua
vim.keymap.set("n", "<leader>cg", "<Plug>(cowrite-generate)")
vim.keymap.set("n", "<leader>ci", "<Plug>(cowrite-instruct)")
vim.keymap.set("n", "<leader>cc", "<Plug>(cowrite-cancel)")
```

`<leader>ci` creates an instruction line below the current paragraph and lets you start typing immediately.

Explore these settings when you need them:

- **Choose a model**: `:Cowrite model`. Use `:Cowrite effort` to choose how much effort to spend.
- **Check usage**: `:Cowrite usage`. Prices shown are estimates and may differ from your bill.
- **Enable web search or file access**: see [Tools in the README](README.md#tools-opt-in). Tools are enabled per document.
- **Set writing preferences for all documents**: see [System prompt in the README](README.md#customizing-the-system-prompt).

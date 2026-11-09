-- Highlight groups (re-applied on :colorscheme, which clears them) and the
-- always-on coloring of `<<<` instruction lines.
local doc = require("cowrite.doc")

local M = {}

M.ns = vim.api.nvim_create_namespace("cowrite.instruction")
-- Instruction lines are colored in these filetypes and in any buffer cowrite
-- has worked on.
M.filetypes = { markdown = true, text = true }

local function define()
  local function set(name, val)
    val.default = true
    vim.api.nvim_set_hl(0, name, val)
  end
  set("CowriteLocked", { fg = "#808080", ctermfg = 244 })
  set("CowriteCursor", { link = "Cursor" })
  set("CowriteThink", { link = "Comment" })
  set("CowriteThinkHeader", { link = "DiagnosticInfo" })
  set("CowriteInstruction", { link = "DiagnosticHint" })
end

function M.setup()
  define()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("cowrite_highlight", { clear = true }),
    callback = define,
  })
  vim.api.nvim_set_decoration_provider(M.ns, {
    on_win = function(_, _, bufnr)
      return M.filetypes[vim.bo[bufnr].filetype] == true or vim.b[bufnr].cowrite == true
    end,
    on_line = function(_, _, bufnr, row)
      local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
      if line and doc.is_instruction(line) then
        vim.api.nvim_buf_set_extmark(bufnr, M.ns, row, 0, {
          end_row = row,
          end_col = #line,
          hl_group = "CowriteInstruction",
          hl_eol = true,
          ephemeral = true,
          priority = 150, -- below CowriteLocked (200), so a locked line turns gray
        })
      end
    end,
  })
end

return M

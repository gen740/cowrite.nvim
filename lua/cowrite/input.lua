local doc = require("cowrite.doc")

local M = {}
local active = {}

-- Use Neovim's comment continuation for both Enter and textwidth wrapping.
-- The three-part syntax requires an end marker. Instructions end with a line
-- without a leader, so use a separator that is outside the document syntax.
local leaders = "sb:@ai,mb:>>>,e:" .. string.char(31)

local function restore(bufnr)
  local saved = active[bufnr]
  if not saved then return end
  active[bufnr] = nil
  local bo = vim.bo[bufnr]
  if bo.comments == leaders then bo.comments = saved.comments end
  if bo.formatoptions == saved.applied_formatoptions then bo.formatoptions = saved.formatoptions end
end

local function update(bufnr, char)
  local bo = vim.bo[bufnr]
  if not bo.modifiable or not (require("cowrite.highlight").filetypes[bo.filetype] or vim.b[bufnr].cowrite) then
    restore(bufnr)
    return
  end
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local line = vim.api.nvim_get_current_line()
  if char and col <= 3 then
    line = line:sub(1, col) .. char .. line:sub(col + 1)
  end
  if not (doc.is_instruction(line) or doc.is_continuation(line)) then
    restore(bufnr)
    return
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  lines[row] = line
  if not doc.instruction_at(lines, row) then
    restore(bufnr)
    return
  end
  if active[bufnr] then return end
  local formatoptions = bo.formatoptions
  local applied = formatoptions
  for _, flag in ipairs({ "c", "r" }) do
    if not applied:find(flag, 1, true) then applied = applied .. flag end
  end
  active[bufnr] = {
    comments = bo.comments,
    formatoptions = formatoptions,
    applied_formatoptions = applied,
  }
  bo.comments = leaders
  bo.formatoptions = applied
end

function M.setup()
  local group = vim.api.nvim_create_augroup("cowrite_input", { clear = true })
  vim.api.nvim_create_autocmd({ "InsertEnter", "InsertCharPre", "CursorMovedI" }, {
    group = group,
    callback = function(args)
      update(args.buf, args.event == "InsertCharPre" and vim.v.char or nil)
    end,
  })
  vim.api.nvim_create_autocmd({ "InsertLeave", "BufLeave" }, {
    group = group,
    callback = function(args) restore(args.buf) end,
  })
  -- CTRL-C can leave Insert mode without firing InsertLeave.
  vim.api.nvim_create_autocmd("ModeChanged", {
    group = group,
    pattern = { "i*:n*", "R*:n*" },
    callback = function(args) restore(args.buf) end,
  })
end

return M

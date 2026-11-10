-- Top-of-editor consent UI. Closing the window always cancels the request.
local M = {}

---@param opts {on_approve: function, on_cancel: function, on_report: function, description?: string[]}
function M.open(opts)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local width = math.max(1, math.min(76, vim.o.columns - 4))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", row = 0, col = math.max(0, math.floor((vim.o.columns - width) / 2) - 1),
    width = width, height = math.max(1, math.min(12, vim.o.lines - 4)),
    style = "minimal", border = "rounded", title = " cowrite · AI use ", title_pos = "center",
  })
  vim.wo[win].wrap = true
  local closed = false
  local ui = {}
  function ui.render(report)
    if closed or not vim.api.nvim_buf_is_valid(buf) then return end
    local lines = { "AI を利用しますか？", "" }
    vim.list_extend(lines, opts.description or {})
    vim.list_extend(lines, {
      "", "[r] report · 別の会話でリスクを評価", "[a] 承認して生成", "[q / Esc] キャンセルして閉じる", "",
    })
    vim.list_extend(lines, vim.split(report or "", "\n", { plain = true }))
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
  end
  function ui.close(approved)
    if closed then return end
    closed = true
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    if approved then opts.on_approve() else opts.on_cancel() end
  end
  local function map(key, fn)
    vim.keymap.set("n", key, fn, { buffer = buf, silent = true, nowait = true })
  end
  map("a", function() ui.close(true) end)
  map("r", function() opts.on_report(ui) end)
  map("q", function() ui.close(false) end)
  map("<Esc>", function() ui.close(false) end)
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win), once = true,
    callback = function() ui.close(false) end,
  })
  ui.render()
  return ui
end
return M

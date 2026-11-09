-- Locks: ranges of whole lines the AI owns while it rewrites them. Shown in
-- gray; Insert mode is refused inside; other edits release the lock.
local M = {}

M.ns = vim.api.nvim_create_namespace("cowrite.lock")

---@type table<integer, cowrite.Lock[]>
M.by_buf = {}
-- changedtick right after our last write, per buffer: consecutive writes of
-- ours join into one undo step unless the user changed something in between.
local our_tick = {}

local function notify(msg, level)
  vim.notify("cowrite: " .. msg, level or vim.log.levels.INFO)
end

function M.set_lines(bufnr, s, e, lines)
  if our_tick[bufnr] == vim.b[bufnr].changedtick then
    pcall(vim.api.nvim_buf_call, bufnr, function()
      vim.cmd("silent! undojoin")
    end)
  end
  vim.api.nvim_buf_set_lines(bufnr, s, e, false, lines)
  our_tick[bufnr] = vim.b[bufnr].changedtick
end

---@class cowrite.Lock
---@field bufnr integer
---@field label string
---@field state "active"|"done"|"released"|"broken"
---@field original string[]
---@field expected string[] what the range holds unless the user touched it
---@field inserted boolean|nil the range is a placeholder line we inserted
---@field reason string|nil
---@field mark integer|nil
---@field cursor integer|nil
local Lock = {}
Lock.__index = Lock

function Lock:range_opts(e)
  local last = vim.api.nvim_buf_get_lines(self.bufnr, e, e + 1, false)[1] or ""
  return {
    id = self.mark,
    end_row = e,
    end_col = #last,
    hl_group = "CowriteLocked",
    hl_eol = true,
    priority = 200,
    invalidate = true,
  }
end

--- Lock rows s..e (0-based, inclusive).
---@return cowrite.Lock
function M.new(bufnr, label, s, e)
  local l = setmetatable({ bufnr = bufnr, label = label, state = "active" }, Lock)
  l.original = vim.api.nvim_buf_get_lines(bufnr, s, e + 1, false)
  l.expected = vim.list_slice(l.original)
  l.mark = vim.api.nvim_buf_set_extmark(bufnr, M.ns, s, 0, l:range_opts(e))
  M.by_buf[bufnr] = M.by_buf[bufnr] or {}
  table.insert(M.by_buf[bufnr], l)
  return l
end

--- Insert an empty placeholder line at `row` and lock it.
function M.new_insert(bufnr, label, row)
  M.set_lines(bufnr, row, row, { "" })
  local l = M.new(bufnr, label, row, row)
  l.inserted = true
  return l
end

function Lock:active()
  return self.state == "active"
end

function Lock:range()
  if not self.mark then
    return nil
  end
  local p = vim.api.nvim_buf_get_extmark_by_id(self.bufnr, M.ns, self.mark, { details = true })
  if not p[1] or p[3].invalid then
    return nil
  end
  return p[1], p[3].end_row
end

function Lock:intact()
  local s, e = self:range()
  return s ~= nil and vim.deep_equal(vim.api.nvim_buf_get_lines(self.bufnr, s, e + 1, false), self.expected)
end

--- Replace the locked lines. With `cursor`, show the AI cursor at the end.
function Lock:write(lines, cursor)
  local s, e = self:range()
  if not s then
    return
  end
  M.set_lines(self.bufnr, s, e + 1, lines)
  self.expected = lines
  if #lines == 0 then
    return
  end
  local ne = s + #lines - 1
  self.mark = vim.api.nvim_buf_set_extmark(self.bufnr, M.ns, s, 0, self:range_opts(ne))
  if cursor then
    self.cursor = vim.api.nvim_buf_set_extmark(self.bufnr, M.ns, ne, #lines[#lines], {
      id = self.cursor,
      virt_text = { { " ", "CowriteCursor" } },
      virt_text_pos = "inline",
      priority = 300,
    })
  end
end

--- Put back what was there before, if the user hasn't touched it.
function Lock:restore()
  if self:active() and self:intact() then
    self:write(self.inserted and {} or self.original, false)
  end
end

function Lock:release(state)
  self.state = state or "released"
  for _, id in ipairs({ self.mark, self.cursor }) do
    pcall(vim.api.nvim_buf_del_extmark, self.bufnr, M.ns, id)
  end
  self.mark, self.cursor = nil, nil
end

--- Put the expected text back after the user changed it. Works even when the
--- whole range was deleted: the (invalidated) mark still knows where it was.
---@return boolean restored
function Lock:enforce()
  if not self.mark then
    return false
  end
  local p = vim.api.nvim_buf_get_extmark_by_id(self.bufnr, M.ns, self.mark, { details = true })
  if not p[1] then
    self:abandon("its text disappeared")
    return false
  end
  local s = p[1]
  local e = p[3].invalid and s - 1 or p[3].end_row
  M.set_lines(self.bufnr, s, e + 1, self.expected)
  pcall(vim.api.nvim_buf_del_extmark, self.bufnr, M.ns, self.mark)
  self.mark = nil
  self.mark = vim.api.nvim_buf_set_extmark(self.bufnr, M.ns, s, 0, self:range_opts(s + #self.expected - 1))
  return true
end

function Lock:abandon(reason)
  self.reason = reason
  self:release("broken")
  notify(self.label .. " released: " .. reason, vim.log.levels.WARN)
end

--- True when rows s..e overlap no active lock.
function M.is_free(bufnr, s, e)
  for _, l in ipairs(M.by_buf[bufnr] or {}) do
    if l:active() then
      local ls, le = l:range()
      if ls and not (e < ls or s > le) then
        return false
      end
    end
  end
  return true
end

function M.guard(bufnr)
  our_tick[bufnr] = nil
  local group = vim.api.nvim_create_augroup("cowrite_lock_" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd("InsertEnter", {
    group = group,
    buffer = bufnr,
    callback = function()
      local row = vim.api.nvim_win_get_cursor(0)[1] - 1
      if not M.is_free(bufnr, row, row) then
        notify("this part is locked while the AI edits it", vim.log.levels.WARN)
        vim.schedule(function()
          vim.cmd("stopinsert")
        end)
      end
    end,
  })
  -- Normal-mode commands (dd, x, p, …) can't be blocked; undo their effect on
  -- locked text right after they happen.
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    group = group,
    buffer = bufnr,
    callback = function()
      local restored = false
      for _, l in ipairs(M.by_buf[bufnr] or {}) do
        if l:active() and not l:intact() then
          restored = l:enforce() or restored
        end
      end
      if restored then
        notify("locked text is read-only while the AI works; restored it", vim.log.levels.WARN)
      end
    end,
  })
end

function M.unguard(bufnr)
  pcall(vim.api.nvim_del_augroup_by_name, "cowrite_lock_" .. bufnr)
  for _, l in ipairs(M.by_buf[bufnr] or {}) do
    if l:active() then
      l:release()
    end
  end
  M.by_buf[bufnr] = nil
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
end

return M

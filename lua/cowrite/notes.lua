-- The AI's notes, shown as virtual lines. They stay after the turn ends until
-- dismissed with `q` (mapped only while notes are shown) or :Cowrite dismiss.
local M = {}

M.ns = vim.api.nvim_create_namespace("cowrite.notes")

local function virt_lines(body, header)
  local vl = { { { "▎cowrite " .. header, "CowriteThinkHeader" } } }
  for _, l in ipairs(vim.split(vim.trim(body or ""), "\n", { plain = true })) do
    if l ~= "" then
      table.insert(vl, { { "▎ " .. l, "CowriteThink" } })
    end
  end
  return vl
end

---@return integer extmark id
function M.place(bufnr, row, above)
  return vim.api.nvim_buf_set_extmark(bufnr, M.ns, row, 0, {
    virt_lines = virt_lines("", "waiting…"),
    virt_lines_above = above,
  })
end

--- Update a note's text; `row` moves it.
function M.update(bufnr, id, body, header, row)
  local p = vim.api.nvim_buf_get_extmark_by_id(bufnr, M.ns, id, { details = true })
  if not p[1] then
    return
  end
  pcall(vim.api.nvim_buf_set_extmark, bufnr, M.ns, row or p[1], 0, {
    id = id,
    virt_lines = virt_lines(body, header),
    virt_lines_above = p[3].virt_lines_above,
  })
end

local saved, saved_key = {}, {}

local function unmap_q(bufnr)
  local s = saved[bufnr]
  if s == nil then
    return
  end
  saved[bufnr] = nil
  pcall(vim.keymap.del, "n", saved_key[bufnr], { buffer = bufnr })
  if s and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_call(bufnr, function()
      vim.fn.mapset("n", false, s)
    end)
  end
end

function M.clear(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  unmap_q(bufnr)
end

--- Map `q` to dismiss, if any notes are shown. Restores the user's own
--- buffer-local `q` mapping afterwards.
function M.enable_dismiss(bufnr)
  local key = require("cowrite.claude").config.dismiss_key
  if not key or saved[bufnr] ~= nil or #vim.api.nvim_buf_get_extmarks(bufnr, M.ns, 0, -1, { limit = 1 }) == 0 then
    return
  end
  local m = vim.api.nvim_buf_call(bufnr, function()
    return vim.fn.maparg(key, "n", false, true)
  end)
  saved[bufnr] = (m.buffer == 1) and m or false
  saved_key[bufnr] = key
  vim.keymap.set("n", key, function()
    M.clear(bufnr)
  end, { buffer = bufnr, nowait = true, desc = "cowrite: dismiss notes" })
end

return M

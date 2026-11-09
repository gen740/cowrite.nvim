local keychain = require("cowrite.keychain")
local state = require("cowrite.state")

local M = {}

---@class cowrite.Provider
---@field id string
---@field label string
---@field needs_key boolean
---@field implemented boolean

---@type cowrite.Provider[]
M.providers = {
  { id = "claude-code", label = "Claude Code (uses the `claude` CLI login)", needs_key = false, implemented = true },
  { id = "anthropic", label = "Claude API (API key)", needs_key = true, implemented = false },
  { id = "openai", label = "OpenAI (API key)", needs_key = true, implemented = false },
}

local function find(id)
  for _, p in ipairs(M.providers) do
    if p.id == id then
      return p
    end
  end
end

local function notify(msg, level)
  vim.notify("cowrite: " .. msg, level or vim.log.levels.INFO)
end

--- Currently selected provider, or nil.
---@return cowrite.Provider|nil
function M.current()
  return find(state.get("provider"))
end

--- API key for a provider from the keychain, or nil.
function M.key(provider_id)
  return keychain.get(provider_id)
end

local function activate(p)
  state.set("provider", p.id)
  local suffix = p.implemented and "" or " (backend not implemented yet; key is stored for later)"
  notify("using " .. p.label .. suffix)
end

local function prompt_key(p)
  local existing = p.needs_key and keychain.get(p.id)
  if existing then
    local choice = vim.fn.confirm("cowrite: a key for " .. p.id .. " is already stored. Replace it?", "&Keep\n&Replace", 1)
    if choice ~= 2 then
      activate(p)
      return
    end
  end
  local key = vim.trim(vim.fn.inputsecret(p.label .. " key: "))
  if key == "" then
    notify("cancelled", vim.log.levels.WARN)
    return
  end
  local ok, err = pcall(keychain.set, p.id, key)
  if not ok then
    notify(tostring(err), vim.log.levels.ERROR)
    return
  end
  activate(p)
end

function M.select()
  local current = state.get("provider")
  vim.ui.select(M.providers, {
    prompt = "cowrite: select auth",
    format_item = function(p)
      local marks = {}
      if p.id == current then
        table.insert(marks, "current")
      end
      if not p.implemented then
        table.insert(marks, "not implemented")
      end
      return p.label .. (#marks > 0 and (" [" .. table.concat(marks, ", ") .. "]") or "")
    end,
  }, function(p)
    if not p then
      return
    end
    -- Some vim.ui.select backends call back inside their own window; defer.
    vim.schedule(function()
      if p.id == "claude-code" then
        if vim.fn.executable("claude") ~= 1 then
          notify("`claude` not found in PATH; install Claude Code and run `claude` to log in", vim.log.levels.WARN)
        end
        activate(p)
      else
        prompt_key(p)
      end
    end)
  end)
end

function M.status()
  local current = M.current()
  local lines = { "auth:" }
  for _, p in ipairs(M.providers) do
    local info
    if p.needs_key then
      info = keychain.get(p.id) and "key stored in keychain" or "no key"
    else
      info = vim.fn.executable("claude") == 1 and "`claude` found" or "`claude` not found"
    end
    local mark = (current and current.id == p.id) and "* " or "  "
    table.insert(lines, string.format("%s%-12s %s", mark, p.id, info))
  end
  notify(table.concat(lines, "\n"))
end

function M.logout()
  local stored = vim.tbl_filter(function(p)
    return p.needs_key and keychain.get(p.id) ~= nil
  end, M.providers)
  if #stored == 0 then
    notify("no stored keys")
    return
  end
  vim.ui.select(stored, {
    prompt = "cowrite: remove key",
    format_item = function(p)
      return p.label
    end,
  }, function(p)
    if not p then
      return
    end
    vim.schedule(function()
      if keychain.delete(p.id) then
        if state.get("provider") == p.id then
          state.set("provider", nil)
        end
        notify("removed key for " .. p.id)
      else
        notify("failed to remove key for " .. p.id, vim.log.levels.ERROR)
      end
    end)
  end)
end

return M

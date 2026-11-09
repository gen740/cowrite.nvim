-- Minimal wrapper around the macOS `security` CLI for generic passwords.
local M = {}

M.service = "cowrite.nvim"

local function ensure_mac()
  if vim.fn.has("mac") ~= 1 then
    error("cowrite: keychain storage is only supported on macOS for now", 0)
  end
end

--- Store (or overwrite) a secret.
--- The secret is passed through `security -i` on stdin so it never appears
--- in the process list as a command-line argument.
---@param account string
---@param secret string
function M.set(account, secret)
  ensure_mac()
  -- `security -i` tokenizes its input like a shell; restrict the charset so
  -- no quoting is ever needed. API keys only use these characters.
  if not secret:match("^[%w%-_%.]+$") then
    error("cowrite: secret contains unsupported characters", 0)
  end
  local line = string.format(
    'add-generic-password -U -s "%s" -a "%s" -l "%s (%s)" -w "%s"\n',
    M.service,
    account,
    M.service,
    account,
    secret
  )
  local res = vim.system({ "security", "-i" }, { stdin = line, text = true }):wait()
  -- `security -i` may exit 0 even if the inner command failed; verify.
  if res.code ~= 0 or M.get(account) ~= secret then
    error("cowrite: failed to save to keychain: " .. vim.trim(res.stderr or ""), 0)
  end
end

---@param account string
---@return string|nil
function M.get(account)
  ensure_mac()
  local res = vim
    .system({ "security", "find-generic-password", "-s", M.service, "-a", account, "-w" }, { text = true })
    :wait()
  if res.code ~= 0 then
    return nil
  end
  return (res.stdout:gsub("\n$", ""))
end

---@param account string
---@return boolean deleted
function M.delete(account)
  ensure_mac()
  local res = vim.system({ "security", "delete-generic-password", "-s", M.service, "-a", account }):wait()
  return res.code == 0
end

return M

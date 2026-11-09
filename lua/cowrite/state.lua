-- Persisted, non-secret settings (e.g. which provider is selected).
local M = {}

local function path()
  return vim.fs.joinpath(vim.fn.stdpath("data"), "cowrite", "state.json")
end

function M.read()
  local f = io.open(path(), "r")
  if not f then
    return {}
  end
  local content = f:read("*a")
  f:close()
  local ok, data = pcall(vim.json.decode, content)
  return ok and type(data) == "table" and data or {}
end

function M.write(data)
  local p = path()
  vim.fn.mkdir(vim.fs.dirname(p), "p")
  local f = assert(io.open(p, "w"))
  f:write(vim.json.encode(data))
  f:close()
end

function M.get(key)
  return M.read()[key]
end

function M.set(key, value)
  local data = M.read()
  data[key] = value
  M.write(data)
end

return M

-- One Claude session per document, persisted so the conversation (and the
-- prompt cache behind it) survives Neovim restarts.
local M = {}

---@class cowrite.Usage
---@field input integer uncached input tokens
---@field cache_read integer
---@field cache_write integer
---@field output integer

---@class cowrite.Session
---@field id string Claude session id
---@field snapshot string|nil document as the model believes it is now
---@field total cowrite.Usage
---@field last cowrite.Usage|nil
---@field turns integer
---@field cost number|nil cumulative USD reported by Claude Code (list price)
---@field last_cost number|nil

-- Sessions are keyed by their id, which lives in the document's front matter
-- (`cowrite.session`), so they follow the file wherever it goes.
local function file(id)
  return vim.fs.joinpath(vim.fn.stdpath("data"), "cowrite", "sessions", id .. ".json")
end

function M.empty_usage()
  return { input = 0, cache_read = 0, cache_write = 0, output = 0 }
end

--- Session id from the buffer's front matter.
function M.id_of(bufnr)
  return (require("cowrite.doc").session_id(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)))
end

---@return cowrite.Session|nil
function M.load(id)
  if not id then
    return nil
  end
  local f = io.open(file(id), "r")
  if not f then
    return nil
  end
  local ok, data = pcall(vim.json.decode, f:read("*a"))
  f:close()
  return ok and type(data) == "table" and data or nil
end

---@param s cowrite.Session
function M.save(s)
  local p = file(s.id)
  vim.fn.mkdir(vim.fs.dirname(p), "p")
  local f = assert(io.open(p, "w"))
  f:write(vim.json.encode(s))
  f:close()
end

function M.new_id()
  local r = vim.system({ "uuidgen" }, { text = true }):wait()
  return vim.trim(r.stdout):lower()
end

---@param u cowrite.Usage
function M.format_usage(u)
  local function k(n)
    if n >= 1000 then
      return ("%.1fk"):format(n / 1000)
    end
    return tostring(n)
  end
  local input_total = u.input + u.cache_read + u.cache_write
  local cached = input_total > 0 and math.floor(u.cache_read / input_total * 100 + 0.5) or 0
  return ("in %s (cache read %s / write %s, %d%% cached) · out %s"):format(
    k(input_total),
    k(u.cache_read),
    k(u.cache_write),
    cached,
    k(u.output)
  )
end

return M

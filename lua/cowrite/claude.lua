-- Backend: Claude Code CLI in print mode, streaming JSON.
local M = { id = "claude-code" }

M.config = {
  cmd = "claude",
  model = nil, -- e.g. "opus", "sonnet"; nil = Claude Code's default
  effort = nil, -- "low" | "medium" | "high" | ...
  system_prompt_file = nil, -- path to your own system prompt (Markdown)
  dismiss_key = "q", -- key that hides the AI's notes while they are shown; false to disable
}

-- The system prompt comes from a Markdown file the user may replace:
--   1. setup({ system_prompt_file = "..." })
--   2. stdpath("config")/cowrite/system.md  (`:Cowrite system` creates it)
--   3. system.md bundled with the plugin
-- Claude Code records a session's system prompt on its first request and
-- reuses it on every resume, so edits apply to new sessions (:Cowrite reset).
-- That also keeps the prompt byte-identical, which the prompt cache needs.
M.bundled_system_file = vim.fs.joinpath(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h"),
  "system.md"
)
M.user_system_file = vim.fs.joinpath(vim.fn.stdpath("config"), "cowrite", "system.md")

--- Path of the system prompt in effect.
function M.system_file()
  local custom = M.config.system_prompt_file
  if custom then
    return vim.fs.normalize(custom)
  end
  if vim.uv.fs_stat(M.user_system_file) then
    return M.user_system_file
  end
  return M.bundled_system_file
end

function M.system_prompt()
  local path = M.system_file()
  local f = io.open(path, "r")
  if not f then
    error("cowrite: cannot read system prompt " .. path, 0)
  end
  local text = f:read("*a")
  f:close()
  return text
end

-- Choices made with :Cowrite model / :Cowrite effort win over setup().
function M.model()
  return require("cowrite.state").get("model") or M.config.model
end

function M.effort()
  return require("cowrite.state").get("effort") or M.config.effort
end

M.models = { "fable", "opus", "sonnet", "haiku" }
M.efforts = { "low", "medium", "high", "xhigh", "max" }

local function workdir()
  -- Claude Code stores sessions per working directory, so it must be stable
  -- for --resume to find them. It also keeps project CLAUDE.md files out.
  local dir = vim.fs.joinpath(vim.fn.stdpath("data"), "cowrite", "claude")
  vim.fn.mkdir(dir, "p")
  return dir
end

-- Tool groups a document can opt into with `cowrite.allow` in its front matter.
M.tool_groups = {
  web = { "WebSearch", "WebFetch" },
  read = { "Read", "Grep", "Glob" },
  shell = { "Bash" },
}

---@class cowrite.RunOpts
---@field prompt string
---@field session_id string
---@field resume boolean
---@field on_text fun(text: string) accumulated assistant text so far
---@field on_start_usage fun(usage: table)|nil input usage of the request, as soon as known
---@field on_tool fun(name: string)|nil a tool call started
---@field allow string[]|nil tool groups to enable (keys of M.tool_groups)
---@field add_dir string|nil extra directory the file tools may read
---@field on_done fun(res: {text: string, usage: table, cost: number|nil})
---@field on_error fun(msg: string, got_output: boolean)

---@param opts cowrite.RunOpts
---@return {kill: fun()}
function M.run(opts)
  local c = M.config
  local args = {
    c.cmd,
    "-p",
    "--output-format",
    "stream-json",
    "--verbose",
    "--include-partial-messages",
    "--safe-mode", -- no CLAUDE.md, hooks, plugins, MCP: stable, small prefix
    "--system-prompt",
    opts.system_prompt or M.system_prompt(),
  }
  -- No tools unless the document opts in: every tool definition is part of
  -- the cached prefix, and tools are a risk the user has to choose.
  local tools = {}
  for _, group in ipairs(opts.allow or {}) do
    vim.list_extend(tools, M.tool_groups[group] or {})
  end
  vim.list_extend(args, { "--tools", table.concat(tools, ",") })
  if #tools > 0 then
    vim.list_extend(args, { "--allowedTools", table.concat(tools, ","), "--permission-prompts", "none" })
    if opts.add_dir then
      vim.list_extend(args, { "--add-dir", opts.add_dir })
    end
  end
  local model, effort = M.model(), M.effort()
  if model then
    vim.list_extend(args, { "--model", model })
  end
  if effort then
    vim.list_extend(args, { "--effort", effort })
  end
  vim.list_extend(args, { opts.resume and "--resume" or "--session-id", opts.session_id })

  local pending, text, result, stderr = "", "", nil, ""

  local function handle(line)
    local ok, ev = pcall(vim.json.decode, line)
    if not ok or type(ev) ~= "table" then
      return
    end
    if ev.type == "stream_event" and type(ev.event) == "table" then
      local e = ev.event
      if e.type == "message_start" and text ~= "" and not text:match("\n$") then
        -- With tools, a turn spans several messages; keep their text apart.
        text = text .. "\n"
      end
      if e.type == "content_block_start" and opts.on_tool and e.content_block and e.content_block.type == "tool_use" then
        local name = e.content_block.name
        vim.schedule(function()
          opts.on_tool(name)
        end)
      end
      if e.type == "content_block_delta" and e.delta and e.delta.type == "text_delta" then
        text = text .. e.delta.text
        local snapshot = text
        vim.schedule(function()
          opts.on_text(snapshot)
        end)
      elseif e.type == "message_start" and opts.on_start_usage and e.message and e.message.usage then
        local u = e.message.usage
        vim.schedule(function()
          opts.on_start_usage(u)
        end)
      end
    elseif ev.type == "result" then
      result = ev
    end
  end

  local ok, proc = pcall(vim.system, args, {
    cwd = workdir(),
    stdin = opts.prompt,
    text = true,
    stdout = function(_, data)
      if not data then
        return
      end
      pending = pending .. data
      while true do
        local nl = pending:find("\n", 1, true)
        if not nl then
          break
        end
        handle(pending:sub(1, nl - 1))
        pending = pending:sub(nl + 1)
      end
    end,
    stderr = function(_, data)
      if data then
        stderr = stderr .. data
      end
    end,
  }, function(obj)
    vim.schedule(function()
      if pending ~= "" then
        handle(pending)
      end
      if result and result.subtype == "success" and not result.is_error then
        -- `result.result` holds only the last message; with tools the answer
        -- may be spread over several, so prefer everything streamed.
        opts.on_done({ text = text ~= "" and text or result.result or "", usage = result.usage or {}, cost = result.total_cost_usd })
      else
        local msg = (result and (result.result or table.concat(result.errors or {}, "; ")))
          or vim.trim(stderr)
        if msg == "" then
          msg = "claude exited with code " .. tostring(obj.code)
        end
        opts.on_error(msg, text ~= "")
      end
    end)
  end)
  if not ok then
    vim.schedule(function()
      opts.on_error(tostring(proc), false)
    end)
    return { kill = function() end }
  end
  return {
    kill = function()
      proc:kill(15)
    end,
  }
end

return M

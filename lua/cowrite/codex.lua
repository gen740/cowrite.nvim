-- Codex app-server over newline-delimited JSON-RPC on stdio.
local M = { id = "codex", config = { cmd = "codex" }, models = {}, efforts = { "low", "medium", "high", "xhigh" } }
M.tool_groups = { web = true, read = true, shell = true }
function M.model()
  return require("cowrite.state").get("codex_model") or M.config.model
end
function M.effort()
  return require("cowrite.state").get("codex_effort") or M.config.effort
end

local function run(opts)
  local proc, closed, seq = nil, false, 0
  local pending, stderr, text = "", "", ""
  local callbacks, messages, order = {}, {}, {}
  local usage, thread_id = {}, opts.backend_session_id
  local phase, timeout = "app-server startup"
  local allow = {}
  for _, name in ipairs(opts.allow or {}) do allow[name] = true end
  local function finish(err, result)
    if closed then return end
    closed = true
    if timeout then
      timeout:stop()
      timeout:close()
    end
    if proc then proc:kill(15) end
    if err then
      local message = err == "cancelled" and err or ("Codex %s failed (%s)"):format(phase, err)
      opts.on_error(message, text ~= "", err)
    else
      opts.on_done(result or { text = text, usage = usage, session_id = thread_id })
    end
  end
  local function send(value)
    if not closed then proc:write(vim.json.encode(value) .. "\n") end
  end
  local function request(method, params, callback)
    phase = method
    seq = seq + 1
    callbacks[seq] = callback or function() end
    send({ id = seq, method = method, params = params })
  end
  local function publish(id, value, append)
    if not messages[id] then order[#order + 1] = id end
    messages[id] = append and ((messages[id] or "") .. value) or value
    local parts = {}
    for _, key in ipairs(order) do parts[#parts + 1] = messages[key] end
    text = table.concat(parts, "\n")
    opts.on_text(text)
  end
  local function handle(line)
    if closed then return end
    local ok, ev = pcall(vim.json.decode, line)
    if not ok or type(ev) ~= "table" then return end
    if ev.id ~= nil and ev.method then
      -- Never grant extra filesystem/network permissions or interactive tool input.
      if ev.method == "item/commandExecution/requestApproval" or ev.method == "item/fileChange/requestApproval" then
        send({ id = ev.id, result = { decision = "decline" } })
      else
        send({ id = ev.id, error = { code = -32601, message = "Unsupported client request" } })
      end
      return
    end
    if ev.id ~= nil then
      local callback = callbacks[ev.id]
      callbacks[ev.id] = nil
      if ev.error then finish(ev.error.message or "Codex request failed")
      elseif callback then callback(ev.result) end
      return
    end
    local p = ev.params or {}
    if ev.method == "item/agentMessage/delta" then
      publish(p.itemId, p.delta, true)
    elseif ev.method == "item/completed" and p.item and p.item.type == "agentMessage" then
      publish(p.item.id, p.item.text or "", false)
    elseif ev.method == "item/started" and p.item and opts.on_tool then
      local kind = p.item.type
      if kind ~= "agentMessage" and kind ~= "reasoning" and kind ~= "userMessage" then opts.on_tool(kind) end
    elseif ev.method == "thread/tokenUsage/updated" then
      local u = p.tokenUsage.last
      usage = { input_tokens = math.max(0, u.inputTokens - u.cachedInputTokens), cache_read_input_tokens = u.cachedInputTokens, output_tokens = u.outputTokens }
    elseif ev.method == "turn/completed" then
      local turn = p.turn or {}
      finish(turn.status ~= "completed" and ((turn.error and turn.error.message) or "Codex turn " .. tostring(turn.status)) or nil)
    end
  end
  local cwd = vim.fs.joinpath(vim.fn.stdpath("data"), "cowrite", "codex")
  local ok, result = pcall(function()
    vim.fn.mkdir(cwd, "p")
    return vim.system({ M.config.cmd, "app-server" }, {
      cwd = cwd, stdin = true, text = true,
      stdout = function(_, data)
        if not data then return end
        vim.schedule(function()
          pending = pending .. data
          while true do
            local nl = pending:find("\n", 1, true)
            if not nl then break end
            local line = pending:sub(1, nl - 1)
            pending = pending:sub(nl + 1)
            handle(line)
          end
        end)
      end,
      stderr = function(_, data) if data then stderr = stderr .. data end end,
    }, function(obj)
      vim.schedule(function()
        if pending ~= "" then handle(pending); pending = "" end
        if not closed then finish(vim.trim(stderr) ~= "" and vim.trim(stderr) or "codex exited with code " .. obj.code) end
      end)
    end)
  end)
  if not ok then
    vim.schedule(function() finish(tostring(result)) end)
  else
    proc = result
    if opts.check or opts.list_models then
      timeout = assert(vim.uv.new_timer())
      timeout:start(10000, 0, vim.schedule_wrap(function()
        finish("request timed out")
      end))
    end
    request("initialize", { clientInfo = { name = "cowrite_nvim", version = "0.1.0" } }, function()
      send({ method = "initialized", params = {} })
      if opts.list_models then
        local models, seen, cursors = {}, {}, {}
        local function list_page(cursor)
          request("model/list", { cursor = cursor, includeHidden = false }, function(page)
            for _, entry in ipairs(page.data) do
              local model = entry.model
              if not entry.hidden and not seen[model] then
                seen[model] = true
                table.insert(models, model)
              end
            end
            local next_cursor = page.nextCursor
            if type(next_cursor) ~= "string" or next_cursor == "" then
              finish(nil, models)
            elseif cursors[next_cursor] then
              finish("repeated pagination cursor")
            else
              cursors[next_cursor] = true
              list_page(next_cursor)
            end
          end)
        end
        list_page()
        return
      end
      local params = {
        cwd = (allow.read or allow.shell) and opts.add_dir or cwd,
        model = M.model(), approvalPolicy = "on-request", sandbox = "read-only",
        ephemeral = opts.check,
        developerInstructions = opts.system_prompt or require("cowrite.claude").system_prompt(),
        config = {
          ["features.shell_tool"] = allow.read == true or allow.shell == true,
          ["features.apply_patch_freeform"] = false,
          web_search = allow.web and "live" or "disabled",
        },
      }
      request("config/read", { cwd = params.cwd, includeLayers = false }, function(settings)
        -- Disable configured MCP servers: document opt-ins cover built-in tools only.
        local mcp_servers = {}
        for name in pairs((settings.config or {}).mcp_servers or {}) do
          mcp_servers[name] = { enabled = false }
        end
        if next(mcp_servers) then params.config.mcp_servers = mcp_servers end
        if opts.resume and thread_id then params.threadId = thread_id end
        request(params.threadId and "thread/resume" or "thread/start", params, function(res)
          thread_id = res.thread.id
          if opts.check then
            request("account/read", { refreshToken = false }, function(account)
              finish(nil, account)
            end)
            return
          end
          request("turn/start", {
            threadId = thread_id, effort = M.effort(),
            input = { { type = "text", text = opts.prompt, text_elements = {} } },
          }, function()
            phase = "turn"
          end)
        end)
      end)
    end)
  end
  return { kill = function() finish("cancelled") end }
end

M.run = run

function M.check(on_done, on_error)
  run({ check = true, on_done = on_done, on_error = on_error })
end

function M.list_models(on_done, on_error)
  run({
    list_models = true,
    on_done = function(models)
      M.models = models
      on_done(models)
    end,
    on_error = on_error,
  })
end

return M

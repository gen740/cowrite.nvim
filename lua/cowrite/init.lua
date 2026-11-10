local M = {}

local function notify(msg, level)
  vim.notify("cowrite: " .. msg, level or vim.log.levels.INFO)
end

local function usage_report()
  local session = require("cowrite.session")
  local sess = session.load(session.id_of(vim.api.nvim_get_current_buf()))
  if not sess or not sess.total then
    notify("no usage yet for this buffer")
    return
  end
  local claude = require("cowrite.backend").current()
  local lines = {
    ("session %s · %d turn(s) · model %s · effort %s"):format(
      sess.id or "(none)",
      sess.turns or 0,
      claude.model() or "default",
      claude.effort() or "default"
    ),
    "last:  " .. session.format_usage(sess.last),
    "total: " .. session.format_usage(sess.total),
  }
  if sess.cost then
    table.insert(lines, ("cost:  last ≈$%.4f · session ≈$%.4f (list price)"):format(sess.last_cost or 0, sess.cost))
  end
  notify(table.concat(lines, "\n"))
end

--- :Cowrite model / :Cowrite effort. With an argument set it directly,
--- otherwise pick from a list. "default" defers to setup() / Claude Code.
local function chooser(key, what, choices)
  return {
    run = function(args)
      local state = require("cowrite.state")
      local function set(v)
        state.set(require("cowrite.backend").key(key), (v ~= "default") and v or nil)
        local claude = require("cowrite.backend").current()
        local now = claude[key]() or "backend default"
        notify(what .. ": " .. now .. (key == "model" and " (a model switch starts a fresh prompt cache)" or ""))
      end
      if args[1] then
        set(args[1])
        return
      end
      choices = require("cowrite.backend").current()[key == "model" and "models" or "efforts"]
      local items = vim.list_extend({ "default" }, choices)
      if key == "model" then
        table.insert(items, "other…")
      end
      local current = state.get(require("cowrite.backend").key(key)) or "default"
      vim.ui.select(items, {
        prompt = "cowrite: " .. what,
        format_item = function(i)
          return i == current and (i .. " [current]") or i
        end,
      }, function(choice)
        if not choice then
          return
        end
        vim.schedule(function()
          if choice == "other…" then
            vim.ui.input({ prompt = "cowrite: model name: " }, function(name)
              if name and vim.trim(name) ~= "" then
                set(vim.trim(name))
              end
            end)
          else
            set(choice)
          end
        end)
      end)
    end,
    complete = vim.list_extend({ "default" }, choices),
  }
end

local subcommands = {
  model = chooser("model", "model", require("cowrite.claude").models),
  effort = chooser("effort", "effort", require("cowrite.claude").efforts),
  system = {
    run = function()
      local claude = require("cowrite.claude")
      local path = claude.system_file()
      if path == claude.bundled_system_file then
        -- Never edit the bundled file; start the user's copy from it.
        path = claude.user_system_file
        vim.fn.mkdir(vim.fs.dirname(path), "p")
        vim.uv.fs_copyfile(claude.bundled_system_file, path)
        notify("created " .. path .. " from the default; it now overrides the bundled prompt")
      end
      vim.cmd.edit(vim.fn.fnameescape(path))
      notify("changes apply to new sessions (run :Cowrite reset in a document to pick them up)")
    end,
  },
  dismiss = {
    run = function()
      require("cowrite.notes").clear(vim.api.nvim_get_current_buf())
    end,
  },
  auth = {
    run = function(args)
      local auth = require("cowrite.auth")
      local action = args[1] or "select"
      if action == "select" then
        auth.select()
      elseif action == "status" then
        auth.status()
      elseif action == "logout" then
        auth.logout()
      else
        notify("unknown auth action: " .. action, vim.log.levels.ERROR)
      end
    end,
    complete = { "select", "status", "logout" },
  },
  generate = {
    run = function()
      require("cowrite.generate").generate(0)
    end,
  },
  cancel = {
    run = function()
      require("cowrite.generate").cancel(0)
    end,
  },
  usage = { run = usage_report },
  reset = {
    run = function()
      require("cowrite.generate").reset(0)
    end,
  },
}

--- Open a `@ai ` line below the paragraph under the cursor, in Insert mode.
function M.instruct()
  local bufnr = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local n = vim.api.nvim_buf_line_count(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if lines[row]:match("%S") then
    -- Skip to the paragraph's last line, past any instructions already there.
    while row < n and lines[row + 1]:match("%S") do
      row = row + 1
    end
  end
  vim.api.nvim_buf_set_lines(bufnr, row, row, false, { "@ai " })
  vim.api.nvim_win_set_cursor(0, { row + 1, 4 })
  vim.cmd("startinsert!")
end

---@param opts {cmd?: string, model?: string, effort?: string, system_prompt_file?: string, dismiss_key?: string|false}|nil
function M.setup(opts)
  local cfg = require("cowrite.claude").config
  for k, v in pairs(opts or {}) do
    if k == "codex" then
      for ck, cv in pairs(v) do require("cowrite.codex").config[ck] = cv end
    else
      cfg[k] = v
    end
  end
end

--- For your statusline, e.g. `vim.o.statusline = "%f %= %{v:lua.require'cowrite'.statusline()}"`.
function M.statusline()
  local bufnr = vim.api.nvim_get_current_buf()
  local running = package.loaded["cowrite.generate"] and require("cowrite.generate").running[bufnr]
  if running then
    return "cowrite: " .. (running.status or "…")
  end
  local session = require("cowrite.session")
  local sess = session.load(session.id_of(bufnr))
  if not sess or not sess.total then
    return ""
  end
  local t = sess.total
  local input = t.input + t.cache_read + t.cache_write
  local s = ("cowrite: %.1fk in (%d%% cached) %.1fk out"):format(
    input / 1000,
    input > 0 and math.floor(t.cache_read / input * 100 + 0.5) or 0,
    t.output / 1000
  )
  if sess.cost then
    s = s .. (" ≈$%.3f"):format(sess.cost)
  end
  return s
end

function M.command(fargs)
  local name = fargs[1]
  if not name then
    notify("usage: :Cowrite {generate|cancel|dismiss|usage|reset|model|effort|system|auth}")
    return
  end
  local sub = subcommands[name]
  if not sub then
    notify("unknown subcommand: " .. name, vim.log.levels.ERROR)
    return
  end
  sub.run(vim.list_slice(fargs, 2))
end

function M.complete(arglead, cmdline)
  local words = vim.split(cmdline, "%s+", { trimempty = true })
  -- Count the word being typed (empty when the cursor follows a space).
  local nwords = #words + (cmdline:match("%s$") and 1 or 0)
  local candidates
  if nwords <= 2 then
    candidates = vim.tbl_keys(subcommands)
  elseif nwords == 3 and subcommands[words[2]] then
    candidates = vim.list_slice(subcommands[words[2]].complete or {})
  else
    return {}
  end
  table.sort(candidates)
  return vim.tbl_filter(function(c)
    return vim.startswith(c, arglead)
  end, candidates)
end

return M

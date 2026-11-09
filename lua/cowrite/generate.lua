local doc = require("cowrite.doc")
local session = require("cowrite.session")
local claude = require("cowrite.claude")
local lock = require("cowrite.lock")
local notes = require("cowrite.notes")

local M = {}

---@type table<integer, {job: {kill: fun()}|nil, status: string, cancelled: boolean|nil}>
M.running = {}

local function notify(msg, level)
  vim.notify("cowrite: " .. msg, level or vim.log.levels.INFO)
end

local function buf_lines(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

--- `<name ...>…</name>` blocks in order, with their id attribute (0 when
--- absent). The last block may still be open while streaming.
---@return {id: integer, body: string, closed: boolean}[]
local function parse_blocks(text, name)
  local out, pos = {}, 1
  while true do
    local s, e, attrs = text:find("<" .. name .. "([^>]*)>", pos)
    if not s then
      break
    end
    if attrs == "" or attrs:match("^%s") then
      local id = tonumber(attrs:match('id="(%d+)"') or "0")
      local bs = e + 1
      if text:sub(bs, bs) == "\n" then
        bs = bs + 1
      end
      local close = text:find("</" .. name .. ">", bs, true)
      if close then
        table.insert(out, { id = id, body = (text:sub(bs, close - 1):gsub("\n$", "")), closed = true })
        pos = close + #name + 3
      else
        -- Drop a half-streamed tag and the trailing newline.
        local body = text:sub(bs):gsub("<[^>\n]*$", ""):gsub("\n$", "")
        table.insert(out, { id = id, body = body, closed = false })
        break
      end
    else
      pos = e + 1
    end
  end
  return out
end

local function by_id(blocks)
  local t = {}
  for _, b in ipairs(blocks) do
    t[b.id] = b
  end
  return t
end

local function rtrim(s)
  return (s:gsub("%s+$", ""))
end

--- 1-based start of `needle` in `lines`, nearest to `near`; `ok(s, e)` may veto.
local function find_block(lines, needle, near, ok)
  local best, bestd
  for i = 1, #lines - #needle + 1 do
    local match = true
    for j = 1, #needle do
      if rtrim(lines[i + j - 1]) ~= rtrim(needle[j]) then
        match = false
        break
      end
    end
    if match and (not ok or ok(i, i + #needle - 1)) then
      local d = math.abs(i - near)
      if not bestd or d < bestd then
        best, bestd = i, d
      end
    end
  end
  return best
end

---------------------------------------------------------------------------
-- Turns
---------------------------------------------------------------------------

local function add_usage(sess, usage, cost)
  local u = {
    input = usage.input_tokens or 0,
    cache_read = usage.cache_read_input_tokens or 0,
    cache_write = usage.cache_creation_input_tokens or 0,
    output = usage.output_tokens or 0,
  }
  sess.total = sess.total or session.empty_usage()
  for k, v in pairs(u) do
    sess.total[k] = (sess.total[k] or 0) + v
  end
  sess.last = u
  sess.turns = (sess.turns or 0) + 1
  if cost then
    -- Claude Code reports the session's cumulative cost.
    sess.last_cost = sess.cost and math.max(cost - sess.cost, 0) or cost
    sess.cost = cost
  end
end

local function report(sess)
  local msg = "done · " .. session.format_usage(sess.last)
  if sess.last_cost then
    msg = msg .. (" · ≈$%.4f (session ≈$%.4f)"):format(sess.last_cost, sess.cost)
  end
  notify(msg)
end

--- Run one turn in session `opts.session_id`. When starting or resuming it
--- fails before any output (deleted, or the id is taken), retry once in a new
--- session; `opts.set_session_id` records the new id.
local function run_turn(bufnr, opts)
  local sess = session.load(opts.session_id)
  local fresh = sess == nil
  if fresh then
    sess = { id = opts.session_id }
  end
  local state = M.running[bufnr] or {}
  state.status = "starting…"
  M.running[bufnr] = state

  state.job = claude.run({
    prompt = opts.build_prompt(sess, fresh),
    session_id = sess.id,
    resume = not fresh,
    on_start_usage = function(u)
      local input = (u.input_tokens or 0) + (u.cache_read_input_tokens or 0) + (u.cache_creation_input_tokens or 0)
      local pct = input > 0 and math.floor((u.cache_read_input_tokens or 0) / input * 100 + 0.5) or 0
      state.status = ("thinking · in %.1fk, %d%% cached"):format(input / 1000, pct)
      opts.on_status(state.status)
    end,
    on_text = opts.on_text,
    allow = opts.allow,
    add_dir = opts.add_dir,
    on_tool = function(name)
      state.status = "using " .. name .. "…"
      opts.on_status(state.status)
    end,
    on_done = function(res)
      add_usage(sess, res.usage, res.cost)
      local ok, snapshot = pcall(opts.finish, res.text)
      if not ok then
        notify("failed to apply result: " .. tostring(snapshot), vim.log.levels.ERROR)
      else
        sess.snapshot = snapshot
      end
      session.save(sess)
      M.running[bufnr] = nil
      opts.cleanup(true)
      report(sess)
    end,
    on_error = function(msg, got_output)
      if not got_output and not state.cancelled and not opts.retried then
        notify(
          ("could not %s session (%s); starting a new one"):format(fresh and "start" or "resume", msg),
          vim.log.levels.WARN
        )
        opts.retried = true
        opts.session_id = session.new_id()
        opts.set_session_id(opts.session_id)
        run_turn(bufnr, opts)
        return
      end
      M.running[bufnr] = nil
      opts.cleanup(false)
      notify(state.cancelled and "cancelled" or msg, not state.cancelled and vim.log.levels.ERROR or nil)
    end,
  })
end

--- Write `id` into the buffer's front matter as `cowrite.session`.
local function write_session_id(bufnr, id)
  local lines = buf_lines(bufnr)
  if doc.session_id(lines) == id then
    return
  end
  local header, replaced = doc.header_with_session(lines, id)
  lock.set_lines(bufnr, 0, replaced, header)
end

--- Shared driver. `mode.stream(text, status, final)` pushes (partial) output
--- into the buffer; `mode.finish(text)` returns the new snapshot;
--- `mode.abort()` undoes unfinished work.
local function drive(bufnr, mode)
  lock.guard(bufnr)
  local status, latest, scheduled, closed = "starting…", "", false, false
  local function flush()
    if not closed then
      mode.stream(latest, status, false)
    end
  end
  flush()

  run_turn(bufnr, {
    session_id = mode.session_id,
    set_session_id = mode.set_session_id,
    allow = mode.allow,
    add_dir = mode.add_dir,
    build_prompt = mode.build_prompt,
    on_status = function(s)
      status = s
      flush()
    end,
    on_text = function(text)
      latest = text
      if not scheduled then
        scheduled = true
        vim.defer_fn(function()
          scheduled = false
          flush()
        end, 30)
      end
    end,
    finish = function(text)
      latest = text
      mode.stream(text, status, true)
      return mode.finish(text)
    end,
    cleanup = function(ok)
      closed = true
      if not ok then
        mode.abort()
      end
      lock.unguard(bufnr)
      notes.enable_dismiss(bufnr)
    end,
  })
end

local DISMISS = " · q to dismiss"

local function start_new(bufnr, what)
  local sid = session.new_id()
  local n = vim.api.nvim_buf_line_count(bufnr)
  local L = lock.new(bufnr, "document", 0, n - 1)
  local note = notes.place(bufnr, n - 1, false)

  drive(bufnr, {
    session_id = sid,
    set_session_id = function(id)
      sid = id -- the header is written once the draft exists
    end,
    build_prompt = function()
      return "<new>\n" .. what .. "\n</new>"
    end,
    stream = function(text, status, final)
      local d = parse_blocks(text, "document")[1]
      local th = by_id(parse_blocks(text, "think"))[0]
      if d and L:active() then
        if not L:intact() and not L:enforce() then
          L:abandon("its text disappeared")
        else
          local lines = doc.split(d.body)
          if d.closed then
            if not vim.deep_equal(lines, L.expected) then
              L:write(lines, false)
            end
            L:release("done")
          elseif #lines > 0 and not vim.deep_equal(lines, L.expected) then
            L:write(lines, true)
          end
        end
      end
      local body = th and th.body
      if final or L.state == "done" then
        -- Park the notes under the front matter, near the top.
        local _, fe = doc.frontmatter(buf_lines(bufnr))
        notes.update(bufnr, note, body, (L.state == "done" and "✓ draft written" or "⚠ no draft") .. DISMISS, (fe or 1) - 1)
      else
        local _, e = L:range()
        notes.update(bufnr, note, body, d and "writing…" or (th and "thinking…" or status), e)
      end
    end,
    finish = function(text)
      local d = parse_blocks(text, "document")[1]
      if not d or not d.closed then
        error("response had no <document>")
      end
      if vim.bo[bufnr].filetype == "" then
        vim.bo[bufnr].filetype = "markdown"
      end
      write_session_id(bufnr, sid)
      return d.body
    end,
    abort = function()
      L:restore()
    end,
  })
end

local function start_edit(bufnr, lines, instrs, sid, allow)
  local annotated = doc.annotate(lines, instrs)

  ---@type table<integer, {ins: cowrite.Instruction, lock: cowrite.Lock, note: integer, edits: table[], finalized: boolean}>
  local I = {}
  for _, ins in ipairs(instrs) do
    I[ins.id] = {
      ins = ins,
      lock = lock.new(bufnr, "instruction " .. ins.id, ins.first - 1, ins.last - 1),
      -- Notes sit just above the instruction: between it and its paragraph.
      -- Once the instruction lines are removed they stay at that spot.
      note = notes.place(bufnr, ins.first - 1, true),
      edits = {},
      finalized = false,
    }
  end

  local function process_edit(st, E, b)
    if E.state == "done" or E.state == "failed" then
      return
    end
    local old = parse_blocks(b.body, "old")[1]
    local new = parse_blocks(b.body, "new")[1]
    if E.state == "pending" then
      if not (old and old.closed) then
        return
      end
      local label = ("instruction %d, edit %d"):format(st.ins.id, E.k)
      local old_lines = doc.split(old.body)
      local at = st.lock:range()
      if #old_lines == 0 then
        if not at then
          E.state, E.reason = "failed", "instruction was removed"
          return
        end
        E.lock = lock.new_insert(bufnr, label, at)
      else
        local i = find_block(buf_lines(bufnr), old_lines, (at or 0) + 1, function(s, e)
          return lock.is_free(bufnr, s - 1, e - 1)
        end)
        if not i then
          E.state, E.reason = "failed", "text to replace not found"
          return
        end
        E.lock = lock.new(bufnr, label, i - 1, i + #old_lines - 2)
      end
      E.state = "writing"
    end
    -- E.state == "writing"
    if not E.lock:active() then
      E.state, E.reason = "failed", E.lock.reason or "released"
      return
    end
    if not E.lock:intact() and not E.lock:enforce() then
      E.state, E.reason = "failed", "the text disappeared"
      return
    end
    if new then
      local nl = doc.split(new.body)
      if new.closed then
        if not vim.deep_equal(nl, E.lock.expected) then
          E.lock:write(nl, false)
        end
        E.lock:release("done")
        E.state = "done"
        return
      elseif #nl > 0 and not vim.deep_equal(nl, E.lock.expected) then
        E.lock:write(nl, true)
      end
    end
    if b.closed then
      E.lock:restore()
      E.lock:release()
      E.state, E.reason = "failed", "malformed edit"
    end
  end

  local function finalize(st, aborted, think)
    st.finalized = true
    local done, failed = 0, {}
    for _, E in ipairs(st.edits) do
      if E.state == "writing" then
        E.lock:restore()
        E.lock:release()
        E.state, E.reason = "failed", aborted and "cancelled" or "incomplete"
      end
      if E.state == "done" then
        done = done + 1
      elseif E.state == "failed" then
        table.insert(failed, E.reason)
      end
    end
    if done > 0 and not aborted and st.lock:intact() then
      local s, e = st.lock:range()
      lock.set_lines(bufnr, s, e + 1, {})
    end
    st.lock:release()
    local header
    if done > 0 then
      header = ("✓ %d edit%s"):format(done, done > 1 and "s" or "")
    elseif #failed == 0 then
      header = aborted and "cancelled" or "no edits (see notes)"
    else
      header = "⚠ nothing applied"
    end
    if #failed > 0 then
      header = header .. (" · %d skipped: %s"):format(#failed, table.concat(failed, ", "))
    end
    notes.update(bufnr, st.note, think, header .. DISMISS)
  end

  local function stream(text, status, final)
    local thinks = by_id(parse_blocks(text, "think"))
    local eblocks = parse_blocks(text, "edit")
    local max_id = 0
    for _, b in ipairs(eblocks) do
      max_id = math.max(max_id, b.id)
    end
    for id in pairs(thinks) do
      max_id = math.max(max_id, id)
    end

    local count = {}
    for _, b in ipairs(eblocks) do
      local st = I[b.id]
      if st and not st.finalized then
        count[b.id] = (count[b.id] or 0) + 1
        local k = count[b.id]
        st.edits[k] = st.edits[k] or { k = k, state = "pending" }
        process_edit(st, st.edits[k], b)
      end
    end

    local first_waiting = true
    for _, ins in ipairs(instrs) do
      local st = I[ins.id]
      local th = thinks[ins.id]
      if not st.finalized then
        if final or ins.id < max_id then
          finalize(st, false, th and th.body)
        else
          local writing = false
          for _, E in ipairs(st.edits) do
            writing = writing or E.state == "writing"
          end
          local header = writing and "writing…"
            or (th and "thinking…")
            or (first_waiting and status)
            or "waiting…"
          notes.update(bufnr, st.note, th and th.body, header)
          first_waiting = false
        end
      end
    end
  end

  local latest_thinks = {}
  local name = vim.api.nvim_buf_get_name(bufnr)
  drive(bufnr, {
    session_id = sid,
    allow = allow,
    add_dir = name ~= "" and vim.fs.dirname(vim.fn.fnamemodify(name, ":p")) or nil,
    set_session_id = function(id)
      sid = id
      write_session_id(bufnr, id)
    end,
    build_prompt = function(sess, fresh)
      local current = table.concat(annotated, "\n")
      local ids = vim.tbl_map(function(i)
        return "[" .. i.id .. "]"
      end, instrs)
      local head = "Instructions to handle: " .. table.concat(ids, " ") .. "\n"
      if not fresh and sess.snapshot then
        local d = doc.diff(sess.snapshot, current)
        if #d < #current then
          return head .. "<diff>\n" .. d .. "</diff>"
        end
      end
      return head .. "<document>\n" .. current .. "\n</document>"
    end,
    stream = function(text, status, final)
      latest_thinks = by_id(parse_blocks(text, "think"))
      stream(text, status, final)
    end,
    finish = function(text)
      local header = parse_blocks(text, "header")[1]
      if header and header.closed then
        local cur = buf_lines(bufnr)
        local fs, fe = doc.frontmatter(cur)
        lock.set_lines(bufnr, fs and fs - 1 or 0, fe or 0, doc.split(header.body))
        write_session_id(bufnr, sid) -- in case the new header dropped it
        notify("the AI updated the front matter (rules); `u` to undo", vim.log.levels.WARN)
      end

      -- What the model now believes the document is: what it was sent, with
      -- all of its edits applied. The next turn diffs reality against this.
      local belief = vim.list_slice(annotated)
      local grouped = {}
      for _, b in ipairs(parse_blocks(text, "edit")) do
        grouped[b.id] = grouped[b.id] or {}
        table.insert(grouped[b.id], b)
      end
      for _, ins in ipairs(instrs) do
        local tag = "^<<< %[" .. ins.id .. "%]"
        local applied = 0
        for _, b in ipairs(grouped[ins.id] or {}) do
          local old = parse_blocks(b.body, "old")[1]
          local new = parse_blocks(b.body, "new")[1]
          if old and old.closed and new and new.closed then
            local at
            for i, l in ipairs(belief) do
              if l:match(tag) then
                at = i
                break
              end
            end
            local old_lines, new_lines = doc.split(old.body), doc.split(new.body)
            local i = #old_lines == 0 and at or find_block(belief, old_lines, at or 1)
            if i then
              for _ = 1, #old_lines do
                table.remove(belief, i)
              end
              for j, l in ipairs(new_lines) do
                table.insert(belief, i + j - 1, l)
              end
              applied = applied + 1
            end
          end
        end
        if applied > 0 then
          for i = #belief, 1, -1 do
            if belief[i]:match(tag) then
              table.remove(belief, i)
            end
          end
        end
      end
      if header and header.closed then
        doc.replace_frontmatter(belief, doc.split(header.body))
      end
      return table.concat(belief, "\n")
    end,
    abort = function()
      for _, ins in ipairs(instrs) do
        local st = I[ins.id]
        if not st.finalized then
          local th = latest_thinks[ins.id]
          finalize(st, true, th and th.body)
        end
      end
    end,
  })
end

--- Tool groups from `cowrite.allow`. Shell access is confirmed once per
--- document session: a document from someone else must not be able to run
--- commands on your machine just by being opened and generated.
local function resolve_allow(bufnr, lines, sid)
  local state = require("cowrite.state")
  local out = {}
  for _, group in ipairs(doc.allow(lines)) do
    if not claude.tool_groups[group] then
      notify("unknown cowrite.allow entry `" .. group .. "` (use web, read, shell)", vim.log.levels.WARN)
    elseif group == "shell" then
      local approved = state.get("shell_approved") or {}
      if approved[sid] then
        table.insert(out, group)
      else
        local choice = vim.fn.confirm(
          ("cowrite: %s asks to let the AI run shell commands (cowrite.allow: shell).\nAllow for this document?"):format(
            vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":~:.")
          ),
          "&Yes\n&No",
          2
        )
        if choice == 1 then
          approved[sid] = true
          state.set("shell_approved", approved)
          table.insert(out, group)
        else
          notify("continuing without shell", vim.log.levels.WARN)
        end
      end
    else
      table.insert(out, group)
    end
  end
  return out
end

function M.generate(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local provider = require("cowrite.auth").current()
  if provider and provider.id ~= "claude-code" then
    notify(provider.label .. " is not implemented yet; choose Claude Code with :Cowrite auth", vim.log.levels.ERROR)
    return
  end
  if vim.fn.executable(claude.config.cmd) ~= 1 then
    notify("`" .. claude.config.cmd .. "` not found in PATH", vim.log.levels.ERROR)
    return
  end
  if M.running[bufnr] then
    notify("already generating in this buffer (:Cowrite cancel to stop)", vim.log.levels.WARN)
    return
  end

  local lines = buf_lines(bufnr)
  if doc.is_empty(lines) then
    -- Reserve the buffer while the user types, so a second generate can't race.
    M.running[bufnr] = { status = "waiting for input" }
    vim.ui.input({ prompt = "cowrite: What document do you want to write? " }, function(what)
      vim.schedule(function()
        M.running[bufnr] = nil
        if what and vim.trim(what) ~= "" then
          vim.b[bufnr].cowrite = true
          notes.clear(bufnr)
          start_new(bufnr, what)
        end
      end)
    end)
    return
  end

  if #doc.instructions(lines) == 0 then
    notify("no instructions. Add a line like `<<< make this paragraph shorter` below the text.")
    return
  end
  local sid = doc.session_id(lines)
  if not sid then
    sid = session.new_id()
    write_session_id(bufnr, sid)
    lines = buf_lines(bufnr)
  end
  vim.b[bufnr].cowrite = true
  notes.clear(bufnr)
  start_edit(bufnr, lines, doc.instructions(lines), sid, resolve_allow(bufnr, lines, sid))
end

--- Start a new session for this document on the next generate.
function M.reset(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  if M.running[bufnr] then
    notify("generating; :Cowrite cancel first", vim.log.levels.WARN)
    return
  end
  if not doc.session_id(buf_lines(bufnr)) then
    notify("this document has no session yet")
    return
  end
  write_session_id(bufnr, session.new_id())
  notify("new session id written to the front matter; the next generate starts fresh")
end

function M.cancel(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  local r = M.running[bufnr]
  if not r or not r.job then
    notify("nothing is running")
    return
  end
  r.cancelled = true
  r.job.kill()
end

return M

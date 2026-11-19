vim.opt.rtp:prepend('.')
local codex = require('cowrite.codex')
local real_system = vim.system
local sent, stopped, output, done, failure
local fail_at
local spawned, turns = 0, 0
vim.system = function(_, config, on_exit)
  spawned = spawned + 1
  local previous_turn
  local function emit(value)
    local line = vim.json.encode(value) .. '\n'
    config.stdout(nil, line:sub(1, 7))
    config.stdout(nil, line:sub(8))
  end
  return {
    kill = function() stopped = true end,
    write = function(_, line)
      local req = vim.json.decode(line)
      sent[#sent + 1] = req
      if fail_at and req.method == fail_at then
        emit({ id = req.id, error = { message = 'invalid MCP transport' } })
        return
      end
      if req.method == 'initialize' then emit({id=req.id,result={}})
      elseif req.method == 'config/read' then
        emit({ id = req.id, result = { config = { mcp_servers = { node_repl = {}, ['other.server'] = {} } } } })
      elseif req.method == 'thread/start' or req.method == 'thread/resume' then
        emit({id=req.id,result={thread={id='thread-test'}}})
      elseif req.method == 'account/read' then
        emit({ id = req.id, result = { account = vim.NIL, requiresOpenaiAuth = true } })
      elseif req.method == 'model/list' then
        assert(req.params.includeHidden == false)
        local data, cursor
        if req.params.cursor == 'next' then
          data = { { model = 'codex-first' }, { model = 'codex-second' } }
          cursor = vim.NIL
        else
          assert(req.params.cursor == nil)
          data = { { id = 'catalog-id', model = 'codex-first' }, { model = 'hidden-model', hidden = true } }
          cursor = 'next'
        end
        emit({ id = req.id, result = { data = data, nextCursor = cursor } })
      elseif req.method == 'turn/start' then
        turns = turns + 1
        local turn = 'turn-' .. turns
        if previous_turn then
          emit({method='item/agentMessage/delta',params={threadId='thread-test',turnId=previous_turn,itemId='stale',delta='stale'}})
        end
        previous_turn = turn
        emit({id=req.id,result={turn={id=turn}}})
        emit({method='item/agentMessage/delta',params={itemId='a',delta='<document>hello'}})
        emit({method='item/agentMessage/delta',params={itemId='a',delta='</document>'}})
        emit({method='item/completed',params={item={id='a',type='agentMessage',text='<document>hello</document>'}}})
        emit({method='thread/tokenUsage/updated',params={tokenUsage={last={inputTokens=100,cachedInputTokens=80,outputTokens=10}}}})
        emit({method='turn/completed',params={threadId='thread-test',turn={id=turn,status='completed'}}})
      end
    end,
  }
end
local function run(resume, allow)
  sent, stopped, output, done, failure = {}, false, nil, nil, nil
  local status
  codex.run({prompt='test',resume=resume,backend_session_id=resume and 'thread-test' or nil,allow=allow,
    on_status=function(value) status=value end,
    on_text=function(t) output=t end,on_done=function(r) done=r end,on_error=function(e) failure=e end})
  assert(vim.wait(1000,function() return done or failure end))
  assert(not failure, failure)
  assert(done.text=='<document>hello</document>' and output==done.text)
  assert(done.usage.input_tokens==20 and done.usage.cache_read_input_tokens==80)
  assert(done.session_id=='thread-test' and status=='thinking…')
end
run(false)
assert(spawned == 1 and not stopped and sent[4].method == 'thread/start')
assert(sent[4].params.sandbox == 'read-only' and not sent[4].params.config['features.shell_tool'])
run(true)
assert(spawned == 1 and not stopped and #sent == 1 and sent[1].method == 'turn/start')
run(true, { 'read' })
assert(spawned == 2 and stopped and sent[4].method == 'thread/resume')
assert(sent[4].params.config['features.shell_tool'])
sent, failure = {}, nil
local job=codex.run({prompt='cancel',resume=true,backend_session_id='thread-test',allow={'read'},
  on_text=function() end,on_done=function() error('completed after cancellation') end,on_error=function(e) failure=e end})
job.kill()
assert(failure=='cancelled' and spawned == 2 and #sent == 1)
vim.wait(20,function() return false end)

sent, stopped, done, failure = {}, false, nil, nil
codex.check(function(account) done = account end, function(err) failure = err end)
assert(vim.wait(1000, function() return done or failure end))
assert(not failure, failure)
assert(done.account == vim.NIL and done.requiresOpenaiAuth)
assert(stopped and #sent == 5 and sent[5].method == 'account/read')
assert(sent[4].params.ephemeral and sent[3].params.cwd == sent[4].params.cwd)
assert(vim.deep_equal(sent[4].params.config.mcp_servers, {
  node_repl = { enabled = false },
  ['other.server'] = { enabled = false },
}))

sent, stopped, done, failure, fail_at = {}, false, nil, nil, 'thread/start'
codex.check(function(account) done = account end, function(err) failure = err end)
assert(vim.wait(1000, function() return done or failure end))
assert(stopped and not done and #sent == 4)
assert(failure == 'Codex thread/start failed (invalid MCP transport)', failure)

vim.cmd('runtime plugin/cowrite.lua')
local state = require('cowrite.state')
local saved = { provider = 'codex', model = 'sonnet' }
state.get = function(key) return saved[key] end
state.set = function(key, value) saved[key] = value end
vim.notify = function() end
local menu
vim.ui.select = function(items, _, pick)
  menu = items
  pick('codex-second')
end
sent, stopped, fail_at = {}, false, nil
vim.cmd('Cowrite model')
assert(vim.wait(1000, function() return saved.codex_model == 'codex-second' end))
assert(saved.model == 'sonnet' and stopped and #sent == 4)
assert(vim.deep_equal(menu, { 'default', 'codex-first', 'codex-second', 'other…' }))
local complete = require('cowrite').complete
assert(vim.deep_equal(complete('codex-', 'Cowrite model codex-'), { 'codex-first', 'codex-second' }))
saved.provider = 'claude-code'
assert(vim.deep_equal(complete('son', 'Cowrite model son'), { 'sonnet' }))

saved.provider, fail_at, menu = 'codex', 'model/list', nil
vim.ui.select = function(items) menu = items end
vim.cmd('Cowrite model')
assert(vim.wait(1000, function() return menu end))
assert(vim.deep_equal(menu, { 'default', 'codex-second', 'other…' }))

run(false)
assert(not stopped)
vim.api.nvim_exec_autocmds('VimLeavePre', {})
assert(stopped, 'Neovim exit should stop the idle app-server')

vim.system=real_system
print('Codex protocol tests passed')

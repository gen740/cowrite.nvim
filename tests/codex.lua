vim.opt.rtp:prepend('.')
local codex = require('cowrite.codex')
local real_system = vim.system
local sent, stopped, output, done, failure
vim.system = function(_, config, on_exit)
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
      if req.method == 'initialize' then emit({id=req.id,result={}})
      elseif req.method == 'config/read' then emit({id=req.id,result={config={mcp_servers={example={}}}}})
      elseif req.method == 'thread/start' or req.method == 'thread/resume' then
        emit({id=req.id,result={thread={id='thread-test'}}})
      elseif req.method == 'turn/start' then
        emit({id=req.id,result={}})
        emit({method='item/agentMessage/delta',params={itemId='a',delta='<document>hello'}})
        emit({method='item/agentMessage/delta',params={itemId='a',delta='</document>'}})
        emit({method='item/completed',params={item={id='a',type='agentMessage',text='<document>hello</document>'}}})
        emit({method='thread/tokenUsage/updated',params={tokenUsage={last={inputTokens=100,cachedInputTokens=80,outputTokens=10}}}})
        emit({method='turn/completed',params={turn={status='completed'}}})
      end
    end,
  }
end
local function run(resume)
  sent, stopped, output, done, failure = {}, false, nil, nil, nil
  codex.run({prompt='test',resume=resume,backend_session_id=resume and 'thread-test' or nil,
    on_text=function(t) output=t end,on_done=function(r) done=r end,on_error=function(e) failure=e end})
  assert(vim.wait(1000,function() return done or failure end))
  assert(not failure, failure)
  assert(done.text=='<document>hello</document>' and output==done.text)
  assert(done.usage.input_tokens==20 and done.usage.cache_read_input_tokens==80)
  assert(done.session_id=='thread-test' and stopped)
  assert(sent[4].method==(resume and 'thread/resume' or 'thread/start'))
  assert(sent[4].params.sandbox=='read-only')
  assert(sent[4].params.config['features.shell_tool']==false)
end
run(false)
run(true)
sent, failure = {}, nil
local job=codex.run({prompt='cancel',on_text=function() end,on_done=function() error('completed after cancellation') end,on_error=function(e) failure=e end})
job.kill()
assert(failure=='cancelled')
vim.wait(20,function() return false end)
vim.system=real_system
print('Codex protocol tests passed')

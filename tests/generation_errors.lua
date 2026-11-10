vim.opt.rtp:prepend('.')
local errors = require('cowrite.errors')
assert(not errors.is_missing_session("API Error: safeguards flagged this message; reasoning_extraction"))
assert(not errors.is_missing_session('API Error: session not found'))
assert(not errors.is_missing_session('rate limit exceeded'))
assert(not errors.is_missing_session('connection failed'))
assert(errors.is_missing_session('No conversation found with session ID: abc'))
assert(errors.is_missing_session('thread abc not found'))
local backend = require('cowrite.claude')
backend.config.cmd = 'nvim'
require('cowrite.auth').current = function() return nil end
local session = require('cowrite.session')
session.load = function() return nil end
session.save = function() end
session.new_id = function() return 'new-id' end
local state = require('cowrite.state')
state.get = function() return nil end
state.set = function() end
vim.notify = function() end
local gen = require('cowrite.generate')
local function prepare()
  vim.cmd.enew({bang=true})
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf,0,-1,false,{'Paragraph','@ai improve'})
  vim.b[buf].cowrite_ai_approved = 'claude-code'
  return buf
end
for _, message in ipairs({'API Error: safeguards flagged this message: reasoning_extraction', 'connection failed', 'session abc not found'}) do
  local buf = prepare()
  local count = 0
  backend.run = function(opts)
    count = count + 1
    vim.schedule(function() opts.on_error(message,false) end)
    return {kill=function() end}
  end
  gen.generate(buf)
  assert(vim.wait(500,function() return not gen.running[buf] end))
  assert(count == (message == 'session abc not found' and 2 or 1), message)
  assert(#require('cowrite.doc').instructions(vim.api.nvim_buf_get_lines(buf,0,-1,false)) == 1)
end
for _, tag in ipairs({'note','think'}) do
  local buf = prepare()
  backend.run = function(opts)
    vim.schedule(function()
      local text = '<'..tag..' id="1">Please clarify the audience.</'..tag..'>'
      opts.on_text(text)
      opts.on_done({text=text,usage={}})
    end)
    return {kill=function() end}
  end
  gen.generate(buf)
  assert(vim.wait(500,function() return not gen.running[buf] end))
  local marks = vim.api.nvim_buf_get_extmarks(buf,require('cowrite.notes').ns,0,-1,{details=true})
  assert(vim.inspect(marks):find('Please clarify the audience.',1,true), tag)
end
local buf = prepare()
local saved
session.save = function(value) saved = vim.deepcopy(value) end
backend.run = function(opts)
  assert(opts.prompt:find('@ai [1] improve', 1, true))
  vim.schedule(function()
    local text = '<note id="1">Revised.</note>\n<edit id="1"><old>Paragraph</old><new>Revised paragraph</new></edit>'
    opts.on_text(text)
    opts.on_done({text=text,usage={}})
  end)
  return {kill=function() end}
end
gen.generate(buf)
assert(vim.wait(500,function() return not gen.running[buf] end))
local result = table.concat(vim.api.nvim_buf_get_lines(buf,0,-1,false), '\n')
assert(result:find('Revised paragraph', 1, true) and not result:find('@ai', 1, true), result)
assert(saved and saved.snapshot:find('Revised paragraph', 1, true))
assert(not saved.snapshot:find('@ai', 1, true), saved.snapshot)
print('Generation error, note, and instruction edit tests passed')

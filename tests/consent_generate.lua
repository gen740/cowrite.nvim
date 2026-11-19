vim.opt.rtp:prepend('.')
local generation = require('cowrite.generate')
local claude = require('cowrite.claude')
claude.config.cmd = 'nvim'
local dialog, calls = nil, {}
require('cowrite.auth').current = function() return nil end
require('cowrite.session').new_id = function() return 'test-review-id' end
require('cowrite.consent').open = function(opts)
  dialog = opts
  return { close = function() opts.on_cancel() end }
end
claude.run = function(opts)
  calls[#calls + 1] = opts
  return { kill = function() end }
end
vim.api.nvim_buf_set_lines(0, 0, -1, false, {'Document', '@ai revise'})
local buf = vim.api.nvim_get_current_buf()
generation.generate(buf)
assert(dialog and #calls == 0, vim.inspect({dialog=dialog,calls=calls,source=debug.getinfo(generation.generate).source,approved=vim.b[buf].cowrite_ai_approved}))
dialog.on_report({render = function() end})
assert(#calls == 1 and #calls[1].allow == 0 and not calls[1].resume)
assert(calls[1].system_prompt:find('risk reviewer', 1, true))
assert(calls[1].backend_session_id == nil)
generation.cancel(buf)
assert(not generation.running[buf])
assert(not vim.b[buf].cowrite_ai_approved)
generation.generate(buf)
vim.api.nvim_buf_set_lines(buf, 0, 1, false, {'Changed'})
dialog.on_approve()
assert(not vim.b[buf].cowrite_ai_approved and #calls == 1)
assert(not generation.running[buf])

local codex = require('cowrite.codex')
local state = require('cowrite.state')
local session = require('cowrite.session')
local approved = { ['old-session'] = true }
local provider, saved, allow, choice, prompts
codex.config.cmd = 'nvim'
require('cowrite.auth').current = function() return { id = provider, implemented = true } end
state.get = function(key) if key == 'shell_approved' then return vim.deepcopy(approved) end end
state.set = function(key, value) if key == 'shell_approved' then approved = value end end
session.load = function(id) if id == 'old-session' then return saved end end
session.new_id = function() return 'new-session' end
vim.fn.confirm = function(message)
  prompts = prompts + 1
  assert(message:find('Codex shell commands in a read-only sandbox', 1, true))
  return choice
end
local function capture(opts)
  allow = opts.allow
  return { kill = function() opts.on_error('cancelled', false) end }
end
claude.run, codex.run = capture, capture
local function generate_with_tools(groups)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    '---', 'cowrite:', '  session: old-session', '  allow: [' .. groups .. ']', '---',
    'Document', '@ai revise',
  })
  vim.b[buf].cowrite_ai_approved = provider
  prompts, allow = 0, nil
  generation.generate(buf)
  assert(allow)
  generation.cancel(buf)
end
provider, choice = 'codex', 2
generate_with_tools('read, shell, web')
assert(prompts == 1 and vim.deep_equal(allow, { 'web' }) and not approved['old-session:codex'])
choice = 1
generate_with_tools('read')
assert(prompts == 1 and vim.deep_equal(allow, { 'read' }) and approved['old-session:codex'])
generate_with_tools('shell')
assert(prompts == 0 and vim.deep_equal(allow, { 'shell' }))
saved = { provider = 'claude-code' }
generate_with_tools('read')
assert(prompts == 1 and approved['new-session:codex'])
assert(session.id_of(buf) == 'new-session')
provider = 'claude-code'
generate_with_tools('read')
assert(prompts == 0 and vim.deep_equal(allow, { 'read' }))

print('Generation consent tests passed')

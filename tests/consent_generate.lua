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
print('Generation consent tests passed')

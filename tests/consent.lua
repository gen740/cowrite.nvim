vim.opt.rtp:prepend('.')
local consent = require('cowrite.consent')
local approved, cancelled = 0, 0
local function open()
  return consent.open({
    on_approve = function() approved = approved + 1 end,
    on_cancel = function() cancelled = cancelled + 1 end,
    on_report = function() end,
  })
end
local ui = open()
assert(vim.api.nvim_win_get_config(0).row == 0)
ui.render('report')
ui.close(true)
ui.close(false)
assert(approved == 1 and cancelled == 0)
ui = open()
vim.api.nvim_win_close(0, true)
assert(approved == 1 and cancelled == 1)
ui = open()
ui.close(false)
assert(cancelled == 2)
print('Consent UI tests passed')

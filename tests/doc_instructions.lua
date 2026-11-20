vim.opt.rtp:prepend('.')
local doc = require('cowrite.doc')
for _, path in ipairs({'tutorial.md','tutorial.ja.md'}) do
  assert(#doc.instructions(vim.fn.readfile(path)) == 0, path)
end
local lines = {
  '@ai real', '```markdown', '@ai example', '```',
  '@ai real again', '~~~~', '@ai example', '~~~', '@ai still example',
  '~~~~', '  ```', '@ai example', '  ```', '@ai final',
}
local items = doc.instructions(lines)
assert(#items == 3)
assert(items[1].first == 1 and items[2].first == 5 and items[3].first == 14)
assert(#doc.instructions({'```', '@ai unclosed'}) == 0)
assert(#doc.instructions({'```lang`invalid', '@ai real'}) == 1)
assert(#doc.instructions({'<<<<<<< conflict', '@ai one', '@ai two'}) == 1)
for _, line in ipairs({'@ai', '@ai revise', '@ai\trevise'}) do
  assert(doc.is_instruction(line), line)
end
for _, line in ipairs({'@aid revise', '@ai: revise', ' @ai revise', 'email@ai example', '<<< revise'}) do
  assert(not doc.is_instruction(line), line)
end
local source = {'---', '@ai header', '---', 'Paragraph', '@ai first', '@ai second', '', '@ai third'}
local groups = doc.instructions(source)
assert(#groups == 2)
assert(groups[1].start == 4 and groups[1].text == 'first\nsecond')
local annotated = doc.annotate(source, groups)
assert(annotated[5] == '@ai [1] first' and annotated[6] == '@ai [1] second')
assert(annotated[8] == '@ai [2] third')
assert(source[5] == '@ai first')

local multiline = {
  'Paragraph', '@ai first', '>>> second', '>>>', '>>> fourth',
  '', '>>> a Markdown quote', '', '```markdown', '@ai example', '>>> example', '```',
}
groups = doc.instructions(multiline)
assert(#groups == 1 and groups[1].start == 1 and groups[1].last == 5)
assert(groups[1].text == 'first\nsecond\n\nfourth')
annotated = doc.annotate(multiline, groups)
assert(annotated[3] == '@ai [1] second' and annotated[4] == '@ai [1] ')
assert(annotated[7] == multiline[7] and annotated[11] == multiline[11])

vim.cmd('runtime plugin/cowrite.lua')
vim.bo.filetype = 'markdown'
local function type_keys(keys)
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), 'nx', false)
end
vim.bo.comments, vim.bo.formatoptions, vim.bo.textwidth = 'n:>', 'q', 20
type_keys('i@ai one two three four five six<CR>seven<Esc>')
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), {
  '@ai one two three', '>>> four five six', '>>> seven',
}), vim.inspect(vim.api.nvim_buf_get_lines(0, 0, -1, false)))
assert(vim.bo.comments == 'n:>' and vim.bo.formatoptions == 'q')
type_keys('A<C-c>')
assert(vim.bo.comments == 'n:>' and vim.bo.formatoptions == 'q')
vim.api.nvim_buf_set_lines(0, 0, -1, false, {'>>> quote'})
type_keys('A<CR>body<Esc>')
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), {'>>> quote', 'body'}))
vim.api.nvim_buf_set_lines(0, 0, -1, false, {'```', '@ai example', '```'})
vim.api.nvim_win_set_cursor(0, {2, 0})
type_keys('A<CR>example<Esc>')
assert(vim.api.nvim_buf_get_lines(0, 2, 3, false)[1] == 'example')

vim.api.nvim_buf_set_lines(0, 0, -1, false, {'Paragraph', 'continued', '', 'Next paragraph'})
vim.api.nvim_win_set_cursor(0, {1, 0})
require('cowrite').instruct()
assert(vim.api.nvim_buf_get_lines(0, 2, 3, false)[1] == '@ai ')
print('Instruction parser tests passed')

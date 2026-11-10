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

vim.api.nvim_buf_set_lines(0, 0, -1, false, {'Paragraph', 'continued', '', 'Next paragraph'})
vim.api.nvim_win_set_cursor(0, {1, 0})
require('cowrite').instruct()
assert(vim.api.nvim_buf_get_lines(0, 2, 3, false)[1] == '@ai ')
print('Instruction parser tests passed')

vim.opt.rtp:prepend('.')
local doc = require('cowrite.doc')
for _, path in ipairs({'tutorial.md','tutorial.ja.md'}) do
  assert(#doc.instructions(vim.fn.readfile(path)) == 0, path)
end
local lines = {
  '<<< real', '```markdown', '<<< example', '```',
  '<<< real again', '~~~~', '<<< example', '~~~', '<<< still example',
  '~~~~', '  ```', '<<< example', '  ```', '<<< final',
}
local items = doc.instructions(lines)
assert(#items == 3)
assert(items[1].first == 1 and items[2].first == 5 and items[3].first == 14)
assert(#doc.instructions({'```', '<<< unclosed'}) == 0)
assert(#doc.instructions({'```lang`invalid', '<<< real'}) == 1)
assert(#doc.instructions({'<<<<<<< conflict', '<<< one', '<<< two'}) == 1)
print('Instruction parser tests passed')

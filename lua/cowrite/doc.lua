-- Parsing of the cowrite document format: YAML front matter and `<<<` lines.
local M = {}

--- True for a `<<<` instruction line: exactly three `<` then whitespace or EOL,
--- so git conflict markers (`<<<<<<<`) never match.
function M.is_instruction(line)
  return line == "<<<" or line:match("^<<<%s") ~= nil
end

local function is_blank(line)
  return line:match("^%s*$") ~= nil
end

function M.is_empty(lines)
  for _, l in ipairs(lines) do
    if not is_blank(l) then
      return false
    end
  end
  return true
end

--- Front matter range (1-based, inclusive), or nil.
---@return integer|nil, integer|nil
function M.frontmatter(lines)
  if lines[1] ~= "---" then
    return nil
  end
  for i = 2, #lines do
    if lines[i] == "---" or lines[i] == "..." then
      return 1, i
    end
  end
end

---@class cowrite.Instruction
---@field id integer
---@field start integer first line of the target paragraph (== first when empty)
---@field first integer first `<<<` line
---@field last integer last `<<<` line
---@field text string

--- Consecutive `<<<` lines form one instruction. Its target is the paragraph
--- (consecutive non-blank lines) directly above it. All indices are 1-based.
---@return cowrite.Instruction[]
function M.instructions(lines)
  local _, fm_end = M.frontmatter(lines)
  fm_end = fm_end or 0
  local result = {}
  local i = fm_end + 1
  while i <= #lines do
    if M.is_instruction(lines[i]) then
      local first, last = i, i
      while last + 1 <= #lines and M.is_instruction(lines[last + 1]) do
        last = last + 1
      end
      local start = first
      while start - 1 > fm_end and not is_blank(lines[start - 1]) and not M.is_instruction(lines[start - 1]) do
        start = start - 1
      end
      local parts = {}
      for j = first, last do
        table.insert(parts, (lines[j]:gsub("^<<<%s?", "")))
      end
      table.insert(result, {
        id = #result + 1,
        start = start,
        first = first,
        last = last,
        text = table.concat(parts, "\n"),
      })
      i = last + 1
    else
      i = i + 1
    end
  end
  return result
end

--- Copy of `lines` where each instruction line is tagged with its id:
--- `<<< foo` -> `<<< [1] foo`.
function M.annotate(lines, instrs)
  local out = vim.list_slice(lines)
  for _, ins in ipairs(instrs) do
    for j = ins.first, ins.last do
      out[j] = ("<<< [%d] %s"):format(ins.id, (lines[j]:gsub("^<<<%s?", "")))
    end
  end
  return out
end

--- Replace (or insert) the front matter in `lines` in place.
function M.replace_frontmatter(lines, header_lines)
  local s, e = M.frontmatter(lines)
  if s then
    for _ = s, e do
      table.remove(lines, 1)
    end
  end
  for k = #header_lines, 1, -1 do
    table.insert(lines, 1, header_lines[k])
  end
end

--- `cowrite.session` from the front matter.
---@return string|nil id, integer|nil line (1-based)
function M.session_id(lines)
  local s, e = M.frontmatter(lines)
  if not s then
    return nil
  end
  local in_cowrite = false
  for i = s + 1, e - 1 do
    local l = lines[i]
    if l:match("^cowrite:%s*$") then
      in_cowrite = true
    elseif l:match("^%S") then
      in_cowrite = false
    elseif in_cowrite then
      local id = l:match("^%s+session:%s*[\"']?([%w%-]+)[\"']?%s*$")
      if id then
        return id, i
      end
    end
  end
end

--- `cowrite.allow` from the front matter: a block list (`- web`) or an
--- inline one (`[web, shell]`).
---@return string[]
function M.allow(lines)
  local s, e = M.frontmatter(lines)
  local out = {}
  if not s then
    return out
  end
  local in_cowrite, in_allow = false, false
  for i = s + 1, e - 1 do
    local l = lines[i]
    if l:match("^cowrite:%s*$") then
      in_cowrite, in_allow = true, false
    elseif l:match("^%S") then
      in_cowrite, in_allow = false, false
    elseif in_cowrite then
      local inline = l:match("^%s+allow:%s*%[(.*)%]%s*$")
      if inline then
        for item in inline:gmatch("[^,%s]+") do
          table.insert(out, (item:gsub("[\"']", "")))
        end
        in_allow = false
      elseif l:match("^%s+allow:%s*$") then
        in_allow = true
      elseif in_allow and l:match("^%s+%-") then
        local item = l:match("^%s+%-%s*[\"']?([%w_%-]+)")
        if item then
          table.insert(out, item)
        end
      elseif l:match("^  %S") then
        in_allow = false
      end
    end
  end
  return out
end

--- The front matter of `lines` with `cowrite.session` set to `id` (creating
--- the front matter or the `cowrite:` key as needed), and how many leading
--- lines of `lines` it replaces.
---@return string[] header, integer replaced
function M.header_with_session(lines, id)
  local entry = "  session: " .. id
  local s, e = M.frontmatter(lines)
  if not s then
    return { "---", "cowrite:", entry, "---", "" }, 0
  end
  local header = vim.list_slice(lines, s, e)
  local _, at = M.session_id(lines)
  if at then
    header[at] = entry
    return header, e
  end
  for i = 2, #header - 1 do
    if header[i]:match("^cowrite:%s*$") then
      table.insert(header, i + 1, entry)
      return header, e
    end
  end
  table.insert(header, #header, "cowrite:")
  table.insert(header, #header, entry)
  return header, e
end

function M.split(text)
  if text == "" then
    return {}
  end
  return vim.split(text, "\n", { plain = true })
end

--- Unified diff between two texts.
function M.diff(a, b)
  local diff = (vim.text and vim.text.diff) or vim.diff
  return diff(a .. "\n", b .. "\n", { result_type = "unified", ctxlen = 3 })
end

return M

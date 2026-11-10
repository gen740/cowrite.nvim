local M = {}
function M.current()
  local provider = require("cowrite.auth").current()
  return require(provider and provider.id == "codex" and "cowrite.codex" or "cowrite.claude")
end
function M.key(key)
  return M.current().id == "codex" and ("codex_" .. key) or key
end
return M

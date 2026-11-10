-- Retry only explicit missing-session errors, never generic/API/safety failures.
local M = {}
function M.is_missing_session(message)
  local msg = tostring(message):lower()
  for _, marker in ipairs({ "api error", "safeguard", "reasoning_extraction", "refusal", "policy", "unauthorized", "rate limit" }) do
    if msg:find(marker, 1, true) then return false end
  end
  return msg:match("no conversation found with session id") ~= nil
    or msg:match("session[^\n]*not found") ~= nil
    or msg:match("thread[^\n]*not found") ~= nil
    or msg:match("no rollout found for thread") ~= nil
end
return M

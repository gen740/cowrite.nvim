if vim.g.loaded_cowrite then
  return
end
vim.g.loaded_cowrite = true

-- Make `:source path/to/plugin/cowrite.lua` work without installing the plugin:
-- put the repository root on 'runtimepath' so `require("cowrite")` resolves.
local this_file = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(this_file, ":p:h:h")
if not vim.tbl_contains(vim.opt.runtimepath:get(), root) then
  vim.opt.runtimepath:append(root)
end

require("cowrite.highlight").setup()

-- <Plug> mappings, for example:
--   vim.keymap.set("n", "<leader>cg", "<Plug>(cowrite-generate)")
local plugs = {
  generate = "Handle @ai instructions / start a document",
  cancel = "Stop generating",
  dismiss = "Hide the AI's notes",
  usage = "Show token usage",
  reset = "Start a new session for this document",
  model = "Choose the model",
  effort = "Choose the effort",
  system = "Edit the system prompt",
  auth = "Choose the backend",
}
for name, desc in pairs(plugs) do
  vim.keymap.set("n", "<Plug>(cowrite-" .. name .. ")", "<Cmd>Cowrite " .. name .. "<CR>", { desc = "cowrite: " .. desc })
end
vim.keymap.set("n", "<Plug>(cowrite-instruct)", function()
  require("cowrite").instruct()
end, { desc = "cowrite: Add a @ai instruction below this paragraph" })

vim.api.nvim_create_user_command("Cowrite", function(opts)
  require("cowrite").command(opts.fargs)
end, {
  nargs = "*",
  desc = "cowrite.nvim",
  complete = function(arglead, cmdline)
    return require("cowrite").complete(arglead, cmdline)
  end,
})

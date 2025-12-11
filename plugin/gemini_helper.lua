-- Gemini Helper plugin loader
-- Auto-loads when Neovim starts

if vim.g.loaded_gemini_helper then
  return
end

vim.g.loaded_gemini_helper = true

-- Check for plenary.nvim
local ok, _ = pcall(require, "plenary")
if not ok then
  vim.notify("gemini_helper requires plenary.nvim", vim.log.levels.ERROR)
  return
end

-- Create autocommand group
local group = vim.api.nvim_create_augroup("GeminiHelper", { clear = true })

-- Lazy load on command or keymap
vim.api.nvim_create_user_command("GeminiSetup", function(opts)
  require("gemini_helper").setup()
end, { desc = "Setup Gemini Helper" })

--- mod-version:3
-- 
-- Official LSP Configuration & On-Demand Toggles
-- 

local core = require "core"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"
local config = require "core.config"
local lspconfig = pcall(require, "plugins.lsp.config") and require("plugins.lsp.config")
local lsp = require "plugins.lsp"

-- Fix autocomplete empty needle (vital for dot triggers & instant dropdowns)
local orig_fuzzy_match = common.fuzzy_match
function common.fuzzy_match(haystack, needle, files)
  if type(haystack) == "table" and (not needle or needle == "") then
    local res = {}
    for _, item in ipairs(haystack) do
      table.insert(res, item)
    end
    return res
  end
  return orig_fuzzy_match(haystack, needle, files)
end

-- Strictly disable LSP auto-starting on startup or document loading.
-- LSP will ONLY start when manually toggled on via keyboard shortcut.
config.plugins.lsp.autostart_server = false
config.plugins.lsp.is_enabled = false

-- Enhanced Autocomplete & Inline Diagnostics Configuration
config.plugins.autocomplete.min_len = 1        -- Trigger suggestions instantly on 1st character (like VS Code)
config.plugins.autocomplete.max_suggestions = 100

-- Lint+ Inline Messages & Error Underlines (Diagnostics)
config.lint = config.lint or {}
config.lint.inline_messages = { error = true, warning = true, info = true, hint = true }
config.lint.lens_style = "solid"               -- Underline problematic code

-- Extreme Resource Saving Configurations
config.plugins.lsp.stop_unneeded_servers = true  -- Instantly kill servers when their last file tab is closed
config.plugins.lsp.more_yielding = true          -- Prevents editor freezing during heavy background parsing
config.plugins.lsp.force_verbosity_off = true    -- Disables heavy server logging to save disk I/O and RAM

if lspconfig then
  -- Register server specifications so they can start on-demand when toggled ON
  lspconfig.rust_analyzer.setup()
  lspconfig.gopls.setup()
  lspconfig.jdtls.setup()
  
  -- Optimize Pyright: Enforce Python 3.12 and strictly limit diagnostics to OPEN files only.
  lspconfig.pyright.setup({
    settings = {
      python = {
        pythonVersion = "3.12",
        analysis = {
          diagnosticMode = "openFilesOnly",  -- Do not index the whole workspace for errors
          typeCheckingMode = "basic",        -- Avoid 'strict' deep type-checking overhead
          autoSearchPaths = true             -- REQUIRED FOR AUTOCOMPLETE: Allow crawling env folders for types
        }
      }
    }
  })
  
  -- Add Ruff LSP for Python Document Formatting (Alt+Shift+F)
  lsp.add_server({
    name = "ruff_lsp",
    language = "python",
    file_patterns = { "%.py$" },
    command = { "ruff", "server" },
    verbose = false
  })
  
  lspconfig.tsserver.setup()
end

-- Command for toggling LSP on demand
command.add(nil, {
  ["lsp:toggle-servers"] = function()
    config.plugins.lsp.is_enabled = not config.plugins.lsp.is_enabled
    if config.plugins.lsp.is_enabled then
      lsp.start_servers()
      core.log("[LSP] Enabled — Language Servers started")
    else
      lsp.stop_servers()
      core.log("[LSP] Disabled — Language Servers stopped")
    end
  end
})

-- Bind Keyboard Shortcuts
keymap.add { 
  ["ctrl+alt+l"] = "lsp:toggle-servers",
  ["alt+l"]      = "lsp:toggle-servers",
  ["f12"]        = "lsp:goto-definition",
  ["shift+f12"]  = "lsp:find-references",
  ["ctrl+space"] = "lsp:complete"
}

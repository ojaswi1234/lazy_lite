--- mod-version:3
-- 
-- Official LSP Configuration & Toggles
-- 

local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local config = require "core.config"
local lspconfig = pcall(require, "plugins.lsp.config") and require("plugins.lsp.config")
local lsp = require "plugins.lsp"

-- Global toggle state
config.plugins.lsp.is_enabled = true

-- Extreme Resource Saving Configurations
config.plugins.lsp.stop_unneeded_servers = false -- Instantly kill servers when their last file tab is closed
config.plugins.lsp.more_yielding = true         -- Prevents editor freezing during heavy background parsing
config.plugins.lsp.force_verbosity_off = true   -- Disables heavy server logging to save disk I/O and RAM

if lspconfig then
  -- The official lsp setup functions are naturally lazy. 
  -- They do NOT launch the servers until a file of that specific language is opened,
  -- perfectly preserving system resources without needing custom folder scanners.
  
  lspconfig.rust_analyzer.setup()
  lspconfig.gopls.setup()
  lspconfig.jdtls.setup()
  
  -- Optimize Pyright: Enforce Python 3.12 and strictly limit diagnostics to OPEN files only.
  -- This prevents Pyright from analyzing hundreds of background files, drastically lowering RAM/CPU usage.
  lspconfig.pyright.setup({
    settings = {
      python = {
        pythonVersion = "3.12",
        analysis = {
          diagnosticMode = "openFilesOnly",  -- Do not index the whole workspace for errors
          typeCheckingMode = "basic",        -- Avoid 'strict' deep type-checking overhead
          autoSearchPaths = false            -- Stop it from crawling random folders for types
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

-- Command for keybindings
command.add("core.docview", {
  ["lsp:toggle-servers"] = function()
    config.plugins.lsp.is_enabled = not config.plugins.lsp.is_enabled
    if config.plugins.lsp.is_enabled then
      lsp.start_servers()
      core.log("[LSP] Servers Started")
    else
      lsp.stop_servers()
      core.log("[LSP] Servers Stopped")
    end
  end
})

-- Bind Keyboard Shortcut (Ctrl+Alt+L)
keymap.add { ["ctrl+alt+l"] = "lsp:toggle-servers" }

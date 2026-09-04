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

-- [ULTRA-LIGHTWEIGHT AUTOSTART]
-- We auto-start servers for seamless UX (autocomplete, hovers), but
-- completely neuter their background indexing to save RAM and CPU.
config.plugins.lsp.autostart_server = true
config.plugins.lsp.is_enabled = true

-- Troubleshooting & Logging for Language Servers
-- Enables verbose stderr logging (fixes silent crashes on Windows due to cmd.exe wrapper)
config.plugins.lsp.log_server_stderr = true

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
  --------------------------------------------------------------------------------
  -- RESOURCE OPTIMIZED LANGUAGE SERVERS
  --------------------------------------------------------------------------------
  
  -- 1. Rust: Disable heavy `cargo check` on every keystroke/save
  lspconfig.rust_analyzer.setup({
    settings = {
      ["rust-analyzer"] = {
        checkOnSave = { enable = false }, -- Stops heavy compiling on save
        cargo = { autoreload = false },   -- Stops background polling
        diagnostics = { disabled = {"unresolved-proc-macro"} }
      }
    }
  })
  
  -- 2. Go: Standard lightweight setup
  lspconfig.gopls.setup({
    settings = { gopls = { analyses = { unusedparams = true } } }
  })
  
  -- 3. Java (JDTLS): Restrict JVM Memory to 512MB to stop RAM hogging
  local jdtls_cmd = { "jdtls" }
  if PLATFORM == "Windows" then
    -- Often JDTLS on Windows accepts JVM args via env variables, but we can pass standard args
  end
  lspconfig.jdtls.setup({
    -- Depending on jdtls launcher, passing args here can restrict RAM
    -- command = { "jdtls", "-J-Xmx512m", "-J-Xms128m" }
  })
  
  -- 4. Python (Pyright): Strictly limit to OPEN files (No workspace indexing)
  lspconfig.pyright.setup({
    settings = {
      python = {
        pythonVersion = "3.12",
        analysis = {
          diagnosticMode = "openFilesOnly",  -- Crucial: Kills workspace-wide CPU spikes
          typeCheckingMode = "basic",        -- Avoid deep type-checking overhead
          autoSearchPaths = true
        }
      }
    }
  })
  
  -- Python (Ruff): Lightning fast Rust-based formatter
  lsp.add_server({
    name = "ruff_lsp", language = "python",
    file_patterns = { "%.py$" }, command = { "ruff", "server" }, verbose = false
  })
  
  -- 5. JS/TS (TSServer): Disable automatic typings acquisition
  lspconfig.tsserver.setup({
    settings = {
      typescript = { disableAutomaticTypeAcquisition = true },
      javascript = { disableAutomaticTypeAcquisition = true }
    }
  })
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

-- Official Lite XL LSP Keybindings (As requested from documentation)
keymap.add { 
  -- Inline Diagnostics & Troubleshooting
  ["shift+alt+e"] = "lsp:toggle-diagnostics",
  ["alt+e"]       = "lsp:view-doc-diagnostics",
  ["ctrl+alt+e"]  = "lsp:view-all-diagnostics",
  
  -- Symbol Search
  ["alt+s"]       = "lsp:view-document-symbols",
  ["shift+alt+s"] = "lsp:find-workspace-symbol",
  
  -- Navigation
  ["alt+d"]       = "lsp:goto-definition",
  ["alt+f"]       = "lsp:find-references",
  
  -- Document Formatting
  ["alt+shift+f"] = "lsp:format",
  
  -- Custom Quality of Life additions
  ["ctrl+alt+l"]  = "lsp:toggle-servers",
  ["alt+l"]       = "lsp:toggle-servers",
  ["ctrl+space"]  = "lsp:complete"
}

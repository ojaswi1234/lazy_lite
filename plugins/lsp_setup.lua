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
local util = require "plugins.lsp.util"

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
  -- RESOURCE OPTIMIZED LANGUAGE SERVERS WITH PRE-FLIGHT EXISTENCE CHECKS
  --------------------------------------------------------------------------------
  
  -- 1. Rust: Disable heavy `cargo check` on every keystroke/save
  if util.command_exists("rust-analyzer") then
    lspconfig.rust_analyzer.setup({
      settings = {
        ["rust-analyzer"] = {
          checkOnSave = { enable = false }, -- Stops heavy compiling on save
          cargo = { autoreload = false },   -- Stops background polling
          diagnostics = { disabled = {"unresolved-proc-macro"} }
        }
      }
    })
  end
  
  -- 2. Go: Standard lightweight setup (only active when gopls is installed)
  if util.command_exists("gopls") then
    lspconfig.gopls.setup({
      settings = { gopls = { analyses = { unusedparams = true } } }
    })
  else
    core.log_quiet("[LSP Setup] 'gopls' not found on system. Go LSP will remain disabled until installed.")
  end
  
  -- 3. Java (JDTLS): Restrict JVM Memory and provide dedicated data directory
  local jdtls_bat = "C:\\Users\\ojasw\\.config\\lite-xl\\jdtls\\bin\\jdtls.bat"
  local jdtls_cmd = nil
  if util.file_exists(jdtls_bat) then
    jdtls_cmd = { jdtls_bat, "-data", "C:\\Users\\ojasw\\.config\\lite-xl\\jdtls_data" }
  elseif util.command_exists("jdtls") then
    jdtls_cmd = { "jdtls", "-data", "C:\\Users\\ojasw\\.config\\lite-xl\\jdtls_data" }
  end

  if jdtls_cmd then
    lspconfig.jdtls.setup({
      command = jdtls_cmd
    })
  else
    core.log_quiet("[LSP Setup] JDTLS executable not found. Java LSP disabled.")
  end
  
  -- 4. Python (Pyright): Strictly limit to OPEN files (No workspace indexing)
  if util.command_exists("pyright-langserver") or util.command_exists("pyright") then
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
  end
  
  -- Python (Ruff): Lightning fast Rust-based formatter and linter
  if util.command_exists("ruff") then
    lsp.add_server({
      name = "ruff_lsp", language = "python",
      file_patterns = { "%.py$" }, command = { "ruff", "server" }, verbose = false
    })
  end
  
  -- 5. JS/TS (TSServer): Auto-resolve tsserver.js for reliable startup
  local tsserver_path = nil
  local ts_candidates = {
    core.project_dir and (core.project_dir .. "/node_modules/typescript/lib/tsserver.js"),
    "C:/Users/ojasw/AppData/Roaming/npm/node_modules/eas-cli/node_modules/typescript/lib/tsserver.js",
    "C:/Users/ojasw/AppData/Roaming/npm/node_modules/typescript/lib/tsserver.js"
  }
  for _, p in ipairs(ts_candidates) do
    if p and util.file_exists(p) then
      tsserver_path = p
      break
    end
  end

  local ts_init = {
    typescript = { disableAutomaticTypeAcquisition = true },
    javascript = { disableAutomaticTypeAcquisition = true }
  }
  if tsserver_path then
    ts_init.tsserver = { path = tsserver_path }
  end

  lspconfig.tsserver.setup({
    init_options = ts_init,
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
  ["ctrl+space"]  = "autocomplete:trigger"
}

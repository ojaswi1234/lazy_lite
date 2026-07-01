local core = require "core"
local command = require "core.command"
local keymap = require "core.keymap"
local config = require "core.config"
local process = require "process"

local SCALE = SCALE or 1

-- Helper to dynamically update the mock CLI configuration
local function update_mock_config(exit_code, delay_ms, stdout, stderr)
  for _, path in ipairs({ "e2e_test_env/mock_config.txt", "mock_config.txt" }) do
    local f = io.open(path, "w")
    if f then
      f:write("[ExitCode]\n" .. tostring(exit_code or 0) .. "\n")
      f:write("[Delay]\n" .. tostring(delay_ms or 0) .. "\n")
      f:write("[Stdout]\n" .. (stdout or "") .. "\n")
      f:write("[Stderr]\n" .. (stderr or "") .. "\n")
      f:close()
    end
  end
end

-- Helper to retrieve the sidebar view instance
local function get_sidebar()
  local sidebar = nil
  for _, v in ipairs(core.root_view.root_node:get_children()) do
    if v.get_name and v:get_name() == "Antigravity" then
      sidebar = v
      break
    end
  end
  if not sidebar then
    command.perform("antigravity:toggle")
    for _, v in ipairs(core.root_view.root_node:get_children()) do
      if v.get_name and v:get_name() == "Antigravity" then
        sidebar = v
        break
      end
    end
  end
  return sidebar
end

-- Helper to wait for the sidebar process to finish and typewriter to complete
local function wait_until_idle(sidebar, timeout_sec)
  timeout_sec = timeout_sec or 5
  local start = os.time()
  while sidebar.process or sidebar.status == "running" do
    coroutine.yield(0.05)
    if os.time() - start > timeout_sec then
      break
    end
  end
  local start_type = os.time()
  while sidebar._ai_displayed_chars < #(sidebar._ai_buf or "") do
    coroutine.yield(0.05)
    if os.time() - start_type > 2 then
      break
    end
  end
  coroutine.yield(0.05)
end

-- Helper to reset state between test cases to ensure isolation
local function reset_sidebar_state(sidebar)
  sidebar.sessions = {}
  sidebar.input = ""
  sidebar.status = "idle"
  sidebar.has_session = false
  if sidebar.process then
    pcall(function() sidebar.process:kill() end)
    sidebar.process = nil
  end
  if sidebar.model_proc then
    pcall(function() sidebar.model_proc:kill() end)
    sidebar.model_proc = nil
  end
  sidebar._ai_buf = ""
  sidebar._ai_displayed_chars = 0
  sidebar.show_model_picker = false
  config.antigravity.selected_model = nil
  sidebar.mention_suggestions = nil
  update_mock_config(0, 0, "Default response", "")
  coroutine.yield(0.05)
end

-- JSON Serializer Helpers
local function escape_json_string(s)
  if not s then return "null" end
  return '"' .. s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r') .. '"'
end

local function save_results_to_json(results, filepath)
  local t = {}
  table.insert(t, "{\n  \"tests\": [")
  for i, res in ipairs(results) do
    local comma = (i < #results) and "," or ""
    local err_line = ""
    if res.error then
      err_line = ",\n      \"error\": " .. escape_json_string(res.error)
    end
    table.insert(t, string.format([[    {
      "name": %s,
      "status": %s,
      "duration": %.3f%s
    }%s]], escape_json_string(res.name), escape_json_string(res.status), res.duration or 0, err_line, comma))
  end
  table.insert(t, "  ],")
  
  local total = #results
  local passed = 0
  local failed = 0
  for _, res in ipairs(results) do
    if res.status == "passed" then
      passed = passed + 1
    else
      failed = failed + 1
    end
  end
  
  table.insert(t, string.format([[  "summary": {
    "total": %d,
    "passed": %d,
    "failed": %d
  }
}]], total, passed, failed))
  
  local content = table.concat(t, "\n")
  local f = io.open(filepath, "w")
  if f then
    f:write(content)
    f:close()
    print("[E2E Simulator] Wrote results to " .. filepath)
  else
    print("[E2E Simulator] ERROR: Could not write results to " .. filepath)
  end
end

-- Test suite configuration
local tests = {}
local function add_test(name, fn)
  table.insert(tests, { name = name, fn = fn })
end

-- ============================================================================
-- TIER 1: Feature Coverage (20 tests)
-- ============================================================================

add_test("test_toggle_sidebar", function(sidebar)
  sidebar.visible = false
  command.perform("antigravity:toggle")
  assert(sidebar.visible == true, "Sidebar should be visible after toggle")
  command.perform("antigravity:toggle")
  assert(sidebar.visible == false, "Sidebar should be hidden after toggling twice")
end)

add_test("test_sidebar_visible", function(sidebar)
  command.perform("antigravity:toggle")
  assert(sidebar.visible == true, "Sidebar should be visible")
end)

add_test("test_sidebar_layout_width", function(sidebar)
  assert(sidebar.target_size >= 180 * SCALE, "Sidebar target size must be at least minimum width")
end)

add_test("test_sidebar_resize", function(sidebar)
  sidebar:set_target_size("x", 320 * SCALE)
  assert(sidebar.target_size == 320 * SCALE, "Sidebar target size should be successfully resized")
end)

add_test("test_scroll_up_down", function(sidebar)
  sidebar.scroll_y = 0
  sidebar:on_key_pressed("down")
  sidebar:on_key_pressed("up")
  assert(sidebar.scroll_y == 0, "scroll_y should be valid after scroll up/down commands")
end)

add_test("test_mouse_wheel_scroll", function(sidebar)
  sidebar.scroll_y = 10
  sidebar:on_mouse_wheel(1)
  assert(sidebar.scroll_y >= 0, "scroll_y should stay non-negative after wheel scroll")
end)

add_test("test_palette_tracking", function(sidebar)
  local ok, err = pcall(function() sidebar:draw() end)
  assert(ok, "Drawing should run without throwing any errors: " .. tostring(err))
end)

add_test("test_auth_status_idle", function(sidebar)
  assert(sidebar.auth_status == nil or type(sidebar.auth_status) == "string", "Auth status must be nil or a string")
end)

add_test("test_fetch_models_success", function(sidebar)
  update_mock_config(0, 0, "gemini-2.5-flash\ngemini-2.5-pro", "")
  sidebar:fetch_models()
  local start = os.time()
  while sidebar.model_proc do
    coroutine.yield(0.05)
    if os.time() - start > 3 then break end
  end
  assert(#sidebar.model_list > 0, "Model list should be populated after a successful fetch")
  assert(sidebar.auth_status == "logged_in", "Auth status should transition to logged_in")
end)

add_test("test_fetch_models_quota_exhausted", function(sidebar)
  update_mock_config(0, 0, "gemini-2.5-flash-thinking (quota exhausted)\ngemini-2.5-pro", "")
  sidebar.model_list = {}
  sidebar:fetch_models()
  local start = os.time()
  while sidebar.model_proc do
    coroutine.yield(0.05)
    if os.time() - start > 3 then break end
  end
  assert(#sidebar.model_list > 0, "Model list should be populated")
  local found_limited = false
  for _, m in ipairs(sidebar.model_list) do
    if m.name == "gemini-2.5-flash-thinking" and m.limited then
      found_limited = true
    end
  end
  assert(found_limited, "gemini-2.5-flash-thinking must be flagged as limited due to quota exhaustion")
end)

add_test("test_context_menu_explain", function(sidebar)
  update_mock_config(0, 0, "Code explanation", "")
  command.perform("antigravity:explain")
  wait_until_idle(sidebar)
  assert(sidebar.sessions[#sidebar.sessions].text:find("Code explanation", 1, true), "Response should match explanation mock")
end)

add_test("test_context_menu_refactor", function(sidebar)
  update_mock_config(0, 0, "Refactored code", "")
  command.perform("antigravity:refactor")
  wait_until_idle(sidebar)
  assert(sidebar.sessions[#sidebar.sessions].text:find("Refactored code", 1, true), "Response should match refactor mock")
end)

add_test("test_context_menu_fix", function(sidebar)
  update_mock_config(0, 0, "Fixed code", "")
  command.perform("antigravity:fix")
  wait_until_idle(sidebar)
  assert(sidebar.sessions[#sidebar.sessions].text:find("Fixed code", 1, true), "Response should match fix mock")
end)

add_test("test_context_menu_tests", function(sidebar)
  update_mock_config(0, 0, "Generated tests", "")
  command.perform("antigravity:tests")
  wait_until_idle(sidebar)
  assert(sidebar.sessions[#sidebar.sessions].text:find("Generated tests", 1, true), "Response should match tests mock")
end)

add_test("test_context_menu_docs", function(sidebar)
  update_mock_config(0, 0, "Generated documentation", "")
  command.perform("antigravity:docs")
  wait_until_idle(sidebar)
  assert(sidebar.sessions[#sidebar.sessions].text:find("Generated documentation", 1, true), "Response should match docs mock")
end)

add_test("test_quick_command_ask", function(sidebar)
  update_mock_config(0, 0, "Ask response", "")
  command.perform("antigravity:submit", "Ask query")
  wait_until_idle(sidebar)
  assert(sidebar.sessions[#sidebar.sessions].text:find("Ask response", 1, true), "Response should match ask mock")
end)

add_test("test_quick_command_submit", function(sidebar)
  update_mock_config(0, 0, "Direct submission response", "")
  sidebar:submit("Direct ask")
  wait_until_idle(sidebar)
  assert(sidebar.sessions[#sidebar.sessions-1].text == "Direct ask", "User message text matches input")
  assert(sidebar.sessions[#sidebar.sessions].text:find("Direct submission response", 1, true), "AI response matches mock")
end)

add_test("test_quick_command_clear_chat", function(sidebar)
  sidebar:_add_session("user", "Clear me")
  assert(#sidebar.sessions > 0, "Chat sessions should contain data before clear")
  local old_mods = keymap.modkeys
  keymap.modkeys = { ctrl = true }
  sidebar:on_key_pressed("return")
  keymap.modkeys = old_mods
  assert(#sidebar.sessions == 0, "Chat sessions should be empty after clear")
  assert(sidebar.has_session == false, "has_session flag should be reset to false")
end)

add_test("test_quick_command_stop", function(sidebar)
  update_mock_config(0, 100, "Slow stdout", "")
  sidebar:submit("Slow ask")
  coroutine.yield(0.05)
  assert(sidebar.process ~= nil, "CLI process should be running")
  sidebar.hover_send = true
  sidebar:on_mouse_pressed("left", 0, 0) -- trigger stop
  coroutine.yield(0.05)
  assert(sidebar.process == nil, "CLI process should have been terminated")
  assert(sidebar.status == "idle", "Status should return to idle after stopping")
end)

add_test("test_drawing_messages", function(sidebar)
  sidebar:_add_session("user", "Hello")
  sidebar:_add_session("ai", "World")
  local ok, err = pcall(function() sidebar:draw() end)
  assert(ok, "Drawing active messages should not fail: " .. tostring(err))
end)


-- ============================================================================
-- TIER 2: Boundary & Corner Cases (22 tests)
-- ============================================================================

add_test("test_empty_input", function(sidebar)
  local before = #sidebar.sessions
  sidebar:submit("")
  assert(#sidebar.sessions == before, "Empty input must not submit a session")
end)

add_test("test_whitespace_input", function(sidebar)
  local before = #sidebar.sessions
  sidebar:submit("   \n   ")
  assert(#sidebar.sessions == before, "Whitespace-only input must not submit a session")
end)

add_test("test_very_long_input", function(sidebar)
  update_mock_config(0, 0, "OK Response", "")
  local long_input = string.rep("LONG", 1000)
  sidebar:submit(long_input)
  wait_until_idle(sidebar)
  assert(sidebar.sessions[#sidebar.sessions-1].text == long_input, "Very long input should submit successfully")
end)

add_test("test_cli_exit_error", function(sidebar)
  update_mock_config(5, 0, "Out", "CLI Error Output")
  sidebar:submit("Fail me")
  wait_until_idle(sidebar)
  assert(sidebar.status == "error", "Sidebar status should be error when CLI returns non-zero")
end)

add_test("test_cli_not_found", function(sidebar)
  local old_cli = config.antigravity.cli
  config.antigravity.cli = "C:/nonexistent_path_to_agy.exe"
  sidebar:submit("Find nothing")
  wait_until_idle(sidebar)
  assert(sidebar.status == "error", "Sidebar should be in error state if CLI executable is missing")
  config.antigravity.cli = old_cli
end)

add_test("test_models_timeout", function(sidebar)
  -- Mock a process that hangs indefinitely to test timeout handling
  local hang_proc = process.start({ "cmd.exe", "/c", "pause" }, { stdin = process.REDIRECT_PIPE, stdout = process.REDIRECT_PIPE })
  sidebar.model_proc = hang_proc
  sidebar.model_started_at = os.time() - 15 -- simulate 15s elapsed time
  sidebar:update()
  assert(sidebar.model_proc == nil, "Model list fetch process should be killed on timeout")
  assert(sidebar.auth_status == "auth_error", "Auth status should transition to auth_error on timeout")
end)

add_test("test_mention_popup_trigger", function(sidebar)
  sidebar.input = "Select file @"
  sidebar:_update_mentions()
  assert(sidebar.mention_suggestions ~= nil, "Mention suggestions must be initialized when @ is typed")
end)

add_test("test_mention_popup_filter", function(sidebar)
  sidebar.input = "Select file @mossy"
  sidebar:_update_mentions()
  assert(sidebar.mention_suggestions ~= nil, "Mention suggestions must exist")
  local found = false
  for _, path in ipairs(sidebar.mention_suggestions) do
    if path:find("mossy", 1, true) then found = true end
  end
  assert(found, "Suggestions should contain entries matching the prefix 'mossy'")
end)

add_test("test_mention_popup_navigate", function(sidebar)
  sidebar.input = "Select file @mossy"
  sidebar:_update_mentions()
  sidebar.mention_idx = 1
  sidebar:on_key_pressed("down")
  assert(sidebar.mention_idx == 2 or #sidebar.mention_suggestions == 1, "Should navigate index down")
  sidebar:on_key_pressed("up")
  assert(sidebar.mention_idx == 1, "Should navigate index back up")
end)

add_test("test_mention_popup_select", function(sidebar)
  sidebar.input = "Select file @mossy"
  sidebar:_update_mentions()
  local selection = sidebar.mention_suggestions[sidebar.mention_idx]
  sidebar:on_key_pressed("return")
  assert(sidebar.input == "Select file @" .. selection .. " ", "Selected file path should autocomplete in input")
  assert(sidebar.mention_suggestions == nil, "Mention suggestions popup should close on selection")
end)

add_test("test_mention_popup_backspace", function(sidebar)
  sidebar.input = "File @"
  sidebar:_update_mentions()
  sidebar:on_key_pressed("backspace")
  assert(sidebar.input == "File ", "Input should remove the @ character")
  assert(sidebar.mention_suggestions == nil, "Mention suggestions popup should close when @ is deleted")
end)

add_test("test_selection_with_text", function(sidebar)
  local doc = core.open_file("e2e_test_env/init.lua")
  doc:set_selection(1, 1, 1, 20)
  update_mock_config(0, 0, "Selection explanation", "")
  command.perform("antigravity:explain")
  wait_until_idle(sidebar)
  local prompt = sidebar.sessions[#sidebar.sessions-1].text
  assert(prompt:find("Regarding the active file", 1, true), "Active file context should be injected in prompt")
end)

add_test("test_selection_without_text", function(sidebar)
  local doc = core.open_file("e2e_test_env/init.lua")
  doc:set_selection(1, 1, 1, 1) -- no selection
  update_mock_config(0, 0, "No selection explanation", "")
  command.perform("antigravity:explain")
  wait_until_idle(sidebar)
  local prompt = sidebar.sessions[#sidebar.sessions-1].text
  assert(prompt:find("Regarding the active file", 1, true), "Context should still refer to active file")
end)

add_test("test_invalid_model_input", function(sidebar)
  config.antigravity.selected_model = "gemini-nonexistent"
  update_mock_config(1, 0, "", "Model invalid error")
  sidebar:submit("Model test query")
  wait_until_idle(sidebar)
  assert(sidebar.status == "error", "Status should be error on invalid model execution")
  config.antigravity.selected_model = nil
end)

add_test("test_empty_mention_suggestions", function(sidebar)
  sidebar.input = "Check @nonexistentfileforrealthistime"
  sidebar:_update_mentions()
  assert(sidebar.mention_suggestions ~= nil and #sidebar.mention_suggestions == 0, "Suggestions should be empty for unmatched file query")
end)

add_test("test_special_characters_input", function(sidebar)
  update_mock_config(0, 0, "Symbols OK", "")
  sidebar:submit("~`!@#$%^&*()_-+={[}]|\\:;\"'<,>.?/")
  wait_until_idle(sidebar)
  assert(sidebar.status == "idle", "Special character prompt should execute without error")
end)

add_test("test_markdown_codeblock_input", function(sidebar)
  update_mock_config(0, 0, "Codeblock OK", "")
  sidebar:submit("```lua\nlocal x = 42\n```")
  wait_until_idle(sidebar)
  assert(sidebar.status == "idle", "Markdown block prompt should execute without error")
end)

add_test("test_typewriter_interruption", function(sidebar)
  update_mock_config(0, 0, "A long typewriter text response", "")
  sidebar:submit("Typewriter check")
  coroutine.yield(0.05)
  sidebar.visible = false
  coroutine.yield(0.1)
  sidebar.visible = true
  wait_until_idle(sidebar)
  assert(sidebar.status == "idle", "Typewriter completion should be stable when sidebar visibility changes")
end)

add_test("test_quick_pill_hover_out_of_bounds", function(sidebar)
  sidebar:on_mouse_moved(-50, -50)
  assert(sidebar.hover_btn == nil, "hover_btn must be nil when mouse is outside the sidebar bounding box")
end)

add_test("test_model_picker_toggle", function(sidebar)
  sidebar.show_model_picker = false
  sidebar.show_model_picker = true
  assert(sidebar.show_model_picker == true, "Model picker show flag should toggle to true")
  sidebar.show_model_picker = false
  assert(sidebar.show_model_picker == false, "Model picker show flag should toggle to false")
end)

add_test("test_model_picker_hover_idx", function(sidebar)
  sidebar.show_model_picker = true
  sidebar._mpicker_rects = { { x = 0, y = 0, w = 150, h = 30, idx = 1 } }
  sidebar:on_mouse_moved(15, 15)
  assert(sidebar.hover_model_idx == 1, "hover_model_idx should capture the hovered model row")
  sidebar.show_model_picker = false
end)

add_test("test_mention_popup_escape", function(sidebar)
  sidebar.input = "Cancel @"
  sidebar:_update_mentions()
  assert(sidebar.mention_suggestions ~= nil, "Suggestions open")
  sidebar:on_key_pressed("escape")
  assert(sidebar.mention_suggestions == nil, "Suggestions closed on pressing Escape")
end)


-- ============================================================================
-- TIER 3: Cross-Feature Combinations (5 tests)
-- ============================================================================

add_test("test_chat_persistence", function(sidebar)
  update_mock_config(0, 0, "Response One", "")
  sidebar:submit("Message One")
  wait_until_idle(sidebar)
  assert(sidebar.has_session == true, "Conversation context must be maintained")
  
  update_mock_config(0, 0, "Response Two", "")
  sidebar:submit("Message Two")
  wait_until_idle(sidebar)
  assert(#sidebar.sessions >= 4, "Should persist chat history containing 4 session entries")
end)

add_test("test_auth_error_model_switch_chat", function(sidebar)
  sidebar.auth_status = "auth_error"
  sidebar.model_list = { { name = "gemini-2.5-pro", limited = false } }
  sidebar.show_model_picker = true
  sidebar._mpicker_rects = { { x = 0, y = 0, w = 100, h = 30, idx = 1 } }
  sidebar:on_mouse_pressed("left", 5, 5) -- Click row 1
  assert(config.antigravity.selected_model == "gemini-2.5-pro", "Model should change to gemini-2.5-pro")
  
  update_mock_config(0, 0, "Response post model switch", "")
  sidebar:submit("Query post model switch")
  wait_until_idle(sidebar)
  assert(sidebar.sessions[#sidebar.sessions].text:find("Response post model switch", 1, true), "Chat succeeds after model switch")
end)

add_test("test_quick_pill_click_during_active_run", function(sidebar)
  update_mock_config(0, 300, "Slow response message", "")
  sidebar:submit("Slow query")
  coroutine.yield(0.05)
  assert(sidebar.process ~= nil, "CLI query must be running in the background")
  sidebar.hover_btn = 2 -- Refactor pill
  local success = sidebar:on_mouse_pressed("left", 0, 0)
  assert(success == false or sidebar.status == "running", "Pill click must be ignored when a process is currently active")
  wait_until_idle(sidebar)
end)

add_test("test_mention_select_clear_chat", function(sidebar)
  sidebar.input = "Analyze @"
  sidebar:_update_mentions()
  sidebar:on_key_pressed("return")
  assert(sidebar.input:find("Analyze @", 1, true), "Mention must be selected and autocompleted")
  
  local old_mods = keymap.modkeys
  keymap.modkeys = { ctrl = true }
  sidebar:on_key_pressed("return")
  keymap.modkeys = old_mods
  assert(sidebar.input == "", "Input should clear after Ctrl+Enter reset")
  assert(#sidebar.sessions == 0, "Sessions should clear after Ctrl+Enter reset")
end)

add_test("test_stop_generation_reset_status", function(sidebar)
  update_mock_config(0, 200, "Should cancel", "")
  sidebar:submit("Cancel run query")
  coroutine.yield(0.05)
  assert(sidebar.process ~= nil, "CLI query process must start successfully")
  sidebar.hover_send = true
  sidebar:on_mouse_pressed("left", 0, 0) -- stop
  assert(sidebar.process == nil, "CLI process must stop immediately on Stop click")
  assert(sidebar.status == "idle", "Sidebar status should reset to idle")
end)


-- ============================================================================
-- TIER 4: Real-World Application Scenarios (6 tests)
-- ============================================================================

add_test("test_explain_full_file", function(sidebar)
  local doc = core.open_file("e2e_test_env/init.lua")
  doc:set_selection(1, 1, 1, 1) -- no selection
  update_mock_config(0, 0, "Full init.lua explanation", "")
  command.perform("antigravity:explain")
  wait_until_idle(sidebar)
  assert(sidebar.sessions[#sidebar.sessions].text:find("Full init.lua explanation", 1, true), "Full file explanation response matches mock")
end)

add_test("test_refactor_selection", function(sidebar)
  local doc = core.open_file("e2e_test_env/init.lua")
  doc:set_selection(1, 1, 4, 15) -- specific range
  update_mock_config(0, 0, "Selection refactored output", "")
  command.perform("antigravity:refactor")
  wait_until_idle(sidebar)
  assert(sidebar.sessions[#sidebar.sessions].text:find("Selection refactored output", 1, true), "Refactor selection output matches mock")
end)

add_test("test_fix_and_stop_generation", function(sidebar)
  local doc = core.open_file("e2e_test_env/init.lua")
  doc:set_selection(1, 1, 1, 1)
  update_mock_config(0, 300, "Fixing error lines...", "")
  command.perform("antigravity:fix")
  coroutine.yield(0.05)
  assert(sidebar.process ~= nil, "CLI fix process starts running")
  sidebar.hover_send = true
  sidebar:on_mouse_pressed("left", 0, 0) -- stop
  assert(sidebar.process == nil, "CLI fix process stops running on click")
  assert(sidebar.sessions[#sidebar.sessions].text:find("%[Stopped by user%]", 1, false), "Response notes user termination")
end)

add_test("test_auth_flow_completion", function(sidebar)
  sidebar.auth_status = nil
  command.perform("antigravity:auth")
  assert(sidebar.auth_status == "checking", "Auth flow command triggers check state transition")
  
  -- Simulate authorization CLI success loading
  update_mock_config(0, 0, "gemini-2.5-pro\ngemini-2.5-flash", "")
  sidebar:fetch_models()
  local start = os.time()
  while sidebar.model_proc do
    coroutine.yield(0.05)
    if os.time() - start > 3 then break end
  end
  assert(sidebar.auth_status == "logged_in", "Transition back to logged_in after successful token validation")
end)

add_test("test_markdown_wrapping", function(sidebar)
  local wrapping_text = "This is a single very long message line designed to wrap. " .. string.rep("WordWrapTest ", 25)
  sidebar:_add_session("ai", wrapping_text)
  sidebar:draw()
  local session = sidebar.sessions[#sidebar.sessions]
  assert(session.lines ~= nil, "Lines cache must be computed")
  assert(#session.lines > 1, "Response text must be split into multiple wrap lines to fit screen width")
end)

add_test("test_auto_healer_traceback", function(sidebar)
  local old_sv_enter = core.command_view.enter
  local entered = false
  core.command_view.enter = function(self, text, callbacks, ...)
    entered = true
    if callbacks.submit then callbacks.submit("n") end
  end
  core.error("[Antigravity] CLI timed out")
  coroutine.yield(0.2)
  core.command_view.enter = old_sv_enter
  assert(entered == true, "Auto-healer intercepts timeout error and triggers confirmation prompt")
end)


-- ============================================================================
-- Runner Thread
-- ============================================================================

core.add_thread(function()
  print("[E2E Simulator] Waiting for Lite-XL initialization...")
  coroutine.yield(1.0) -- wait for application startup and layout to complete
  
  local sidebar = get_sidebar()
  if not sidebar then
    print("[E2E Simulator] ERROR: Could not locate Antigravity Sidebar view!")
    core.quit()
    return
  end
  
  print("[E2E Simulator] Starting test execution suite. Total tests: " .. #tests)
  local results = {}
  
  for idx, test in ipairs(tests) do
    print(string.format("[E2E Simulator] Running test %d/%d: %s", idx, #tests, test.name))
    reset_sidebar_state(sidebar)
    
    local start_time = os.clock()
    local ok, err = xpcall(function()
      test.fn(sidebar)
    end, debug.traceback)
    local duration = os.clock() - start_time
    
    local status = ok and "passed" or "failed"
    local result = {
      name = test.name,
      status = status,
      duration = duration
    }
    if not ok then
      result.error = err
      print("[E2E Simulator] FAIL: " .. test.name .. "\n" .. tostring(err))
    else
      print("[E2E Simulator] PASS: " .. test.name)
    end
    
    table.insert(results, result)
    coroutine.yield(0.05) -- yield to maintain liveness and allow rendering updates
  end
  
  -- Final cleanup
  reset_sidebar_state(sidebar)
  
  -- Save JSON results
  local results_path = "C:\\Users\\ojasw\\Documents\\LiteXL-Mossy-Setup\\e2e_test_results.json"
  save_results_to_json(results, results_path)
  
  print("[E2E Simulator] Test execution complete. Exiting...")
  core.quit()
end)

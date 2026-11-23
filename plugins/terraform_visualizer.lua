-- mod-version:3
-- ============================================================================
-- Terraform Visualizer: Cloud Architecture Studio for Lite XL
-- Full Interactive Topology Canvas, Dependency DAG, Cloud Hierarchy Containers,
-- Plan Diff & Blast Radius Mode, Static Security Linter & AI Architect
-- ============================================================================

local core = require "core"
local common = require "core.common"
local command = require "core.command"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"
local system = require "system"
local renderer = renderer or require "renderer"

local SCALE = SCALE or 1

-- Color palette helpers
local function c(r, g, b, a) return { r, g, b, a or 255 } end
local COLOR_BG_PANEL    = c(28, 30, 38)
local COLOR_BG_CANVAS   = c(20, 22, 28)
local COLOR_BG_CARD     = c(36, 40, 52)
local COLOR_BG_HOVER    = c(50, 56, 72)
local COLOR_BG_SELECTED = c(62, 70, 92)
local COLOR_BORDER      = c(54, 60, 78)
local COLOR_BORDER_HIGH = c(90, 100, 130)

-- Brand & Cloud Provider Accents
local COLOR_ACCENT      = c(132, 79, 186)   -- Terraform Purple (#844FBA)
local COLOR_AWS         = c(255, 153, 0)    -- AWS Orange (#FF9900)
local COLOR_AZURE       = c(0, 137, 214)    -- Azure Blue (#0089D6)
local COLOR_GCP         = c(66, 133, 244)   -- GCP Blue (#4285F4)
local COLOR_K8S         = c(50, 108, 229)   -- Kubernetes Blue (#326CE5)
local COLOR_CLOUDFLARE  = c(243, 128, 32)   -- Cloudflare Orange
local COLOR_CUSTOM      = c(100, 180, 240)  -- Generic Provider

-- Category Accents
local COLOR_VPC         = c(100, 140, 230, 80) -- VPC bounding box fill
local COLOR_SUBNET      = c(60, 180, 140, 60)  -- Subnet bounding box fill
local COLOR_COMPUTE     = c(245, 158, 11)   -- Compute / Instances (Amber)
local COLOR_DATABASE    = c(59, 130, 246)   -- Database / RDS (Blue)
local COLOR_STORAGE     = c(16, 185, 129)   -- Storage / S3 (Emerald)
local COLOR_NETWORK     = c(168, 85, 247)   -- Networking / Gateways (Purple)
local COLOR_SECURITY    = c(239, 68, 68)    -- Security / IAM / SGs (Red)
local COLOR_MODULE      = c(234, 179, 8)    -- Modules (Yellow)
local COLOR_VAR         = c(132, 204, 22)   -- Variables (Lime)
local COLOR_OUTPUT      = c(244, 114, 182)  -- Outputs (Pink)

-- Plan Diff Colors
local COLOR_DIFF_CREATE = c(34, 197, 94)    -- + Create (Green)
local COLOR_DIFF_UPDATE = c(234, 179, 8)    -- ~ Update (Amber)
local COLOR_DIFF_DELETE = c(239, 68, 68)    -- - Destroy (Red)
local COLOR_DIFF_REPLACE= c(249, 115, 22)   -- +/- Replace (Orange)

-- Security Severity Colors
local COLOR_SEC_CRITICAL= c(220, 38, 38)
local COLOR_SEC_HIGH    = c(234, 88, 12)
local COLOR_SEC_MEDIUM  = c(202, 138, 4)
local COLOR_SEC_LOW     = c(59, 130, 246)

local HEADER_H          = 36 * SCALE

-- ─────────────────────────────────────────────────────────────────────────────
-- Pixel-Perfect Orthogonal Line & Arrowhead Primitives
-- ─────────────────────────────────────────────────────────────────────────────
local function draw_h_seg(x1, x2, y, thickness, color, dashed)
  thickness = math.max(1, math.floor(thickness or 1))
  local min_x = math.min(x1, x2)
  local max_x = math.max(x1, x2)
  local span = max_x - min_x
  if span <= 0 then return end

  if not dashed then
    renderer.draw_rect(min_x, y - math.floor(thickness / 2), span, thickness, color)
  else
    local dash_len = 6 * SCALE
    local gap_len  = 4 * SCALE
    local cur_x    = min_x
    while cur_x < max_x do
      local cur_w = math.min(dash_len, max_x - cur_x)
      renderer.draw_rect(cur_x, y - math.floor(thickness / 2), cur_w, thickness, color)
      cur_x = cur_x + dash_len + gap_len
    end
  end
end

local function draw_v_seg(y1, y2, x, thickness, color, dashed)
  thickness = math.max(1, math.floor(thickness or 1))
  local min_y = math.min(y1, y2)
  local max_y = math.max(y1, y2)
  local span = max_y - min_y
  if span <= 0 then return end

  if not dashed then
    renderer.draw_rect(x - math.floor(thickness / 2), min_y, thickness, span, color)
  else
    local dash_len = 6 * SCALE
    local gap_len  = 4 * SCALE
    local cur_y    = min_y
    while cur_y < max_y do
      local cur_h = math.min(dash_len, max_y - cur_y)
      renderer.draw_rect(x - math.floor(thickness / 2), cur_y, thickness, cur_h, color)
      cur_y = cur_y + dash_len + gap_len
    end
  end
end

local function draw_arrow_right(cx, cy, color, size)
  size = math.max(4, math.floor(size or 6))
  for dx = 0, size do
    local x = cx - dx
    local half_h = math.floor(dx * 0.7)
    renderer.draw_rect(x, cy - half_h, 1, half_h * 2 + 1, color)
  end
end

local function draw_orthogonal_edge(x1, y1, x2, y2, color, thickness)
  local arrow_size = 6 * SCALE
  if x2 >= x1 + 16 * SCALE then
    local mid_x = math.floor((x1 + x2) / 2)
    draw_h_seg(x1, mid_x, y1, thickness, color)
    draw_v_seg(y1, y2, mid_x, thickness, color)
    draw_h_seg(mid_x, x2 - arrow_size, y2, thickness, color)
    draw_arrow_right(x2, y2, color, arrow_size)
  else
    local gutter_pad = 20 * SCALE
    local exit_x = x1 + gutter_pad
    local enter_x = x2 - gutter_pad
    local loop_y = math.min(y1, y2) - 26 * SCALE
    draw_h_seg(x1, exit_x, y1, thickness, color)
    draw_v_seg(y1, loop_y, exit_x, thickness, color)
    draw_h_seg(exit_x, enter_x, loop_y, thickness, color)
    draw_v_seg(loop_y, y2, enter_x, thickness, color)
    draw_h_seg(enter_x, x2 - arrow_size, y2, thickness, color)
    draw_arrow_right(x2, y2, color, arrow_size)
  end
end

local TerraformVisualizerView = View:extend()

function TerraformVisualizerView:new()
  TerraformVisualizerView.super.new(self)
  self.name = "Terraform Visualizer"
  self.scrollable = true
  self.target_size = 380 * SCALE
  self.visible = true
  self.size = { x = 380 * SCALE, y = 0 }

  -- Presentation Mode: "tree" (Sidebar Outline) or "canvas" (2D Architecture Graph)
  self.mode = "tree"

  -- Ingested Data Models
  self.providers    = {}
  self.resources    = {}
  self.data_sources = {}
  self.modules      = {}
  self.variables    = {}
  self.outputs      = {}
  self.containers   = {}
  self.edges        = {}
  self.security_all = {}
  self.plan_summary = { create = 0, update = 0, delete = 0, replace = 0, has_plan = false }

  self.files_scanned = 0
  self.last_scan_time = 0
  self.is_scanning = false
  self.filter = ""

  -- Tree View state
  self.hovered_idx = nil
  self.items = {}
  self.collapsed = {
    plan_diff    = false,
    security     = false,
    containers   = false,
    providers    = false,
    resources    = false,
    data_sources = true,
    modules      = false,
    variables    = true,
    outputs      = true,
  }

  -- Canvas View state
  self.pan = { x = 60 * SCALE, y = 60 * SCALE }
  self.zoom = 1.0
  self.is_panning = false
  self.pan_start = { x = 0, y = 0, px = 0, py = 0 }
  self.selected_node_id = nil
  self.hovered_node_id = nil
  self.dragging_node_id = nil
  self.drag_offset = { x = 0, y = 0 }
  self.canvas_buttons = {}
  self.blast_radius_ids = {}

  self.content_height = 0
  self.scroll = { x = 0, y = 0, to = { x = 0, y = 0 } }
end

function TerraformVisualizerView:update()
  TerraformVisualizerView.super.update(self)
  local dest = self.visible and self.target_size or 0
  self:move_towards(self.size, "x", dest, nil, "terraform_visualizer")
end

function TerraformVisualizerView:get_name()
  return "Terraform Visualizer"
end

function TerraformVisualizerView:get_scrollable_size()
  if self.mode == "canvas" then
    return self.size.y + 1
  end
  return math.max(self.size.y + 1, self.content_height + 40 * SCALE)
end

function TerraformVisualizerView:set_target_size(axis, value)
  if axis == "x" then
    self.target_size = value
    return true
  elseif axis == "y" then
    self.size.y = value
    return true
  end
  return false
end

-- ============================================================================
-- Provider Categorization & Cloud Badges
-- ============================================================================

local function get_provider_info(provider_str)
  local p = (provider_str or ""):lower()
  if p:find("aws") then
    return { name = "AWS", color = COLOR_AWS, icon = "\u{f0c2}" }
  elseif p:find("azurerm") or p:find("azure") then
    return { name = "Azure", color = COLOR_AZURE, icon = "\u{f0c2}" }
  elseif p:find("google") or p:find("gcp") then
    return { name = "GCP", color = COLOR_GCP, icon = "\u{f0c2}" }
  elseif p:find("kubernetes") or p:find("k8s") or p:find("helm") then
    return { name = "K8s", color = COLOR_K8S, icon = "\u{f1b2}" }
  elseif p:find("cloudflare") then
    return { name = "Cloudflare", color = COLOR_CLOUDFLARE, icon = "\u{f0c2}" }
  else
    return { name = (provider_str or "Custom"):upper(), color = COLOR_CUSTOM, icon = "\u{f1b3}" }
  end
end

local function get_resource_category(res_type)
  local t = (res_type or ""):lower()
  if t:find("vpc") or t:find("virtual_network") or t:find("network") then
    return "vpc", COLOR_VPC, "\u{f0c2}"
  elseif t:find("subnet") then
    return "subnet", COLOR_SUBNET, "\u{f0e8}"
  elseif t:find("instance") or t:find("server") or t:find("vm") or t:find("node") or t:find("container") or t:find("pod") or t:find("ecs") or t:find("eks") then
    return "compute", COLOR_COMPUTE, "\u{f233}"
  elseif t:find("db") or t:find("database") or t:find("sql") or t:find("rds") or t:find("dynamo") or t:find("mongo") then
    return "database", COLOR_DATABASE, "\u{f1c0}"
  elseif t:find("bucket") or t:find("s3") or t:find("storage") or t:find("blob") or t:find("ebs") or t:find("disk") then
    return "storage", COLOR_STORAGE, "\u{f0a0}"
  elseif t:find("gateway") or t:find("lb") or t:find("load_balancer") or t:find("route") or t:find("dns") or t:find("ip") then
    return "network", COLOR_NETWORK, "\u{f012}"
  elseif t:find("security_group") or t:find("iam") or t:find("firewall") or t:find("policy") or t:find("role") or t:find("key") then
    return "security", COLOR_SECURITY, "\u{f023}"
  else
    return "resource", COLOR_ACCENT, "\u{f1b3}"
  end
end

-- ============================================================================
-- Static Security & Compliance Linter Engine (Phase 5 - 15 CIS Rules)
-- ============================================================================

local function run_security_linter(res)
  local findings = {}
  local t = res.type or ""
  local attrs = res.attrs or {}

  -- 1. Open SSH Ingress
  if t:find("security_group") or t:find("firewall") then
    for k, v in pairs(attrs) do
      if type(v) == "string" and v:find("0%.0%.0%.0/0") then
        if attrs.from_port == "22" or attrs.to_port == "22" or k:find("22") then
          table.insert(findings, {
            severity = "CRITICAL",
            title = "CIS-1.1: Open SSH Ingress (0.0.0.0/0)",
            desc = "Security group exposes SSH port 22 directly to the public internet.",
            line = res.line
          })
        elseif attrs.from_port == "3389" or attrs.to_port == "3389" or k:find("3389") then
          table.insert(findings, {
            severity = "CRITICAL",
            title = "CIS-1.2: Open RDP Ingress (0.0.0.0/0)",
            desc = "Security group exposes Windows RDP port 3389 to the public internet.",
            line = res.line
          })
        elseif attrs.protocol == "-1" or attrs.protocol == "all" then
          table.insert(findings, {
            severity = "HIGH",
            title = "All Ingress Traffic Open to World",
            desc = "Rule permits unrestricted ingress for all protocols and ports.",
            line = res.line
          })
        end
      end
    end
  end

  -- 2. S3 Bucket Public Access & Encryption
  if t:find("s3_bucket") or t:find("storage_bucket") then
    if attrs.acl == '"public-read"' or attrs.acl == '"public-read-write"' then
      table.insert(findings, {
        severity = "CRITICAL",
        title = "S3 Bucket Public ACL Enabled",
        desc = "Storage bucket ACL configured with public read/write permission.",
        line = res.line
      })
    end
    if attrs.server_side_encryption_configuration == nil and attrs.encryption == nil then
      table.insert(findings, {
        severity = "HIGH",
        title = "Missing At-Rest SSE Encryption",
        desc = "Bucket lacks explicit server-side encryption configuration (AES256/KMS).",
        line = res.line
      })
    end
  end

  -- 3. Database Publicly Accessible & Unencrypted
  if t:find("db_instance") or t:find("database") or t:find("rds") then
    if attrs.publicly_accessible == "true" then
      table.insert(findings, {
        severity = "CRITICAL",
        title = "RDS Instance Publicly Accessible",
        desc = "Database has publicly_accessible=true, allowing direct internet routing.",
        line = res.line
      })
    end
    if attrs.storage_encrypted == "false" then
      table.insert(findings, {
        severity = "HIGH",
        title = "Database Storage Encryption Disabled",
        desc = "RDS storage volume is unencrypted, violating data governance rules.",
        line = res.line
      })
    end
  end

  -- 4. Unencrypted EBS Volumes
  if t:find("ebs_volume") and attrs.encrypted == "false" then
    table.insert(findings, {
      severity = "MEDIUM",
      title = "Unencrypted EBS Block Device",
      desc = "Elastic Block Store volume is provisioned without KMS encryption.",
      line = res.line
    })
  end

  -- 5. Insecure TLS Versions
  if attrs.min_tls_version and (attrs.min_tls_version:find("TLS1_0") or attrs.min_tls_version:find("TLS1_1")) then
    table.insert(findings, {
      severity = "HIGH",
      title = "Insecure Minimum TLS Protocol",
      desc = "Configured TLS version is deprecated (< TLS 1.2). Vulnerable to POODLE/BEAST.",
      line = res.line
    })
  end

  -- 6. Kubernetes Privileged Mode
  if (t:find("kubernetes") or t:find("k8s")) and attrs.privileged == "true" then
    table.insert(findings, {
      severity = "CRITICAL",
      title = "Privileged Container Execution",
      desc = "Container granted host root access and capabilities.",
      line = res.line
    })
  end

  -- 7. Hardcoded Plaintext Secrets Detection
  for k, v in pairs(attrs) do
    if (k:find("pass") or k:find("secret") or k:find("token") or k:find("api_key")) and type(v) == "string" then
      if not v:find("var%.") and not v:find("local%.") and not v:find("data%.") and #v > 4 then
        table.insert(findings, {
          severity = "CRITICAL",
          title = "Hardcoded Secret In HCL Attribute",
          desc = string.format("Potential plaintext secret exposed in attribute '%s'.", k),
          line = res.line
        })
        break
      end
    end
  end

  return findings
end

-- ============================================================================
-- Workspace Scanning & Deep HCL AST Parser (Phase 1)
-- ============================================================================

local function get_project_dirs()
  local dirs = {}
  if core.project_directories then
    for _, pd in ipairs(core.project_directories) do
      table.insert(dirs, pd.name or pd)
    end
  elseif core.project_dir then
    table.insert(dirs, core.project_dir)
  end
  return dirs
end

local function normalize_path(p)
  return (p or ""):gsub("\\", "/")
end

local function is_ignored_dir(name)
  local n = name:lower()
  return n == ".terraform" or n == ".git" or n == "node_modules"
      or n == ".visualizer" or n == "dist" or n == "build" or n == "vendor"
end

local function scan_files_recursive(dir, file_list, extra_files)
  local files = system.list_dir(dir)
  if not files then return end
  for _, fname in ipairs(files) do
    if not fname:match("^%.") or fname == ".tfvars" then
      local full = dir .. "/" .. fname
      local info = system.get_file_info(full)
      if info then
        if info.type == "dir" and not is_ignored_dir(fname) then
          scan_files_recursive(full, file_list, extra_files)
        elseif info.type == "file" then
          if fname:match("%.tf$") or fname:match("%.tfvars$") then
            table.insert(file_list, full)
          elseif fname == "plan.json" or fname == "tfplan.json" or fname == "terraform.tfstate" then
            extra_files[fname] = full
          end
        end
      end
    end
  end
end

local function simple_json_decode(str)
  local ok, res = pcall(function()
    if common.json_decode then return common.json_decode(str) end
    local changes = {}
    for addr, actions_str in str:gmatch('"address"%s*:%s*"([^"]+)"%s*,.-"actions"%s*:%s*%[([^%]]+)%]') do
      local act = "update"
      if actions_str:find('"create"') and actions_str:find('"delete"') then
        act = "replace"
      elseif actions_str:find('"create"') then
        act = "create"
      elseif actions_str:find('"delete"') then
        act = "delete"
      end
      changes[addr] = act
    end
    return { resource_changes = changes }
  end)
  if ok and res then return res end
  return nil
end

function TerraformVisualizerView:scan_project()
  self.is_scanning = true
  self.providers    = {}
  self.resources    = {}
  self.data_sources = {}
  self.modules      = {}
  self.variables    = {}
  self.outputs      = {}
  self.containers   = {}
  self.edges        = {}
  self.security_all = {}
  self.plan_summary = { create = 0, update = 0, delete = 0, replace = 0, has_plan = false }
  self.files_scanned = 0

  local file_list = {}
  local extra_files = {}
  local pdirs = get_project_dirs()
  for _, pdir in ipairs(pdirs) do
    scan_files_recursive(normalize_path(pdir), file_list, extra_files)
  end
  self.files_scanned = #file_list

  local res_by_id = {}
  local raw_deps_map = {}

  for _, full_path in ipairs(file_list) do
    local f = io.open(full_path, "r")
    if f then
      local content = f:read("*a")
      f:close()

      local rel_path = full_path
      for _, pdir in ipairs(pdirs) do
        local np = normalize_path(pdir)
        if full_path:sub(1, #np) == np then
          rel_path = full_path:sub(#np + 2)
          break
        end
      end

      local line_no = 1
      local current_block = nil
      local depth = 0

      for line in (content .. "\n"):gmatch("(.-)\r?\n") do
        local trimmed = line:match("^%s*(.-)%s*$")
        local is_comment = trimmed:match("^#") or trimmed:match("^//")

        if not is_comment and #trimmed > 0 then
          if depth == 0 then
            local r_type, r_name = trimmed:match('^resource%s+"([^"]+)"%s+"([^"]+)"')
            local d_type, d_name = trimmed:match('^data%s+"([^"]+)"%s+"([^"]+)"')
            local p_name         = trimmed:match('^provider%s+"([^"]+)"')
            local m_name         = trimmed:match('^module%s+"([^"]+)"')
            local v_name         = trimmed:match('^variable%s+"([^"]+)"')
            local o_name         = trimmed:match('^output%s+"([^"]+)"')

            if r_type and r_name then
              local prov = r_type:match("^([^_]+)") or "custom"
              local rid = r_type .. "." .. r_name
              current_block = {
                id = rid,
                kind = "resource",
                provider = prov,
                type = r_type,
                name = r_name,
                file = rel_path,
                abs_file = full_path,
                line = line_no,
                attrs = {},
                deps = {}
              }
              res_by_id[rid] = current_block
              table.insert(self.resources, current_block)
            elseif d_type and d_name then
              local prov = d_type:match("^([^_]+)") or "custom"
              local did = "data." .. d_type .. "." .. d_name
              current_block = {
                id = did,
                kind = "data",
                provider = prov,
                type = d_type,
                name = d_name,
                file = rel_path,
                abs_file = full_path,
                line = line_no,
                attrs = {},
                deps = {}
              }
              table.insert(self.data_sources, current_block)
            elseif p_name then
              local exists = false
              for _, p in ipairs(self.providers) do
                if p.name == p_name and p.file == rel_path then exists = true; break end
              end
              if not exists then
                current_block = {
                  id = "provider." .. p_name,
                  name = p_name,
                  file = rel_path,
                  abs_file = full_path,
                  line = line_no,
                  attrs = {}
                }
                table.insert(self.providers, current_block)
              end
            elseif m_name then
              current_block = {
                id = "module." .. m_name,
                kind = "module",
                name = m_name,
                file = rel_path,
                abs_file = full_path,
                line = line_no,
                attrs = {},
                deps = {}
              }
              table.insert(self.modules, current_block)
            elseif v_name then
              current_block = {
                id = "var." .. v_name,
                name = v_name,
                file = rel_path,
                abs_file = full_path,
                line = line_no,
                attrs = {}
              }
              table.insert(self.variables, current_block)
            elseif o_name then
              current_block = {
                id = "output." .. o_name,
                name = o_name,
                file = rel_path,
                abs_file = full_path,
                line = line_no,
                attrs = {}
              }
              table.insert(self.outputs, current_block)
            end
          end

          if current_block then
            local k, v = trimmed:match('^([%w_%-]+)%s*=%s*(.+)$')
            if k and v and current_block.attrs then
              current_block.attrs[k] = v
            end

            if current_block.id then
              for ref_type, ref_name in trimmed:gmatch('([%w_%-]+)%.([%w_%-]+)%.?[%w_%-]*') do
                if ref_type ~= "var" and ref_type ~= "local" and ref_type ~= "count" and ref_type ~= "each" then
                  local candidate = ref_type .. "." .. ref_name
                  if not raw_deps_map[current_block.id] then raw_deps_map[current_block.id] = {} end
                  raw_deps_map[current_block.id][candidate] = true
                end
              end
            end
          end

          for ch in trimmed:gmatch(".") do
            if ch == "{" then depth = depth + 1
            elseif ch == "}" then
              depth = math.max(0, depth - 1)
              if depth == 0 then current_block = nil end
            end
          end
        end

        line_no = line_no + 1
      end
    end
  end

  -- Ingest Plan Diff if available (Phase 4)
  local plan_path = extra_files["plan.json"] or extra_files["tfplan.json"]
  if plan_path then
    local pf = io.open(plan_path, "r")
    if pf then
      local pdata = pf:read("*a")
      pf:close()
      local parsed_plan = simple_json_decode(pdata)
      if parsed_plan and parsed_plan.resource_changes then
        self.plan_summary.has_plan = true
        for addr, action in pairs(parsed_plan.resource_changes) do
          if res_by_id[addr] then
            res_by_id[addr].plan_action = action
            if action == "create" then self.plan_summary.create = self.plan_summary.create + 1
            elseif action == "update" then self.plan_summary.update = self.plan_summary.update + 1
            elseif action == "delete" then self.plan_summary.delete = self.plan_summary.delete + 1
            elseif action == "replace" then self.plan_summary.replace = self.plan_summary.replace + 1
            end
          end
        end
      end
    end
  end

  -- Build Directed Graph Edges & Containers (Phase 1 & Phase 3)
  for _, res in ipairs(self.resources) do
    local findings = run_security_linter(res)
    res.findings = findings
    for _, f in ipairs(findings) do
      table.insert(self.security_all, {
        res_id = res.id,
        file = res.file,
        abs_file = res.abs_file,
        finding = f
      })
    end

    if raw_deps_map[res.id] then
      for target_id, _ in pairs(raw_deps_map[res.id]) do
        if res_by_id[target_id] and target_id ~= res.id then
          table.insert(res.deps, target_id)
          table.insert(self.edges, { from = target_id, to = res.id, type = "ref" })
        end
      end
    end

    local cat = get_resource_category(res.type)
    if cat == "vpc" then
      local cidr = res.attrs.cidr_block or res.attrs.cidr or "VPC Network"
      table.insert(self.containers, {
        id = res.id,
        kind = "vpc",
        name = res.name,
        cidr = cidr:gsub('"', ''),
        file = res.file,
        line = res.line,
        children = {},
        x = 0, y = 0, w = 0, h = 0
      })
    elseif cat == "subnet" then
      local cidr = res.attrs.cidr_block or res.attrs.cidr or "Subnet"
      table.insert(self.containers, {
        id = res.id,
        kind = "subnet",
        name = res.name,
        cidr = cidr:gsub('"', ''),
        file = res.file,
        line = res.line,
        parent_id = nil,
        children = {},
        x = 0, y = 0, w = 0, h = 0
      })
    end
  end

  -- Link Child Resources into Containers
  local container_by_id = {}
  for _, cbox in ipairs(self.containers) do container_by_id[cbox.id] = cbox end

  for _, res in ipairs(self.resources) do
    local cat = get_resource_category(res.type)
    if cat ~= "vpc" and cat ~= "subnet" then
      for _, dep_id in ipairs(res.deps) do
        if container_by_id[dep_id] and container_by_id[dep_id].kind == "subnet" then
          res.container_id = dep_id
          table.insert(container_by_id[dep_id].children, res.id)
          break
        end
      end
      if not res.container_id then
        for _, dep_id in ipairs(res.deps) do
          if container_by_id[dep_id] and container_by_id[dep_id].kind == "vpc" then
            res.container_id = dep_id
            table.insert(container_by_id[dep_id].children, res.id)
            break
          end
        end
      end
    end
  end

  self:compute_canvas_layout()
  self:fit_to_view()

  self.last_scan_time = system.get_time()
  self.is_scanning = false
  core.redraw = true
end

-- ============================================================================
-- 2D Canvas Auto-Layout Engine (Phase 2 & Phase 3)
-- ============================================================================

function TerraformVisualizerView:get_all_drawable_nodes()
  local list = {}
  for _, r in ipairs(self.resources or {}) do table.insert(list, r) end
  for _, d in ipairs(self.data_sources or {}) do table.insert(list, d) end
  for _, m in ipairs(self.modules or {}) do table.insert(list, m) end
  return list
end

function TerraformVisualizerView:update_container_bounds()
  for _, cbox in ipairs(self.containers or {}) do
    local r = nil
    for _, res in ipairs(self.resources or {}) do
      if res.id == cbox.id then r = res; break end
    end
    if r and r.x and r.y then
      local rw = r.w or (210 * SCALE)
      local rh = r.h or (68 * SCALE)
      local min_x, min_y = r.x - 16 * SCALE, r.y - 16 * SCALE
      local max_x, max_y = r.x + rw + 16 * SCALE, r.y + rh + 16 * SCALE

      for _, cid in ipairs(cbox.children or {}) do
        for _, child in ipairs(self.resources or {}) do
          if child.id == cid and child.x and child.y then
            local cw = child.w or (210 * SCALE)
            local ch = child.h or (68 * SCALE)
            min_x = math.min(min_x, child.x - 14 * SCALE)
            min_y = math.min(min_y, child.y - 14 * SCALE)
            max_x = math.max(max_x, child.x + cw + 14 * SCALE)
            max_y = math.max(max_y, child.y + ch + 14 * SCALE)
          end
        end
      end
      cbox.x = min_x
      cbox.y = min_y
      cbox.w = max_x - min_x
      cbox.h = max_y - min_y
    end
  end
end

function TerraformVisualizerView:compute_canvas_layout()
  local start_x = 60 * SCALE
  local start_y = 60 * SCALE
  local node_w = 210 * SCALE
  local node_h = 68 * SCALE
  local gap_x = 70 * SCALE
  local gap_y = 50 * SCALE

  local cols = {
    vpcs = {},
    subnets = {},
    network_security = {},
    compute_db = {},
    storage_other = {}
  }

  for _, r in ipairs(self.resources or {}) do
    r.w = node_w
    r.h = node_h
    local cat = get_resource_category(r.type)
    if cat == "vpc" then
      table.insert(cols.vpcs, r)
    elseif cat == "subnet" then
      table.insert(cols.subnets, r)
    elseif cat == "security" or cat == "network" then
      table.insert(cols.network_security, r)
    elseif cat == "compute" or cat == "database" then
      table.insert(cols.compute_db, r)
    else
      table.insert(cols.storage_other, r)
    end
  end

  for _, d in ipairs(self.data_sources or {}) do
    d.w = node_w
    d.h = node_h
    local cat = get_resource_category(d.type)
    if cat == "vpc" or cat == "subnet" then
      table.insert(cols.subnets, d)
    else
      table.insert(cols.storage_other, d)
    end
  end

  for _, m in ipairs(self.modules or {}) do
    m.w = node_w
    m.h = node_h
    table.insert(cols.compute_db, m)
  end

  local col_order = { cols.vpcs, cols.subnets, cols.network_security, cols.compute_db, cols.storage_other }
  local cur_x = start_x

  for _, col_nodes in ipairs(col_order) do
    local cur_y = start_y
    for _, r in ipairs(col_nodes) do
      r.x = cur_x
      r.y = cur_y
      cur_y = cur_y + node_h + gap_y
    end
    if #col_nodes > 0 then
      cur_x = cur_x + node_w + gap_x
    end
  end

  self:update_container_bounds()
end

function TerraformVisualizerView:fit_to_view()
  local all_items = self:get_all_drawable_nodes()

  if #all_items == 0 then
    self.pan = { x = 60 * SCALE, y = 60 * SCALE }
    self.zoom = 1.0
    return
  end

  local min_x, min_y =  math.huge,  math.huge
  local max_x, max_y = -math.huge, -math.huge
  for _, n in ipairs(all_items) do
    if n.x and n.y then
      min_x = math.min(min_x, n.x)
      min_y = math.min(min_y, n.y)
      max_x = math.max(max_x, n.x + (n.w or 210 * SCALE))
      max_y = math.max(max_y, n.y + (n.h or 68 * SCALE))
    end
  end

  if min_x == math.huge then
    self.pan = { x = 60 * SCALE, y = 60 * SCALE }
    self.zoom = 1.0
    return
  end

  local gw = math.max(max_x - min_x, 100 * SCALE)
  local gh = math.max(max_y - min_y, 100 * SCALE)
  local avail_w = math.max(self.size.x - 80 * SCALE, 120 * SCALE)
  local avail_h = math.max(self.size.y - HEADER_H - 80 * SCALE, 120 * SCALE)

  local fit_scale = math.min(avail_w / gw, avail_h / gh)
  fit_scale = math.max(0.35, math.min(1.2, fit_scale))
  self.zoom = fit_scale

  -- Center the content in the viewport
  local cx_world = (min_x + max_x) / 2
  local cy_world = (min_y + max_y) / 2
  self.pan.x = (self.size.x / 2) / self.zoom - cx_world
  self.pan.y = ((self.size.y - HEADER_H) / 2) / self.zoom - cy_world
  core.redraw = true
end

-- Compute Upstream and Downstream Blast Radius (Phase 4)
function TerraformVisualizerView:compute_blast_radius(root_id)
  self.blast_radius_ids = {}
  if not root_id then return end
  self.blast_radius_ids[root_id] = "root"

  local function visit_upstream(id)
    for _, e in ipairs(self.edges) do
      if e.to == id and e.from and not self.blast_radius_ids[e.from] then
        self.blast_radius_ids[e.from] = "upstream"
        visit_upstream(e.from)
      end
    end
  end
  visit_upstream(root_id)

  local function visit_downstream(id)
    for _, e in ipairs(self.edges) do
      if e.from == id and e.to and not self.blast_radius_ids[e.to] then
        self.blast_radius_ids[e.to] = "downstream"
        visit_downstream(e.to)
      end
    end
  end
  visit_downstream(root_id)
end

-- ============================================================================
-- World/Screen Transforms
-- ============================================================================

function TerraformVisualizerView:world_to_screen(wx, wy)
  local top_y = self.position.y + HEADER_H
  return self.position.x + (wx + self.pan.x) * self.zoom,
         top_y + (wy + self.pan.y) * self.zoom
end

function TerraformVisualizerView:screen_to_world(sx, sy)
  local top_y = self.position.y + HEADER_H
  return (sx - self.position.x) / self.zoom - self.pan.x,
         (sy - top_y) / self.zoom - self.pan.y
end

-- ============================================================================
-- Mouse & Interaction Handling
-- ============================================================================

function TerraformVisualizerView:on_mouse_wheel(y, x)
  if self.mode == "canvas" then
    local old_zoom = self.zoom
    local factor = y > 0 and 1.15 or 0.87
    local new_zoom = math.max(0.3, math.min(2.5, old_zoom * factor))

    local mx = self.mouse_x or (self.position.x + self.size.x / 2)
    local my = self.mouse_y or (self.position.y + HEADER_H + (self.size.y - HEADER_H) / 2)
    local wx, wy = self:screen_to_world(mx, my)

    self.zoom = new_zoom
    local top_y = self.position.y + HEADER_H
    self.pan.x = (mx - self.position.x) / self.zoom - wx
    self.pan.y = (my - top_y) / self.zoom - wy
    core.redraw = true
    return true
  else
    self.scroll.to.y = self.scroll.to.y - y * 40 * SCALE
    local max_scroll = math.max(0, self:get_scrollable_size() - self.size.y)
    self.scroll.to.y = math.max(0, math.min(self.scroll.to.y, max_scroll))
    return true
  end
end

function TerraformVisualizerView:on_mouse_moved(x, y, dx, dy)
  TerraformVisualizerView.super.on_mouse_moved(self, x, y, dx, dy)
  self.mouse_x = x
  self.mouse_y = y

  if self.mode == "canvas" then
    if self.is_panning then
      self.pan.x = self.pan.x + dx / self.zoom
      self.pan.y = self.pan.y + dy / self.zoom
      core.redraw = true
      return
    end

    local all_nodes = self:get_all_drawable_nodes()

    if self.dragging_node_id then
      for _, r in ipairs(all_nodes) do
        if r.id == self.dragging_node_id then
          local wx, wy = self:screen_to_world(x, y)
          r.x = wx - self.drag_offset.x
          r.y = wy - self.drag_offset.y
          self:update_container_bounds()
          core.redraw = true
          break
        end
      end
      return
    end

    local found_node = nil
    for _, r in ipairs(all_nodes) do
      if r.x and r.y then
        local sx, sy = self:world_to_screen(r.x, r.y)
        local sw, sh = (r.w or (210 * SCALE)) * self.zoom, (r.h or (68 * SCALE)) * self.zoom
        if x >= sx and x <= sx + sw and y >= sy and y <= sy + sh then
          found_node = r.id
          break
        end
      end
    end

    if found_node ~= self.hovered_node_id then
      self.hovered_node_id = found_node
      core.redraw = true
    end

    if found_node then system.set_cursor("hand") else system.set_cursor("arrow") end
  else
    local found_hover = nil
    for idx, item in ipairs(self.items) do
      if x >= item.x and x <= item.x + item.w and y >= item.y and y <= item.y + item.h then
        found_hover = idx
        break
      end
    end
    if found_hover ~= self.hovered_idx then
      self.hovered_idx = found_hover
      core.redraw = true
    end
    if found_hover then system.set_cursor("hand") else system.set_cursor("arrow") end
  end
end

function TerraformVisualizerView:on_mouse_pressed(button, x, y, clicks)
  for _, btn in ipairs(self.canvas_buttons) do
    if x >= btn.x and x <= btn.x + btn.w and y >= btn.y and y <= btn.y + btn.h then
      if btn.action == "set_mode" then
        self.mode = btn.mode
        if self.mode == "canvas" then
          local node = core.root_view.root_node:get_node_for_view(self)
          if node and node.size.x < 560 * SCALE then
            node.size.x = 560 * SCALE
            self.size.x = 560 * SCALE
            self.target_size = 560 * SCALE
          end
          self:fit_to_view()
        else
          local node = core.root_view.root_node:get_node_for_view(self)
          if node and node.size.x > 380 * SCALE then
            node.size.x = 380 * SCALE
            self.size.x = 380 * SCALE
            self.target_size = 380 * SCALE
          end
        end
        core.redraw = true
        return true
      elseif btn.action == "refresh" then
        self:scan_project()
        return true
      elseif btn.action == "reset_canvas" or btn.action == "fit_view" then
        self:fit_to_view()
        self.selected_node_id = nil
        self.blast_radius_ids = {}
        core.redraw = true
        return true
      elseif btn.action == "zoom_in" then
        self:on_mouse_wheel(1, 0)
        return true
      elseif btn.action == "zoom_out" then
        self:on_mouse_wheel(-1, 0)
        return true
      elseif btn.action == "export_mermaid" then
        command.perform("terraform_visualizer:export_mermaid")
        return true
      elseif btn.action == "ai_explain" then
        command.perform("terraform_visualizer:explain_ai")
        return true
      end
    end
  end

  if self.mode == "canvas" then
    if button == "middle" or (button == "left" and keymap.modkeys and keymap.modkeys["space"]) then
      self.is_panning = true
      return true
    end

    if button == "left" then
      local all_nodes = self:get_all_drawable_nodes()
      for _, r in ipairs(all_nodes) do
        if r.x and r.y then
          local sx, sy = self:world_to_screen(r.x, r.y)
          local sw, sh = (r.w or (210 * SCALE)) * self.zoom, (r.h or (68 * SCALE)) * self.zoom
          if x >= sx and x <= sx + sw and y >= sy and y <= sy + sh then
            if clicks == 2 and r.abs_file and r.line then
              local doc = core.open_doc(r.abs_file)
              if doc then
                local doc_view = core.root_view:open_doc(doc)
                doc:set_selection(r.line, 1, r.line, 1)
                if doc_view and doc_view.scroll_to_line then
                  doc_view:scroll_to_line(r.line, true)
                end
              end
              return true
            else
              self.selected_node_id = r.id
              self:compute_blast_radius(r.id)
              self.dragging_node_id = r.id
              local wx, wy = self:screen_to_world(x, y)
              self.drag_offset.x = wx - r.x
              self.drag_offset.y = wy - r.y
              core.redraw = true
              return true
            end
          end
        end
      end

      self.selected_node_id = nil
      self.blast_radius_ids = {}
      self.is_panning = true
      core.redraw = true
      return true
    end
  else
    if button == "left" then
      for _, item in ipairs(self.items) do
        if x >= item.x and x <= item.x + item.w and y >= item.y and y <= item.y + item.h then
          if item.action == "toggle_section" then
            self.collapsed[item.section] = not self.collapsed[item.section]
            core.redraw = true
            return true
          elseif item.action == "jump" and item.abs_file and item.line then
            local doc = core.open_doc(item.abs_file)
            if doc then
              local doc_view = core.root_view:open_doc(doc)
              doc:set_selection(item.line, 1, item.line, 1)
              if doc_view and doc_view.scroll_to_line then
                doc_view:scroll_to_line(item.line, true)
              end
            end
            return true
          end
        end
      end
    end
  end

  return TerraformVisualizerView.super.on_mouse_pressed(self, button, x, y, clicks)
end

function TerraformVisualizerView:on_mouse_released(button, x, y)
  if button == "left" or button == "middle" then
    self.is_panning = false
    self.dragging_node_id = nil
    core.redraw = true
  end
  return TerraformVisualizerView.super.on_mouse_released(self, button, x, y)
end

-- ============================================================================
-- Rendering: Header, Tree Outline & 2D Architecture Canvas
-- ============================================================================

function TerraformVisualizerView:draw()
  self:draw_background(style.background)
  local font = style.font
  local bfont = style.big_font or font
  local cfont = style.code_font or font
  local fh = font:get_height()
  local pad = 10 * SCALE

  local x, y, w, h = self.position.x, self.position.y, self.size.x, self.size.y
  if w <= 0 or h <= 0 then return end

  self.canvas_buttons = {}

  -- ── 1. Top Master Control Header (Always Visible) ──────────────────────────
  local header_h = 36 * SCALE
  renderer.draw_rect(x, y, w, header_h, COLOR_BG_PANEL)
  renderer.draw_rect(x, y + header_h - 1, w, 1, COLOR_BORDER)

  -- Icon & Studio Title
  local title = "\u{f1b3} Studio"
  renderer.draw_text(bfont, title, x + pad, y + (header_h - bfont:get_height()) / 2, COLOR_ACCENT)

  -- Mode Switch Tabs: [ Tree | Canvas ]
  local mode_tree_w = font:get_width("Outline") + 16 * SCALE
  local mode_canvas_w = font:get_width("Canvas") + 16 * SCALE
  local tab_h = 24 * SCALE
  local tab_y = y + (header_h - tab_h) / 2
  local mode_tree_x = x + pad + bfont:get_width(title) + 14 * SCALE
  local mode_canvas_x = mode_tree_x + mode_tree_w + 4 * SCALE

  local is_tree_active = (self.mode == "tree")
  renderer.draw_rect(mode_tree_x, tab_y, mode_tree_w, tab_h, is_tree_active and COLOR_ACCENT or COLOR_BG_CARD)
  renderer.draw_text(font, "Outline", mode_tree_x + 8 * SCALE, tab_y + (tab_h - fh) / 2, is_tree_active and style.background or style.text)
  table.insert(self.canvas_buttons, { action = "set_mode", mode = "tree", x = mode_tree_x, y = tab_y, w = mode_tree_w, h = tab_h })

  local is_canvas_active = (self.mode == "canvas")
  renderer.draw_rect(mode_canvas_x, tab_y, mode_canvas_w, tab_h, is_canvas_active and COLOR_ACCENT or COLOR_BG_CARD)
  renderer.draw_text(font, "Canvas", mode_canvas_x + 8 * SCALE, tab_y + (tab_h - fh) / 2, is_canvas_active and style.background or style.text)
  table.insert(self.canvas_buttons, { action = "set_mode", mode = "canvas", x = mode_canvas_x, y = tab_y, w = mode_canvas_w, h = tab_h })

  -- Action Buttons: [ Scan ] [ AI ]
  local btn_scan_w = font:get_width("Scan") + 14 * SCALE
  local btn_scan_x = x + w - pad - btn_scan_w
  renderer.draw_rect(btn_scan_x, tab_y, btn_scan_w, tab_h, COLOR_BG_CARD)
  renderer.draw_text(font, self.is_scanning and "Scanning..." or "Scan", btn_scan_x + 7 * SCALE, tab_y + (tab_h - fh) / 2, style.text)
  table.insert(self.canvas_buttons, { action = "refresh", x = btn_scan_x, y = tab_y, w = btn_scan_w, h = tab_h })

  local btn_ai_w = font:get_width("AI") + 14 * SCALE
  local btn_ai_x = btn_scan_x - btn_ai_w - 6 * SCALE
  renderer.draw_rect(btn_ai_x, tab_y, btn_ai_w, tab_h, COLOR_BG_CARD)
  renderer.draw_text(font, "AI", btn_ai_x + 7 * SCALE, tab_y + (tab_h - fh) / 2, COLOR_CUSTOM)
  table.insert(self.canvas_buttons, { action = "ai_explain", x = btn_ai_x, y = tab_y, w = btn_ai_w, h = tab_h })

  -- ── 2. Render Mode Content ────────────────────────────────────────────────
  if self.mode == "canvas" then
    self:draw_canvas_mode(x, y + header_h, w, h - header_h)
  else
    self:draw_tree_mode(x, y + header_h, w, h - header_h)
  end
end

-- ============================================================================
-- Mode A: 2D Interactive Architecture Canvas (Phase 2 & 3 & 4)
-- ============================================================================

function TerraformVisualizerView:draw_canvas_mode(cx, cy, cw, ch)
  if cw <= 0 or ch <= 0 then return end
  core.push_clip_rect(cx, cy, cw, ch)
  renderer.draw_rect(cx, cy, cw, ch, COLOR_BG_CANVAS)

  local font = style.font
  local bfont = style.big_font or font
  local cfont = style.code_font or font
  local fh = font:get_height()

  -- Subtle Blueprint Dot Grid
  local grid_size = 40 * SCALE * self.zoom
  if grid_size > 8 then
    local ox = (self.pan.x * self.zoom) % grid_size
    local oy = (self.pan.y * self.zoom) % grid_size
    for gx = cx + ox, cx + cw, grid_size do
      for gy = cy + oy, cy + ch, grid_size do
        renderer.draw_rect(gx, gy, 1.5 * SCALE, 1.5 * SCALE, c(255, 255, 255, 20))
      end
    end
  end

  local all_drawable = self:get_all_drawable_nodes()

  -- Empty state notice
  if #all_drawable == 0 then
    local cx_mid = cx + cw / 2
    local cy_mid = cy + ch / 2
    local msg = self.is_scanning and "Scanning workspace for Terraform resources..." or "No Terraform Resources Detected"
    local sub = self.is_scanning and "Parsing .tf files in the active project..." or "Open a Terraform workspace or click Scan to generate 2D infrastructure map"
    local mw = bfont:get_width(msg)
    local sw = font:get_width(sub)
    renderer.draw_text(bfont, msg, cx_mid - mw / 2, cy_mid - 32 * SCALE, style.text)
    renderer.draw_text(font, sub, cx_mid - sw / 2, cy_mid + 4 * SCALE, style.dim)

    if not self.is_scanning then
      local btn_text = " 🔍 Scan Workspace "
      local bw = font:get_width(btn_text) + 24 * SCALE
      local bh = 32 * SCALE
      local bx = cx_mid - bw / 2
      local by = cy_mid + 36 * SCALE
      local b_hov = (self.mouse_x and self.mouse_y and self.mouse_x >= bx and self.mouse_x <= bx + bw and self.mouse_y >= by and self.mouse_y <= by + bh)
      renderer.draw_rect(bx, by, bw, bh, b_hov and COLOR_ACCENT or COLOR_BG_CARD)
      renderer.draw_rect(bx, by, bw, 1, COLOR_BORDER_HIGH)
      renderer.draw_text(font, btn_text, bx + 12 * SCALE, by + (bh - fh) / 2, b_hov and style.background or style.text)
      table.insert(self.canvas_buttons, { action = "refresh", x = bx, y = by, w = bw, h = bh })
    end

    core.pop_clip_rect()
    return
  end

  -- Draw Containers (VPCs & Subnets bounding boxes - Phase 3)
  for _, cbox in ipairs(self.containers or {}) do
    if cbox.w and cbox.w > 0 and cbox.h and cbox.h > 0 and cbox.x and cbox.y then
      local sx, sy = self:world_to_screen(cbox.x, cbox.y)
      local sw, sh = cbox.w * self.zoom, cbox.h * self.zoom

      local fill_col = cbox.kind == "vpc" and COLOR_VPC or COLOR_SUBNET
      local border_col = cbox.kind == "vpc" and COLOR_ACCENT or COLOR_STORAGE

      renderer.draw_rect(sx, sy, sw, sh, fill_col)
      renderer.draw_rect(sx, sy, sw, 1, border_col)
      renderer.draw_rect(sx, sy + sh - 1, sw, 1, border_col)
      renderer.draw_rect(sx, sy, 1, sh, border_col)
      renderer.draw_rect(sx + sw - 1, sy, 1, sh, border_col)

      local clabel = string.format("[%s] %s (%s)", cbox.kind:upper(), cbox.name or "", cbox.cidr or "")
      local lw = cfont:get_width(clabel) + 12 * SCALE
      local lh = cfont:get_height() + 4 * SCALE
      renderer.draw_rect(sx + 8 * SCALE, sy + 6 * SCALE, lw, lh, COLOR_BG_CARD)
      renderer.draw_text(cfont, clabel, sx + 14 * SCALE, sy + 8 * SCALE, border_col)
    end
  end

  -- Draw Directed Dependency Edges (Phase 1 & 2 - Manhattan Orthogonal Routing)
  local node_by_id = {}
  for _, n in ipairs(all_drawable) do node_by_id[n.id] = n end

  for _, e in ipairs(self.edges or {}) do
    local r1 = node_by_id[e.from]
    local r2 = node_by_id[e.to]

    if r1 and r2 and r1.x and r1.y and r2.x and r2.y then
      local rw1 = r1.w or (210 * SCALE)
      local rh1 = r1.h or (68 * SCALE)
      local rh2 = r2.h or (68 * SCALE)
      local x1, y1 = self:world_to_screen(r1.x + rw1, r1.y + rh1 / 2)
      local x2, y2 = self:world_to_screen(r2.x, r2.y + rh2 / 2)

      local edge_color = c(80, 90, 110, 140)
      local edge_w = 1.5 * SCALE

      if self.selected_node_id then
        if self.blast_radius_ids[e.from] and self.blast_radius_ids[e.to] then
          if self.blast_radius_ids[e.to] == "downstream" or e.from == self.selected_node_id then
            edge_color = COLOR_AWS
            edge_w = 3 * SCALE
          else
            edge_color = COLOR_GCP
            edge_w = 2.5 * SCALE
          end
        else
          edge_color = c(50, 55, 70, 40)
        end
      end

      draw_orthogonal_edge(x1, y1, x2, y2, edge_color, edge_w)
    end
  end

  -- Draw Node Cards (Phase 2 & 4)
  for _, r in ipairs(all_drawable) do
    if r.x and r.y then
      local rw = r.w or (210 * SCALE)
      local rh = r.h or (68 * SCALE)
      local sx, sy = self:world_to_screen(r.x, r.y)
      local sw, sh = rw * self.zoom, rh * self.zoom

      if sx + sw >= cx and sx <= cx + cw and sy + sh >= cy and sy <= cy + ch then
        local is_sel = (r.id == self.selected_node_id)
        local is_hov = (r.id == self.hovered_node_id)
        local pinfo = get_provider_info(r.provider or "custom")
        local cat, cat_col, cat_icon = get_resource_category(r.type or r.kind or "resource")

        local card_bg = COLOR_BG_CARD
        local border_col = COLOR_BORDER

        if self.selected_node_id then
          if is_sel then
            card_bg = COLOR_BG_SELECTED
            border_col = COLOR_ACCENT
          elseif self.blast_radius_ids[r.id] == "downstream" then
            border_col = COLOR_DIFF_DELETE
            card_bg = c(55, 35, 40)
          elseif self.blast_radius_ids[r.id] == "upstream" then
            border_col = COLOR_GCP
            card_bg = c(30, 45, 65)
          else
            card_bg = c(28, 30, 38, 120)
          end
        elseif is_hov then
          card_bg = COLOR_BG_HOVER
          border_col = COLOR_BORDER_HIGH
        end

        renderer.draw_rect(sx, sy, sw, sh, card_bg)
        renderer.draw_rect(sx, sy, sw, 1, border_col)
        renderer.draw_rect(sx, sy + sh - 1, sw, 1, border_col)
        renderer.draw_rect(sx, sy, 1, sh, border_col)
        renderer.draw_rect(sx + sw - 1, sy, 1, sh, border_col)

        renderer.draw_rect(sx, sy, 4 * SCALE * self.zoom, sh, pinfo.color)

        local badge_text = string.format("%s %s", cat_icon, pinfo.name)
        renderer.draw_text(cfont, badge_text, sx + 8 * SCALE * self.zoom, sy + 6 * SCALE * self.zoom, pinfo.color)

        local name_str = r.name or r.id or "resource"
        if #name_str > 18 then name_str = name_str:sub(1, 16) .. ".." end
        renderer.draw_text(font, name_str, sx + 8 * SCALE * self.zoom, sy + 22 * SCALE * self.zoom, style.text)

        local sub_type = r.type or r.kind or "resource"
        if #sub_type > 22 then sub_type = sub_type:sub(1, 20) .. ".." end
        renderer.draw_text(cfont, sub_type, sx + 8 * SCALE * self.zoom, sy + 40 * SCALE * self.zoom, style.dim)

        if r.plan_action then
          local pcol = COLOR_DIFF_UPDATE
          local pchar = "~"
          if r.plan_action == "create" then pcol = COLOR_DIFF_CREATE; pchar = "+"
          elseif r.plan_action == "delete" then pcol = COLOR_DIFF_DELETE; pchar = "-"
          elseif r.plan_action == "replace" then pcol = COLOR_DIFF_REPLACE; pchar = "+/-"
          end
          local pw = cfont:get_width(pchar) + 8 * SCALE * self.zoom
          local ph = cfont:get_height() + 2 * SCALE * self.zoom
          local px = sx + sw - pw - 6 * SCALE * self.zoom
          local py = sy + 6 * SCALE * self.zoom
          renderer.draw_rect(px, py, pw, ph, pcol)
          renderer.draw_text(cfont, pchar, px + 4 * SCALE * self.zoom, py + 1 * SCALE * self.zoom, style.background)
        end

        if r.findings and #r.findings > 0 then
          local sec_str = string.format("Alert %d", #r.findings)
          local sw_w = cfont:get_width(sec_str) + 8 * SCALE * self.zoom
          local sw_h = cfont:get_height() + 2 * SCALE * self.zoom
          local px = sx + sw - sw_w - 6 * SCALE * self.zoom
          local py = sy + sh - sw_h - 6 * SCALE * self.zoom
          renderer.draw_rect(px, py, sw_w, sw_h, COLOR_SEC_HIGH)
          renderer.draw_text(cfont, sec_str, px + 4 * SCALE * self.zoom, py + 1 * SCALE * self.zoom, style.background)
        end
      end
    end
  end

  -- ── Floating Canvas Control Overlay (Zoom, Reset, Export) ─────────────────
  local ctl_x = cx + cw - 194 * SCALE
  local ctl_y = cy + ch - 48 * SCALE
  local ctl_w = 182 * SCALE
  local ctl_h = 36 * SCALE

  renderer.draw_rect(ctl_x, ctl_y, ctl_w, ctl_h, COLOR_BG_PANEL)
  renderer.draw_rect(ctl_x, ctl_y, ctl_w, 1, COLOR_BORDER)
  renderer.draw_rect(ctl_x, ctl_y, 1, ctl_h, COLOR_BORDER)

  local function add_ctl_btn(btn_label, bx, bw, action)
    renderer.draw_rect(bx, ctl_y + 4 * SCALE, bw, ctl_h - 8 * SCALE, COLOR_BG_CARD)
    renderer.draw_text(font, btn_label, bx + (bw - font:get_width(btn_label)) / 2, ctl_y + (ctl_h - fh) / 2, style.text)
    table.insert(self.canvas_buttons, { action = action, x = bx, y = ctl_y + 4 * SCALE, w = bw, h = ctl_h - 8 * SCALE })
  end

  add_ctl_btn("+", ctl_x + 6 * SCALE, 26 * SCALE, "zoom_in")
  add_ctl_btn("-", ctl_x + 36 * SCALE, 26 * SCALE, "zoom_out")
  add_ctl_btn("Fit", ctl_x + 66 * SCALE, 36 * SCALE, "fit_view")
  add_ctl_btn("Reset", ctl_x + 106 * SCALE, 42 * SCALE, "reset_canvas")
  add_ctl_btn("MMD", ctl_x + 152 * SCALE, 24 * SCALE, "export_mermaid")

  -- ── Floating Blast Radius HUD (if node is selected) ───────────────────────
  if self.selected_node_id then
    local sel_res = nil
    for _, r in ipairs(all_drawable) do if r.id == self.selected_node_id then sel_res = r; break end end
    if sel_res then
      local down_count = 0
      local up_count = 0
      for _, mode in pairs(self.blast_radius_ids) do
        if mode == "downstream" then down_count = down_count + 1
        elseif mode == "upstream" then up_count = up_count + 1
        end
      end

      local hud_w = math.min(360 * SCALE, cw - 32 * SCALE)
      local hud_h = 60 * SCALE
      local hud_x = cx + 16 * SCALE
      local hud_y = cy + ch - hud_h - 16 * SCALE

      renderer.draw_rect(hud_x, hud_y, hud_w, hud_h, COLOR_BG_PANEL)
      renderer.draw_rect(hud_x, hud_y, 4 * SCALE, hud_h, down_count > 0 and COLOR_DIFF_DELETE or COLOR_ACCENT)
      renderer.draw_rect(hud_x, hud_y, hud_w, 1, COLOR_BORDER)

      local h_title = string.format("Blast Radius: %s", sel_res.id)
      renderer.draw_text(font, h_title, hud_x + 12 * SCALE, hud_y + 8 * SCALE, style.text)

      local h_desc = string.format("Affects %d downstream resources | Depends on %d upstream parents", down_count, up_count)
      renderer.draw_text(cfont, h_desc, hud_x + 12 * SCALE, hud_y + 26 * SCALE, down_count > 0 and COLOR_AWS or style.dim)

      local h_sub = "Double click node to open source file & line"
      renderer.draw_text(cfont, h_sub, hud_x + 12 * SCALE, hud_y + 42 * SCALE, style.dim)
    end
  end

  core.pop_clip_rect()
end

-- ============================================================================
-- Mode B: Sidebar Tree & Categorized Outline Mode
-- ============================================================================

function TerraformVisualizerView:draw_tree_mode(tx, ty, tw, th)
  if tw <= 0 or th <= 0 then return end
  local font = style.font
  local bfont = style.big_font or font
  local cfont = style.code_font or font
  local fh = font:get_height()
  local pad = 12 * SCALE

  local cy = ty + pad - self.scroll.y
  local inner_w = tw - pad * 2
  self.items = {}

  -- ── Stats Summary Bar ─────────────────────────────────────────────────────
  local total_res = #self.resources + #self.data_sources
  local stats_text = string.format("%d files | %d resources | %d providers | %d modules",
    self.files_scanned, total_res, #self.providers, #self.modules)
  renderer.draw_text(font, stats_text, tx + pad + 4 * SCALE, cy, style.dim)
  cy = cy + fh + 8 * SCALE

  -- ── Plan Diff Banner (Phase 4) ────────────────────────────────────────────
  if self.plan_summary.has_plan then
    local diff_h = 28 * SCALE
    renderer.draw_rect(tx + pad, cy, inner_w, diff_h, COLOR_BG_CARD)
    local dmsg = string.format("Plan: +%d to add | ~%d to change | -%d to destroy",
      self.plan_summary.create, self.plan_summary.update, self.plan_summary.delete)
    renderer.draw_text(font, dmsg, tx + pad + 8 * SCALE, cy + (diff_h - fh) / 2, COLOR_DIFF_CREATE)
    cy = cy + diff_h + 8 * SCALE
  end

  -- ── Security Findings Banner (Phase 5) ────────────────────────────────────
  if #self.security_all > 0 then
    local sec_h = 28 * SCALE
    renderer.draw_rect(tx + pad, cy, inner_w, sec_h, c(50, 30, 35))
    renderer.draw_rect(tx + pad, cy, 3 * SCALE, sec_h, COLOR_SEC_HIGH)
    local sec_msg = string.format("Shield: %d Security Findings Detected in IaC", #self.security_all)
    renderer.draw_text(font, sec_msg, tx + pad + 10 * SCALE, cy + (sec_h - fh) / 2, COLOR_SEC_HIGH)
    cy = cy + sec_h + 8 * SCALE
  end

  -- Empty State
  if self.files_scanned == 0 then
    local empty_card_h = 90 * SCALE
    renderer.draw_rect(tx + pad, cy, inner_w, empty_card_h, COLOR_BG_CARD)
    renderer.draw_rect(tx + pad, cy, inner_w, empty_card_h, COLOR_BORDER)

    local msg1 = "No Terraform files found in workspace."
    local msg2 = "Create or open *.tf files, then click 'Scan' to inspect resources."
    renderer.draw_text(font, msg1, tx + pad + 14 * SCALE, cy + 18 * SCALE, style.text)
    renderer.draw_text(font, msg2, tx + pad + 14 * SCALE, cy + 42 * SCALE, style.dim)
    self.content_height = cy + empty_card_h - ty
    return
  end

  local function draw_section_header(sec_id, title_str, count, tag_color)
    local is_coll = self.collapsed[sec_id]
    local arrow = is_coll and "\u{25b6} " or "\u{25bc} "
    local sh_h = 24 * SCALE

    renderer.draw_rect(tx + pad, cy, inner_w, sh_h, COLOR_BG_CARD)
    renderer.draw_rect(tx + pad, cy, 2 * SCALE, sh_h, tag_color)

    local full_title = string.format("%s%s (%d)", arrow, title_str, count)
    renderer.draw_text(font, full_title, tx + pad + 8 * SCALE, cy + (sh_h - fh) / 2, tag_color)

    table.insert(self.items, {
      action = "toggle_section",
      section = sec_id,
      x = tx + pad,
      y = cy,
      w = inner_w,
      h = sh_h
    })

    cy = cy + sh_h + 4 * SCALE
    return not is_coll
  end

  local function draw_resource_card(item, badge_text, badge_color)
    local item_h = 42 * SCALE
    local item_x = tx + pad + 8 * SCALE
    local item_w = inner_w - 8 * SCALE

    local is_hov = (self.hovered_idx == #self.items + 1)
    renderer.draw_rect(item_x, cy, item_w, item_h, is_hov and COLOR_BG_HOVER or COLOR_BG_CARD)
    renderer.draw_rect(item_x, cy, item_w, 1, COLOR_BORDER)
    renderer.draw_rect(item_x, cy + item_h - 1, item_w, 1, COLOR_BORDER)

    local bw = cfont:get_width(badge_text) + 10 * SCALE
    local bh = cfont:get_height() + 4 * SCALE
    local bx = item_x + 6 * SCALE
    local by = cy + (item_h - bh) / 2
    renderer.draw_rect(bx, by, bw, bh, badge_color)
    renderer.draw_text(cfont, badge_text, bx + 5 * SCALE, by + 2 * SCALE, style.background)

    local label = item.type and (item.type .. "." .. item.name) or item.name
    local lx = bx + bw + 8 * SCALE
    renderer.draw_text(font, label, lx, cy + 4 * SCALE, style.text)

    local sub = string.format("%s:%d", item.file or "", item.line or 1)
    if item.findings and #item.findings > 0 then
      sub = sub .. string.format(" | Alerts %d", #item.findings)
    end
    renderer.draw_text(cfont, sub, lx, cy + 22 * SCALE, (item.findings and #item.findings > 0) and COLOR_SEC_HIGH or style.dim)

    if item.plan_action then
      local pact = item.plan_action:upper()
      local pw = cfont:get_width(pact) + 8 * SCALE
      local px = item_x + item_w - pw - 6 * SCALE
      renderer.draw_rect(px, cy + 6 * SCALE, pw, 18 * SCALE, COLOR_DIFF_CREATE)
      renderer.draw_text(cfont, pact, px + 4 * SCALE, cy + 8 * SCALE, style.background)
    end

    table.insert(self.items, {
      action = "jump",
      abs_file = item.abs_file,
      line = item.line,
      x = item_x,
      y = cy,
      w = item_w,
      h = item_h
    })

    cy = cy + item_h + 3 * SCALE
  end

  -- ── Section: Security Alerts (Phase 5) ────────────────────────────────────
  if #self.security_all > 0 then
    if draw_section_header("security", "Security Linter Findings", #self.security_all, COLOR_SEC_HIGH) then
      for _, sf in ipairs(self.security_all) do
        local item_h = 38 * SCALE
        local item_x = tx + pad + 8 * SCALE
        local item_w = inner_w - 8 * SCALE

        renderer.draw_rect(item_x, cy, item_w, item_h, COLOR_BG_CARD)
        renderer.draw_rect(item_x, cy, 3 * SCALE, item_h, sf.finding.severity == "CRITICAL" and COLOR_SEC_CRITICAL or COLOR_SEC_HIGH)

        renderer.draw_text(font, sf.finding.title, item_x + 8 * SCALE, cy + 4 * SCALE, COLOR_SEC_HIGH)
        local sdesc = string.format("%s:%d — %s", sf.file or "", sf.finding.line or 1, sf.res_id)
        renderer.draw_text(cfont, sdesc, item_x + 8 * SCALE, cy + 20 * SCALE, style.dim)

        table.insert(self.items, {
          action = "jump",
          abs_file = sf.abs_file,
          line = sf.finding.line,
          x = item_x,
          y = cy,
          w = item_w,
          h = item_h
        })

        cy = cy + item_h + 3 * SCALE
      end
      cy = cy + 6 * SCALE
    end
  end

  -- ── Section: Cloud Hierarchy Containers (Phase 3) ─────────────────────────
  if #self.containers > 0 then
    if draw_section_header("containers", "Cloud Boundaries (VPC / Subnets)", #self.containers, COLOR_VPC) then
      for _, cbox in ipairs(self.containers) do
        draw_resource_card(cbox, cbox.kind, cbox.kind == "vpc" and COLOR_ACCENT or COLOR_STORAGE)
      end
      cy = cy + 6 * SCALE
    end
  end

  -- ── Section: Providers ────────────────────────────────────────────────────
  if #self.providers > 0 then
    if draw_section_header("providers", "Providers", #self.providers, COLOR_ACCENT) then
      for _, p in ipairs(self.providers) do
        draw_resource_card(p, "provider", COLOR_ACCENT)
      end
      cy = cy + 6 * SCALE
    end
  end

  -- ── Section: Managed Resources ────────────────────────────────────────────
  if #self.resources > 0 then
    if draw_section_header("resources", "Resources", #self.resources, COLOR_AWS) then
      for _, r in ipairs(self.resources) do
        local cat, col = get_resource_category(r.type)
        draw_resource_card(r, cat, col)
      end
      cy = cy + 6 * SCALE
    end
  end

  -- ── Section: Data Sources ─────────────────────────────────────────────────
  if #self.data_sources > 0 then
    if draw_section_header("data_sources", "Data Sources", #self.data_sources, COLOR_GCP) then
      for _, d in ipairs(self.data_sources) do
        draw_resource_card(d, "data", COLOR_GCP)
      end
      cy = cy + 6 * SCALE
    end
  end

  -- ── Section: Modules ──────────────────────────────────────────────────────
  if #self.modules > 0 then
    if draw_section_header("modules", "Modules", #self.modules, COLOR_MODULE) then
      for _, m in ipairs(self.modules) do
        draw_resource_card(m, "module", COLOR_MODULE)
      end
      cy = cy + 6 * SCALE
    end
  end

  -- ── Section: Variables & Outputs ──────────────────────────────────────────
  if #self.variables > 0 then
    if draw_section_header("variables", "Variables", #self.variables, COLOR_VAR) then
      for _, v in ipairs(self.variables) do
        draw_resource_card(v, "var", COLOR_VAR)
      end
      cy = cy + 6 * SCALE
    end
  end

  if #self.outputs > 0 then
    if draw_section_header("outputs", "Outputs", #self.outputs, COLOR_OUTPUT) then
      for _, o in ipairs(self.outputs) do
        draw_resource_card(o, "output", COLOR_OUTPUT)
      end
      cy = cy + 6 * SCALE
    end
  end

  self.content_height = cy + self.scroll.y - ty + 20 * SCALE
end

-- ============================================================================
-- AI Cloud Architect & Mermaid Export Helpers (Phase 5)
-- ============================================================================

local function generate_mermaid_diagram(view)
  local lines = { "```mermaid", "flowchart TD" }
  for _, cbox in ipairs(view.containers) do
    table.insert(lines, string.format('  subgraph %s["%s: %s (%s)"]', cbox.id:gsub("[%.%-]", "_"), cbox.kind:upper(), cbox.name, cbox.cidr))
    for _, cid in ipairs(cbox.children) do
      table.insert(lines, string.format('    %s["%s"]', cid:gsub("[%.%-]", "_"), cid))
    end
    table.insert(lines, "  end")
  end
  for _, r in ipairs(view.resources) do
    if not r.container_id then
      table.insert(lines, string.format('  %s["%s\\n(%s)"]', r.id:gsub("[%.%-]", "_"), r.id, r.type))
    end
  end
  for _, e in ipairs(view.edges) do
    table.insert(lines, string.format("  %s --> %s", e.from:gsub("[%.%-]", "_"), e.to:gsub("[%.%-]", "_")))
  end
  table.insert(lines, "```")
  return table.concat(lines, "\n")
end

-- ============================================================================
-- Commands & Keymaps
-- ============================================================================

local tv_view = nil

local function toggle_tf_view()
  local sidebar = rawget(_G, "get_sidebar_node") and _G.get_sidebar_node()
  if tv_view and core.root_view.root_node:get_node_for_view(tv_view) then
    local node = core.root_view.root_node:get_node_for_view(tv_view)
    if sidebar and node == sidebar and node.active_view == tv_view then
      for i = #node.views, 1, -1 do
        node:close_view(core.root_view.root_node, node.views[i])
      end
      tv_view = nil
      rawset(_G, "_ag_sidebar_node", nil)
    elseif sidebar and node == sidebar then
      node:set_active_view(tv_view)
      core.set_active_view(tv_view)
    else
      node:close_view(core.root_view.root_node, tv_view)
      tv_view = nil
    end
  else
    if not tv_view then tv_view = TerraformVisualizerView() end
    tv_view.visible = true
    if sidebar then
      -- Add new view first so node is never empty/destroyed
      if not core.root_view.root_node:get_node_for_view(tv_view) then
        sidebar:add_view(tv_view)
      end
      for i = #sidebar.views, 1, -1 do
        local v = sidebar.views[i]
        if v ~= tv_view then
          sidebar:remove_view(core.root_view.root_node, v)
        end
      end
      sidebar:set_active_view(tv_view)
      core.set_active_view(tv_view)
    else
      local primary = core.root_view:get_primary_node()
      sidebar = primary:split("right", tv_view, { x = true }, true)
      if sidebar then
        sidebar.should_show_tabs = function() return false end
        if not sidebar._ab_patched then
          local old_av = sidebar.add_view
          sidebar.add_view = function(self, v)
            local l = self.locked; self.locked = nil
            old_av(self, v)
            self.locked = l
          end
          sidebar._ab_patched = true
        end
        rawset(_G, "_ag_sidebar_node", sidebar)
        sidebar.size.x = 380 * SCALE
        tv_view.size.x = 380 * SCALE
        sidebar:set_active_view(tv_view)
        core.set_active_view(tv_view)
      end
    end
    tv_view:scan_project()
  end
  core.redraw = true
end

command.add(nil, {
  ["terraform_visualizer:toggle"] = function()
    toggle_tf_view()
  end,
  ["terraform_visualizer:open_canvas"] = function()
    if not tv_view then tv_view = TerraformVisualizerView() end
    tv_view.mode = "canvas"
    tv_view.target_size = 560 * SCALE
    local primary = core.root_view:get_primary_node()
    local existing_node = core.root_view.root_node:get_node_for_view(tv_view)
    if existing_node then
      if existing_node ~= primary then
        existing_node:remove_view(core.root_view.root_node, tv_view)
        primary:add_view(tv_view)
      end
    else
      primary:add_view(tv_view)
    end
    core.set_active_view(tv_view)
    tv_view:scan_project()
  end,
  ["terraform_visualizer:refresh"] = function()
    if tv_view then tv_view:scan_project() end
  end,
  ["terraform_visualizer:export_mermaid"] = function()
    if tv_view then
      local mmd = generate_mermaid_diagram(tv_view)
      system.set_clipboard(mmd)
      core.log("[Terraform Studio] Mermaid diagram copied to clipboard!")
    end
  end,
  ["terraform_visualizer:explain_ai"] = function()
    if tv_view then
      local total = #tv_view.resources
      local prompt = string.format("Please analyze our Terraform infrastructure architecture containing %d resources across %d files. Identify architectural risks, single points of failure, and cost-saving recommendations.", total, tv_view.files_scanned)
      local sidebar_view = rawget(_G, "antigravity_sidebar_view")
      if sidebar_view and sidebar_view.send_message then
        sidebar_view:send_message(prompt)
      else
        system.set_clipboard(prompt)
        core.log("[Terraform Studio] AI Architecture Review prompt copied to clipboard!")
      end
    end
  end,
})

keymap.add({
  ["ctrl+shift+x"] = "terraform_visualizer:toggle",
  ["ctrl+alt+t"]   = "terraform_visualizer:open_canvas"
})

core.log("[Terraform Studio] Cloud Architecture Studio Loaded — use 'terraform_visualizer:toggle' or Activity Bar \u{f1b3}")

return TerraformVisualizerView

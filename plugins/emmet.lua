-- mod-version:3
-- 
-- Emmet 2.0 Abbreviation Expansion Engine for Lite XL
-- Supports: HTML, JSX, TSX, Vue, Svelte, XML, CSS
-- Features: Multipliers (div*4), Nesting (ul>li*3>a), Siblings (h1+p),
--           Climb-up (div>p^span), Grouping ((header>nav)+footer),
--           Classes (.card), IDs (#hero), Attributes ([type=email required]),
--           Text content ({Submit}), Numbering ($), HTML5 Boilerplate (!, html:5),
--           JSX className adaptation, and CSS property abbreviations.
-- 

local core = require "core"
local common = require "core.common"
local config = require "core.config"
local command = require "core.command"
local keymap = require "core.keymap"
local DocView = require "core.docview"
local autocomplete = pcall(require, "plugins.autocomplete") and require("plugins.autocomplete")
local snippets = pcall(require, "plugins.snippets") and require("plugins.snippets")

local emmet = {}

-- Self-closing void tags
local VOID_TAGS = {
  area = true, base = true, br = true, col = true, embed = true,
  hr = true, img = true, input = true, link = true, meta = true,
  param = true, source = true, track = true, wbr = true
}

-- CSS Abbreviation Map
local CSS_ABBRS = {
  df = "display: flex;$0",
  db = "display: block;$0",
  dib = "display: inline-block;$0",
  di = "display: inline;$0",
  dg = "display: grid;$0",
  dn = "display: none;$0",
  jcc = "justify-content: center;$0",
  jcs = "justify-content: flex-start;$0",
  jce = "justify-content: flex-end;$0",
  jcsb = "justify-content: space-between;$0",
  jcsa = "justify-content: space-around;$0",
  aic = "align-items: center;$0",
  ais = "align-items: flex-start;$0",
  aie = "align-items: flex-end;$0",
  aib = "align-items: baseline;$0",
  fdc = "flex-direction: column;$0",
  fdr = "flex-direction: row;$0",
  fww = "flex-wrap: wrap;$0",
  fwn = "flex-wrap: nowrap;$0",
  flx = "flex: ${1:1};$0",
  g = "gap: ${1:1rem};$0",
  pos = "position: ${1:relative};$0",
  ["pos:a"] = "position: absolute;$0",
  ["pos:r"] = "position: relative;$0",
  ["pos:f"] = "position: fixed;$0",
  ["pos:s"] = "position: sticky;$0",
  t = "top: ${1:0};$0",
  b = "bottom: ${1:0};$0",
  l = "left: ${1:0};$0",
  r = "right: ${1:0};$0",
  z = "z-index: ${1:10};$0",
  w = "width: ${1:100%};$0",
  ["w:a"] = "width: auto;$0",
  h = "height: ${1:100%};$0",
  ["h:a"] = "height: auto;$0",
  maw = "max-width: ${1:100%};$0",
  miw = "min-width: ${1:0};$0",
  mah = "max-height: ${1:100%};$0",
  mih = "min-height: ${1:0};$0",
  m = "margin: ${1:0};$0",
  ["m:a"] = "margin: 0 auto;$0",
  mt = "margin-top: ${1:1rem};$0",
  mb = "margin-bottom: ${1:1rem};$0",
  ml = "margin-left: ${1:1rem};$0",
  mr = "margin-right: ${1:1rem};$0",
  mx = "margin-left: ${1:auto}; margin-right: ${1:auto};$0",
  my = "margin-top: ${1:1rem}; margin-bottom: ${1:1rem};$0",
  p = "padding: ${1:1rem};$0",
  pt = "padding-top: ${1:1rem};$0",
  pb = "padding-bottom: ${1:1rem};$0",
  pl = "padding-left: ${1:1rem};$0",
  pr = "padding-right: ${1:1rem};$0",
  px = "padding-left: ${1:1rem}; padding-right: ${1:1rem};$0",
  py = "padding-top: ${1:1rem}; padding-bottom: ${1:1rem};$0",
  bg = "background: ${1:#fff};$0",
  bgc = "background-color: ${1:#fff};$0",
  bgi = "background-image: url('${1:}');$0",
  bgs = "background-size: ${1:cover};$0",
  bgp = "background-position: ${1:center};$0",
  bgr = "background-repeat: ${1:no-repeat};$0",
  c = "color: ${1:#000};$0",
  op = "opacity: ${1:1};$0",
  bd = "border: ${1:1px solid #e5e7eb};$0",
  bdn = "border: none;$0",
  bdt = "border-top: ${1:1px solid #e5e7eb};$0",
  bdb = "border-bottom: ${1:1px solid #e5e7eb};$0",
  bdl = "border-left: ${1:1px solid #e5e7eb};$0",
  bdr = "border-right: ${1:1px solid #e5e7eb};$0",
  bdrs = "border-radius: ${1:0.5rem};$0",
  bxz = "box-sizing: ${1:border-box};$0",
  bxs = "box-shadow: ${1:0 4px 6px -1px rgba(0, 0, 0, 0.1)};$0",
  cur = "cursor: ${1:pointer};$0",
  ["cur:p"] = "cursor: pointer;$0",
  ["cur:d"] = "cursor: default;$0",
  ["cur:na"] = "cursor: not-allowed;$0",
  ov = "overflow: ${1:hidden};$0",
  ["ov:h"] = "overflow: hidden;$0",
  ["ov:a"] = "overflow: auto;$0",
  ["ov:s"] = "overflow: scroll;$0",
  ff = "font-family: ${1:system-ui, -apple-system, sans-serif};$0",
  fs = "font-size: ${1:1rem};$0",
  fw = "font-weight: ${1:500};$0",
  lh = "line-height: ${1:1.5};$0",
  tac = "text-align: center;$0",
  tal = "text-align: left;$0",
  tar = "text-align: right;$0",
  taj = "text-align: justify;$0",
  tdn = "text-decoration: none;$0",
  tdu = "text-decoration: underline;$0",
  ttu = "text-transform: uppercase;$0",
  ttl = "text-transform: lowercase;$0",
  ttc = "text-transform: capitalize;$0",
  ws = "white-space: ${1:nowrap};$0",
  tr = "transition: all ${1:0.2s ease-in-out};$0",
  anim = "animation: ${1:name} ${2:1s} ${3:ease} ${4:infinite};$0",
  us = "user-select: none;$0",
  pe = "pointer-events: ${1:none};$0"
}

-- Default HTML tag aliases
local TAG_ALIASES = {
  ["!"] = "html5_boilerplate",
  ["html:5"] = "html5_boilerplate",
  ["html:4t"] = "html4_boilerplate",
  ["link:css"] = "link[rel=stylesheet href=\"${1:style.css}\"]",
  ["link:favicon"] = "link[rel=\"shortcut icon\" type=\"image/x-icon\" href=\"${1:favicon.ico}\"]",
  ["script:src"] = "script[src=\"${1:main.js}\"]",
  ["script:module"] = "script[type=module src=\"${1:main.js}\"]",
  ["a:link"] = "a[href=\"${1:http://}\"]",
  ["a:mail"] = "a[href=\"mailto:${1:}\"]",
  ["a:tel"] = "a[href=\"tel:${1:}\"]",
  ["img:s"] = "img[src=\"${1:image.jpg}\" alt=\"${2:}\"]",
  ["form:post"] = "form[action=\"${1:}\" method=post]",
  ["form:get"] = "form[action=\"${1:}\" method=get]",
  ["input:text"] = "input[type=text name=\"${1:}\" id=\"${1:}\"]",
  ["input:password"] = "input[type=password name=\"${1:}\" id=\"${1:}\"]",
  ["input:email"] = "input[type=email name=\"${1:}\" id=\"${1:}\"]",
  ["input:number"] = "input[type=number name=\"${1:}\" id=\"${1:}\"]",
  ["input:checkbox"] = "input[type=checkbox name=\"${1:}\" id=\"${1:}\"]",
  ["input:radio"] = "input[type=radio name=\"${1:}\" id=\"${1:}\"]",
  ["input:submit"] = "input[type=submit value=\"${1:Submit}\"]",
  ["input:button"] = "input[type=button value=\"${1:Button}\"]",
  ["input:file"] = "input[type=file name=\"${1:}\" id=\"${1:}\"]",
  ["btn:s"] = "button[type=submit]{${1:Submit}}",
  ["btn:b"] = "button[type=button]{${1:Button}}",
  ["meta:vp"] = "meta[name=viewport content=\"width=device-width, initial-scale=1.0\"]",
  ["meta:utf"] = "meta[charset=UTF-8]"
}

local function is_jsx_doc(doc)
  if not doc then return false end
  local filename = (doc.filename or doc.new_file or ""):lower()
  if filename:find("%.jsx$") or filename:find("%.tsx$") or filename:find("%.js$") or filename:find("%.ts$") then
    return true
  end
  if doc.syntax and (doc.syntax.name == "JavaScript" or doc.syntax.name == "TypeScript") then
    return true
  end
  return false
end

local function is_css_doc(doc)
  if not doc then return false end
  local filename = (doc.filename or doc.new_file or ""):lower()
  if filename:find("%.css$") or filename:find("%.scss$") or filename:find("%.less$") or filename:find("%.sass$") then
    return true
  end
  if doc.syntax and (doc.syntax.name == "CSS" or doc.syntax.name == "SCSS" or doc.syntax.name == "Sass") then
    return true
  end
  return false
end

local function is_web_doc(doc)
  if not doc then return false end
  local filename = (doc.filename or doc.new_file or ""):lower()
  if filename:find("%.html$") or filename:find("%.htm$") or filename:find("%.jsx$") or filename:find("%.tsx$")
     or filename:find("%.vue$") or filename:find("%.svelte$") or filename:find("%.php$") or filename:find("%.xml$")
     or filename:find("%.js$") or filename:find("%.ts$") then
    return true
  end
  if doc.syntax and (doc.syntax.name == "HTML" or doc.syntax.name == "XML" or doc.syntax.name == "PHP") then
    return true
  end
  return false
end

-- ============================================================================
-- HTML / JSX EMMET PARSER & COMPILER
-- ============================================================================

local function parse_single_node(str, index_num, is_jsx)
  -- Parse node tokens: tag, #id, .classes, [attributes], {text}, *multiplier
  local node = {
    tag = "div",
    id = nil,
    classes = {},
    attributes = {},
    text = nil,
    count = 1
  }

  -- Text content extraction { ... }
  local text_content = str:match("{(.-)}")
  if text_content then
    str = str:gsub("{.-}", "")
    -- Replace $ with index_num
    node.text = text_content:gsub("%$", tostring(index_num or 1))
  end

  -- Attributes extraction [ ... ]
  local attr_str = str:match("%[(.-)%]")
  if attr_str then
    str = str:gsub("%[.-%]", "")
    for k, v in attr_str:gmatch('([%w_%-%:]+)=["\']?(.-)["\']?%s+') do
      node.attributes[k] = v:gsub("%$", tostring(index_num or 1))
    end
    for k, v in attr_str:gmatch('([%w_%-%:]+)=["\']?([^%s"\']+)["\']?$') do
      node.attributes[k] = v:gsub("%$", tostring(index_num or 1))
    end
    for k in attr_str:gmatch('([%w_%-%:]+)%s*') do
      if not node.attributes[k] and not k:find("=") then
        node.attributes[k] = true
      end
    end
  end

  -- Tag extraction
  local tag = str:match("^([%w_%-]+)")
  if tag then
    node.tag = tag
    str = str:sub(#tag + 1)
  end

  -- ID extraction
  local id = str:match("#([%w_%-%$]+)")
  if id then
    node.id = id:gsub("%$", tostring(index_num or 1))
  end

  -- Classes extraction
  for cls in str:gmatch("%.([%w_%-%$]+)") do
    table.insert(node.classes, cls:gsub("%$", tostring(index_num or 1)))
  end

  return node
end

local function render_node(node, is_jsx, indent_level, indent_str, inner_content)
  local tag = node.tag or "div"
  local class_attr_name = is_jsx and "className" or "class"
  local for_attr_name = is_jsx and "htmlFor" or "for"

  local attrs = {}

  if node.id then
    table.insert(attrs, string.format('id="%s"', node.id))
  end

  if #node.classes > 0 then
    table.insert(attrs, string.format('%s="%s"', class_attr_name, table.concat(node.classes, " ")))
  end

  -- Common default attributes
  if tag == "a" and not node.attributes["href"] then
    table.insert(attrs, 'href="${1:#}"')
  elseif tag == "img" and not node.attributes["src"] then
    table.insert(attrs, 'src="${1:}" alt="${2:}"')
  elseif tag == "input" and not node.attributes["type"] then
    table.insert(attrs, 'type="text"')
  elseif tag == "link" and not node.attributes["rel"] then
    table.insert(attrs, 'rel="stylesheet" href="${1:style.css}"')
  elseif tag == "script" and not node.attributes["src"] and not inner_content then
    table.insert(attrs, 'src="${1:main.js}"')
  end

  for k, v in pairs(node.attributes) do
    local actual_k = k
    if is_jsx then
      if k == "class" then actual_k = "className" end
      if k == "for" then actual_k = "htmlFor" end
    end
    if v == true then
      table.insert(attrs, actual_k)
    else
      table.insert(attrs, string.format('%s="%s"', actual_k, tostring(v)))
    end
  end

  local attr_formatted = #attrs > 0 and (" " .. table.concat(attrs, " ")) or ""
  local current_indent = string.rep(indent_str, indent_level)
  local child_indent = string.rep(indent_str, indent_level + 1)

  if VOID_TAGS[tag:lower()] then
    if is_jsx then
      return string.format("%s<%s%s />", current_indent, tag, attr_formatted)
    else
      return string.format("%s<%s%s>", current_indent, tag, attr_formatted)
    end
  end

  if inner_content and #inner_content > 0 then
    return string.format("%s<%s%s>\n%s\n%s</%s>", current_indent, tag, attr_formatted, inner_content, current_indent, tag)
  elseif node.text then
    return string.format("%s<%s%s>%s</%s>", current_indent, tag, attr_formatted, node.text, tag)
  else
    return string.format("%s<%s%s>${0}</%s>", current_indent, tag, attr_formatted, tag)
  end
end

-- Recursive AST builder for Emmet expressions: div>ul>li*3>a
local function expand_emmet_tree(expr, is_jsx, indent_str)
  indent_str = indent_str or "  "

  -- Check special alias
  if TAG_ALIASES[expr] then
    local alias = TAG_ALIASES[expr]
    if alias == "html5_boilerplate" then
      return "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n  <meta charset=\"UTF-8\">\n  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n  <title>${1:Document}</title>\n</head>\n<body>\n  ${0}\n</body>\n</html>"
    elseif alias == "html4_boilerplate" then
      return "<!DOCTYPE HTML PUBLIC \"-//W3C//DTD HTML 4.01 Transitional//EN\" \"http://www.w3.org/TR/html4/loose.dtd\">\n<html lang=\"en\">\n<head>\n  <meta http-equiv=\"Content-Type\" content=\"text/html;charset=UTF-8\">\n  <title>${1:Document}</title>\n</head>\n<body>\n  ${0}\n</body>\n</html>"
    else
      expr = alias
    end
  end

  -- Handle multiplication at top level or within siblings
  -- Split by sibling '+'
  local function parse_group(group_str, indent_level)
    local out_lines = {}
    
    -- Split by child '>'
    local parts = {}
    local depth = 0
    local cur = ""
    for i = 1, #group_str do
      local c = group_str:sub(i, i)
      if c == "(" or c == "{" or c == "[" then
        depth = depth + 1
        cur = cur .. c
      elseif c == ")" or c == "}" or c == "]" then
        depth = math.max(0, depth - 1)
        cur = cur .. c
      elseif c == ">" and depth == 0 then
        table.insert(parts, cur)
        cur = ""
      else
        cur = cur .. c
      end
    end
    if #cur > 0 then table.insert(parts, cur) end

    -- Build from innermost child backwards
    local function compile_level(idx, mult_index)
      if idx > #parts then return nil end
      local part = parts[idx]

      -- Check if this part has sibling +
      local sibs = {}
      local sdepth = 0
      local scur = ""
      for i = 1, #part do
        local c = part:sub(i, i)
        if c == "(" or c == "{" or c == "[" then
          sdepth = sdepth + 1
          scur = scur .. c
        elseif c == ")" or c == "}" or c == "]" then
          sdepth = math.max(0, sdepth - 1)
          scur = scur .. c
        elseif c == "+" and sdepth == 0 then
          table.insert(sibs, scur)
          scur = ""
        else
          scur = scur .. c
        end
      end
      if #scur > 0 then table.insert(sibs, scur) end

      local sib_rendered = {}
      for _, sib in ipairs(sibs) do
        -- Check group ( ... )
        local inner_group = sib:match("^%((.+)%)$")
        if inner_group then
          local grp_res = parse_group(inner_group, indent_level + (idx - 1))
          table.insert(sib_rendered, grp_res)
        else
          -- Check multiplier *N
          local node_expr, count_str = sib:match("^(.-)%*(%d+)$")
          local count = tonumber(count_str) or 1
          node_expr = node_expr or sib

          for k = 1, count do
            local node = parse_single_node(node_expr, k, is_jsx)
            local child_res = compile_level(idx + 1, k)
            local res = render_node(node, is_jsx, indent_level + (idx - 1), indent_str, child_res)
            table.insert(sib_rendered, res)
          end
        end
      end

      return table.concat(sib_rendered, "\n")
    end

    return compile_level(1, 1)
  end

  return parse_group(expr, 0)
end

-- ============================================================================
-- CSS ABBREVIATION PARSER
-- ============================================================================

local function expand_css_abbreviation(abbr)
  if CSS_ABBRS[abbr] then
    return CSS_ABBRS[abbr]
  end

  -- Numbered properties like p10 -> padding: 10px; m10-20 -> margin: 10px 20px;
  local prop, val = abbr:match("^([a-z]+)(%-?%d+.*)$")
  if prop and val then
    local css_prop = nil
    if prop == "p" then css_prop = "padding"
    elseif prop == "pt" then css_prop = "padding-top"
    elseif prop == "pb" then css_prop = "padding-bottom"
    elseif prop == "pl" then css_prop = "padding-left"
    elseif prop == "pr" then css_prop = "padding-right"
    elseif prop == "m" then css_prop = "margin"
    elseif prop == "mt" then css_prop = "margin-top"
    elseif prop == "mb" then css_prop = "margin-bottom"
    elseif prop == "ml" then css_prop = "margin-left"
    elseif prop == "mr" then css_prop = "margin-right"
    elseif prop == "w" then css_prop = "width"
    elseif prop == "h" then css_prop = "height"
    elseif prop == "fs" then css_prop = "font-size"
    elseif prop == "lh" then css_prop = "line-height"
    elseif prop == "z" then css_prop = "z-index"
    elseif prop == "op" then css_prop = "opacity"
    elseif prop == "bdrs" then css_prop = "border-radius"
    elseif prop == "g" then css_prop = "gap"
    end

    if css_prop then
      -- Format val (e.g. 10 -> 10px, 10p -> 10%, 10-20 -> 10px 20px)
      local parts = {}
      for chunk in val:gmatch("([^%-]+)") do
        if chunk:match("^%d+$") then
          table.insert(parts, chunk .. "px")
        elseif chunk:match("^(%d+)p$") then
          table.insert(parts, chunk:gsub("p$", "%%"))
        elseif chunk:match("^(%d+)rem$") or chunk:match("^(%d+)em$") or chunk:match("^(%d+)vh$") or chunk:match("^(%d+)vw$") then
          table.insert(parts, chunk)
        else
          table.insert(parts, chunk)
        end
      end
      return string.format("%s: %s;$0", css_prop, table.concat(parts, " "))
    end
  end

  return nil
end

-- ============================================================================
-- MAIN EMMET EXPANSION API
-- ============================================================================

function emmet.expand(expr, doc)
  if not expr or #expr == 0 then return nil end

  if is_css_doc(doc) then
    return expand_css_abbreviation(expr)
  end

  local is_jsx = is_jsx_doc(doc)
  local indent_str = config.indent_type == "tabs" and "\t" or string.rep(" ", config.indent_size or 2)
  return expand_emmet_tree(expr, is_jsx, indent_str)
end

-- Check if current text before cursor is a valid Emmet candidate
local function get_emmet_candidate(doc)
  local line, col = doc:get_selection()
  local line_text = doc.lines[line] or ""
  local before_cursor = line_text:sub(1, col - 1)

  -- Match Emmet expression before cursor
  local candidate = before_cursor:match("([%w_%-%+%>%*%^%.%#%[%]%{%=%}%:\"%!%$]+)$")
  if candidate and #candidate > 0 then
    -- Avoid matching plain keywords unless it's ! or contains emmet operators
    if candidate == "!" or candidate == "html:5" or candidate:find("[%*%>%+%.%#%[%]{}%:]") then
      return candidate, col - #candidate, col
    end
    -- In HTML/Web/CSS, single tags or CSS shortcodes are also candidates
    if is_css_doc(doc) and CSS_ABBRS[candidate] then
      return candidate, col - #candidate, col
    end
  end
  return nil
end

-- ============================================================================
-- COMMANDS & KEYMAP
-- ============================================================================

local function emmet_predicate(dv)
  if not dv or not dv:is(DocView) or not dv.doc then return false end
  local candidate = get_emmet_candidate(dv.doc)
  return candidate ~= nil
end

command.add(emmet_predicate, {
  ["emmet:expand-abbreviation"] = function(dv)
    local doc = dv.doc
    local candidate, col1, col2 = get_emmet_candidate(doc)
    if candidate then
      local expanded = emmet.expand(candidate, doc)
      if expanded then
        local line = doc:get_selection()
        doc:remove(line, col1, line, col2)
        if snippets and snippets.add then
          local snip_id = snippets.add {
            format = "lsp",
            template = expanded
          }
          if snip_id then
            snippets.execute(snip_id, doc, false)
          else
            doc:text_input(expanded:gsub("%$%d", ""):gsub("%${%d:.-}", ""))
          end
        else
          doc:text_input(expanded:gsub("%$%d", ""):gsub("%${%d:.-}", ""))
        end
        return true
      end
    end
    return false
  end
})

keymap.add {
  ["tab"] = "emmet:expand-abbreviation"
}

-- Register Emmet Snippet Provider with Autocomplete
if autocomplete then
  local web_files = { "%.html$", "%.htm$", "%.jsx$", "%.tsx$", "%.vue$", "%.svelte$", "%.php$", "%.xml$", "%.js$", "%.ts$", "%.css$", "%.scss$" }
  
  local emmet_previews = {
    ["!"] = { desc = "HTML5 Boilerplate\n\nGenerates full HTML5 document structure with viewport and meta tags." },
    ["html:5"] = { desc = "HTML5 Boilerplate\n\nGenerates full HTML5 document structure with viewport and meta tags." },
    ["link:css"] = { desc = "Link CSS Stylesheet\n<link rel=\"stylesheet\" href=\"style.css\">" },
    ["script:src"] = { desc = "Script tag with source\n<script src=\"main.js\"></script>" },
    ["a:link"] = { desc = "Hyperlink tag\n<a href=\"http://\">...</a>" },
    ["form:post"] = { desc = "Form tag with POST method\n<form action=\"\" method=\"post\">...</form>" },
    ["input:text"] = { desc = "Text Input\n<input type=\"text\" name=\"\" id=\"\">" },
    ["input:password"] = { desc = "Password Input\n<input type=\"password\" name=\"\" id=\"\">" },
    ["input:email"] = { desc = "Email Input\n<input type=\"email\" name=\"\" id=\"\">" },
    ["input:checkbox"] = { desc = "Checkbox Input\n<input type=\"checkbox\" name=\"\" id=\"\">" },
    ["btn:s"] = { desc = "Submit Button\n<button type=\"submit\">Submit</button>" }
  }

  local ac_items = {}
  for trig, info in pairs(emmet_previews) do
    ac_items[trig] = {
      info = "Emmet",
      desc = info.desc,
      onselect = function()
        command.perform("emmet:expand-abbreviation")
        return true
      end
    }
  end

  autocomplete.add {
    name = "emmet-previews",
    files = web_files,
    items = ac_items
  }
end

return emmet

-- mod-version:3
-- Formatted, Adaptive Empty File Placeholder Guide for Lite XL
-- Displays a beautiful, theme-adaptive contextual watermark/help card
-- in empty files specific to the language/tech stack, disappearing as soon
-- as the user types a single character.

local core = require "core"
local common = require "core.common"
local style = require "core.style"
local DocView = require "core.docview"

local STACK_GUIDES = {
  -- HTML & Web
  html = {
    title = "HTML5 & Web Architecture",
    badge = "HTML5 / Web",
    desc = "Modern web document. Supports Emmet abbreviations and HTML5 boilerplates.",
    snippets = {
      { key = "! [Tab]", desc = "HTML5 Boilerplate with viewport & meta" },
      { key = "div*4 [Tab]", desc = "Generate 4 container div elements" },
      { key = "ul>li*3>a [Tab]", desc = "Generate nested navigation list" },
      { key = "link:css [Tab]", desc = "Link external stylesheet" },
      { key = "script:src [Tab]", desc = "Include JavaScript module" },
      { key = "form:post [Tab]", desc = "Form container with POST method" },
    },
    shortcuts = {
      { key = "Ctrl+P", desc = "Quick open project files" },
      { key = "Alt+L", desc = "Toggle LSP syntax servers" },
      { key = "Ctrl+Shift+P", desc = "Open Command Palette" },
    }
  },

  -- React & Next.js / TypeScript
  react = {
    title = "React & Next.js Ecosystem",
    badge = "React / Next.js / TS",
    desc = "Full-stack React environment with automatic component name inference.",
    snippets = {
      { key = "rfce [Tab]", desc = "React Functional Component (Default Export)" },
      { key = "rafce [Tab]", desc = "React Arrow Component (Default Export)" },
      { key = "tsrfce [Tab]", desc = "TypeScript React Component with Props" },
      { key = "useState [Tab]", desc = "useState Hook with setter synchronization" },
      { key = "useEffect [Tab]", desc = "useEffect Hook with dependency array" },
      { key = "nextpage [Tab]", desc = "Next.js 14 App Router Page Component" },
      { key = "nextapi [Tab]", desc = "Next.js Route Handler (GET / POST)" },
      { key = "bg-slate-900 [Tab]", desc = "Tailwind CSS Utility & Color Swatch" },
    },
    shortcuts = {
      { key = "Shift+Alt+F", desc = "Format document code" },
      { key = "Ctrl+`", desc = "Toggle integrated terminal" },
      { key = "Alt+L", desc = "Toggle TypeScript LSP Server" },
    }
  },

  -- Vue 3
  vue = {
    title = "Vue 3 Composition API",
    badge = "Vue 3 SFC",
    desc = "Single File Component with <script setup> and Composition API.",
    snippets = {
      { key = "vbase [Tab]", desc = "Vue 3 SFC boilerplate (<script setup lang='ts'>)" },
      { key = "vref [Tab]", desc = "Reactive state variable (ref)" },
      { key = "vreactive [Tab]", desc = "Reactive state object (reactive)" },
      { key = "vcomputed [Tab]", desc = "Computed property with getter" },
      { key = "vfor [Tab]", desc = "v-for loop directive with index key" },
      { key = "vmodel [Tab]", desc = "Two-way data binding (v-model)" },
    },
    shortcuts = {
      { key = "Shift+Alt+F", desc = "Format Vue SFC" },
      { key = "Alt+L", desc = "Toggle Volar / TypeScript LSP" },
      { key = "Ctrl+P", desc = "Quick open component files" },
    }
  },

  -- Svelte
  svelte = {
    title = "Svelte Component",
    badge = "Svelte",
    desc = "Reactive Svelte component with typescript support.",
    snippets = {
      { key = "svbase [Tab]", desc = "Svelte boilerplate with props and styles" },
      { key = "onMount [Tab]", desc = "onMount lifecycle hook" },
      { key = "createEventDispatcher [Tab]", desc = "Component event dispatcher" },
    },
    shortcuts = {
      { key = "Shift+Alt+F", desc = "Format Svelte component" },
      { key = "Alt+L", desc = "Toggle Svelte LSP Server" },
      { key = "Ctrl+P", desc = "Quick open file" },
    }
  },

  -- Python
  python = {
    title = "Python Engineering & Microservices",
    badge = "Python / FastAPI / Django",
    desc = "Python environment with FastAPI, Flask, and Django snippets.",
    snippets = {
      { key = "fapi [Tab]", desc = "FastAPI Application Server boilerplate" },
      { key = "djmodel [Tab]", desc = "Django ORM Model definition" },
      { key = "pydantic [Tab]", desc = "Pydantic BaseModel schema" },
      { key = "def [Tab]", desc = "Function definition with typed parameters" },
      { key = "class [Tab]", desc = "Class definition with constructor" },
      { key = "ifmain [Tab]", desc = "if __name__ == '__main__': entrypoint" },
      { key = "trycatch [Tab]", desc = "try-except-finally error handler" },
    },
    shortcuts = {
      { key = "Shift+Alt+F", desc = "Format with Black / autopep8" },
      { key = "Alt+L", desc = "Toggle Pyright / LSP Server" },
      { key = "Ctrl+`", desc = "Run in Python REPL / Terminal" },
    }
  },

  -- Go
  go = {
    title = "Go Systems & Cloud Services",
    badge = "Go / Gin / Fiber",
    desc = "High-performance Go environment with Gin, Fiber, and concurrency tools.",
    snippets = {
      { key = "main [Tab]", desc = "package main with func main() entry" },
      { key = "gin-app [Tab]", desc = "Gin Web Server boilerplate with JSON routes" },
      { key = "fiber-app [Tab]", desc = "Fiber Web Server boilerplate" },
      { key = "iferr [Tab]", desc = "if err != nil error return check" },
      { key = "struct [Tab]", desc = "Struct definition with JSON tags" },
      { key = "forr [Tab]", desc = "for range iteration loop" },
      { key = "go [Tab]", desc = "Anonymous concurrent goroutine" },
    },
    shortcuts = {
      { key = "Shift+Alt+F", desc = "Format code with gofmt" },
      { key = "Alt+L", desc = "Toggle gopls LSP Server" },
      { key = "Ctrl+Shift+R", desc = "Restart Lite-XL workspace" },
    }
  },

  -- Rust
  rust = {
    title = "Rust Native & Systems Programming",
    badge = "Rust / Axum",
    desc = "Memory-safe Rust environment with Axum, Actix, and Tokio async snippets.",
    snippets = {
      { key = "fnmain [Tab]", desc = "fn main() { println!... } entrypoint" },
      { key = "axum-app [Tab]", desc = "Axum Web Server with Tokio runtime" },
      { key = "struct [Tab]", desc = "pub struct with serde derive macros" },
      { key = "impl [Tab]", desc = "impl Type block with constructor" },
      { key = "match [Tab]", desc = "match Result/Option expression" },
      { key = "test [Tab]", desc = "#[test] unit test function" },
    },
    shortcuts = {
      { key = "Shift+Alt+F", desc = "Format with rustfmt" },
      { key = "Alt+L", desc = "Toggle rust-analyzer LSP" },
      { key = "Ctrl+`", desc = "Cargo build / test in terminal" },
    }
  },

  -- Java & Spring Boot
  java = {
    title = "Java & Spring Boot Framework",
    badge = "Java / Spring Boot",
    desc = "Enterprise Java suite with JPA, REST Controllers, and Services.",
    snippets = {
      { key = "psvm [Tab]", desc = "public static void main entrypoint" },
      { key = "sbcontroller [Tab]", desc = "Spring Boot @RestController with endpoints" },
      { key = "sbservice [Tab]", desc = "Spring Boot @Service class" },
      { key = "sbrepo [Tab]", desc = "Spring Data JPA @Repository interface" },
      { key = "sbentity [Tab]", desc = "JPA @Entity with ID and table mapping" },
      { key = "sout [Tab]", desc = "System.out.println() logger" },
    },
    shortcuts = {
      { key = "Shift+Alt+F", desc = "Format Java document" },
      { key = "Alt+L", desc = "Toggle Eclipse JDT.LS Server" },
      { key = "Ctrl+P", desc = "Quick open Java classes" },
    }
  },

  -- C / C++
  cpp = {
    title = "C / C++ Systems Engineering",
    badge = "C / C++",
    desc = "C/C++ environment with header guards, memory structs, and classes.",
    snippets = {
      { key = "main [Tab]", desc = "int main(int argc, char *argv[]) entry" },
      { key = "inc [Tab]", desc = "#include <header.h> system include" },
      { key = "guard [Tab]", desc = "#ifndef HEADER_H include guard" },
      { key = "class [Tab]", desc = "C++ class with constructor and destructor" },
      { key = "struct [Tab]", desc = "C typedef struct definition" },
      { key = "cout [Tab]", desc = "std::cout << message << std::endl;" },
    },
    shortcuts = {
      { key = "Shift+Alt+F", desc = "Format with clang-format" },
      { key = "Alt+L", desc = "Toggle Clangd LSP Server" },
      { key = "Ctrl+`", desc = "Compile / Run in terminal" },
    }
  },

  -- SQL
  sql = {
    title = "SQL Database & Queries",
    badge = "SQL / Database",
    desc = "Relational database queries, schemas, and indexing.",
    snippets = {
      { key = "select [Tab]", desc = "SELECT * FROM table WHERE condition" },
      { key = "insert [Tab]", desc = "INSERT INTO table VALUES (...)" },
      { key = "update [Tab]", desc = "UPDATE table SET col = val WHERE condition" },
      { key = "create-table [Tab]", desc = "CREATE TABLE DDL schema" },
      { key = "join [Tab]", desc = "INNER JOIN two tables on primary keys" },
    },
    shortcuts = {
      { key = "Ctrl+Shift+P", desc = "Open Command Palette" },
      { key = "Ctrl+P", desc = "Quick open SQL migrations" },
    }
  },

  -- DevOps (Docker & K8s)
  devops = {
    title = "DevOps & Cloud Infrastructure",
    badge = "Docker / K8s / YAML",
    desc = "Containerization, orchestration, and CI/CD pipelines.",
    snippets = {
      { key = "docker-node [Tab]", desc = "Production Node.js Multi-Stage Dockerfile" },
      { key = "docker-python [Tab]", desc = "Production Python Fast-Slim Dockerfile" },
      { key = "docker-go [Tab]", desc = "Go Alpine Multi-Stage Dockerfile" },
      { key = "compose-web-db [Tab]", desc = "Docker Compose (App + PostgreSQL)" },
      { key = "k8s-dep [Tab]", desc = "Kubernetes Deployment configuration" },
      { key = "k8s-svc [Tab]", desc = "Kubernetes ClusterIP Service" },
      { key = "gha-ci [Tab]", desc = "GitHub Actions CI workflow" },
    },
    shortcuts = {
      { key = "Shift+Alt+F", desc = "Format YAML document" },
      { key = "Ctrl+`", desc = "Run docker / kubectl in terminal" },
    }
  },

  -- Default / Generic
  generic = {
    title = "Lite-XL Code Editor",
    badge = "Editor Workspace",
    desc = "High-performance lightweight code editor. Type anywhere to start.",
    snippets = {
      { key = "Ctrl+P", desc = "Quick Open File in Workspace" },
      { key = "Ctrl+Shift+P", desc = "Command Palette (Run any command)" },
      { key = "Alt+L", desc = "Toggle Language Server (LSP) On/Off" },
      { key = "Ctrl+`", desc = "Toggle Integrated Terminal" },
      { key = "Ctrl+B", desc = "Toggle File Explorer Sidebar" },
      { key = "Alt+P", desc = "Open PDF Reader View" },
    },
    shortcuts = {
      { key = "Ctrl+S", desc = "Save active document" },
      { key = "Ctrl+Z", desc = "Undo edit" },
      { key = "Ctrl+Y", desc = "Redo edit" },
    }
  }
}

local function get_stack_for_doc(doc)
  if not doc then return STACK_GUIDES.generic end
  local fn = (doc.filename or doc.abs_filename or doc.new_file or ""):lower()
  local sname = (doc.syntax and doc.syntax.name or ""):lower()

  if fn:find("%.html?$") or sname:find("html") then
    return STACK_GUIDES.html
  elseif fn:find("%.[jt]sx$") or fn:find("%.[jt]s$") or fn:find("%.mjs$") or sname:find("javascript") or sname:find("typescript") then
    return STACK_GUIDES.react
  elseif fn:find("%.vue$") or sname:find("vue") then
    return STACK_GUIDES.vue
  elseif fn:find("%.svelte$") or sname:find("svelte") then
    return STACK_GUIDES.svelte
  elseif fn:find("%.pyw?$") or sname:find("python") then
    return STACK_GUIDES.python
  elseif fn:find("%.go$") or sname:find("go") then
    return STACK_GUIDES.go
  elseif fn:find("%.rs$") or sname:find("rust") then
    return STACK_GUIDES.rust
  elseif fn:find("%.java$") or sname:find("java") then
    return STACK_GUIDES.java
  elseif fn:find("%.c$") or fn:find("%.cpp$") or fn:find("%.cc$") or fn:find("%.h$") or fn:find("%.hpp$") or sname:find("c%+%+") or sname:find("c") then
    return STACK_GUIDES.cpp
  elseif fn:find("%.sql$") or sname:find("sql") then
    return STACK_GUIDES.sql
  elseif fn:find("dockerfile") or fn:find("%.ya?ml$") or sname:find("yaml") or sname:find("docker") then
    return STACK_GUIDES.devops
  end

  return STACK_GUIDES.generic
end

local function is_doc_empty(doc)
  if not doc or not doc.lines then return false end
  if #doc.lines > 1 then return false end
  local l = doc.lines[1]
  return l == nil or l == "" or l == "\n" or l == "\r\n"
end

local function is_leetcode_doc(doc)
  if not doc then return false end
  if doc.is_leetcode then return true end
  local fn = (doc.filename or doc.abs_filename or ""):lower()
  if fn:find("leetcode") or fn:find("interview_prep") then
    return true
  end
  return false
end

local function get_theme_palette()
  local bg = style.background or { 30, 30, 30 }
  local lum = 0.299 * (bg[1] or 0) + 0.587 * (bg[2] or 0) + 0.114 * (bg[3] or 0)
  local is_dark = lum < 128

  if is_dark then
    return {
      card_bg      = { math.max(0, bg[1] - 4), math.max(0, bg[2] - 4), math.max(0, bg[3] - 4), 220 },
      border_col   = { 255, 255, 255, 25 },
      badge_bg     = { (style.accent and style.accent[1] or 104), (style.accent and style.accent[2] or 193), (style.accent and style.accent[3] or 113), 35 },
      badge_text   = style.accent or { 140, 215, 160 },
      title_col    = { 235, 245, 240, 220 },
      desc_col     = { 160, 180, 170, 150 },
      sec_hdr_col  = style.accent or { 130, 205, 150 },
      key_bg       = { 255, 255, 255, 22 },
      key_border   = { 255, 255, 255, 45 },
      key_text     = { 245, 250, 245, 230 },
      label_col    = { 200, 215, 205, 160 },
      hint_col     = { 140, 160, 150, 130 },
      divider_col  = { 255, 255, 255, 18 }
    }
  else
    -- Light Theme
    return {
      card_bg      = { math.min(255, bg[1] + 6), math.min(255, bg[2] + 6), math.min(255, bg[3] + 6), 230 },
      border_col   = { 0, 0, 0, 25 },
      badge_bg     = { (style.accent and style.accent[1] or 60), (style.accent and style.accent[2] or 130), (style.accent and style.accent[3] or 90), 30 },
      badge_text   = style.accent or { 40, 110, 70 },
      title_col    = { 40, 55, 45, 230 },
      desc_col     = { 90, 110, 100, 180 },
      sec_hdr_col  = style.accent or { 45, 115, 75 },
      key_bg       = { 0, 0, 0, 14 },
      key_border   = { 0, 0, 0, 35 },
      key_text     = { 30, 45, 35, 240 },
      label_col    = { 65, 80, 70, 190 },
      hint_col     = { 110, 130, 120, 150 },
      divider_col  = { 0, 0, 0, 18 }
    }
  end
end

local function draw_rounded_pill(x, y, w, h, bg, border, text_font, text, text_col)
  renderer.draw_rect(x, y, w, h, bg)
  if border then
    renderer.draw_rect(x, y, w, 1, border)
    renderer.draw_rect(x, y + h - 1, w, 1, border)
    renderer.draw_rect(x, y, 1, h, border)
    renderer.draw_rect(x + w - 1, y, 1, h, border)
  end
  if text and text_font and text_col then
    common.draw_text(text_font, text_col, text, "center", x, y, w, h)
  end
end

local function draw_empty_placeholder_guide(dv)
  if not dv or not dv.doc or not is_doc_empty(dv.doc) or is_leetcode_doc(dv.doc) then
    return
  end

  local p = get_theme_palette()
  local guide = get_stack_for_doc(dv.doc)

  local vx, vy, vw, vh = dv.position.x, dv.position.y, dv.size.x, dv.size.y
  local font = style.font
  local big_font = style.big_font or font
  local code_font = style.code_font or font

  local card_w = math.min(vw - 60 * SCALE, 680 * SCALE)
  local card_x = vx + math.floor((vw - card_w) / 2)
  local card_y = vy + math.max(30 * SCALE, math.floor((vh - 460 * SCALE) / 2))

  local pad_x = 24 * SCALE
  local pad_y = 20 * SCALE
  local cur_y = card_y + pad_y

  -- Calculate card height dynamically
  local snippet_count = #(guide.snippets or {})
  local row_h = math.floor(font:get_height() + 8 * SCALE)
  local content_h = pad_y * 2 + 80 * SCALE + (snippet_count * row_h) + 40 * SCALE
  local card_h = math.min(vh - 40 * SCALE, content_h)

  -- Draw Card Background with Drop Border
  renderer.draw_rect(card_x - 1, card_y - 1, card_w + 2, card_h + 2, p.border_col)
  renderer.draw_rect(card_x, card_y, card_w, card_h, p.card_bg)

  -- Left Accent Bar
  renderer.draw_rect(card_x, card_y, 4 * SCALE, card_h, p.badge_text)

  -- 1. Header: Badge & Title
  local badge_str = " " .. (guide.badge or "Editor") .. " "
  local badge_w = font:get_width(badge_str) + 12 * SCALE
  local badge_h = math.floor(font:get_height() + 4 * SCALE)
  draw_rounded_pill(card_x + pad_x, cur_y, badge_w, badge_h, p.badge_bg, p.border_col, font, badge_str, p.badge_text)

  local title_x = card_x + pad_x + badge_w + 12 * SCALE
  common.draw_text(big_font, p.title_col, guide.title or "Workspace", "left", title_x, cur_y - 2 * SCALE, card_w - (title_x - card_x) - pad_x, badge_h)
  cur_y = cur_y + badge_h + 8 * SCALE

  -- 2. Subtitle / Description
  common.draw_text(font, p.desc_col, guide.desc or "", "left", card_x + pad_x, cur_y, card_w - pad_x * 2, font:get_height())
  cur_y = cur_y + font:get_height() + 14 * SCALE

  -- Divider Line
  renderer.draw_rect(card_x + pad_x, cur_y, card_w - pad_x * 2, 1, p.divider_col)
  cur_y = cur_y + 12 * SCALE

  -- 3. Snippets & Quick Triggers
  common.draw_text(font, p.sec_hdr_col, "AVAILABLE SNIPPETS & SHORTCUTS", "left", card_x + pad_x, cur_y, card_w - pad_x * 2, font:get_height())
  cur_y = cur_y + font:get_height() + 10 * SCALE

  for _, item in ipairs(guide.snippets or {}) do
    if cur_y + row_h > card_y + card_h - 32 * SCALE then break end
    
    local key_text = " " .. item.key .. " "
    local kw = code_font:get_width(key_text) + 10 * SCALE
    local kh = math.floor(code_font:get_height() + 4 * SCALE)
    local k_y = cur_y + math.floor((row_h - kh) / 2)

    draw_rounded_pill(card_x + pad_x, k_y, kw, kh, p.key_bg, p.key_border, code_font, key_text, p.key_text)

    local desc_x = card_x + pad_x + kw + 14 * SCALE
    local desc_w = card_w - (desc_x - card_x) - pad_x
    common.draw_text(font, p.label_col, item.desc, "left", desc_x, cur_y, desc_w, row_h)

    cur_y = cur_y + row_h
  end

  -- 4. Footer Hint
  local hint_str = "✦ Start typing or press [Tab] to dismiss this guide..."
  local footer_y = card_y + card_h - font:get_height() - 12 * SCALE
  common.draw_text(font, p.hint_col, hint_str, "center", card_x, footer_y, card_w, font:get_height())
end

-- Hook into DocView Drawing
local orig_docview_draw = DocView.draw
function DocView:draw(...)
  orig_docview_draw(self, ...)
  local ok, err = pcall(draw_empty_placeholder_guide, self)
  if not ok and err then
    -- Fail gracefully without crashing editor
  end
end

return {
  guides = STACK_GUIDES
}

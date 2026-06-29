-- mod-version:3
-- ~/.config/lite-xl/plugins/mossy_icons.lua
-- Centralised icon registry. Requires a Nerd Font installed as a terminal/system font.
-- Install Fira Code Nerd Font from: https://github.com/ryanoasis/nerd-fonts

local M = {}

-- File extension → Nerd Font glyph (Unicode)
M.ext = {
  -- Go
  go      = "\u{e627} ",
  mod     = "\u{e6ad} ",
  -- Web
  html    = "\u{e736} ",
  css     = "\u{e749} ",
  js      = "\u{e74e} ",
  ts      = "\u{e628} ",
  jsx     = "\u{e7ba} ",
  tsx     = "\u{e7ba} ",
  json    = "\u{e60b} ",
  yaml    = "\u{e615} ",
  toml    = "\u{e615} ",
  xml     = "\u{e619} ",
  -- Scripting
  lua     = "\u{e620} ",
  py      = "\u{e606} ",
  rb      = "\u{e739} ",
  sh      = "\u{e795} ",
  bash    = "\u{e795} ",
  zsh     = "\u{e795} ",
  fish    = "\u{e795} ",
  -- Systems
  c       = "\u{e61e} ",
  cpp     = "\u{e61d} ",
  h       = "\u{e61e} ",
  hpp     = "\u{e61d} ",
  rs      = "\u{e7a8} ",
  java    = "\u{e738} ",
  kt      = "\u{e634} ",
  swift   = "\u{e755} ",
  -- Data
  sql     = "\u{e706} ",
  csv     = "\u{f1c0} ",
  -- Docs
  md      = "\u{e73e} ",
  txt     = "\u{f15c} ",
  pdf     = "\u{f1c1} ",
  -- Config / DevOps
  env     = "\u{f462} ",
  lock    = "\u{f023} ",
  -- Images
  png     = "\u{f1c5} ",
  jpg     = "\u{f1c5} ",
  jpeg    = "\u{f1c5} ",
  svg     = "\u{f1c5} ",
  gif     = "\u{f1c5} ",
  ico     = "\u{f1c5} ",
  -- Archives
  zip     = "\u{f410} ",
  tar     = "\u{f410} ",
  gz      = "\u{f410} ",
}

-- Special filenames (matched before extension lookup)
M.names = {
  [".gitignore"]           = "\u{e702} ",
  [".gitattributes"]       = "\u{e702} ",
  [".env"]                 = "\u{f462} ",
  ["Makefile"]             = "\u{e779} ",
  ["makefile"]             = "\u{e779} ",
  ["Dockerfile"]           = "\u{e7b0} ",
  ["docker-compose.yml"]   = "\u{e7b0} ",
  ["package.json"]         = "\u{e718} ",
  ["package-lock.json"]    = "\u{e718} ",
  ["go.mod"]               = "\u{e627} ",
  ["go.sum"]               = "\u{e627} ",
  ["README.md"]            = "\u{f48a} ",
  ["LICENSE"]              = "\u{f022} ",
  ["LICENSE.md"]           = "\u{f022} ",
  ["init.lua"]             = "\u{e620} ",
  [".luarc.json"]          = "\u{e620} ",
  ["tsconfig.json"]        = "\u{e628} ",
  ["rust-toolchain"]       = "\u{e7a8} ",
  ["Cargo.toml"]           = "\u{e7a8} ",
  ["Cargo.lock"]           = "\u{e7a8} ",
}

-- Directory icons
M.folder_open   = "\u{f115} "
M.folder_closed = "\u{f114} "
M.file_default  = "\u{f15b} "

-- Resolve icon string for a given filename
function M.get(name, is_dir, is_open)
  if is_dir then
    return is_open and M.folder_open or M.folder_closed
  end
  local base = name:match("([^/\\]+)$") or name
  if M.names[base] then return M.names[base] end
  local ext = base:match("%.([^%.]+)$")
  if ext and M.ext[ext:lower()] then return M.ext[ext:lower()] end
  return M.file_default
end

return M

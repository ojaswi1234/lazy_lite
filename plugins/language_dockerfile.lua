-- mod-version:3
local syntax = require "core.syntax"

syntax.add {
  name = "Dockerfile",
  files = { "^Dockerfile$", "^Dockerfile%..*", "%.dockerfile$" },
  comment = "#",
  patterns = {
    { pattern = "#.*",                 type = "comment" },
    { pattern = { '"', '"', '\\' },    type = "string"  },
    { pattern = { "'", "'", '\\' },    type = "string"  },
    { pattern = "$-?%d+[%d%.eE]*",      type = "number"  },
    { pattern = "%$[%a_][%w_]*",       type = "keyword2" },
    { pattern = "%${[%a_][%w_]*}",     type = "keyword2" },
    { pattern = "^%s*([%a_]+)",        type = "keyword" },
    { pattern = "[%a_][%w_]*",         type = "symbol"  },
  },
  symbols = {
    ["FROM"] = "keyword",
    ["RUN"] = "keyword",
    ["CMD"] = "keyword",
    ["LABEL"] = "keyword",
    ["MAINTAINER"] = "keyword",
    ["EXPOSE"] = "keyword",
    ["ENV"] = "keyword",
    ["ADD"] = "keyword",
    ["COPY"] = "keyword",
    ["ENTRYPOINT"] = "keyword",
    ["VOLUME"] = "keyword",
    ["USER"] = "keyword",
    ["WORKDIR"] = "keyword",
    ["ARG"] = "keyword",
    ["ONBUILD"] = "keyword",
    ["STOPSIGNAL"] = "keyword",
    ["HEALTHCHECK"] = "keyword",
    ["SHELL"] = "keyword",
    ["AS"] = "keyword",
    
    ["true"] = "literal",
    ["false"] = "literal",
  }
}

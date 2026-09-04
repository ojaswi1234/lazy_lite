-- mod-version:3
-- Comprehensive Universal Multi-Stack Snippet Library for Lite XL
-- Covers: React, Next.js, Vue 3, Svelte, Express, FastAPI, Flask, Django,
--         Spring Boot, Go, Rust, C/C++, Java, SQL, Docker, K8s, GitHub Actions,
--         Tailwind CSS, and HTML5.

local core = require "core"

-- [AUTO-GENERATED CACHED COLORS FOR GC OPTIMIZATION]
local _COLOR_CACHE_0 = {103,232,249}
local _COLOR_CACHE_1 = {59,7,100}
local _COLOR_CACHE_2 = {238,242,255}
local _COLOR_CACHE_3 = {76,5,25}
local _COLOR_CACHE_4 = {139,92,246}
local _COLOR_CACHE_5 = {82,82,91}
local _COLOR_CACHE_6 = {8,51,68}
local _COLOR_CACHE_7 = {253,242,248}
local _COLOR_CACHE_8 = {253,244,255}
local _COLOR_CACHE_9 = {156,163,175}
local _COLOR_CACHE_10 = {24,24,27}
local _COLOR_CACHE_11 = {129,140,248}
local _COLOR_CACHE_12 = {76,29,149}
local _COLOR_CACHE_13 = {74,4,78}
local _COLOR_CACHE_14 = {46,16,101}
local _COLOR_CACHE_15 = {20,83,45}
local _COLOR_CACHE_16 = {2,44,34}
local _COLOR_CACHE_17 = {196,181,253}
local _COLOR_CACHE_18 = {2,6,23}
local _COLOR_CACHE_19 = {254,215,170}
local _COLOR_CACHE_20 = {74,222,128}
local _COLOR_CACHE_21 = {204,251,241}
local _COLOR_CACHE_22 = {12,74,110}
local _COLOR_CACHE_23 = {55,48,163}
local _COLOR_CACHE_24 = {125,211,252}
local _COLOR_CACHE_25 = {190,18,60}
local _COLOR_CACHE_26 = {254,249,195}
local _COLOR_CACHE_27 = {127,29,29}
local _COLOR_CACHE_28 = {251,191,36}
local _COLOR_CACHE_29 = {31,41,55}
local _COLOR_CACHE_30 = {159,18,57}
local _COLOR_CACHE_31 = {167,243,208}
local _COLOR_CACHE_32 = {251,113,133}
local _COLOR_CACHE_33 = {239,246,255}
local _COLOR_CACHE_34 = {209,213,219}
local _COLOR_CACHE_35 = {254,243,199}
local _COLOR_CACHE_36 = {217,119,6}
local _COLOR_CACHE_37 = {240,171,252}
local _COLOR_CACHE_38 = {21,128,61}
local _COLOR_CACHE_39 = {39,39,42}
local _COLOR_CACHE_40 = {29,78,216}
local _COLOR_CACHE_41 = {241,245,249}
local _COLOR_CACHE_42 = {236,253,245}
local _COLOR_CACHE_43 = {124,58,237}
local _COLOR_CACHE_44 = {209,250,229}
local _COLOR_CACHE_45 = {240,249,255}
local _COLOR_CACHE_46 = {6,78,59}
local _COLOR_CACHE_47 = {168,85,247}
local _COLOR_CACHE_48 = {107,114,128}
local _COLOR_CACHE_49 = {23,37,84}
local _COLOR_CACHE_50 = {6,182,212}
local _COLOR_CACHE_51 = {34,197,94}
local _COLOR_CACHE_52 = {254,240,138}
local _COLOR_CACHE_53 = {220,252,231}
local _COLOR_CACHE_54 = {15,118,110}
local _COLOR_CACHE_55 = {112,26,117}
local _COLOR_CACHE_56 = {63,98,18}
local _COLOR_CACHE_57 = {52,211,153}
local _COLOR_CACHE_58 = {157,23,77}
local _COLOR_CACHE_59 = {225,29,72}
local _COLOR_CACHE_60 = {186,230,253}
local _COLOR_CACHE_61 = {59,130,246}
local _COLOR_CACHE_62 = {165,180,252}
local _COLOR_CACHE_63 = {187,247,208}
local _COLOR_CACHE_64 = {251,207,232}
local _COLOR_CACHE_65 = {14,165,233}
local _COLOR_CACHE_66 = {245,243,255}
local _COLOR_CACHE_67 = {49,46,129}
local _COLOR_CACHE_68 = {232,121,249}
local _COLOR_CACHE_69 = {224,231,255}
local _COLOR_CACHE_70 = {136,19,55}
local _COLOR_CACHE_71 = {253,224,71}
local _COLOR_CACHE_72 = {253,164,175}
local _COLOR_CACHE_73 = {249,168,212}
local _COLOR_CACHE_74 = {234,179,8}
local _COLOR_CACHE_75 = {63,63,70}
local _COLOR_CACHE_76 = {67,56,202}
local _COLOR_CACHE_77 = {8,47,73}
local _COLOR_CACHE_78 = {45,212,191}
local _COLOR_CACHE_79 = {91,33,182}
local _COLOR_CACHE_80 = {250,232,255}
local _COLOR_CACHE_81 = {153,27,27}
local _COLOR_CACHE_82 = {132,204,22}
local _COLOR_CACHE_83 = {30,41,59}
local _COLOR_CACHE_84 = {5,46,22}
local _COLOR_CACHE_85 = {56,189,248}
local _COLOR_CACHE_86 = {255,228,230}
local _COLOR_CACHE_87 = {216,180,254}
local _COLOR_CACHE_88 = {244,244,245}
local _COLOR_CACHE_89 = {100,116,139}
local _COLOR_CACHE_90 = {79,70,229}
local _COLOR_CACHE_91 = {6,95,70}
local _COLOR_CACHE_92 = {250,250,250}
local _COLOR_CACHE_93 = {251,146,60}
local _COLOR_CACHE_94 = {71,85,105}
local _COLOR_CACHE_95 = {96,165,250}
local _COLOR_CACHE_96 = {75,85,99}
local _COLOR_CACHE_97 = {94,234,212}
local _COLOR_CACHE_98 = {3,7,18}
local _COLOR_CACHE_99 = {101,163,13}
local _COLOR_CACHE_100 = {244,114,182}
local _COLOR_CACHE_101 = {109,40,217}
local _COLOR_CACHE_102 = {254,205,211}
local _COLOR_CACHE_103 = {110,231,183}
local _COLOR_CACHE_104 = {131,24,67}
local _COLOR_CACHE_105 = {199,210,254}
local _COLOR_CACHE_106 = {254,252,232}
local _COLOR_CACHE_107 = {19,78,74}
local _COLOR_CACHE_108 = {194,65,12}
local _COLOR_CACHE_109 = {233,213,255}
local _COLOR_CACHE_110 = {202,138,4}
local _COLOR_CACHE_111 = {163,230,53}
local _COLOR_CACHE_112 = {20,184,166}
local _COLOR_CACHE_113 = {5,150,105}
local _COLOR_CACHE_114 = {51,65,85}
local _COLOR_CACHE_115 = {253,186,116}
local _COLOR_CACHE_116 = {3,105,161}
local _COLOR_CACHE_117 = {30,58,138}
local _COLOR_CACHE_118 = {26,46,5}
local _COLOR_CACHE_119 = {124,45,18}
local _COLOR_CACHE_120 = {217,249,157}
local _COLOR_CACHE_121 = {80,7,36}
local _COLOR_CACHE_122 = {240,253,244}
local _COLOR_CACHE_123 = {148,163,184}
local _COLOR_CACHE_124 = {4,47,46}
local _COLOR_CACHE_125 = {21,94,117}
local _COLOR_CACHE_126 = {54,83,20}
local _COLOR_CACHE_127 = {22,78,99}
local _COLOR_CACHE_128 = {99,102,241}
local _COLOR_CACHE_129 = {239,68,68}
local _COLOR_CACHE_130 = {113,113,122}
local _COLOR_CACHE_131 = {69,26,3}
local _COLOR_CACHE_132 = {226,232,240}
local _COLOR_CACHE_133 = {236,252,203}
local _COLOR_CACHE_134 = {224,242,254}
local _COLOR_CACHE_135 = {219,234,254}
local _COLOR_CACHE_136 = {237,233,254}
local _COLOR_CACHE_137 = {190,24,93}
local _COLOR_CACHE_138 = {4,120,87}
local _COLOR_CACHE_139 = {250,245,255}
local _COLOR_CACHE_140 = {30,64,175}
local _COLOR_CACHE_141 = {146,64,14}
local _COLOR_CACHE_142 = {252,165,165}
local _COLOR_CACHE_143 = {253,230,138}
local _COLOR_CACHE_144 = {14,116,144}
local _COLOR_CACHE_145 = {254,226,226}
local _COLOR_CACHE_146 = {255,241,242}
local _COLOR_CACHE_147 = {153,246,228}
local _COLOR_CACHE_148 = {161,98,7}
local _COLOR_CACHE_149 = {180,83,9}
local _COLOR_CACHE_150 = {133,77,14}
local _COLOR_CACHE_151 = {147,197,253}
local _COLOR_CACHE_152 = {217,70,239}
local _COLOR_CACHE_153 = {247,254,231}
local _COLOR_CACHE_154 = {250,204,21}
local _COLOR_CACHE_155 = {167,139,250}
local _COLOR_CACHE_156 = {16,185,129}
local _COLOR_CACHE_157 = {240,253,250}
local _COLOR_CACHE_158 = {17,94,89}
local _COLOR_CACHE_159 = {8,145,178}
local _COLOR_CACHE_160 = {248,113,113}
local _COLOR_CACHE_161 = {17,24,39}
local _COLOR_CACHE_162 = {234,88,12}
local _COLOR_CACHE_163 = {219,39,119}
local _COLOR_CACHE_164 = {236,72,153}
local _COLOR_CACHE_165 = {9,9,11}
local _COLOR_CACHE_166 = {220,38,38}
local _COLOR_CACHE_167 = {77,124,15}
local _COLOR_CACHE_168 = {254,242,242}
local _COLOR_CACHE_169 = {190,242,100}
local _COLOR_CACHE_170 = {207,250,254}
local _COLOR_CACHE_171 = {66,32,6}
local _COLOR_CACHE_172 = {67,20,7}
local _COLOR_CACHE_173 = {221,214,254}
local _COLOR_CACHE_174 = {134,25,143}
local _COLOR_CACHE_175 = {154,52,18}
local _COLOR_CACHE_176 = {245,208,254}
local _COLOR_CACHE_177 = {252,211,77}
local _COLOR_CACHE_178 = {229,231,235}
local _COLOR_CACHE_179 = {165,243,252}
local _COLOR_CACHE_180 = {243,232,255}
local _COLOR_CACHE_181 = {126,34,206}
local _COLOR_CACHE_182 = {88,28,135}
local _COLOR_CACHE_183 = {162,28,175}
local _COLOR_CACHE_184 = {191,219,254}
local _COLOR_CACHE_185 = {15,23,42}
local _COLOR_CACHE_186 = {255,237,213}
local _COLOR_CACHE_187 = {185,28,28}
local _COLOR_CACHE_188 = {2,132,199}
local _COLOR_CACHE_189 = {249,115,22}
local _COLOR_CACHE_190 = {192,132,252}
local _COLOR_CACHE_191 = {245,158,11}
local _COLOR_CACHE_192 = {252,231,243}
local _COLOR_CACHE_193 = {161,161,170}
local _COLOR_CACHE_194 = {37,99,235}
local _COLOR_CACHE_195 = {147,51,234}
local _COLOR_CACHE_196 = {22,163,74}
local _COLOR_CACHE_197 = {255,251,235}
local _COLOR_CACHE_198 = {55,65,81}
local _COLOR_CACHE_199 = {228,228,231}
local _COLOR_CACHE_200 = {113,63,18}
local _COLOR_CACHE_201 = {236,254,255}
local _COLOR_CACHE_202 = {34,211,238}
local _COLOR_CACHE_203 = {254,202,202}
local _COLOR_CACHE_204 = {13,148,136}
local _COLOR_CACHE_205 = {107,33,168}
local _COLOR_CACHE_206 = {30,27,75}
local _COLOR_CACHE_207 = {120,53,15}
local _COLOR_CACHE_208 = {249,250,251}
local _COLOR_CACHE_209 = {22,101,52}
local _COLOR_CACHE_210 = {255,247,237}
local _COLOR_CACHE_211 = {243,244,246}
local _COLOR_CACHE_212 = {203,213,225}
local _COLOR_CACHE_213 = {212,212,216}
local _COLOR_CACHE_214 = {69,10,10}
local _COLOR_CACHE_215 = {248,250,252}
local _COLOR_CACHE_216 = {7,89,133}
local _COLOR_CACHE_217 = {244,63,94}
local _COLOR_CACHE_218 = {192,38,211}
local _COLOR_CACHE_219 = {134,239,172}
local snippets = require "plugins.snippets"
pcall(require, "plugins.lsp_snippets")
pcall(require, "plugins.emmet")
local autocomplete = require "plugins.autocomplete"

local SNIPPET_PACKS = {
  -- ==========================================================================
  -- 1. REACT, NEXT.JS & TYPESCRIPT / JAVASCRIPT
  -- ==========================================================================
  {
    files = { "%.jsx$", "%.tsx$", "%.js$", "%.ts$", "%.mjs$", "%.cjs$" },
    snippets = {
      -- React Components
      { trigger = "rfce", desc = "React Functional Component (Default Export)", template = "import React from 'react';\n\nfunction ${1:$TM_FILENAME_BASE}() {\n  return (\n    <div>\n      ${0:Content}\n    </div>\n  );\n}\n\nexport default ${1:$TM_FILENAME_BASE};\n" },
      { trigger = "rafce", desc = "React Arrow Function Component (Default Export)", template = "import React from 'react';\n\nconst ${1:$TM_FILENAME_BASE} = () => {\n  return (\n    <div>\n      ${0:Content}\n    </div>\n  );\n};\n\nexport default ${1:$TM_FILENAME_BASE};\n" },
      { trigger = "rfc", desc = "React Functional Component (Named Export)", template = "import React from 'react';\n\nexport const ${1:$TM_FILENAME_BASE} = () => {\n  return (\n    <div>\n      ${0:Content}\n    </div>\n  );\n};\n" },
      { trigger = "rafc", desc = "React Arrow Component (Named Export)", template = "export const ${1:$TM_FILENAME_BASE} = () => {\n  return (\n    <div>\n      ${0:Content}\n    </div>\n  );\n};\n" },
      { trigger = "rcc", desc = "React Class Component", template = "import React, { Component } from 'react';\n\nexport default class ${1:$TM_FILENAME_BASE} extends Component {\n  render() {\n    return (\n      <div>\n        ${0:Content}\n      </div>\n    );\n  }\n}\n" },
      { trigger = "rconst", desc = "React Class Constructor with State", template = "constructor(props) {\n  super(props);\n  this.state = {\n    ${1:key}: ${2:value}\n  };\n}" },
      
      -- TypeScript React Components
      { trigger = "tsrfce", desc = "TypeScript React Functional Component", template = "import React from 'react';\n\ninterface ${1:$TM_FILENAME_BASE}Props {\n  ${2:children}?: React.ReactNode;\n}\n\nfunction ${1:$TM_FILENAME_BASE}({ ${3:} }: ${1:$TM_FILENAME_BASE}Props) {\n  return (\n    <div>\n      ${0:Content}\n    </div>\n  );\n}\n\nexport default ${1:$TM_FILENAME_BASE};\n" },
      { trigger = "tsrafce", desc = "TypeScript React Arrow Component", template = "import React from 'react';\n\ninterface ${1:$TM_FILENAME_BASE}Props {\n  ${2:children}?: React.ReactNode;\n}\n\nconst ${1:$TM_FILENAME_BASE}: React.FC<${1:$TM_FILENAME_BASE}Props> = ({ ${3:} }) => {\n  return (\n    <div>\n      ${0:Content}\n    </div>\n  );\n};\n\nexport default ${1:$TM_FILENAME_BASE};\n" },

      -- React Hooks
      { trigger = "useState", desc = "React useState hook", template = "const [${1:state}, set${1/(.*)/${1:/capitalize}/}] = useState(${2:initialState});$0" },
      { trigger = "usf", desc = "React useState shorthand", template = "const [${1:state}, set${1/(.*)/${1:/capitalize}/}] = useState(${2:initialState});$0" },
      { trigger = "useEffect", desc = "React useEffect hook", template = "useEffect(() => {\n  ${0:}\n}, [${1:deps}]);" },
      { trigger = "uef", desc = "React useEffect shorthand", template = "useEffect(() => {\n  ${0:}\n}, [${1:deps}]);" },
      { trigger = "useMemo", desc = "React useMemo hook", template = "const ${1:memoized} = useMemo(() => {\n  return ${0:};\n}, [${2:deps}]);" },
      { trigger = "umm", desc = "React useMemo shorthand", template = "const ${1:memoized} = useMemo(() => ${0:compute}, [${2:deps}]);" },
      { trigger = "useCallback", desc = "React useCallback hook", template = "const ${1:callback} = useCallback((${2:params}) => {\n  ${0:}\n}, [${3:deps}]);" },
      { trigger = "ucb", desc = "React useCallback shorthand", template = "const ${1:callback} = useCallback((${2:params}) => {\n  ${0:}\n}, [${3:deps}]);" },
      { trigger = "useRef", desc = "React useRef hook", template = "const ${1:ref} = useRef(${2:null});$0" },
      { trigger = "urf", desc = "React useRef shorthand", template = "const ${1:ref} = useRef(${2:null});$0" },
      { trigger = "useContext", desc = "React useContext hook", template = "const ${1:value} = useContext(${2:Context});$0" },
      { trigger = "ucc", desc = "React useContext shorthand", template = "const ${1:value} = useContext(${2:Context});$0" },
      { trigger = "useReducer", desc = "React useReducer hook", template = "const [${1:state}, ${2:dispatch}] = useReducer(${3:reducer}, ${4:initialState});$0" },
      { trigger = "urd", desc = "React useReducer shorthand", template = "const [${1:state}, ${2:dispatch}] = useReducer(${3:reducer}, ${4:initialState});$0" },

      -- Next.js 14 App Router
      { trigger = "nextpage", desc = "Next.js App Router Page Component", template = "export default function ${1:$TM_FILENAME_BASE}() {\n  return (\n    <main className=\"container mx-auto p-4\">\n      <h1 className=\"text-2xl font-bold\">${1:$TM_FILENAME_BASE}</h1>\n      ${0:}\n    </main>\n  );\n}\n" },
      { trigger = "nextlayout", desc = "Next.js App Router Layout Component", template = "export default function ${1:Root}Layout({\n  children,\n}: {\n  children: React.ReactNode;\n}) {\n  return (\n    <div className=\"min-h-screen flex flex-col\">\n      ${0:}\n      <main className=\"flex-1\">{children}</main>\n    </div>\n  );\n}\n" },
      { trigger = "nextloading", desc = "Next.js Loading UI component", template = "export default function Loading() {\n  return (\n    <div className=\"flex items-center justify-center min-h-[50vh]\">\n      <div className=\"animate-spin rounded-full h-8 w-8 border-b-2 border-primary\" />\n    </div>\n  );\n}\n" },
      { trigger = "nexterror", desc = "Next.js Error boundary component", template = "'use client';\n\nimport { useEffect } from 'react';\n\nexport default function Error({\n  error,\n  reset,\n}: {\n  error: Error & { digest?: string };\n  reset: () => void;\n}) {\n  useEffect(() => {\n    console.error(error);\n  }, [error]);\n\n  return (\n    <div className=\"p-6 text-center\">\n      <h2 className=\"text-xl font-semibold mb-4\">Something went wrong!</h2>\n      <button\n        onClick={() => reset()}\n        className=\"px-4 py-2 bg-red-600 text-white rounded-md hover:bg-red-700\"\n      >\n        Try again\n      </button>\n    </div>\n  );\n}\n" },
      { trigger = "nextapi", desc = "Next.js App Router Route Handler (API)", template = "import { NextResponse } from 'next/server';\n\nexport async function GET(request: Request) {\n  return NextResponse.json({ message: '${1:Hello World}' });\n}\n\nexport async function POST(request: Request) {\n  const data = await request.json();\n  return NextResponse.json({ success: true, data });\n}\n" },
      { trigger = "useClient", desc = "'use client' directive", template = "'use client';\n$0" },
      { trigger = "useServer", desc = "'use server' directive", template = "'use server';\n$0" },

      -- Imports & Exports
      { trigger = "imr", desc = "import React from 'react'", template = "import React from 'react';\n$0" },
      { trigger = "imrd", desc = "import ReactDOM from 'react-dom/client'", template = "import ReactDOM from 'react-dom/client';\n$0" },
      { trigger = "imrc", desc = "import React, { useState, useEffect }", template = "import React, { useState, useEffect } from 'react';\n$0" },
      { trigger = "imp", desc = "import module from 'path'", template = "import ${1:module} from '${2:path}';\n$0" },
      { trigger = "imd", desc = "import { destructured } from 'path'", template = "import { ${1:exports} } from '${2:path}';\n$0" },
      { trigger = "exp", desc = "export default name", template = "export default ${1:name};\n$0" },
      { trigger = "exd", desc = "export { destructured } from 'path'", template = "export { ${1:exports} } from '${2:path}';\n$0" },
      { trigger = "enf", desc = "export const func = () => {}", template = "export const ${1:name} = (${2:params}) => {\n  ${0:}\n};\n" },

      -- Console Statements
      { trigger = "clg", desc = "console.log()", template = "console.log(${1:val});$0" },
      { trigger = "cle", desc = "console.error()", template = "console.error(${1:err});$0" },
      { trigger = "clw", desc = "console.warn()", template = "console.warn(${1:msg});$0" },
      { trigger = "clt", desc = "console.table()", template = "console.table(${1:data});$0" },
      { trigger = "ct", desc = "console.time() / timeEnd()", template = "console.time('${1:timer}');\n${0:}\nconsole.timeEnd('${1:timer}');" },

      -- Core JavaScript / TypeScript
      { trigger = "fn", desc = "Named Function", template = "function ${1:name}(${2:params}) {\n  ${0:}\n}" },
      { trigger = "afn", desc = "Arrow Function", template = "const ${1:name} = (${2:params}) => {\n  ${0:}\n};" },
      { trigger = "asyncfn", desc = "Async Function", template = "async function ${1:name}(${2:params}) {\n  try {\n    ${0:}\n  } catch (err) {\n    console.error(err);\n  }\n}" },
      { trigger = "prom", desc = "New Promise", template = "new Promise((resolve, reject) => {\n  ${0:}\n});" },
      { trigger = "trycatch", desc = "try-catch block", template = "try {\n  ${0:}\n} catch (err) {\n  console.error(err);\n}" },
      { trigger = "forof", desc = "for-of loop", template = "for (const ${1:item} of ${2:iterable}) {\n  ${0:}\n}" },
      { trigger = "forin", desc = "for-in loop", template = "for (const ${1:key} in ${2:object}) {\n  ${0:}\n}" },
      { trigger = "fori", desc = "for-index loop", template = "for (let ${1:i} = 0; ${1:i} < ${2:n}; ${1:i}++) {\n  ${0:}\n}" },
      { trigger = "fetch", desc = "fetch API request", template = "const res = await fetch('${1:https://api.example.com}', {\n  method: '${2:GET}',\n  headers: { 'Content-Type': 'application/json' },\n});\nconst data = await res.json();\n$0" },
      { trigger = "req", desc = "const module = require()", template = "const ${1:module} = require('${2:module}');$0" }
    }
  },

  -- ==========================================================================
  -- 2. VUE.JS 3 (SINGLE FILE COMPONENTS & COMPOSITION API)
  -- ==========================================================================
  {
    files = { "%.vue$" },
    snippets = {
      { trigger = "vbase", desc = "Vue 3 SFC boilerplate (<script setup>)", template = "<template>\n  <div class=\"${1:container}\">\n    ${0:<h1>Hello Vue 3</h1>}\n  </div>\n</template>\n\n<script setup lang=\"ts\">\nimport { ref } from 'vue';\n\n</script>\n\n<style scoped>\n\n</style>\n" },
      { trigger = "vbase-setup", desc = "Vue 3 SFC standard setup", template = "<template>\n  <div>\n    ${0:}\n  </div>\n</template>\n\n<script setup>\nimport { ref, onMounted } from 'vue';\n\n</script>\n\n<style scoped>\n\n</style>\n" },
      { trigger = "vref", desc = "Vue ref() state", template = "const ${1:name} = ref(${2:initialValue});$0" },
      { trigger = "vreactive", desc = "Vue reactive() state", template = "const ${1:state} = reactive({\n  ${2:key}: ${3:value},\n});$0" },
      { trigger = "vcomputed", desc = "Vue computed() property", template = "const ${1:name} = computed(() => {\n  return ${2:};\n});$0" },
      { trigger = "vwatch", desc = "Vue watch() effect", template = "watch(${1:source}, (${2:newVal}, ${3:oldVal}) => {\n  ${0:}\n});" },
      { trigger = "vwatchEffect", desc = "Vue watchEffect()", template = "watchEffect(() => {\n  ${0:}\n});" },
      { trigger = "vonMounted", desc = "Vue onMounted lifecycle hook", template = "onMounted(() => {\n  ${0:}\n});" },
      { trigger = "vonUnmounted", desc = "Vue onUnmounted lifecycle hook", template = "onUnmounted(() => {\n  ${0:}\n});" },
      { trigger = "vfor", desc = "v-for directive", template = "v-for=\"(${1:item}, ${2:index}) in ${3:items}\" :key=\"${2:index}\"$0" },
      { trigger = "vif", desc = "v-if directive", template = "v-if=\"${1:condition}\"$0" },
      { trigger = "velse", desc = "v-else directive", template = "v-else$0" },
      { trigger = "vmodel", desc = "v-model directive", template = "v-model=\"${1:model}\"$0" },
      { trigger = "vprops", desc = "defineProps() definition", template = "const props = defineProps<{\n  ${1:propName}: ${2:string};\n}>();$0" },
      { trigger = "vemits", desc = "defineEmits() definition", template = "const emit = defineEmits<{\n  (e: '${1:change}', ${2:value}: ${3:any}): void;\n}>();$0" }
    }
  },

  -- ==========================================================================
  -- 3. SVELTE
  -- ==========================================================================
  {
    files = { "%.svelte$" },
    snippets = {
      { trigger = "svbase", desc = "Svelte Component boilerplate", template = "<script lang=\"ts\">\n  export let ${1:name}: string = '${2:world}';\n</script>\n\n<main>\n  <h1>Hello {${1:name}}!</h1>\n  ${0:}\n</main>\n\n<style>\n  main {\n    padding: 1rem;\n  }\n</style>\n" },
      { trigger = "onMount", desc = "Svelte onMount lifecycle", template = "onMount(() => {\n  ${0:}\n});" },
      { trigger = "onDestroy", desc = "Svelte onDestroy lifecycle", template = "onDestroy(() => {\n  ${0:}\n});" },
      { trigger = "createEventDispatcher", desc = "Svelte dispatch event", template = "const dispatch = createEventDispatcher();\ndispatch('${1:event}', { ${2:data} });$0" }
    }
  },

  -- ==========================================================================
  -- 4. NODE.JS & EXPRESS BACKEND
  -- ==========================================================================
  {
    files = { "%.js$", "%.ts$", "%.mjs$" },
    snippets = {
      { trigger = "exps", desc = "Express Server Boilerplate", template = "const express = require('express');\nconst app = express();\nconst PORT = process.env.PORT || ${1:3000};\n\napp.use(express.json());\n\napp.get('/', (req, res) => {\n  res.json({ message: 'API is running' });\n});\n\napp.listen(PORT, () => {\n  console.log(`Server running on http://localhost:${PORT}`);\n});\n$0" },
      { trigger = "router", desc = "Express Router module", template = "const express = require('express');\nconst router = express.Router();\n\nrouter.get('/', async (req, res) => {\n  try {\n    ${0:res.json({ success: true });}\n  } catch (err) {\n    res.status(500).json({ error: err.message });\n  }\n});\n\nmodule.exports = router;\n" },
      { trigger = "middleware", desc = "Express Middleware function", template = "const ${1:middlewareName} = (req, res, next) => {\n  ${0:}\n  next();\n};\n\nmodule.exports = ${1:middlewareName};\n" }
    }
  },

  -- ==========================================================================
  -- 5. PYTHON (FASTAPI, FLASK, DJANGO & CORE PYTHON)
  -- ==========================================================================
  {
    files = { "%.py$", "%.pyw$" },
    snippets = {
      -- FastAPI
      { trigger = "fapi", desc = "FastAPI Application Boilerplate", template = "from fastapi import FastAPI, HTTPException\nfrom pydantic import BaseModel\n\napp = FastAPI(title=\"${1:My API}\", version=\"1.0.0\")\n\n@app.get(\"/\")\ndef root():\n    return {\"message\": \"API is online\"}\n\n$0" },
      { trigger = "fapiroute", desc = "FastAPI APIRouter module", template = "from fastapi import APIRouter, HTTPException, status\n\nrouter = APIRouter(prefix=\"/${1:items}\", tags=[\"${1:items}\"])\n\n@router.get(\"/\")\ndef get_all():\n    return [${0:}]\n" },
      { trigger = "pydantic", desc = "Pydantic BaseModel schema", template = "from pydantic import BaseModel, Field\nfrom typing import Optional\n\nclass ${1:ItemSchema}(BaseModel):\n    ${2:id}: int\n    ${3:name}: str\n    ${4:description}: Optional[str] = None\n$0" },

      -- Flask
      { trigger = "flask", desc = "Flask App Boilerplate", template = "from flask import Flask, jsonify, request\n\napp = Flask(__name__)\n\n@app.route(\"/\")\ndef index():\n    return jsonify({\"message\": \"Hello from Flask\"})\n\nif __name__ == \"__main__\":\n    app.run(debug=True, port=${1:5000})\n$0" },
      { trigger = "flaskroute", desc = "Flask route handler", template = "@app.route(\"/${1:api}\", methods=[\"${2:GET}\"])\ndef ${3:handler}():\n    ${0:return jsonify({\"status\": \"ok\"})}" },

      -- Django
      { trigger = "djmodel", desc = "Django ORM Model", template = "from django.db import models\n\nclass ${1:$TM_FILENAME_BASE}(models.Model):\n    ${2:title} = models.CharField(max_length=200)\n    created_at = models.DateTimeField(auto_now_add=True)\n    updated_at = models.DateTimeField(auto_now=True)\n\n    def __str__(self):\n        return self.${2:title}\n\n    class Meta:\n        verbose_name_plural = \"${1:$TM_FILENAME_BASE}s\"\n$0" },
      { trigger = "djview", desc = "Django Functional View", template = "from django.shortcuts import render, get_object_or_404, redirect\nfrom django.http import JsonResponse\n\ndef ${1:my_view}(request):\n    ${0:return render(request, \"${2:index.html}\", {})}\n" },

      -- Core Python
      { trigger = "def", desc = "Python function definition", template = "def ${1:name}(${2:params}):\n    ${3:pass}\n$0" },
      { trigger = "asyncdef", desc = "Python async function", template = "async def ${1:name}(${2:params}):\n    ${3:pass}\n$0" },
      { trigger = "class", desc = "Python class definition", template = "class ${1:ClassName}:\n    def __init__(self, ${2:params}):\n        ${3:pass}\n$0" },
      { trigger = "init", desc = "Python __init__ constructor", template = "def __init__(self, ${1:params}):\n    ${2:pass}\n$0" },
      { trigger = "ifmain", desc = "Python if __name__ == '__main__'", template = "if __name__ == \"__main__\":\n    ${1:main()}\n$0" },
      { trigger = "try", desc = "Python try-except block", template = "try:\n    ${1:pass}\nexcept ${2:Exception} as ${3:e}:\n    ${4:raise e}\n$0" },
      { trigger = "tryf", desc = "Python try-except-finally block", template = "try:\n    ${1:pass}\nexcept ${2:Exception} as ${3:e}:\n    ${4:raise e}\nfinally:\n    ${5:pass}\n$0" },
      { trigger = "for", desc = "Python for-in loop", template = "for ${1:item} in ${2:iterable}:\n    ${3:pass}\n$0" },
      { trigger = "fori", desc = "Python range index loop", template = "for ${1:i} in range(${2:n}):\n    ${3:pass}\n$0" },
      { trigger = "with", desc = "Python with-open statement", template = "with open(${1:\"filename\"}, \"${2:r}\") as ${3:f}:\n    ${4:data = f.read()}\n$0" },
      { trigger = "prop", desc = "Python @property getter", template = "@property\ndef ${1:name}(self):\n    return self._${1:name}\n$0" },
      { trigger = "pr", desc = "Python print statement", template = "print(f\"${1:message}\")$0" },
      { trigger = "lambda", desc = "Python lambda expression", template = "lambda ${1:x}: ${2:x}" },
      { trigger = "listcomp", desc = "Python list comprehension", template = "[${1:x} for ${1:x} in ${2:iterable} if ${3:True}]" },
      { trigger = "dictcomp", desc = "Python dictionary comprehension", template = "{${1:k}: ${2:v} for ${1:k}, ${2:v} in ${3:iterable}}" },
      { trigger = "docstr", desc = "Python docstring template", template = "\"\"\"${1:Description}\n\nArgs:\n    ${2:arg}: ${3:desc}\n\nReturns:\n    ${4:desc}\n\"\"\"$0" }
    }
  },

  -- ==========================================================================
  -- 6. JAVA & SPRING BOOT
  -- ==========================================================================
  {
    files = { "%.java$" },
    snippets = {
      { trigger = "psvm", desc = "Java main method (public static void main)", template = "public static void main(String[] args) {\n    $0\n}" },
      { trigger = "main", desc = "Java main method", template = "public static void main(String[] args) {\n    $0\n}" },
      { trigger = "sout", desc = "System.out.println()", template = "System.out.println(${1:val});$0" },
      { trigger = "sbcontroller", desc = "Spring Boot @RestController", template = "package ${1:com.example.demo.controller};\n\nimport org.springframework.web.bind.annotation.*;\nimport org.springframework.http.ResponseEntity;\n\n@RestController\n@RequestMapping(\"/api/${2:v1}\")\npublic class ${3:$TM_FILENAME_BASE}Controller {\n\n    @GetMapping\n    public ResponseEntity<?> getAll() {\n        return ResponseEntity.ok($0);\n    }\n}\n" },
      { trigger = "sbservice", desc = "Spring Boot @Service class", template = "package ${1:com.example.demo.service};\n\nimport org.springframework.stereotype.Service;\n\n@Service\npublic class ${2:$TM_FILENAME_BASE}Service {\n    $0\n}\n" },
      { trigger = "sbrepo", desc = "Spring Data JPA @Repository interface", template = "package ${1:com.example.demo.repository};\n\nimport org.springframework.data.jpa.repository.JpaRepository;\nimport org.springframework.stereotype.Repository;\n\n@Repository\npublic interface ${2:$TM_FILENAME_BASE}Repository extends JpaRepository<${3:ItemEntity}, ${4:Long}> {\n}\n" },
      { trigger = "sbentity", desc = "JPA @Entity definition", template = "package ${1:com.example.demo.model};\n\nimport jakarta.persistence.*;\n\n@Entity\n@Table(name = \"${2:items}\")\npublic class ${3:$TM_FILENAME_BASE}Entity {\n\n    @Id\n    @GeneratedValue(strategy = GenerationType.IDENTITY)\n    private Long id;\n\n    private String name;\n\n    public Long getId() { return id; }\n    public void setId(Long id) { this.id = id; }\n    public String getName() { return name; }\n    public void setName(String name) { this.name = name; }\n}\n" },
      { trigger = "fori", desc = "Java index for loop", template = "for (int ${1:i} = 0; ${1:i} < ${2:n}; ${1:i}++) {\n    $0\n}" },
      { trigger = "trycatch", desc = "Java try-catch block", template = "try {\n    $0\n} catch (${1:Exception} e) {\n    e.printStackTrace();\n}" }
    }
  },

  -- ==========================================================================
  -- 7. GO (GOLANG, GIN & FIBER)
  -- ==========================================================================
  {
    files = { "%.go$" },
    snippets = {
      { trigger = "main", desc = "Go main package & entrypoint", template = "package main\n\nimport \"fmt\"\n\nfunc main() {\n\tfmt.Println(\"Hello, World!\")\n\t$0\n}" },
      { trigger = "gin-app", desc = "Gin Web Server Boilerplate", template = "package main\n\nimport (\n\t\"github.com/gin-gonic/gin\"\n)\n\nfunc main() {\n\tr := gin.Default()\n\tr.GET(\"/\", func(c *gin.Context) {\n\t\tc.JSON(200, gin.H{\"message\": \"Gin API is running\"})\n\t})\n\tr.Run(\":${1:8080}\")\n}\n$0" },
      { trigger = "fiber-app", desc = "Fiber Web Server Boilerplate", template = "package main\n\nimport (\n\t\"github.com/gofiber/fiber/v2\"\n)\n\nfunc main() {\n\tapp := fiber.New()\n\n\tapp.Get(\"/\", func(c *fiber.Ctx) error {\n\t\treturn c.JSON(fiber.Map{\"message\": \"Fiber API is running\"})\n\t})\n\n\tapp.Listen(\":${1:3000}\")\n}\n$0" },
      { trigger = "func", desc = "Go function with return", template = "func ${1:name}(${2:params}) ${3:error} {\n\t$0\n}" },
      { trigger = "fn", desc = "Go simple function", template = "func ${1:name}(${2:params}) {\n\t$0\n}" },
      { trigger = "meth", desc = "Go method on struct receiver", template = "func (${1:r} *${2:Type}) ${3:name}(${4:params}) ${5:error} {\n\t$0\n}" },
      { trigger = "iferr", desc = "Go if err != nil check", template = "if err != nil {\n\treturn ${1:err}\n}\n$0" },
      { trigger = "ife", desc = "Go if-else condition", template = "if ${1:condition} {\n\t$2\n} else {\n\t$0\n}" },
      { trigger = "forr", desc = "Go for range loop", template = "for ${1:k}, ${2:v} := range ${3:items} {\n\t$0\n}" },
      { trigger = "fori", desc = "Go standard index loop", template = "for ${1:i} := 0; ${1:i} < ${2:n}; ${1:i}++ {\n\t$0\n}" },
      { trigger = "struct", desc = "Go struct definition", template = "type ${1:Name} struct {\n\t${2:Field} ${3:string} `json:\"${4:field}\"`\n}\n$0" },
      { trigger = "interface", desc = "Go interface definition", template = "type ${1:Name} interface {\n\t${2:Method}(${3:params}) ${4:error}\n}\n$0" },
      { trigger = "go", desc = "Go anonymous goroutine", template = "go func() {\n\t$0\n}()" },
      { trigger = "test", desc = "Go unit test function", template = "func Test${1:Name}(t *testing.T) {\n\t$0\n}" },
      { trigger = "pln", desc = "Go fmt.Println", template = "fmt.Println(${1:val})$0" }
    }
  },

  -- ==========================================================================
  -- 8. RUST (AXUM, ACTIX & CORE RUST)
  -- ==========================================================================
  {
    files = { "%.rs$" },
    snippets = {
      { trigger = "fnmain", desc = "Rust main function", template = "fn main() {\n    println!(\"Hello, world!\");\n    $0\n}" },
      { trigger = "axum-app", desc = "Axum Web Server Boilerplate", template = "use axum::{routing::get, Json, Router};\nuse serde_json::{json, Value};\n\n#[tokio::main]\nasync fn main() {\n    let app = Router::new().route(\"/\", get(root));\n    let listener = tokio::net::TcpListener::bind(\"0.0.0.0:${1:3000}\").await.unwrap();\n    println!(\"Axum listening on :${1:3000}\");\n    axum::serve(listener, app).await.unwrap();\n}\n\nasync fn root() -> Json<Value> {\n    Json(json!({ \"message\": \"Axum API is running\" }))\n}\n$0" },
      { trigger = "actix-app", desc = "Actix Web Server Boilerplate", template = "use actix_web::{get, App, HttpResponse, HttpServer, Responder};\n\n#[get(\"/\")]\nasync fn index() -> impl Responder {\n    HttpResponse::Ok().json(serde_json::json!({ \"message\": \"Actix is running\" }))\n}\n\n#[actix_web::main]\nasync fn main() -> std::io::Result<()> {\n    HttpServer::new(|| App::new().service(index))\n        .bind((\"127.0.0.1\", ${1:8080}))?\n        .run()\n        .await\n}\n$0" },
      { trigger = "fn", desc = "Rust function", template = "fn ${1:name}(${2:params}) -> ${3:Result<(), Box<dyn std::error::Error>>} {\n    $0\n}" },
      { trigger = "struct", desc = "Rust struct", template = "#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]\npub struct ${1:Name} {\n    pub ${2:field}: ${3:String},\n}\n$0" },
      { trigger = "enum", desc = "Rust enum", template = "#[derive(Debug, PartialEq, Eq, Clone)]\npub enum ${1:Name} {\n    ${2:Variant},\n}\n$0" },
      { trigger = "impl", desc = "Rust impl block", template = "impl ${1:Type} {\n    pub fn new(${2:params}) -> Self {\n        Self {\n            $0\n        }\n    }\n}" },
      { trigger = "trait", desc = "Rust trait definition", template = "pub trait ${1:Name} {\n    fn ${2:method}(&self) -> ${3:()};\n}\n$0" },
      { trigger = "match", desc = "Rust match expression", template = "match ${1:expr} {\n    Ok(${2:val}) => ${3:val},\n    Err(${4:e}) => return Err(${4:e}.into()),\n}\n$0" },
      { trigger = "test", desc = "Rust unit test", template = "#[test]\nfn test_${1:name}() {\n    assert_eq!(${2:1 + 1}, ${3:2});\n    $0\n}" },
      { trigger = "pln", desc = "println! macro", template = "println!(\"${1:{}}\", ${2:val});$0" }
    }
  },

  -- ==========================================================================
  -- 9. C / C++
  -- ==========================================================================
  {
    files = { "%.c$", "%.cpp$", "%.h$", "%.hpp$", "%.cc$", "%.cxx$" },
    snippets = {
      { trigger = "main", desc = "C/C++ main entrypoint", template = "int main(int argc, char *argv[]) {\n    $0\n    return 0;\n}" },
      { trigger = "inc", desc = "#include <header>", template = "#include <${1:stdio.h}>\n$0" },
      { trigger = "incq", desc = "#include \"local.h\"", template = "#include \"${1:header.h}\"\n$0" },
      { trigger = "printf", desc = "printf statement", template = "printf(\"${1:%s}\\n\", ${2:val});$0" },
      { trigger = "cout", desc = "std::cout stream", template = "std::cout << ${1:\"message\"} << std::endl;$0" },
      { trigger = "cin", desc = "std::cin stream", template = "std::cin >> ${1:var};$0" },
      { trigger = "fori", desc = "Index for-loop", template = "for (int ${1:i} = 0; ${1:i} < ${2:n}; ++${1:i}) {\n    $0\n}" },
      { trigger = "class", desc = "C++ class definition", template = "class ${1:ClassName} {\npublic:\n    ${1:ClassName}();\n    ~${1:ClassName}();\n\nprivate:\n    $0\n};" },
      { trigger = "struct", desc = "C struct definition", template = "typedef struct {\n    ${2:int} ${3:field};\n} ${1:Name};$0" },
      { trigger = "guard", desc = "Header include guard", template = "#ifndef ${1:HEADER_H}\n#define ${1:HEADER_H}\n\n$0\n\n#endif // ${1:HEADER_H}" },
      { trigger = "vector", desc = "std::vector initialization", template = "std::vector<${1:int}> ${2:vec};$0" }
    }
  },

  -- ==========================================================================
  -- 10. SQL & DATABASE
  -- ==========================================================================
  {
    files = { "%.sql$" },
    snippets = {
      { trigger = "select", desc = "SQL SELECT query", template = "SELECT ${1:*}\nFROM ${2:table_name}\nWHERE ${3:condition};$0" },
      { trigger = "insert", desc = "SQL INSERT statement", template = "INSERT INTO ${1:table_name} (${2:columns})\nVALUES (${3:values});$0" },
      { trigger = "update", desc = "SQL UPDATE statement", template = "UPDATE ${1:table_name}\nSET ${2:column} = ${3:value}\nWHERE ${4:condition};$0" },
      { trigger = "delete", desc = "SQL DELETE statement", template = "DELETE FROM ${1:table_name}\nWHERE ${2:condition};$0" },
      { trigger = "create-table", desc = "SQL CREATE TABLE DDL", template = "CREATE TABLE ${1:table_name} (\n    id SERIAL PRIMARY KEY,\n    ${2:name} VARCHAR(255) NOT NULL,\n    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP\n);$0" },
      { trigger = "join", desc = "SQL INNER JOIN query", template = "SELECT ${1:t1.*, t2.*}\nFROM ${2:table1} t1\nINNER JOIN ${3:table2} t2 ON t1.${4:id} = t2.${5:t1_id}\nWHERE ${6:condition};$0" },
      { trigger = "index", desc = "SQL CREATE INDEX", template = "CREATE INDEX idx_${1:table}_${2:col} ON ${1:table}(${2:col});$0" }
    }
  },

  -- ==========================================================================
  -- 11. DEVOPS (DOCKER, KUBERNETES, GITHUB ACTIONS)
  -- ==========================================================================
  {
    files = { "Dockerfile", "%.dockerfile$", "docker%-compose%.ya?ml$", "%.ya?ml$" },
    snippets = {
      { trigger = "docker-node", desc = "Production Node.js Dockerfile", template = "FROM node:20-alpine AS builder\nWORKDIR /app\nCOPY package*.json ./\nRUN npm ci\nCOPY . .\nRUN npm run build\n\nFROM node:20-alpine AS runner\nWORKDIR /app\nENV NODE_ENV=production\nCOPY --from=builder /app ./ \nEXPOSE ${1:3000}\nCMD [\"npm\", \"start\"]\n" },
      { trigger = "docker-python", desc = "Production Python Dockerfile", template = "FROM python:3.12-slim\nWORKDIR /app\nENV PYTHONUNBUFFERED=1\nCOPY requirements.txt .\nRUN pip install --no-cache-dir -r requirements.txt\nCOPY . .\nEXPOSE ${1:8000}\nCMD [\"uvicorn\", \"main:app\", \"--host\", \"0.0.0.0\", \"--port\", \"${1:8000}\"]\n" },
      { trigger = "docker-go", desc = "Multi-Stage Go Dockerfile", template = "FROM golang:1.22-alpine AS builder\nWORKDIR /app\nCOPY go.mod go.sum ./\nRUN go mod download\nCOPY . .\nRUN CGO_ENABLED=0 GOOS=linux go build -o /server .\n\nFROM alpine:latest\nWORKDIR /\nCOPY --from=builder /server /server\nEXPOSE ${1:8080}\nCMD [\"/server\"]\n" },
      { trigger = "compose-web-db", desc = "Docker Compose (App + Postgres)", template = "version: '3.8'\n\nservices:\n  app:\n    build: .\n    ports:\n      - \"${1:3000}:${1:3000}\"\n    environment:\n      - DATABASE_URL=postgres://user:password@db:5432/app_db\n    depends_on:\n      - db\n\n  db:\n    image: postgres:16-alpine\n    restart: always\n    environment:\n      POSTGRES_USER: user\n      POSTGRES_PASSWORD: password\n      POSTGRES_DB: app_db\n    ports:\n      - \"5432:5432\"\n    volumes:\n      - pgdata:/var/lib/postgresql/data\n\nvolumes:\n  pgdata:\n" },
      { trigger = "k8s-dep", desc = "Kubernetes Deployment YAML", template = "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: ${1:app-name}\n  labels:\n    app: ${1:app-name}\nspec:\n  replicas: ${2:3}\n  selector:\n    matchLabels:\n      app: ${1:app-name}\n  template:\n    metadata:\n      labels:\n        app: ${1:app-name}\n    spec:\n      containers:\n      - name: ${1:app-name}\n        image: ${3:image:tag}\n        ports:\n        - containerPort: ${4:8080}\n" },
      { trigger = "k8s-svc", desc = "Kubernetes Service YAML", template = "apiVersion: v1\nkind: Service\nmetadata:\n  name: ${1:app-name}-svc\nspec:\n  selector:\n    app: ${1:app-name}\n  ports:\n  - protocol: TCP\n    port: ${2:80}\n    targetPort: ${3:8080}\n  type: ${4:ClusterIP}\n" },
      { trigger = "gha-ci", desc = "GitHub Actions CI Workflow", template = "name: CI\n\non:\n  push:\n    branches: [ main ]\n  pull_request:\n    branches: [ main ]\n\njobs:\n  test:\n    runs-on: ubuntu-latest\n    steps:\n    - uses: actions/checkout@v4\n    - name: Set up Environment\n      uses: actions/setup-node@v4\n      with:\n        node-version: 20\n    - run: npm ci\n    - run: npm test\n    - run: npm run build\n" }
    }
  }
}

-- Register All Snippets using native LSP Snippet parser with interactive tabstops
for _, pack in ipairs(SNIPPET_PACKS) do
  for _, snip in ipairs(pack.snippets) do
    snippets.add {
      trigger = snip.trigger,
      format = "lsp",
      files = pack.files,
      info = "Snippet",
      desc = snip.desc .. "\n\nTemplate Preview:\n" .. snip.template,
      template = snip.template
    }
  end
end

-- ============================================================================
-- TAILWIND CSS COMPREHENSIVE COLOR & UTILITY INTELLISENSE
-- ============================================================================
local TAILWIND_COLORS = {
  slate   = { [50]=_COLOR_CACHE_215, [100]=_COLOR_CACHE_41, [200]=_COLOR_CACHE_132, [300]=_COLOR_CACHE_212, [400]=_COLOR_CACHE_123, [500]=_COLOR_CACHE_89, [600]=_COLOR_CACHE_94, [700]=_COLOR_CACHE_114, [800]=_COLOR_CACHE_83, [900]=_COLOR_CACHE_185, [950]=_COLOR_CACHE_18 },
  gray    = { [50]=_COLOR_CACHE_208, [100]=_COLOR_CACHE_211, [200]=_COLOR_CACHE_178, [300]=_COLOR_CACHE_34, [400]=_COLOR_CACHE_9, [500]=_COLOR_CACHE_48, [600]=_COLOR_CACHE_96, [700]=_COLOR_CACHE_198, [800]=_COLOR_CACHE_29, [900]=_COLOR_CACHE_161, [950]=_COLOR_CACHE_98 },
  zinc    = { [50]=_COLOR_CACHE_92, [100]=_COLOR_CACHE_88, [200]=_COLOR_CACHE_199, [300]=_COLOR_CACHE_213, [400]=_COLOR_CACHE_193, [500]=_COLOR_CACHE_130, [600]=_COLOR_CACHE_5, [700]=_COLOR_CACHE_75, [800]=_COLOR_CACHE_39, [900]=_COLOR_CACHE_10, [950]=_COLOR_CACHE_165 },
  red     = { [50]=_COLOR_CACHE_168, [100]=_COLOR_CACHE_145, [200]=_COLOR_CACHE_203, [300]=_COLOR_CACHE_142, [400]=_COLOR_CACHE_160, [500]=_COLOR_CACHE_129, [600]=_COLOR_CACHE_166, [700]=_COLOR_CACHE_187, [800]=_COLOR_CACHE_81, [900]=_COLOR_CACHE_27, [950]=_COLOR_CACHE_214 },
  orange  = { [50]=_COLOR_CACHE_210, [100]=_COLOR_CACHE_186, [200]=_COLOR_CACHE_19, [300]=_COLOR_CACHE_115, [400]=_COLOR_CACHE_93, [500]=_COLOR_CACHE_189, [600]=_COLOR_CACHE_162, [700]=_COLOR_CACHE_108, [800]=_COLOR_CACHE_175, [900]=_COLOR_CACHE_119, [950]=_COLOR_CACHE_172 },
  amber   = { [50]=_COLOR_CACHE_197, [100]=_COLOR_CACHE_35, [200]=_COLOR_CACHE_143, [300]=_COLOR_CACHE_177, [400]=_COLOR_CACHE_28, [500]=_COLOR_CACHE_191, [600]=_COLOR_CACHE_36, [700]=_COLOR_CACHE_149, [800]=_COLOR_CACHE_141, [900]=_COLOR_CACHE_207, [950]=_COLOR_CACHE_131 },
  yellow  = { [50]=_COLOR_CACHE_106, [100]=_COLOR_CACHE_26, [200]=_COLOR_CACHE_52, [300]=_COLOR_CACHE_71, [400]=_COLOR_CACHE_154, [500]=_COLOR_CACHE_74, [600]=_COLOR_CACHE_110, [700]=_COLOR_CACHE_148, [800]=_COLOR_CACHE_150, [900]=_COLOR_CACHE_200, [950]=_COLOR_CACHE_171 },
  lime    = { [50]=_COLOR_CACHE_153, [100]=_COLOR_CACHE_133, [200]=_COLOR_CACHE_120, [300]=_COLOR_CACHE_169, [400]=_COLOR_CACHE_111, [500]=_COLOR_CACHE_82, [600]=_COLOR_CACHE_99, [700]=_COLOR_CACHE_167, [800]=_COLOR_CACHE_56, [900]=_COLOR_CACHE_126, [950]=_COLOR_CACHE_118 },
  green   = { [50]=_COLOR_CACHE_122, [100]=_COLOR_CACHE_53, [200]=_COLOR_CACHE_63, [300]=_COLOR_CACHE_219, [400]=_COLOR_CACHE_20, [500]=_COLOR_CACHE_51, [600]=_COLOR_CACHE_196, [700]=_COLOR_CACHE_38, [800]=_COLOR_CACHE_209, [900]=_COLOR_CACHE_15, [950]=_COLOR_CACHE_84 },
  emerald = { [50]=_COLOR_CACHE_42, [100]=_COLOR_CACHE_44, [200]=_COLOR_CACHE_31, [300]=_COLOR_CACHE_103, [400]=_COLOR_CACHE_57, [500]=_COLOR_CACHE_156, [600]=_COLOR_CACHE_113, [700]=_COLOR_CACHE_138, [800]=_COLOR_CACHE_91, [900]=_COLOR_CACHE_46, [950]=_COLOR_CACHE_16 },
  teal    = { [50]=_COLOR_CACHE_157, [100]=_COLOR_CACHE_21, [200]=_COLOR_CACHE_147, [300]=_COLOR_CACHE_97, [400]=_COLOR_CACHE_78, [500]=_COLOR_CACHE_112, [600]=_COLOR_CACHE_204, [700]=_COLOR_CACHE_54, [800]=_COLOR_CACHE_158, [900]=_COLOR_CACHE_107, [950]=_COLOR_CACHE_124 },
  cyan    = { [50]=_COLOR_CACHE_201, [100]=_COLOR_CACHE_170, [200]=_COLOR_CACHE_179, [300]=_COLOR_CACHE_0, [400]=_COLOR_CACHE_202, [500]=_COLOR_CACHE_50, [600]=_COLOR_CACHE_159, [700]=_COLOR_CACHE_144, [800]=_COLOR_CACHE_125, [900]=_COLOR_CACHE_127, [950]=_COLOR_CACHE_6 },
  sky     = { [50]=_COLOR_CACHE_45, [100]=_COLOR_CACHE_134, [200]=_COLOR_CACHE_60, [300]=_COLOR_CACHE_24, [400]=_COLOR_CACHE_85, [500]=_COLOR_CACHE_65, [600]=_COLOR_CACHE_188, [700]=_COLOR_CACHE_116, [800]=_COLOR_CACHE_216, [900]=_COLOR_CACHE_22, [950]=_COLOR_CACHE_77 },
  blue    = { [50]=_COLOR_CACHE_33, [100]=_COLOR_CACHE_135, [200]=_COLOR_CACHE_184, [300]=_COLOR_CACHE_151, [400]=_COLOR_CACHE_95, [500]=_COLOR_CACHE_61, [600]=_COLOR_CACHE_194, [700]=_COLOR_CACHE_40, [800]=_COLOR_CACHE_140, [900]=_COLOR_CACHE_117, [950]=_COLOR_CACHE_49 },
  indigo  = { [50]=_COLOR_CACHE_2, [100]=_COLOR_CACHE_69, [200]=_COLOR_CACHE_105, [300]=_COLOR_CACHE_62, [400]=_COLOR_CACHE_11, [500]=_COLOR_CACHE_128, [600]=_COLOR_CACHE_90, [700]=_COLOR_CACHE_76, [800]=_COLOR_CACHE_23, [900]=_COLOR_CACHE_67, [950]=_COLOR_CACHE_206 },
  violet  = { [50]=_COLOR_CACHE_66, [100]=_COLOR_CACHE_136, [200]=_COLOR_CACHE_173, [300]=_COLOR_CACHE_17, [400]=_COLOR_CACHE_155, [500]=_COLOR_CACHE_4, [600]=_COLOR_CACHE_43, [700]=_COLOR_CACHE_101, [800]=_COLOR_CACHE_79, [900]=_COLOR_CACHE_12, [950]=_COLOR_CACHE_14 },
  purple  = { [50]=_COLOR_CACHE_139, [100]=_COLOR_CACHE_180, [200]=_COLOR_CACHE_109, [300]=_COLOR_CACHE_87, [400]=_COLOR_CACHE_190, [500]=_COLOR_CACHE_47, [600]=_COLOR_CACHE_195, [700]=_COLOR_CACHE_181, [800]=_COLOR_CACHE_205, [900]=_COLOR_CACHE_182, [950]=_COLOR_CACHE_1 },
  fuchsia = { [50]=_COLOR_CACHE_8, [100]=_COLOR_CACHE_80, [200]=_COLOR_CACHE_176, [300]=_COLOR_CACHE_37, [400]=_COLOR_CACHE_68, [500]=_COLOR_CACHE_152, [600]=_COLOR_CACHE_218, [700]=_COLOR_CACHE_183, [800]=_COLOR_CACHE_174, [900]=_COLOR_CACHE_55, [950]=_COLOR_CACHE_13 },
  pink    = { [50]=_COLOR_CACHE_7, [100]=_COLOR_CACHE_192, [200]=_COLOR_CACHE_64, [300]=_COLOR_CACHE_73, [400]=_COLOR_CACHE_100, [500]=_COLOR_CACHE_164, [600]=_COLOR_CACHE_163, [700]=_COLOR_CACHE_137, [800]=_COLOR_CACHE_58, [900]=_COLOR_CACHE_104, [950]=_COLOR_CACHE_121 },
  rose    = { [50]=_COLOR_CACHE_146, [100]=_COLOR_CACHE_86, [200]=_COLOR_CACHE_102, [300]=_COLOR_CACHE_72, [400]=_COLOR_CACHE_32, [500]=_COLOR_CACHE_217, [600]=_COLOR_CACHE_59, [700]=_COLOR_CACHE_25, [800]=_COLOR_CACHE_30, [900]=_COLOR_CACHE_70, [950]=_COLOR_CACHE_3 }
}

local web_files = { "%.html$", "%.htm$", "%.jsx$", "%.tsx$", "%.vue$", "%.svelte$", "%.css$", "%.js$", "%.ts$" }
local tailwind_items = {}

for name, shades in pairs(TAILWIND_COLORS) do
  for shade, rgb in pairs(shades) do
    local hex = string.format("#%02x%02x%02x", rgb[1], rgb[2], rgb[3])
    
    local bg_key = string.format("bg-%s-%d", name, shade)
    tailwind_items[bg_key] = {
      info = "Tailwind",
      desc = string.format("Background color: %s (%s)\nRGB: rgb(%d, %d, %d)", bg_key, hex, rgb[1], rgb[2], rgb[3]),
      color = rgb
    }
    
    local text_key = string.format("text-%s-%d", name, shade)
    tailwind_items[text_key] = {
      info = "Tailwind",
      desc = string.format("Text color: %s (%s)\nRGB: rgb(%d, %d, %d)", text_key, hex, rgb[1], rgb[2], rgb[3]),
      color = rgb
    }

    local border_key = string.format("border-%s-%d", name, shade)
    tailwind_items[border_key] = {
      info = "Tailwind",
      desc = string.format("Border color: %s (%s)\nRGB: rgb(%d, %d, %d)", border_key, hex, rgb[1], rgb[2], rgb[3]),
      color = rgb
    }
  end
end

-- Layout & Display Utilities
local TAILWIND_LAYOUT = {
  ["flex"]            = "display: flex;",
  ["inline-flex"]     = "display: inline-flex;",
  ["grid"]            = "display: grid;",
  ["inline-grid"]     = "display: inline-grid;",
  ["block"]           = "display: block;",
  ["inline-block"]    = "display: inline-block;",
  ["hidden"]          = "display: none;",
  ["flex-col"]        = "flex-direction: column;",
  ["flex-row"]        = "flex-direction: row;",
  ["flex-wrap"]       = "flex-wrap: wrap;",
  ["flex-1"]          = "flex: 1 1 0%;",
  ["items-center"]    = "align-items: center;",
  ["items-start"]     = "align-items: flex-start;",
  ["items-end"]       = "align-items: flex-end;",
  ["justify-center"]  = "justify-content: center;",
  ["justify-between"] = "justify-content: space-between;",
  ["justify-start"]   = "justify-content: flex-start;",
  ["justify-end"]     = "justify-content: flex-end;",
  ["relative"]        = "position: relative;",
  ["absolute"]        = "position: absolute;",
  ["fixed"]           = "position: fixed;",
  ["sticky"]          = "position: sticky;",
  ["w-full"]          = "width: 100%;",
  ["w-screen"]        = "width: 100vw;",
  ["h-full"]          = "height: 100%;",
  ["h-screen"]        = "height: 100vh;",
  ["min-h-screen"]    = "min-height: 100vh;",
  ["rounded"]         = "border-radius: 0.25rem;",
  ["rounded-md"]      = "border-radius: 0.375rem;",
  ["rounded-lg"]      = "border-radius: 0.5rem;",
  ["rounded-xl"]      = "border-radius: 0.75rem;",
  ["rounded-2xl"]     = "border-radius: 1rem;",
  ["rounded-full"]    = "border-radius: 9999px;",
  ["shadow-sm"]       = "box-shadow: 0 1px 2px 0 rgb(0 0 0 / 0.05);",
  ["shadow"]          = "box-shadow: 0 1px 3px 0 rgb(0 0 0 / 0.1);",
  ["shadow-md"]       = "box-shadow: 0 4px 6px -1px rgb(0 0 0 / 0.1);",
  ["shadow-lg"]       = "box-shadow: 0 10px 15px -3px rgb(0 0 0 / 0.1);",
  ["shadow-xl"]       = "box-shadow: 0 20px 25px -5px rgb(0 0 0 / 0.1);",
  ["cursor-pointer"]  = "cursor: pointer;",
  ["overflow-hidden"] = "overflow: hidden;",
  ["overflow-auto"]   = "overflow: auto;",
  ["transition-all"]  = "transition-property: all; transition-timing-function: cubic-bezier(0.4, 0, 0.2, 1); transition-duration: 150ms;"
}

for class_name, css_val in pairs(TAILWIND_LAYOUT) do
  tailwind_items[class_name] = {
    info = "Tailwind",
    desc = string.format("Tailwind CSS Utility:\n%s {\n  %s\n}", class_name, css_val)
  }
end

-- Spacing scale (p-*, m-*, gap-*)
local SPACING = { [0]="0px", [1]="0.25rem", [2]="0.5rem", [3]="0.75rem", [4]="1rem", [5]="1.25rem", [6]="1.5rem", [8]="2rem", [10]="2.5rem", [12]="3rem", [16]="4rem", [20]="5rem", [24]="6rem" }
for k, v in pairs(SPACING) do
  local p_key = "p-" .. tostring(k)
  tailwind_items[p_key] = { info = "Tailwind", desc = string.format("Padding: %s (%s)", p_key, v) }
  local px_key = "px-" .. tostring(k)
  tailwind_items[px_key] = { info = "Tailwind", desc = string.format("Horizontal Padding: %s (%s)", px_key, v) }
  local py_key = "py-" .. tostring(k)
  tailwind_items[py_key] = { info = "Tailwind", desc = string.format("Vertical Padding: %s (%s)", py_key, v) }
  local m_key = "m-" .. tostring(k)
  tailwind_items[m_key] = { info = "Tailwind", desc = string.format("Margin: %s (%s)", m_key, v) }
  local gap_key = "gap-" .. tostring(k)
  tailwind_items[gap_key] = { info = "Tailwind", desc = string.format("Grid/Flex Gap: %s (%s)", gap_key, v) }
end

autocomplete.add {
  name = "tailwind-intellisense",
  files = web_files,
  items = tailwind_items
}

return {
  packs = SNIPPET_PACKS
}

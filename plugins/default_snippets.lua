-- mod-version:3
-- Comprehensive Universal Multi-Stack Snippet Library for Lite XL
-- Covers: React, Next.js, Vue 3, Svelte, Express, FastAPI, Flask, Django,
--         Spring Boot, Go, Rust, C/C++, Java, SQL, Docker, K8s, GitHub Actions,
--         Tailwind CSS, and HTML5.

local core = require "core"
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
  slate   = { [50]={248,250,252}, [100]={241,245,249}, [200]={226,232,240}, [300]={203,213,225}, [400]={148,163,184}, [500]={100,116,139}, [600]={71,85,105}, [700]={51,65,85}, [800]={30,41,59}, [900]={15,23,42}, [950]={2,6,23} },
  gray    = { [50]={249,250,251}, [100]={243,244,246}, [200]={229,231,235}, [300]={209,213,219}, [400]={156,163,175}, [500]={107,114,128}, [600]={75,85,99}, [700]={55,65,81}, [800]={31,41,55}, [900]={17,24,39}, [950]={3,7,18} },
  zinc    = { [50]={250,250,250}, [100]={244,244,245}, [200]={228,228,231}, [300]={212,212,216}, [400]={161,161,170}, [500]={113,113,122}, [600]={82,82,91}, [700]={63,63,70}, [800]={39,39,42}, [900]={24,24,27}, [950]={9,9,11} },
  red     = { [50]={254,242,242}, [100]={254,226,226}, [200]={254,202,202}, [300]={252,165,165}, [400]={248,113,113}, [500]={239,68,68}, [600]={220,38,38}, [700]={185,28,28}, [800]={153,27,27}, [900]={127,29,29}, [950]={69,10,10} },
  orange  = { [50]={255,247,237}, [100]={255,237,213}, [200]={254,215,170}, [300]={253,186,116}, [400]={251,146,60}, [500]={249,115,22}, [600]={234,88,12}, [700]={194,65,12}, [800]={154,52,18}, [900]={124,45,18}, [950]={67,20,7} },
  amber   = { [50]={255,251,235}, [100]={254,243,199}, [200]={253,230,138}, [300]={252,211,77}, [400]={251,191,36}, [500]={245,158,11}, [600]={217,119,6}, [700]={180,83,9}, [800]={146,64,14}, [900]={120,53,15}, [950]={69,26,3} },
  yellow  = { [50]={254,252,232}, [100]={254,249,195}, [200]={254,240,138}, [300]={253,224,71}, [400]={250,204,21}, [500]={234,179,8}, [600]={202,138,4}, [700]={161,98,7}, [800]={133,77,14}, [900]={113,63,18}, [950]={66,32,6} },
  lime    = { [50]={247,254,231}, [100]={236,252,203}, [200]={217,249,157}, [300]={190,242,100}, [400]={163,230,53}, [500]={132,204,22}, [600]={101,163,13}, [700]={77,124,15}, [800]={63,98,18}, [900]={54,83,20}, [950]={26,46,5} },
  green   = { [50]={240,253,244}, [100]={220,252,231}, [200]={187,247,208}, [300]={134,239,172}, [400]={74,222,128}, [500]={34,197,94}, [600]={22,163,74}, [700]={21,128,61}, [800]={22,101,52}, [900]={20,83,45}, [950]={5,46,22} },
  emerald = { [50]={236,253,245}, [100]={209,250,229}, [200]={167,243,208}, [300]={110,231,183}, [400]={52,211,153}, [500]={16,185,129}, [600]={5,150,105}, [700]={4,120,87}, [800]={6,95,70}, [900]={6,78,59}, [950]={2,44,34} },
  teal    = { [50]={240,253,250}, [100]={204,251,241}, [200]={153,246,228}, [300]={94,234,212}, [400]={45,212,191}, [500]={20,184,166}, [600]={13,148,136}, [700]={15,118,110}, [800]={17,94,89}, [900]={19,78,74}, [950]={4,47,46} },
  cyan    = { [50]={236,254,255}, [100]={207,250,254}, [200]={165,243,252}, [300]={103,232,249}, [400]={34,211,238}, [500]={6,182,212}, [600]={8,145,178}, [700]={14,116,144}, [800]={21,94,117}, [900]={22,78,99}, [950]={8,51,68} },
  sky     = { [50]={240,249,255}, [100]={224,242,254}, [200]={186,230,253}, [300]={125,211,252}, [400]={56,189,248}, [500]={14,165,233}, [600]={2,132,199}, [700]={3,105,161}, [800]={7,89,133}, [900]={12,74,110}, [950]={8,47,73} },
  blue    = { [50]={239,246,255}, [100]={219,234,254}, [200]={191,219,254}, [300]={147,197,253}, [400]={96,165,250}, [500]={59,130,246}, [600]={37,99,235}, [700]={29,78,216}, [800]={30,64,175}, [900]={30,58,138}, [950]={23,37,84} },
  indigo  = { [50]={238,242,255}, [100]={224,231,255}, [200]={199,210,254}, [300]={165,180,252}, [400]={129,140,248}, [500]={99,102,241}, [600]={79,70,229}, [700]={67,56,202}, [800]={55,48,163}, [900]={49,46,129}, [950]={30,27,75} },
  violet  = { [50]={245,243,255}, [100]={237,233,254}, [200]={221,214,254}, [300]={196,181,253}, [400]={167,139,250}, [500]={139,92,246}, [600]={124,58,237}, [700]={109,40,217}, [800]={91,33,182}, [900]={76,29,149}, [950]={46,16,101} },
  purple  = { [50]={250,245,255}, [100]={243,232,255}, [200]={233,213,255}, [300]={216,180,254}, [400]={192,132,252}, [500]={168,85,247}, [600]={147,51,234}, [700]={126,34,206}, [800]={107,33,168}, [900]={88,28,135}, [950]={59,7,100} },
  fuchsia = { [50]={253,244,255}, [100]={250,232,255}, [200]={245,208,254}, [300]={240,171,252}, [400]={232,121,249}, [500]={217,70,239}, [600]={192,38,211}, [700]={162,28,175}, [800]={134,25,143}, [900]={112,26,117}, [950]={74,4,78} },
  pink    = { [50]={253,242,248}, [100]={252,231,243}, [200]={251,207,232}, [300]={249,168,212}, [400]={244,114,182}, [500]={236,72,153}, [600]={219,39,119}, [700]={190,24,93}, [800]={157,23,77}, [900]={131,24,67}, [950]={80,7,36} },
  rose    = { [50]={255,241,242}, [100]={255,228,230}, [200]={254,205,211}, [300]={253,164,175}, [400]={251,113,133}, [500]={244,63,94}, [600]={225,29,72}, [700]={190,18,60}, [800]={159,18,57}, [900]={136,19,55}, [950]={76,5,25} }
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

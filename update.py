import os

# Update install.ps1
with open("install.ps1", "r", encoding="utf-8") as f:
    content = f.read()
    
old_block = """    if ($realPython) {
        try { & python -m pip install pymongo --quiet 2>$null } catch {}
    }
}"""

new_block = """    if ($realPython) {
        try { & python -m pip install pymongo --quiet 2>$null } catch {}
    }
}

if ($realPython) {
    Write-Host "Installing Core AI Dependencies (LangGraph, MCP, Graphify, etc.)..." -ForegroundColor Cyan
    try { & python -m pip install langchain-core langchain-google-genai langchain-groq langchain-openai langchain-anthropic langgraph mcp langchain-mcp-adapters graphifyy duckduckgo-search psutil --quiet 2>$null } catch {}
}"""

content = content.replace(old_block, new_block)
with open("install.ps1", "w", encoding="utf-8") as f:
    f.write(content)


# Update install.sh
with open("install.sh", "r", encoding="utf-8") as f:
    content = f.read()
    
old_block = """        if command -v python3 &> /dev/null; then
            python3 -m pip install pymongo --break-system-packages --quiet 2>/dev/null || \
            python3 -m pip install pymongo --user --quiet 2>/dev/null || \
            python3 -m pip install pymongo --quiet 2>/dev/null || true
        fi
    fi
fi

animate_progress "Installing Lite-XL Mossy Configuration & Plugins...\""""

new_block = """        if command -v python3 &> /dev/null; then
            python3 -m pip install pymongo --break-system-packages --quiet 2>/dev/null || \
            python3 -m pip install pymongo --user --quiet 2>/dev/null || \
            python3 -m pip install pymongo --quiet 2>/dev/null || true
        fi
    fi
fi

if command -v python3 &> /dev/null; then
    echo "Installing Core AI Dependencies (LangGraph, MCP, Graphify, etc.)..."
    python3 -m pip install langchain-core langchain-google-genai langchain-groq langchain-openai langchain-anthropic langgraph mcp langchain-mcp-adapters graphifyy duckduckgo-search psutil --break-system-packages --quiet 2>/dev/null || \
    python3 -m pip install langchain-core langchain-google-genai langchain-groq langchain-openai langchain-anthropic langgraph mcp langchain-mcp-adapters graphifyy duckduckgo-search psutil --user --quiet 2>/dev/null || \
    python3 -m pip install langchain-core langchain-google-genai langchain-groq langchain-openai langchain-anthropic langgraph mcp langchain-mcp-adapters graphifyy duckduckgo-search psutil --quiet 2>/dev/null || true
fi

animate_progress "Installing Lite-XL Mossy Configuration & Plugins...\""""

content = content.replace(old_block, new_block)
with open("install.sh", "w", encoding="utf-8") as f:
    f.write(content)

print("Setup scripts patched!")
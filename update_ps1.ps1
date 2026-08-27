$file = "install.ps1"
$content = Get-Content $file -Raw
$new_deps = "langchain-core langchain-google-genai langchain-groq langchain-openai langchain-anthropic langgraph mcp langchain-mcp-adapters graphifyy duckduckgo-search psutil"

$old_block = """    if ($realPython) {
        try { & python -m pip install pymongo --quiet 2>$null } catch {}
    }"""

$new_block = """    if ($realPython) {
        try { & python -m pip install pymongo --quiet 2>$null } catch {}
    }
}

if ($realPython) {
    Write-Host "Installing Core AI Dependencies (LangGraph, MCP, Graphify, etc.)..." -ForegroundColor Cyan
    try { & python -m pip install langchain-core langchain-google-genai langchain-groq langchain-openai langchain-anthropic langgraph mcp langchain-mcp-adapters graphifyy duckduckgo-search psutil --quiet 2>$null } catch {
        Write-Host "WARNING: Failed to install some AI dependencies." -ForegroundColor Yellow
    }"""

$content = $content.Replace($old_block, $new_block)
[IO.File]::WriteAllText($file, $content)
Write-Output "Updated install.ps1"
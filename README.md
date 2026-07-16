# Project Documentation

## Features

### 1. Framework Detection & Status Bar Controls
- The Antigravity environment dynamically detects the frameworks used in your project (e.g., React, Node, Python, Vite, Next.js).
- Interactive controls appear in the status bar at the bottom. Clicking them triggers relevant actions, such as running the development server for that specific framework.

### 2. Venv-Aware Terminal States
- The integrated terminal automatically detects if a Python virtual environment (`venv`, `.venv`, `env`, etc.) exists in the workspace.
- It will automatically activate the virtual environment upon terminal launch, ensuring that package commands run in the correct isolated context.
- Zombified Python processes (like Flask apps stuck on port 5000) can be searched and forcefully terminated via the Terminal/Port Manager UI.

### 3. Port Manager & Live Preview
- The Port Manager allows multi-selecting and searching active processes by port and killing them in bulk.
- Live Web Preview will automatically scan for open development ports (e.g., 5173-5177 for Vite) and proxy the webview to the correct active port, rendering it inside the IDE natively.

#!/usr/bin/env python3
"""
setup_google_workspace_mcp.py

Interactive OAuth setup and configuration script for Google Workspace MCP in Lite-XL.
Integrates:
- Gmail MCP (search, read, drafts, reply, send)
- Google Docs MCP (create, read, append, insert, markdown)
- Google Sheets MCP (create, read, write, append, format, merge)
- Google Slides MCP (create, edit slides, text, markdown presentation)
- Google Calendar MCP (events, schedule, delete)
- Google Meet MCP (create meetings with Google Meet video conferences)
- Google Drive MCP (search, upload, organize)
"""

import os
import sys
import json
import glob
import webbrowser
from pathlib import Path

try:
    from google_auth_oauthlib.flow import InstalledAppFlow
    from google.oauth2.credentials import Credentials
except ImportError:
    print("Missing required package 'google-auth-oauthlib'. Installing...", flush=True)
    import subprocess
    subprocess.check_call([sys.executable, "-m", "pip", "install", "google-auth-oauthlib", "google-workspace-mcp"])
    from google_auth_oauthlib.flow import InstalledAppFlow
    from google.oauth2.credentials import Credentials

SCOPES = [
    "https://www.googleapis.com/auth/gmail.modify",
    "https://www.googleapis.com/auth/documents",
    "https://www.googleapis.com/auth/spreadsheets",
    "https://www.googleapis.com/auth/presentations",
    "https://www.googleapis.com/auth/calendar",
    "https://www.googleapis.com/auth/calendar.events",
    "https://www.googleapis.com/auth/drive",
]

def find_client_secrets_file():
    # 1. Check command line argument
    if len(sys.argv) > 1 and os.path.exists(sys.argv[1]):
        return os.path.abspath(sys.argv[1])
    
    # 2. Check current directory and script directory
    script_dir = os.path.dirname(os.path.abspath(__file__))
    candidates = glob.glob(os.path.join(script_dir, "client_secret*.json"))
    if candidates:
        return candidates[0]
        
    # 3. Check Downloads directory
    user_home = Path.home()
    downloads_dir = user_home / "Downloads"
    download_candidates = sorted(
        downloads_dir.glob("client_secret*.json"),
        key=os.path.getmtime,
        reverse=True
    )
    if download_candidates:
        return str(download_candidates[0])
        
    return None

def main():
    print("=" * 65)
    print("  Lite-XL Google Workspace MCP OAuth Authorization Setup")
    print("=" * 65)
    print("Services included: Gmail, Docs, Sheets, Slides, Calendar & Meet\n")
    
    creds_file = find_client_secrets_file()
    if not creds_file:
        print("ERROR: Could not find client_secret_*.json file automatically.")
        print("Please provide the path to your OAuth Client ID JSON file:")
        creds_file = input("Path: ").strip(' "\'')
        if not os.path.exists(creds_file):
            print(f"File not found: {creds_file}")
            sys.exit(1)
            
    print(f"Using OAuth client secrets: {creds_file}")
    
    with open(creds_file, "r", encoding="utf-8") as f:
        data = json.load(f)
        client_info = data.get("installed") or data.get("web") or {}
        client_id = client_info.get("client_id")
        client_secret = client_info.get("client_secret")
        
    if not client_id or not client_secret:
        print("ERROR: Invalid credentials file. Missing 'client_id' or 'client_secret'.")
        sys.exit(1)
        
    print(f"Client ID: {client_id[:25]}... (valid)")
    print("\nStarting local OAuth 2.0 authorization server...")
    print("Your browser should open automatically.")
    print("If it does not, click the URL below and approve the permissions for your Google account.\n")

    flow = InstalledAppFlow.from_client_secrets_file(creds_file, scopes=SCOPES)
    try:
        creds = flow.run_local_server(
            port=0,
            authorization_prompt_message="Visit this URL to authorize Lite-XL Google Workspace tools:\n{url}\n",
            success_message="Authorization successful! Google Workspace MCP is now authenticated for Lite-XL. You may close this tab.",
            open_browser=True,
            access_type="offline",
            prompt="consent"
        )
    except Exception as e:
        print(f"\nLocal server failed ({e}), attempting console auth flow...")
        creds = flow.run_console(access_type="offline", prompt="consent")

    refresh_token = creds.refresh_token
    if not refresh_token:
        print("\nWARNING: No refresh token returned. If you already authorized this app before,")
        print("Google may only return an access token unless consent is forced.")
        print("Please run this script again and ensure you click 'Allow'.")
        sys.exit(1)

    print("\nSUCCESS: Obtained OAuth refresh token!")

    # Target mcp_config.json paths
    config_paths = [
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "mcp_config.json"),
        os.path.expanduser("~/.config/lite-xl/scripts/mcp_config.json"),
        os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts/mcp_config.json")
    ]

    updated_paths = set()
    for cfg_path in config_paths:
        cfg_path = os.path.abspath(cfg_path)
        if cfg_path in updated_paths or not os.path.exists(os.path.dirname(cfg_path)):
            continue

        cfg = {}
        if os.path.exists(cfg_path):
            try:
                with open(cfg_path, "r", encoding="utf-8") as f:
                    cfg = json.load(f)
            except Exception:
                cfg = {}

        if "mcpServers" not in cfg:
            cfg["mcpServers"] = {}

        # Configure unified google-workspace server
        cfg["mcpServers"]["google-workspace"] = {
            "command": "python",
            "args": ["-m", "google_workspace_mcp"],
            "env": {
                "GOOGLE_WORKSPACE_CLIENT_ID": client_id,
                "GOOGLE_WORKSPACE_CLIENT_SECRET": client_secret,
                "GOOGLE_WORKSPACE_REFRESH_TOKEN": refresh_token
            }
        }

        with open(cfg_path, "w", encoding="utf-8") as f:
            json.dump(cfg, f, indent=2)

        print(f"Updated configuration in: {cfg_path}")
        updated_paths.add(cfg_path)

    print("\nConfiguration complete! 57 Google Workspace tools are now active in Lite-XL.")
    print("Tools include:")
    print("  - Gmail: query_gmail_emails, gmail_send_email, create_gmail_draft, ...")
    print("  - Docs: docs_create_document, docs_get_content_as_markdown, docs_append_text, ...")
    print("  - Sheets: sheets_create_spreadsheet, sheets_read_range, sheets_write_range, ...")
    print("  - Slides: create_presentation, add_text_to_slide, create_presentation_from_markdown, ...")
    print("  - Calendar & Meet: calendar_get_events, create_calendar_event (with Meet video link)")
    print("  - Drive: drive_search_files, drive_upload_file, drive_create_folder, ...")

if __name__ == "__main__":
    main()

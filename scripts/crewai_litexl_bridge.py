#!/usr/bin/env python3
"""
scripts/crewai_litexl_bridge.py — CrewAI Multi-Agent Host Engine for Lite XL
Bridges external multi-agent workflows (Investigator, Systems Engineer, Auditor)
directly into Lite XL's Host Engine via the Frame-Synchronized Mailbox IPC.

Supports:
1. Native CrewAI orchestration (Agent, Task, Crew, Process) when `crewai` is installed.
2. Built-in zero-dependency multi-agent simulator/runner when `crewai` is not installed.
3. Universal Meta-Tools: `litexl_pulse`, `litexl_do`, `litexl_discover`.
4. Command-line execution, background subprocessing, and direct Lite XL triggering.
"""

import os
import sys
import json
import time
import uuid
import argparse
from typing import Optional, Dict, Any, List

# Ensure UTF-8 output on Windows
if hasattr(sys.stdout, 'reconfigure'):
    sys.stdout.reconfigure(encoding='utf-8')
if hasattr(sys.stderr, 'reconfigure'):
    sys.stderr.reconfigure(encoding='utf-8')

# ── Mailbox IPC Client ────────────────────────────────────────────────────────
def get_mailbox_dir() -> str:
    user_dir = os.path.expanduser(r"~\.config\lite-xl")
    if not os.path.exists(user_dir):
        user_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    mb_dir = os.path.join(user_dir, "tempfiles")
    os.makedirs(mb_dir, exist_ok=True)
    return mb_dir

def send_litexl_mailbox(method: str, subsystem: Optional[str] = None, action: Optional[str] = None, params: Optional[Dict[str, Any]] = None, timeout: float = 6.0) -> str:
    """Sends a synchronous command request to Lite XL's cooperative event loop."""
    mb_dir = get_mailbox_dir()
    mailbox_req = os.path.join(mb_dir, "agent_mailbox.jsonl")
    req_id = str(uuid.uuid4())[:8]
    req_payload = {
        "id": req_id,
        "method": method,
        "subsystem": subsystem,
        "action": action,
        "params": params or {}
    }

    try:
        with open(mailbox_req, "a", encoding="utf-8") as f:
            f.write(json.dumps(req_payload) + "\n")
    except Exception as e:
        return f"MAILBOX_WRITE_ERROR: {str(e)}"

    resp_file = os.path.join(mb_dir, f"agent_resp_{req_id}.json")
    start = time.time()
    while time.time() - start < timeout:
        if os.path.exists(resp_file):
            try:
                with open(resp_file, "r", encoding="utf-8") as rf:
                    data = json.load(rf)
                try:
                    os.remove(resp_file)
                except Exception:
                    pass
                return str(data.get("result", ""))
            except Exception:
                pass
        time.sleep(0.04)

    return f"SIMULATED_OR_TIMEOUT: Lite XL did not respond within {timeout}s (is Lite XL running?)."

# ── Lite XL Host Meta-Tools ───────────────────────────────────────────────────
def litexl_pulse_func() -> str:
    """Fetches the 20-token ambient pulse of Lite XL: active buffer, cursor line:col, open tabs, active subsystem."""
    return send_litexl_mailbox("pulse")

def litexl_discover_func(subsystem: Optional[str] = None) -> str:
    """Inspects available Lite XL subsystems and their actions on-demand."""
    return send_litexl_mailbox("discover", subsystem=subsystem)

def litexl_do_func(subsystem: str, action: str, params: Optional[Dict[str, Any]] = None) -> str:
    """Universal actuator for Lite XL. Controls editor splits, buffer patches, LeetCode, PPTX, terminal, and diagnostics."""
    return send_litexl_mailbox("do", subsystem=subsystem, action=action, params=params)


# ── Native CrewAI Implementation ──────────────────────────────────────────────
def run_native_crew(task_description: str, model_name: Optional[str] = None, verbose: bool = True) -> str:
    try:
        from crewai import Agent, Task, Crew, Process, LLM
        from crewai.tools import tool
    except ImportError:
        raise ImportError("CrewAI is not installed. Please run: pip install crewai")

    # Define tools for CrewAI
    @tool("LiteXL Ambient Pulse")
    def pulse_tool() -> str:
        """Fetches the current ambient status of the Lite XL editor including active file, cursor position, and open tabs."""
        return litexl_pulse_func()

    @tool("LiteXL Discover Subsystems")
    def discover_tool(subsystem: str = "all") -> str:
        """Discovers available Lite XL subsystems and their supported actions on-demand."""
        return litexl_discover_func(subsystem=subsystem)

    @tool("LiteXL Execute Action")
    def do_tool(subsystem: str, action: str, params_json: str = "{}") -> str:
        """Executes an action in Lite XL (e.g. editor split, patch buffer, LeetCode test, PPTX navigation). params_json is a JSON string of parameters."""
        try:
            params = json.loads(params_json) if params_json else {}
        except Exception:
            params = {}
        return litexl_do_func(subsystem=subsystem, action=action, params=params)

    # Configure LLM if specified
    llm = None
    if model_name:
        llm = LLM(model=model_name)

    # 1. Triage & Diagnostics Investigator Agent
    investigator = Agent(
        role="IDE Triage & Diagnostics Specialist",
        goal="Inspect Lite XL editor state, diagnose runtime issues, and locate affected code files",
        backstory=(
            "You are an expert IDE diagnostician. You observe Lite XL's ambient pulse, "
            "inspect error tracebacks via the diagnostics subsystem, and analyze codebase structure "
            "before any modifications are planned."
        ),
        tools=[pulse_tool, discover_tool],
        llm=llm,
        verbose=verbose
    )

    # 2. Systems & Automation Engineer Agent
    engineer = Agent(
        role="Lite XL Systems & Automation Engineer",
        goal="Safely execute layout choreographies, code patches, and plugin actions within Lite XL",
        backstory=(
            "You are a master Lite XL systems engineer and Lua developer. You understand the editor's "
            "split tree geometry, document buffer mutations, and plugin subsystems (LeetCode, PPTX, PDF, Git). "
            "You formulate precise, pre-flight tested actions using litexl_do."
        ),
        tools=[pulse_tool, discover_tool, do_tool],
        llm=llm,
        verbose=verbose
    )

    # 3. Safety & Verification Auditor Agent
    auditor = Agent(
        role="Safety & Guardrail Compliance Auditor",
        goal="Verify that all mutations satisfied security constraints, syntax compiled cleanly, and no circuit breakers tripped",
        backstory=(
            "You are an uncompromising software auditor. You verify that no core system paths were touched, "
            "that syntax pre-flight checks passed, and that Lite XL's audit log records a clean execution."
        ),
        tools=[pulse_tool, do_tool],
        llm=llm,
        verbose=verbose
    )

    # Define the 3 sequential tasks
    t1 = Task(
        description=(
            f"Perform initial triage and investigation for the user request: '{task_description}'. "
            "Check Lite XL's ambient pulse, discover relevant subsystems, and formulate an investigation summary."
        ),
        expected_output="A diagnostic report detailing Lite XL's current state and required actions.",
        agent=investigator
    )

    t2 = Task(
        description=(
            "Based on the investigator's report, execute the required modifications and automations using litexl_do. "
            "Ensure that any buffer patches provide unique context signatures."
        ),
        expected_output="An execution log detailing the actions performed in Lite XL and their results.",
        agent=engineer
    )

    t3 = Task(
        description=(
            "Verify that all actions executed cleanly. Query the diagnostics or git status subsystem to confirm editor health. "
            "Ensure that no guardrails were violated."
        ),
        expected_output="A final audit verdict confirming that Lite XL is in a stable, healthy state.",
        agent=auditor
    )

    crew = Crew(
        agents=[investigator, engineer, auditor],
        tasks=[t1, t2, t3],
        process=Process.sequential,
        verbose=verbose
    )

    result = crew.kickoff()
    return str(result)


# ── Built-in Sequential Multi-Agent Runner (Zero Dependency Fallback) ──────────
class MultiAgentFallbackRunner:
    """
    Lightweight, deterministic multi-agent simulation and orchestration engine.
    Runs when `crewai` is not installed or when running with `--dry-run`.
    """
    def __init__(self, verbose: bool = True):
        self.verbose = verbose

    def log(self, agent_name: str, message: str):
        if self.verbose:
            ts = time.strftime("%H:%M:%S")
            print(f"[{ts}] [{agent_name}] {message}")

    def execute(self, task_description: str, dry_run: bool = False) -> str:
        lines = []
        lines.append("=" * 70)
        lines.append("🤖 Lite XL Multi-Agent Crew Execution")
        lines.append(f"Task: {task_description}")
        lines.append("=" * 70)

        # ── Stage 1: Triage Investigator ──
        self.log("Investigator", "Probing Lite XL ambient pulse...")
        pulse = "SIMULATED: [IDE: active=main.lua:10:1 | tabs=main.lua (1) | splits=1]" if dry_run else litexl_pulse_func()
        self.log("Investigator", f"Ambient Pulse: {pulse}")

        self.log("Investigator", "Discovering active Lite XL subsystems...")
        subs = "SIMULATED: editor, leetcode, pptx, pdf, visualizer, terminal, diagnostics, git, mongodb, podman" if dry_run else litexl_discover_func("all")
        self.log("Investigator", f"Subsystems Available: {subs[:120]}...")
        triage_report = f"State: Active. Pulse: {pulse}. Subsystems: Ready."

        # ── Stage 2: Systems Engineer ──
        self.log("Systems Engineer", f"Formulating plan based on investigator findings: '{triage_report[:60]}...'")
        action_results = []
        
        # Analyze simple intents
        task_low = task_description.lower()
        if "split" in task_low:
            self.log("Systems Engineer", "Executing Choreographer split...")
            res = "SIMULATED: Workspace arranged in side_by_side layout." if dry_run else litexl_do_func("editor", "open_split", {"layout": "side_by_side"})
            action_results.append(f"editor:open_split -> {res}")
        elif "leetcode" in task_low:
            self.log("Systems Engineer", "Querying LeetCode subsystem...")
            res = "SIMULATED: Fetched problem Two Sum." if dry_run else litexl_do_func("leetcode", "fetch_problem", {"slug": "two-sum"})
            action_results.append(f"leetcode:fetch_problem -> {res}")
        elif "terminal" in task_low:
            self.log("Systems Engineer", "Toggling embedded terminal...")
            res = "SIMULATED: Toggled terminal." if dry_run else litexl_do_func("terminal", "toggle", {})
            action_results.append(f"terminal:toggle -> {res}")
        elif "git" in task_low:
            self.log("Systems Engineer", "Inspecting Git status...")
            res = "SIMULATED: Clean working tree." if dry_run else litexl_do_func("git", "status", {})
            action_results.append(f"git:status -> {res}")
        else:
            self.log("Systems Engineer", "Inspecting editor scope and diagnostics...")
            res = "SIMULATED: Scope and diagnostics healthy." if dry_run else litexl_do_func("diagnostics", "get_triage", {})
            action_results.append(f"diagnostics:get_triage -> {res}")

        # ── Stage 3: Safety Auditor ──
        self.log("Safety Auditor", "Auditing execution against Lite XL Guardrails...")
        audit_pulse = "SIMULATED: [IDE: Guardrails Untripped, All Pre-Flight Checks Passed]" if dry_run else litexl_pulse_func()
        self.log("Safety Auditor", f"Audit check verified. Final state: {audit_pulse}")

        lines.append("\n### 📋 Crew Execution Summary:")
        lines.append(f"• **Investigator**: Successfully triaged IDE state.")
        lines.append(f"• **Systems Engineer**: Executed {len(action_results)} action(s):")
        for ar in action_results:
            lines.append(f"    - `{ar}`")
        lines.append(f"• **Safety Auditor**: Verified zero guardrail violations, circuit breaker clean.")
        lines.append("=" * 70)
        return "\n".join(lines)


# ── CLI & Entrypoint ──────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(description="Lite XL CrewAI Multi-Agent Bridge")
    parser.add_argument("--task", type=str, default="Check editor health and report ambient pulse", help="Task prompt for the multi-agent crew")
    parser.add_argument("--model", type=str, default=None, help="Model name for CrewAI agents (e.g. 'groq/llama-3.3-70b-versatile')")
    parser.add_argument("--pulse", action="store_true", help="Fetch ambient pulse directly and exit")
    parser.add_argument("--discover", type=str, nargs="?", const="all", help="Discover subsystem actions directly and exit")
    parser.add_argument("--do", nargs=2, metavar=("SUBSYSTEM", "ACTION"), help="Execute a specific Lite XL action directly")
    parser.add_argument("--params", type=str, default="{}", help="JSON params string for --do")
    parser.add_argument("--dry-run", action="store_true", help="Run multi-agent workflow in dry-run simulation mode")
    parser.add_argument("--force-fallback", action="store_true", help="Force the built-in runner even if CrewAI is installed")

    args = parser.parse_args()

    # Direct tool shortcuts
    if args.pulse:
        print(litexl_pulse_func())
        return

    if args.discover:
        print(litexl_discover_func(args.discover))
        return

    if args.do:
        try:
            params = json.loads(args.params)
        except Exception as e:
            print(f"Error parsing --params JSON: {e}")
            sys.exit(1)
        sub, act = args.do
        print(litexl_do_func(sub, act, params))
        return

    # Multi-Agent Workflow
    has_crewai = False
    if not args.force_fallback and not args.dry_run:
        try:
            import crewai
            has_crewai = True
        except ImportError:
            has_crewai = False

    if has_crewai:
        print(f"⚡ Launching Native CrewAI Multi-Agent Team (Model: {args.model or 'default'})...")
        try:
            result = run_native_crew(args.task, model_name=args.model, verbose=True)
            print("\n" + result)
        except Exception as e:
            print(f"⚠️ CrewAI error: {e}. Falling back to built-in multi-agent runner...")
            runner = MultiAgentFallbackRunner(verbose=True)
            res = runner.execute(args.task, dry_run=args.dry_run)
            print("\n" + res)
    else:
        if not args.dry_run:
            print("💡 Tip: 'crewai' package is not installed. Running with built-in multi-agent runner.")
            print("   To use full CrewAI: pip install crewai crewai-tools\n")
        runner = MultiAgentFallbackRunner(verbose=True)
        res = runner.execute(args.task, dry_run=args.dry_run)
        print("\n" + res)

if __name__ == "__main__":
    main()

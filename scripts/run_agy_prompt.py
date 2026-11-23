"""
run_agy_prompt.py — Safe runner for executing AGY CLI prompts from Lite-XL.
Bypasses OS command-line character limits and argument splitting by streaming
prompt content directly via stdin to agy.exe with full stdout/stderr capture.
"""
import sys
import os
import subprocess

def main():
    if len(sys.argv) < 3:
        sys.stderr.write("Usage: run_agy_prompt.py <agy_path> <prompt_file> [--conversation <cid>]\n")
        sys.exit(1)

    agy_path = sys.argv[1]
    prompt_file = sys.argv[2]
    conv_id = None
    model_name = None

    if "--conversation" in sys.argv:
        try:
            c_idx = sys.argv.index("--conversation")
            if c_idx + 1 < len(sys.argv):
                conv_id = sys.argv[c_idx + 1]
        except Exception:
            pass

    if "--model" in sys.argv:
        try:
            m_idx = sys.argv.index("--model")
            if m_idx + 1 < len(sys.argv):
                model_name = sys.argv[m_idx + 1]
        except Exception:
            pass

    if not os.path.exists(prompt_file):
        sys.stderr.write(f"Prompt file not found: {prompt_file}\n")
        sys.exit(1)

    try:
        with open(prompt_file, "r", encoding="utf-8", errors="replace") as f:
            prompt_content = f.read()
    except Exception as e:
        sys.stderr.write(f"Failed to read prompt file: {e}\n")
        sys.exit(1)

    cmd = [agy_path, "--dangerously-skip-permissions"]
    if model_name and model_name.strip() and model_name.strip() != "Default":
        cmd.extend(["--model", model_name.strip()])

    if conv_id and conv_id.strip():
        brain_path = os.path.expanduser(f"~/.gemini/antigravity-cli/brain/{conv_id.strip()}")
        if os.path.exists(brain_path):
            cmd.extend(["--conversation", conv_id.strip()])

    try:
        proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace"
        )
        stdout, stderr = proc.communicate(input=prompt_content, timeout=240)

        if stdout:
            sys.stdout.write(stdout)
            sys.stdout.flush()

        # Suppress benign CLI stderr warnings (e.g. conversation lookup or spinner noise)
        if stderr:
            filtered = [
                line for line in stderr.splitlines()
                if "not found" not in line.lower() and "fetching" not in line.lower()
            ]
            if filtered:
                sys.stderr.write("\n".join(filtered))
                sys.stderr.flush()

        sys.exit(proc.returncode or 0)
    except subprocess.TimeoutExpired:
        try:
            proc.kill()
        except Exception:
            pass
        sys.stderr.write("AGY execution timed out after 240 seconds.\n")
        sys.exit(124)
    except Exception as e:
        sys.stderr.write(f"AGY execution error: {e}\n")
        sys.exit(1)

if __name__ == "__main__":
    main()

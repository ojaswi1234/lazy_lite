import sys, os, re

def strip_ansi(text):
    ansi_escape = re.compile(r'\x1b(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')
    return ansi_escape.sub('', text)

def safe_write(text):
    sys.stdout.buffer.write(text.encode('utf-8', errors='replace'))
    sys.stdout.buffer.flush()

def run_pty(argv):
    if os.name == 'nt':
        try:
            from winpty import PtyProcess
        except ImportError:
            sys.stderr.write("ERROR: pywinpty not installed. Run: pip install pywinpty\n")
            sys.exit(1)
        proc = PtyProcess.spawn(argv, dimensions=(24, 220))
        try:
            while proc.isalive():
                try:
                    chunk = proc.read(4096)
                    if chunk:
                        safe_write(strip_ansi(chunk))
                except EOFError:
                    break
        except KeyboardInterrupt:
            proc.terminate()
        try:
            while True:
                chunk = proc.read(4096)
                if not chunk: break
                safe_write(strip_ansi(chunk))
        except (EOFError, Exception):
            pass
        proc.wait()
        return proc.exitstatus or 0
    else:
        import pty, select, termios, struct, fcntl, subprocess
        master_fd, slave_fd = pty.openpty()
        fcntl.ioctl(slave_fd, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 220, 0, 0))
        proc = subprocess.Popen(argv, stdin=slave_fd, stdout=slave_fd, stderr=slave_fd, close_fds=True)
        os.close(slave_fd)
        try:
            while True:
                try:
                    r, _, _ = select.select([master_fd], [], [], 0.1)
                    if master_fd in r:
                        chunk = os.read(master_fd, 4096)
                        if not chunk: break
                        safe_write(strip_ansi(chunk.decode('utf-8', errors='replace')))
                except (OSError, IOError): break
                if proc.poll() is not None:
                    try:
                        while True:
                            r, _, _ = select.select([master_fd], [], [], 0.05)
                            if master_fd not in r: break
                            chunk = os.read(master_fd, 4096)
                            if not chunk: break
                            safe_write(strip_ansi(chunk.decode('utf-8', errors='replace')))
                    except (OSError, IOError): pass
                    break
        finally:
            os.close(master_fd)
        proc.wait()
        return proc.returncode or 0

if __name__ == '__main__':
    if len(sys.argv) < 2:
        sys.stderr.buffer.write(b"Usage: agy_pty_bridge.py <agy_path> [args...]\n")
        sys.exit(1)
    sys.exit(run_pty(sys.argv[1:]))

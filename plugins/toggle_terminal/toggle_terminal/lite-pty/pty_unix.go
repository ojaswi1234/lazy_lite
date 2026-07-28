//go:build !windows
// +build !windows

package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/creack/pty"
)

func defaultShell() string {
	shell := os.Getenv("SHELL")
	if shell == "" {
		shell = "bash"
	}
	return shell
}

// UnixPTY implements the PTY interface for Unix
type UnixPTY struct {
	ptm *os.File
	cmd *exec.Cmd
}

func SpawnPTY(shell string, cols, rows int) (PTY, error) {
	fields := strings.Fields(shell)
	if len(fields) == 0 {
		return nil, fmt.Errorf("empty shell")
	}
	cmd := exec.Command(fields[0], fields[1:]...)
	cmd.Env = append(os.Environ(), "TERM=xterm-256color")

	// Start the command with a pty
	ptm, err := pty.StartWithSize(cmd, &pty.Winsize{
		Rows: uint16(rows),
		Cols: uint16(cols),
	})
	if err != nil {
		return nil, fmt.Errorf("failed to start pty: %w", err)
	}

	return &UnixPTY{
		ptm: ptm,
		cmd: cmd,
	}, nil
}

func (p *UnixPTY) Read(b []byte) (int, error) {
	return p.ptm.Read(b)
}

func (p *UnixPTY) Write(b []byte) (int, error) {
	return p.ptm.Write(b)
}

func (p *UnixPTY) Close() error {
	p.cmd.Process.Kill()
	return p.ptm.Close()
}

func (p *UnixPTY) Resize(cols, rows int) error {
	return pty.Setsize(p.ptm, &pty.Winsize{
		Rows: uint16(rows),
		Cols: uint16(cols),
	})
}

func (p *UnixPTY) Wait() error {
	return p.cmd.Wait()
}

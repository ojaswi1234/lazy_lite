//go:build windows
// +build windows

package main

import (
	"context"
	"fmt"

	"github.com/UserExistsError/conpty"
)

func defaultShell() string {
	return "powershell.exe"
}

// WindowsPTY implements the PTY interface for Windows using ConPTY
type WindowsPTY struct {
	cpty *conpty.ConPty
}

func SpawnPTY(shell string, cols, rows int) (PTY, error) {
	// conpty.Start takes the command line string
	cpty, err := conpty.Start(shell, conpty.ConPtyDimensions(cols, rows))
	if err != nil {
		return nil, fmt.Errorf("failed to start conpty: %w", err)
	}

	return &WindowsPTY{
		cpty: cpty,
	}, nil
}

func (p *WindowsPTY) Read(b []byte) (int, error) {
	return p.cpty.Read(b)
}

func (p *WindowsPTY) Write(b []byte) (int, error) {
	return p.cpty.Write(b)
}

func (p *WindowsPTY) Close() error {
	return p.cpty.Close()
}

func (p *WindowsPTY) Resize(cols, rows int) error {
	return p.cpty.Resize(cols, rows)
}

func (p *WindowsPTY) Wait() error {
	_, err := p.cpty.Wait(context.Background())
	return err
}

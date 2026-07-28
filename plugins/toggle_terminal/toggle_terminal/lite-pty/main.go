package main

import (
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
)

var (
	shell = flag.String("shell", "", "Shell to execute (default: powershell on Windows, bash on Unix)")
	cols  = flag.Int("cols", 80, "Initial terminal columns")
	rows  = flag.Int("rows", 24, "Initial terminal rows")
)

type PTY interface {
	io.ReadWriteCloser
	Resize(cols, rows int) error
	Wait() error
}

func main() {
	flag.Parse()

	if *shell == "" {
		*shell = defaultShell()
	}

	// Clamp initial values to prevent math errors
	if *cols < 80 {
		*cols = 80
	}
	if *rows < 24 {
		*rows = 24
	}

	// Spawn the OS-specific PTY
	p, err := SpawnPTY(*shell, *cols, *rows)
	if err != nil {
		log.Fatalf("Failed to spawn PTY: %v\n", err)
	}
	defer p.Close()

	// Start HTTP listener for out-of-band control (resizing)
	httpListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		log.Fatalf("Failed to start HTTP listener: %v\n", err)
	}
	defer httpListener.Close()

	httpPort := httpListener.Addr().(*net.TCPAddr).Port

	http.HandleFunc("/resize", func(w http.ResponseWriter, r *http.Request) {
		c := r.URL.Query().Get("cols")
		rws := r.URL.Query().Get("rows")
		cInt, _ := strconv.Atoi(c)
		rInt, _ := strconv.Atoi(rws)
		if cInt > 0 && rInt > 0 {
			p.Resize(cInt, rInt)
		}
		w.WriteHeader(http.StatusOK)
	})

	go func() {
		http.Serve(httpListener, nil)
	}()

	// Print control port to stdout and sync to ensure Lua gets it immediately
	fmt.Printf("CTRL_PORT=%d\n", httpPort)
	os.Stdout.Sync()

	// Pipe stdin -> PTY
	go func() {
		io.Copy(p, os.Stdin)
		p.Close()
		os.Exit(0)
	}()

	// Pipe PTY -> stdout
	io.Copy(os.Stdout, p)

	// Wait for the shell process to exit
	err = p.Wait()
	if err != nil {
		log.Printf("Process exited with error: %v\n", err)
	}
}

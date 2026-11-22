package main

import (
	"fmt"
	"os"
	"time"
	"github.com/UserExistsError/conpty"
)

func main() {
	cpty, err := conpty.Start("powershell.exe -NoProfile", conpty.ConPtyDimensions(80, 24))
	if err != nil {
		fmt.Printf("Error: %v\n", err)
		return
	}
	defer cpty.Close()

	outBuf := make([]byte, 65536)
	
	// Read initial banner
	n, _ := cpty.Read(outBuf)
	fmt.Printf("Read banner: %d bytes\n", n)

	// Send a command
	cpty.Write([]byte("echo HELLO\r"))
	time.Sleep(1000 * time.Millisecond)
	n, _ = cpty.Read(outBuf)
	fmt.Printf("After echo: %d bytes\n", n)

	// Send Clear-Host
	cpty.Write([]byte("Clear-Host\r"))
	time.Sleep(1000 * time.Millisecond)
	n, _ = cpty.Read(outBuf)
	fmt.Printf("After Clear-Host: %d bytes\n", n)
	
	f, _ := os.Create("conpty_clear_dump.bin")
	f.Write(outBuf[:n])
	f.Close()
	fmt.Printf("Dumped %d bytes to conpty_clear_dump.bin\n", n)
}
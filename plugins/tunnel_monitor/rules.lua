return {
  { name = "Public Tunnel (Port 5173)", cmd = "ssh -p 443 -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o ServerAliveInterval=60 -o ServerAliveCountMax=10 -o ExitOnForwardFailure=yes -o ConnectTimeout=15 -o LogLevel=ERROR -T -R 0:127.0.0.1:15173 tcp@a.pinggy.io", target_port = 5173, proxy_port = 15173, auto_restart = true },
}

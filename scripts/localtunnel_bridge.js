const localtunnel = require('localtunnel');

const port = parseInt(process.argv[2], 10);

if (!port) {
  console.error("Usage: node localtunnel_bridge.js <port>");
  process.exit(1);
}

(async () => {
  try {
    console.log(`Requesting public tunnel for local port ${port}...`);
    
    // Add a timeout for the localtunnel connection
    const timeout = new Promise((_, reject) => 
      setTimeout(() => reject(new Error("Localtunnel server is currently unresponsive or down (timed out after 10 seconds). Try again later.")), 10000)
    );
    
    const tunnel = await Promise.race([
      localtunnel({ port: port }),
      timeout
    ]);
    
    console.log(`\n======================================================`);
    console.log(`🌍 PUBLIC URL: ${tunnel.url}`);
    console.log(`======================================================\n`);
    
    tunnel.on('close', () => {
      console.log('Tunnel closed.');
      process.exit(0);
    });
    
    tunnel.on('error', (err) => {
      console.error('Tunnel error:', err);
    });
  } catch (error) {
    console.error('[-] Failed to establish localtunnel:', error.message);
    process.exit(1);
  }
})();

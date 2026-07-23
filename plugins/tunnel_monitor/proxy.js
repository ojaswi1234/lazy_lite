const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');
const httpProxy = require('http-proxy');

const listenPort = parseInt(process.argv[2]);
const targetPort = parseInt(process.argv[3]);
const logFile = path.join(__dirname, 'visitors.json');
const mdFile = path.join(__dirname, 'visitors.md');

const proxy = httpProxy.createProxyServer({
    target: { host: 'localhost', port: targetPort },
    ws: true,
    changeOrigin: true
});

let visitors = [];
try { if (fs.existsSync(logFile)) visitors = JSON.parse(fs.readFileSync(logFile)); } catch(e){}

const seenIps = {};

function saveLog() {
    fs.writeFileSync(logFile, JSON.stringify(visitors, null, 2));
    
    // Auto-generate Markdown for live-reloading in Lite XL
    let md = "# 🕵️ Tunnel Visitor Analytics\n\n| IP Address | Location | Time | User Agent |\n|---|---|---|---|\n";
    if (visitors.length === 0) {
        md += "| No visitors yet | - | - | - |\n";
    } else {
        for (const v of visitors) {
            md += `| ${v.ip} | ${v.location} | ${v.time} | ${v.userAgent} |\n`;
        }
    }
    fs.writeFileSync(mdFile, md);
}

const server = http.createServer((req, res) => {
    // 1. Forward traffic transparently to the real app
    proxy.web(req, res, (e) => {
        if (!res.headersSent) {
            res.writeHead(502);
            res.end('Bad Gateway');
        }
    });

    // 2. Safely capture visitor details
    const rawIp = req.headers['x-forwarded-for'] || '';
    const ip = rawIp.split(',')[0].trim();
    
    if (ip && ip !== '127.0.0.1' && !seenIps[ip]) {
        seenIps[ip] = true;
        let ua = req.headers['user-agent'] || 'Unknown';
        // Truncate long user agents
        if (ua.length > 50) ua = ua.substring(0, 50) + '...';
        
        const timestamp = new Date().toLocaleString();
        
        // Securely fetch geo data over HTTPS for the VISITOR'S IP only.
        https.get(`https://freeipapi.com/api/json/${ip}`, (apiRes) => {
            let data = '';
            apiRes.on('data', c => data += c);
            apiRes.on('end', () => {
                try {
                    const geo = JSON.parse(data);
                    const location = geo.cityName ? `${geo.cityName}, ${geo.countryName}` : 'Unknown Location';
                    visitors.unshift({ ip, location, userAgent: ua, time: timestamp });
                    if (visitors.length > 50) visitors.pop();
                    saveLog();
                } catch(e){}
            });
        }).on('error', () => {
            visitors.unshift({ ip, location: 'Geo-Fetch Failed', userAgent: ua, time: timestamp });
            saveLog();
        });
    }
});

// Forward WebSockets (essential for Vite HMR)
server.on('upgrade', (req, socket, head) => {
    proxy.ws(req, socket, head, (e) => {
        socket.destroy();
    });
});

server.listen(listenPort, 'localhost', () => {
    console.log(`Proxy running on ${listenPort}`);
});

// Admin API Server (for standalone/web deployment)
const adminPort = listenPort + 1000;
const adminServer = http.createServer((req, res) => {
    // Enable CORS for web deployment
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, OPTIONS');
    
    if (req.method === 'OPTIONS') {
        res.writeHead(200);
        res.end();
        return;
    }
    
    if (req.url === '/api/visitors') {
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(visitors));
    } else {
        res.writeHead(404, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Endpoint not found. Use /api/visitors' }));
    }
});

adminServer.listen(adminPort, 'localhost', () => {
    console.log(`Analytics API running on http://localhost:${adminPort}/api/visitors`);
});

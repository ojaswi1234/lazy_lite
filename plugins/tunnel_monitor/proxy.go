package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

type Visitor struct {
	IP        string `json:"ip"`
	Location  string `json:"location"`
	UserAgent string `json:"userAgent"`
	Time      string `json:"time"`
	Path      string `json:"path"`
	Method    string `json:"method"`
	Referer   string `json:"referer"`
	Language  string `json:"language"`
	ISP       string `json:"isp"`
}

type GeoAPIResponse struct {
	CountryName     string `json:"countryName"`
	CityName        string `json:"cityName"`
	IsProxy         bool   `json:"isProxy"`
	AsnOrganization string `json:"asnOrganization"`
}

var (
	visitors []Visitor
	geoCache = make(map[string]GeoAPIResponse)
	geoMutex sync.Mutex
	mutex    sync.Mutex
	logFile  string
)

const authHTMLTemplate = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>LazyLite Tunnel Auth</title>
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&display=swap" rel="stylesheet">
  <style>
    :root {
      --bg-gradient: linear-gradient(135deg, #0f172a 0%, #1e1b4b 50%, #0f172a 100%);
      --card-bg: rgba(30, 41, 59, 0.6);
      --card-border: rgba(255, 255, 255, 0.1);
      --primary: #6366f1;
      --primary-hover: #4f46e5;
      --text: #f8fafc;
      --text-muted: #94a3b8;
      --error: #ef4444;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: 'Inter', system-ui, sans-serif; min-height: 100vh; display: flex; justify-content: center; align-items: center; background: var(--bg-gradient); background-size: 400% 400%; animation: gradientBG 15s ease infinite; color: var(--text); padding: 20px; }
    @keyframes gradientBG { 0% { background-position: 0% 50%; } 50% { background-position: 100% 50%; } 100% { background-position: 0% 50%; } }
    .auth-container { background: var(--card-bg); backdrop-filter: blur(16px); -webkit-backdrop-filter: blur(16px); border: 1px solid var(--card-border); border-radius: 24px; padding: 48px 40px; width: 100%; max-width: 420px; text-align: center; box-shadow: 0 25px 50px -12px rgba(0,0,0,0.5); animation: slideUp 0.6s cubic-bezier(0.16,1,0.3,1); }
    @keyframes slideUp { from { opacity: 0; transform: translateY(20px); } to { opacity: 1; transform: translateY(0); } }
    .icon-wrapper { width: 64px; height: 64px; background: rgba(99,102,241,0.1); border-radius: 50%; display: flex; justify-content: center; align-items: center; margin: 0 auto 24px; border: 1px solid rgba(99,102,241,0.2); }
    .icon-wrapper svg { width: 28px; height: 28px; fill: var(--primary); }
    h1 { font-size: 24px; font-weight: 600; margin-bottom: 8px; letter-spacing: -0.5px; }
    p { color: var(--text-muted); font-size: 15px; margin-bottom: 32px; line-height: 1.5; }
    .form-group { position: relative; margin-bottom: 24px; }
    input { width: 100%; background: rgba(15,23,42,0.6); border: 1px solid rgba(255,255,255,0.1); border-radius: 12px; padding: 16px 20px; color: white; font-size: 16px; font-family: inherit; transition: all 0.3s ease; outline: none; text-align: center; letter-spacing: 2px; }
    input:focus { border-color: var(--primary); box-shadow: 0 0 0 4px rgba(99,102,241,0.15); }
    input::placeholder { color: #475569; letter-spacing: normal; }
    button { width: 100%; background: var(--primary); color: white; border: none; border-radius: 12px; padding: 16px; font-size: 16px; font-weight: 500; font-family: inherit; cursor: pointer; transition: all 0.2s ease; display: flex; justify-content: center; align-items: center; gap: 8px; }
    button:hover { background: var(--primary-hover); transform: translateY(-1px); }
    button:active { transform: translateY(1px); }
    button svg { width: 18px; height: 18px; fill: currentColor; }
    .error-msg { color: var(--error); font-size: 14px; margin-bottom: 20px; animation: shake 0.5s; background: rgba(239,68,68,0.1); border: 1px solid rgba(239,68,68,0.2); padding: 10px; border-radius: 8px; font-weight: 500; }
    @keyframes shake { 0%,100%{transform:translateX(0);} 25%{transform:translateX(-4px);} 75%{transform:translateX(4px);} }
    @media (max-width: 480px) { .auth-container { padding: 40px 24px; border-radius: 20px; } h1 { font-size: 22px; } }
  </style>
</head>
<body>
  <div class="auth-container">
    <div class="icon-wrapper">
      <svg viewBox="0 0 24 24"><path d="M12 2C9.243 2 7 4.243 7 7v3H6c-1.103 0-2 .897-2 2v8c0 1.103.897 2 2 2h12c1.103 0 2-.897 2-2v-8c0-1.103-.897-2-2-2h-1V7c0-2.757-2.243-5-5-5zm-3 5c0-1.654 1.346-3 3-3s3 1.346 3 3v3H9V7zm9 13H6v-8h12v8z"/><circle cx="12" cy="16" r="2"/></svg>
    </div>
    <h1>LazyLite Tunnel</h1>
    <p>Please enter your access PIN to<br>connect to the local environment.</p>
    {{ERROR_PLACEHOLDER}}
    <form method="POST" action="/__tunnel_auth">
      <div class="form-group">
        <input type="password" name="token" placeholder="Enter PIN..." autofocus required autocomplete="off">
      </div>
      <button type="submit">
        Authenticate
        <svg viewBox="0 0 24 24"><path d="M10.707 17.707 16.414 12l-5.707-5.707-1.414 1.414L13.586 12l-4.293 4.293z"/></svg>
      </button>
    </form>
  </div>
</body>
</html>`

func saveLog() {
	mutex.Lock()
	defer mutex.Unlock()
	data, err := json.MarshalIndent(visitors, "", "  ")
	if err == nil {
		os.WriteFile(logFile, data, 0644)
	}
}

func parseUA(ua string) string {
	browser := "Unknown Browser"
	if strings.Contains(ua, "Firefox") { browser = "Firefox" }
	if strings.Contains(ua, "Chrome") { browser = "Chrome" }
	if strings.Contains(ua, "Safari") && !strings.Contains(ua, "Chrome") { browser = "Safari" }
	if strings.Contains(ua, "Edge") || strings.Contains(ua, "Edg") { browser = "Edge" }

	osStr := "Unknown OS"
	if strings.Contains(ua, "Windows") { osStr = "Windows" }
	if strings.Contains(ua, "Macintosh") || strings.Contains(ua, "Mac OS") { osStr = "macOS" }
	if strings.Contains(ua, "Linux") { osStr = "Linux" }
	if strings.Contains(ua, "Android") { osStr = "Android" }
	if strings.Contains(ua, "iPhone") { osStr = "iPhone" }
	if strings.Contains(ua, "iPad") { osStr = "iPad" }
	
	if browser == "Unknown Browser" && osStr == "Unknown OS" {
		if len(ua) > 20 { return ua[:20] + "..." }
		return ua
	}
	return browser + " on " + osStr
}

func parseLang(l string) string {
	if l == "" { return "Unknown" }
	return strings.Split(l, ",")[0]
}

func fetchGeoAndLog(ip, ua, path, method, referer, lang string) {
	geoMutex.Lock()
	geo, ok := geoCache[ip]
	if !ok {
		resp, err := http.Get("https://freeipapi.com/api/json/" + ip)
		if err == nil {
			defer resp.Body.Close()
			body, _ := io.ReadAll(resp.Body)
			json.Unmarshal(body, &geo)
			geoCache[ip] = geo
		}
	}
	geoMutex.Unlock()

	location := "Unknown Location"
	if geo.CityName != "" {
		location = geo.CityName + ", " + geo.CountryName
		if geo.IsProxy {
			location += " [VPN/PROXY]"
		}
	}
	isp := geo.AsnOrganization
	if isp == "" { isp = "Unknown ISP" }

	timestamp := time.Now().Format("15:04:05")

	v := Visitor{
		IP:        ip,
		Location:  location,
		UserAgent: parseUA(ua),
		Time:      timestamp,
		Path:      path,
		Method:    method,
		Referer:   referer,
		Language:  parseLang(lang),
		ISP:       isp,
	}

	mutex.Lock()
	visitors = append([]Visitor{v}, visitors...)
	if len(visitors) > 200 {
		visitors = visitors[:200]
	}
	mutex.Unlock()

	saveLog()
}

func isIgnored(path string) bool {
	exts := []string{".js", ".css", ".ico", ".png", ".jpg", ".jpeg", ".svg", ".woff", ".woff2", ".ttf", ".map", ".ts", ".vue", ".jsx", ".tsx", "@vite/client"}
	lowPath := strings.ToLower(path)
	for _, ext := range exts {
		if strings.HasSuffix(lowPath, ext) {
			return true
		}
	}
	return false
}

func main() {
	if len(os.Args) < 3 {
		log.Fatal("Usage: proxy <listenPort> <targetPort> [authToken]")
	}

	listenPort := os.Args[1]
	targetPort := os.Args[2]
	authToken := ""
	if len(os.Args) >= 4 {
		authToken = os.Args[3]
	}

	exePath, _ := os.Executable()
	logFile = filepath.Join(filepath.Dir(exePath), "visitors.json")

	data, err := os.ReadFile(logFile)
	if err == nil {
		json.Unmarshal(data, &visitors)
	}

	targetURL, _ := url.Parse(fmt.Sprintf("http://localhost:%s", targetPort))
	proxy := httputil.NewSingleHostReverseProxy(targetURL)
	
	proxy.Transport = &http.Transport{
		MaxIdleConns:          100,
		MaxIdleConnsPerHost:   10,
		MaxConnsPerHost:       50,
		ResponseHeaderTimeout: 30 * time.Second,
		IdleConnTimeout:       10 * time.Second,
		DialContext: (&net.Dialer{
			Timeout:   5 * time.Second,
			KeepAlive: 30 * time.Second,
		}).DialContext,
		ForceAttemptHTTP2: false,
	}
	
	originalDirector := proxy.Director
	proxy.Director = func(req *http.Request) {
		originalDirector(req)
		req.Host = targetURL.Host
		req.Header.Set("X-Forwarded-For", req.RemoteAddr)
		req.Header.Set("X-Forwarded-Proto", "https")
		req.Header.Set("X-Real-IP", req.RemoteAddr)
	}

	proxy.ErrorHandler = func(rw http.ResponseWriter, req *http.Request, err error) {
		log.Printf("Proxy error: %v", err)
		rw.Header().Set("Content-Type", "text/html; charset=utf-8")
		rw.WriteHeader(http.StatusBadGateway)
		rw.Write([]byte("<h2>Bad Gateway</h2><p>Backend server may be restarting. Refresh in a few seconds.</p>"))
	}

	proxyHandler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if authToken != "" {
			if r.Method == "POST" && r.URL.Path == "/__tunnel_auth" {
				r.ParseForm()
				token := r.FormValue("token")
				if token == authToken {
					http.SetCookie(w, &http.Cookie{
						Name:     "tunnel_auth",
						Value:    token,
						Path:     "/",
						HttpOnly: true,
						MaxAge:   86400,
					})
					http.Redirect(w, r, "/", http.StatusFound)
				} else {
					w.Header().Set("Content-Type", "text/html")
					w.WriteHeader(http.StatusUnauthorized)
					html := strings.Replace(authHTMLTemplate, "{{ERROR_PLACEHOLDER}}", `<div class="error-msg">Incorrect PIN. Please try again.</div>`, 1)
					w.Write([]byte(html))
				}
				return
			}

			cookie, _ := r.Cookie("tunnel_auth")
			if cookie == nil || cookie.Value != authToken {
				w.Header().Set("Content-Type", "text/html")
				w.WriteHeader(http.StatusUnauthorized)
				html := strings.Replace(authHTMLTemplate, "{{ERROR_PLACEHOLDER}}", "", 1)
				w.Write([]byte(html))
				return
			}
		}

		rawIP := r.Header.Get("X-Forwarded-For")
		if rawIP != "" {
			ip := strings.TrimSpace(strings.Split(rawIP, ",")[0])
			if ip != "" && ip != "127.0.0.1" && ip != "::1" && !isIgnored(r.URL.Path) {
				ua := r.Header.Get("User-Agent")
				ref := r.Header.Get("Referer")
				lang := r.Header.Get("Accept-Language")
				go fetchGeoAndLog(ip, ua, r.URL.Path, r.Method, ref, lang)
			}
		}

		if strings.ToLower(r.Header.Get("Upgrade")) == "websocket" {
			targetConn, err := net.Dial("tcp", "localhost:"+targetPort)
			if err != nil {
				log.Printf("WebSocket dial failed: %v", err)
				http.Error(w, "Backend unavailable", http.StatusBadGateway)
				return
			}

			hj, ok := w.(http.Hijacker)
			if !ok {
				targetConn.Close()
				http.Error(w, "webserver doesn't support hijacking", http.StatusInternalServerError)
				return
			}
			clientConn, _, err := hj.Hijack()
			if err != nil {
				targetConn.Close()
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}

			err = r.Write(targetConn)
			if err != nil {
				targetConn.Close()
				clientConn.Close()
				return
			}

			var wg sync.WaitGroup
			wg.Add(2)
			go func() {
				defer wg.Done()
				io.Copy(targetConn, clientConn)
			}()
			go func() {
				defer wg.Done()
				io.Copy(clientConn, targetConn)
			}()

			wg.Wait()
			targetConn.Close()
			clientConn.Close()
			return
		}

		proxy.ServeHTTP(w, r)
	})

	adminPortInt, _ := strconv.Atoi(listenPort)
	adminPort := strconv.Itoa(adminPortInt + 1000)

	adminMux := http.NewServeMux()
	adminMux.HandleFunc("/api/visitors", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, OPTIONS")
		if r.Method == "OPTIONS" {
			w.WriteHeader(http.StatusOK)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		
		mutex.Lock()
		respData, _ := json.Marshal(visitors)
		mutex.Unlock()
		
		w.Write(respData)
	})
	
	adminMux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusNotFound)
		w.Write([]byte(`{"error": "Endpoint not found. Use /api/visitors"}`))
	})

	go func() {
		log.Printf("Analytics API running on http://127.0.0.1:%s/api/visitors", adminPort)
		http.ListenAndServe("127.0.0.1:"+adminPort, adminMux)
	}()

	log.Printf("Proxy starting: listening on %s, forwarding to localhost:%s", listenPort, targetPort)
	err = http.ListenAndServe("127.0.0.1:"+listenPort, proxyHandler)
	if err != nil {
		log.Fatal(err)
	}
}

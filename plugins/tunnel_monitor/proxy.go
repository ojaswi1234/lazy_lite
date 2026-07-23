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
		log.Fatal("Usage: proxy <listenPort> <targetPort>")
	}

	listenPort := os.Args[1]
	targetPort := os.Args[2]

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

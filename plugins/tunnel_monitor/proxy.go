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
}

type GeoAPIResponse struct {
	CountryName string `json:"countryName"`
	CityName    string `json:"cityName"`
	IsProxy     bool   `json:"isProxy"`
}

var (
	visitors []Visitor
	seenIPs  = make(map[string]bool)
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

func fetchGeoAndLog(ip string, ua string) {
	resp, err := http.Get(fmt.Sprintf("https://freeipapi.com/api/json/%s", ip))
	location := "Unknown Location"
	if err == nil {
		defer resp.Body.Close()
		body, _ := io.ReadAll(resp.Body)
		var geo GeoAPIResponse
		if json.Unmarshal(body, &geo) == nil {
			if geo.CityName != "" {
				location = fmt.Sprintf("%s, %s", geo.CityName, geo.CountryName)
				if geo.IsProxy {
					location += " [VPN/PROXY]"
				}
			}
		}
	} else {
		location = "Geo-Fetch Failed"
	}

	timestamp := time.Now().Format("1/2/2006, 3:04:05 PM")

	mutex.Lock()
	// Prepend to slice
	visitors = append([]Visitor{{IP: ip, Location: location, UserAgent: ua, Time: timestamp}}, visitors...)
	if len(visitors) > 50 {
		visitors = visitors[:50]
	}
	mutex.Unlock()

	saveLog()
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
		for _, v := range visitors {
			seenIPs[v.IP] = true
		}
	}

	targetURL, _ := url.Parse(fmt.Sprintf("http://localhost:%s", targetPort))
	proxy := httputil.NewSingleHostReverseProxy(targetURL)
	
	// NEW: Add custom transport with timeouts to prevent hangs
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
		ForceAttemptHTTP2: false, // localhost.run uses HTTP/1.1 for tunnels
	}
	
	// Ensure Host header matches target (critical for Vite/Django)
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
			if ip != "" && ip != "127.0.0.1" && ip != "::1" {
				mutex.Lock()
				if !seenIPs[ip] {
					seenIPs[ip] = true
					mutex.Unlock()

					ua := r.Header.Get("User-Agent")
					if ua == "" {
						ua = "Unknown"
					}
					if len(ua) > 50 {
						ua = ua[:47] + "..."
					}
					go fetchGeoAndLog(ip, ua)
				} else {
					mutex.Unlock()
				}
			}
		}

		if strings.ToLower(r.Header.Get("Upgrade")) == "websocket" {
			rawIP := r.Header.Get("X-Forwarded-For")
			if rawIP != "" {
				ip := strings.TrimSpace(strings.Split(rawIP, ",")[0])
				if ip != "" && ip != "127.0.0.1" && ip != "::1" {
					mutex.Lock()
					if !seenIPs[ip] {
						seenIPs[ip] = true
						mutex.Unlock()
						ua := r.Header.Get("User-Agent")
						if ua == "" { ua = "Unknown" }
						if len(ua) > 50 { ua = ua[:47] + "..." }
						go fetchGeoAndLog(ip, ua)
					} else {
						mutex.Unlock()
					}
				}
			}

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

	// Start Admin API Server
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
		log.Printf("Analytics API running on http://localhost:%s/api/visitors", adminPort)
		http.ListenAndServe("127.0.0.1:"+adminPort, adminMux)
	}()

	log.Printf("Proxy starting: listening on %s, forwarding to localhost:%s", listenPort, targetPort)
	err = http.ListenAndServe("127.0.0.1:"+listenPort, proxyHandler)
	if err != nil {
		log.Fatal(err)
	}
}

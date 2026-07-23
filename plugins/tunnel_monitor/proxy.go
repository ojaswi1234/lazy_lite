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
	CityName    string `json:"cityName"`
	CountryName string `json:"countryName"`
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
		ResponseHeaderTimeout: 60 * time.Second,
		IdleConnTimeout:       30 * time.Second,
		DialContext: (&net.Dialer{
			Timeout: 5 * time.Second,
		}).DialContext,
	}
	
	// Ensure Host header matches target (critical for Vite/Django)
	originalDirector := proxy.Director
	proxy.Director = func(req *http.Request) {
		originalDirector(req)
		req.Host = targetURL.Host
	}

	proxy.ErrorHandler = func(rw http.ResponseWriter, req *http.Request, err error) {
		rw.WriteHeader(http.StatusBadGateway)
		rw.Write([]byte("Bad Gateway"))
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
				http.Error(w, "Bad Gateway", http.StatusBadGateway)
				return
			}
			defer targetConn.Close()

			hj, ok := w.(http.Hijacker)
			if !ok {
				http.Error(w, "webserver doesn't support hijacking", http.StatusInternalServerError)
				return
			}
			clientConn, _, err := hj.Hijack()
			if err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
			defer clientConn.Close()

			err = r.Write(targetConn)
			if err != nil {
				return
			}

			go func() {
				io.Copy(targetConn, clientConn)
			}()
			io.Copy(clientConn, targetConn)
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
		http.ListenAndServe("localhost:"+adminPort, adminMux)
	}()

	log.Printf("Proxy running on localhost:%s forwarding to %s", listenPort, targetPort)
	err = http.ListenAndServe("localhost:"+listenPort, proxyHandler)
	if err != nil {
		log.Fatal(err)
	}
}

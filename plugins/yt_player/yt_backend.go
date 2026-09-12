package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"sync"
	"time"
)

type Request struct {
	Cmd        string        `json:"cmd"`
	Query      string        `json:"query"`
	VideoID    string        `json:"video_id"`
	MLConcised bool          `json:"ml_concised"`
	MLModel    *MLModelCfg   `json:"ml_model"`
	Transcript []TranscBlock `json:"transcript"`
	Segments   [][2]float64  `json:"segments"`
	Enabled    bool          `json:"enabled"`
	Offset     float64       `json:"offset"`
	Page       int           `json:"page"`
	SearchType string        `json:"search_type"`
	Language    string        `json:"language"`
	PlaylistID  string        `json:"playlist_id"`
	SponsorBlock bool         `json:"sponsor_block"`
}

type MLModelCfg struct {
	Provider string `json:"provider"`
	Name     string `json:"name"`
}

type TranscBlock struct {
	Start    float64 `json:"start"`
	Duration float64 `json:"duration"`
	Text     string  `json:"text"`
}

type Event map[string]interface{}

type YTFormat struct {
	VCodec      string            `json:"vcodec"`
	ACodec      string            `json:"acodec"`
	Height      int               `json:"height"`
	ABR         float64           `json:"abr"`
	URL         string            `json:"url"`
	Language    string            `json:"language"`
	HTTPHeaders map[string]string `json:"http_headers"`
}

type YTInfo struct {
	ID          string            `json:"id"`
	Title       string            `json:"title"`
	Duration    float64           `json:"duration"`
	URL         string            `json:"url"`
	Formats     []YTFormat        `json:"formats"`
	HTTPHeaders map[string]string `json:"http_headers"`
}

const (
	ffmpegExe   = `C:\Users\ojasw\.spci\bin\ffmpeg.exe`
	vlcExe      = `C:\Program Files\VideoLAN\VLC\vlc.exe`
	apiKeysPath = `C:\Users\ojasw\.config\lite-xl\scripts\ai_api_keys.json`
	vlcPort     = "9090"
)

var (
	sendMu sync.Mutex
	bk     *Backend
)

type Backend struct {
	mu              sync.Mutex
	cachedInfo      *YTInfo
	prefetch        map[string]*YTInfo
	repeatMode      bool
	mlConcised      bool
	mlModel         *MLModelCfg
	keepSegments    [][2]float64
	sponsorSegments [][2]float64
	segIdx          int
	ffmpegProcs  []*exec.Cmd
	vlcProcess   *exec.Cmd
	statMu       sync.Mutex
	statPos      float64
	statLen      float64
	statPlaying  bool
	
	ctx          context.Context
	cancel       context.CancelFunc
	searchCancel context.CancelFunc
	videoListener net.Listener
	activeVlcPort string

	searchCache      []map[string]interface{}
	searchCacheQuery string
	searchCacheType  string
}

// Write JSON safely with buffer flush
var stdoutWriter = bufio.NewWriter(os.Stdout)
func send(ev Event) {
	sendMu.Lock()
	defer sendMu.Unlock()
	b, _ := json.Marshal(ev)
	stdoutWriter.Write(append(b, '\n'))
	stdoutWriter.Flush()
}



func sendInfo(msg string) { send(Event{"event": "info", "message": msg}) }

func hideCmd(cmd *exec.Cmd) *exec.Cmd {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	return cmd
}

func sendErr(msg string)  { send(Event{"event": "error", "message": msg}) }

func ytdlp(ctx context.Context, args ...string) *exec.Cmd {
	return hideCmd(exec.CommandContext(ctx, "python", append([]string{"-m", "yt_dlp", "--no-warnings", "--quiet", "--extractor-args", "youtube:player_client=mweb,default"}, args...)...))
}

func extractInfo(ctx context.Context, url string) (*YTInfo, error) {
	cmd := ytdlp(ctx, "--dump-json", "--no-playlist", "--force-ipv4", url)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" { msg = err.Error() }
		return nil, fmt.Errorf("%s", msg)
	}
	var info YTInfo
	err = json.Unmarshal(bytes.TrimSpace(out), &info)
	return &info, err
}

// isPlaylistID returns true if the ID looks like a YouTube playlist ID.
func isPlaylistID(id string) bool {
	if len(id) < 2 { return false }
	prefixes := []string{"PL", "RD", "FL", "OL", "UU"}
	for _, p := range prefixes {
		if strings.HasPrefix(id, p) { return true }
	}
	return false
}

// fetchSearchResults does the actual yt-dlp call with speed-optimized flags.
// Fetches up to 60 results at once so pagination pages 1-3 are instant.
func fetchSearchResults(ctx context.Context, query string, searchType string) []map[string]interface{} {
	var searchURL string
	if searchType == "playlist" {
		// YouTube playlist search filter URL
		encodedQ := strings.ReplaceAll(strings.TrimSpace(query), " ", "+")
		searchURL = "https://www.youtube.com/results?search_query=" + encodedQ + "&sp=EgIQAw%3D%3D"
	} else {
		searchURL = fmt.Sprintf("ytsearch60:%s", query)
	}

	args := []string{
		"--flat-playlist",
		"--dump-json",
		"--socket-timeout", "15",
		"--retries", "2",
		"--no-check-certificate",
	}
	
	if searchType == "playlist" {
		// Limit to 60 items so we don't fetch 300+ and take 30 seconds
		args = append(args, "--playlist-items", "1-60")
	}

	args = append(args, searchURL)

	cmd := ytdlp(ctx, args...)
	out, err := cmd.Output()
	if err != nil {
		return nil
	}

	var all []map[string]interface{}
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		if line == "" { continue }
		var e map[string]interface{}
		if json.Unmarshal([]byte(line), &e) != nil { continue }
		
		id, _ := e["id"].(string)
		title, _ := e["title"].(string)
		if id == "" || title == "" { continue }

		if isPlaylistID(id) {
			if searchType == "" || searchType == "playlist" {
				entryCount, _ := e["entry_count"].(float64)
				vidCount, _ := e["playlist_count"].(float64)
				if entryCount == 0 { entryCount = vidCount }
				all = append(all, map[string]interface{}{
					"id":          id,
					"title":       title,
					"type":        "playlist",
					"entry_count": entryCount,
					"duration":    entryCount, // UI uses duration field to display count
				})
			}
		} else {
			if searchType == "" || searchType == "video" {
				dur, _ := e["duration"].(float64)
				if dur == 0 || dur > 43200 { continue }
				all = append(all, map[string]interface{}{
					"id":       id,
					"title":    title,
					"duration": dur,
					"type":     "video",
				})
			}
		}
	}
	return all
}

func searchYT(ctx context.Context, b *Backend, query string, page int, searchType string) []map[string]interface{} {
	const limit = 20
	// Check if the cache already covers this query+type
	b.mu.Lock()
	cacheHit := b.searchCacheQuery == query && b.searchCacheType == searchType && b.searchCache != nil
	var cached []map[string]interface{}
	if cacheHit {
		cached = b.searchCache
	}
	b.mu.Unlock()

	if !cacheHit {
		// Fetch fresh data and store in cache
		all := fetchSearchResults(ctx, query, searchType)
		if ctx.Err() != nil { return nil }
		if all == nil {
			sendErr("Search returned no results. Try a different query.")
			return []map[string]interface{}{}
		}
		b.mu.Lock()
		b.searchCache = all
		b.searchCacheQuery = query
		b.searchCacheType = searchType
		b.mu.Unlock()
		cached = all
	}

	startIdx := (page - 1) * limit
	if startIdx >= len(cached) { return []map[string]interface{}{} }
	endIdx := startIdx + limit
	if endIdx > len(cached) { endIdx = len(cached) }
	
	send(Event{"event": "search_pagination", "total_pages": (len(cached) + limit - 1) / limit})
	return cached[startIdx:endIdx]
}

func getPlaylistVideos(ctx context.Context, playlistID string) []map[string]interface{} {
	url := fmt.Sprintf("https://www.youtube.com/playlist?list=%s", playlistID)
	cmd := ytdlp(ctx,
		"--flat-playlist", "--dump-json",
		"--socket-timeout", "10",
		"--retries", "2",
		"--no-check-certificate",
		"--playlist-end", "100", // don't freeze on massive playlists
		url,
	)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		errStr := stderr.String()
		if strings.Contains(errStr, "unviewable") {
			sendErr("YouTube Mixes (RD...) cannot be loaded directly.")
		} else if strings.Contains(errStr, "does not exist") {
			sendErr("This playlist does not exist or is private.")
		} else {
			sendErr("Failed to load playlist: " + err.Error())
		}
		return nil
	}
	var videos []map[string]interface{}
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		if line == "" { continue }
		var e map[string]interface{}
		if json.Unmarshal([]byte(line), &e) != nil { continue }
		
		id, _ := e["id"].(string)
		title, _ := e["title"].(string)
		dur, _ := e["duration"].(float64)
		if id == "" || title == "" { continue }
		if dur > 86400 { continue } // skip >24h
		
		videos = append(videos, map[string]interface{}{
			"id": id, "title": title, "duration": dur, "type": "video",
		})
	}
	return videos
}

func getAudioLanguages(info *YTInfo) []string {
	langSet := make(map[string]bool)
	for _, f := range info.Formats {
		vc := f.VCodec
		ac := f.ACodec
		noV := vc == "" || vc == "none"
		hasA := ac != "" && ac != "none" && strings.Contains(ac, "mp4a")
		if noV && hasA && f.Language != "" {
			langSet[f.Language] = true
		}
	}
	var langs []string
	for l := range langSet {
		langs = append(langs, l)
	}
	sort.Strings(langs)
	return langs
}

func bestStreams(info *YTInfo, preferredLang string) (vid, aud *YTFormat) {
	var videos, audios []YTFormat
	for _, f := range info.Formats {
		vc := f.VCodec
		ac := f.ACodec
		hasV := vc != "" && vc != "none" && strings.Contains(vc, "avc1")
		hasA := ac != "" && ac != "none" && strings.Contains(ac, "mp4a")
		noV := vc == "" || vc == "none"
		noA := ac == "" || ac == "none"
		if hasV && noA && f.Height <= 1080 {
			videos = append(videos, f)
		}
		if hasA && noV {
			audios = append(audios, f)
		}
	}
	sort.Slice(videos, func(i, j int) bool { return videos[i].Height < videos[j].Height })
	
	// Sort audios by ABR first
	sort.Slice(audios, func(i, j int) bool { return audios[i].ABR < audios[j].ABR })

	// If preferredLang is provided, try to find the best audio that matches it
	var bestAudio *YTFormat
	if preferredLang != "" && preferredLang != "original" {
		for i := len(audios) - 1; i >= 0; i-- {
			if audios[i].Language == preferredLang || strings.HasPrefix(audios[i].Language, preferredLang) {
				a := audios[i]
				bestAudio = &a
				break
			}
		}
	}
	
	if bestAudio == nil && len(audios) > 0 {
		// Fallback to original/highest ABR if preferred lang not found
		a := audios[len(audios)-1]
		bestAudio = &a
	}
	aud = bestAudio

	if len(videos) > 0 {
		v := videos[len(videos)-1]
		vid = &v
	}
	return vid, aud
}

func buildHeaders(f *YTFormat, info *YTInfo) string {
	ua := f.HTTPHeaders["User-Agent"]
	if ua == "" {
		ua = info.HTTPHeaders["User-Agent"]
	}
	return fmt.Sprintf("User-Agent: %s\r\nReferer: https://www.youtube.com/\r\n", ua)
}

// vlcHTTP sends command via VLC's HTTP RC interface
func (b *Backend) vlcHTTP(cmd string) {
	b.mu.Lock(); port := b.activeVlcPort; b.mu.Unlock()
	if port == "" { port = "9090" }
	url := fmt.Sprintf("http://127.0.0.1:%s/requests/status.json?command=%s", port, cmd)
	req, _ := http.NewRequest("GET", url, nil)
	req.SetBasicAuth("", "secret")
	http.DefaultClient.Do(req)
}

func (b *Backend) vlcStatus() map[string]interface{} {
	b.mu.Lock(); port := b.activeVlcPort; b.mu.Unlock()
	if port == "" { port = "9090" }
	url := fmt.Sprintf("http://127.0.0.1:%s/requests/status.json", port)
	req, _ := http.NewRequest("GET", url, nil)
	req.SetBasicAuth("", "secret")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	var st map[string]interface{}
	json.NewDecoder(resp.Body).Decode(&st)
	return st
}

func fetchSponsorBlock(videoID string) [][2]float64 {
	url := "https://sponsor.ajay.app/api/skipSegments?videoID=" + videoID + "&categories=[\"sponsor\",\"intro\",\"outro\",\"interaction\",\"selfpromo\",\"music_offtopic\"]"
	resp, err := http.Get(url)
	if err != nil { return nil }
	defer resp.Body.Close()
	var res []map[string]interface{}
	if json.NewDecoder(resp.Body).Decode(&res) != nil { return nil }
	
	var skips [][2]float64
	for _, s := range res {
		if seg, ok := s["segment"].([]interface{}); ok && len(seg) == 2 {
			if start, ok := seg[0].(float64); ok {
				if end, ok := seg[1].(float64); ok {
					skips = append(skips, [2]float64{start, end})
				}
			}
		}
	}
	return skips
}

func (b *Backend) Play(videoID string, mlConcised bool, mlModel *MLModelCfg, language string, sponsorBlock bool) {
	send(Event{"event": "producing", "message": "Extracting stream..."})
	
	if sponsorBlock {
		go func() {
			skips := fetchSponsorBlock(videoID)
			b.mu.Lock()
			b.sponsorSegments = skips
			b.mu.Unlock()
		}()
	}
	
	b.mu.Lock()
	info := b.prefetch[videoID]
	b.mu.Unlock()

	var err error
	if info == nil {
		info, err = extractInfo(b.ctx, "https://www.youtube.com/watch?v=" + videoID)
		if err != nil {
			sendErr(err.Error())
			return
		}
	}

	// Send available languages if any
	langs := getAudioLanguages(info)
	if len(langs) > 0 {
		send(Event{"event": "languages_available", "languages": langs, "current": language})
	}

	_, aud := bestStreams(info, language)
	if aud == nil {
		sendErr("No compatible audio stream found.")
		return
	}

	b.mu.Lock()
	b.cachedInfo = info
	b.mlConcised = mlConcised
	b.mlModel = mlModel
	b.keepSegments = nil
	if !sponsorBlock { b.sponsorSegments = nil }
	b.segIdx = 0
	b.activeVlcPort = "9090"
	
	// Kill any active VLC video windows so we don't have overlapping audio
	for _, p := range b.ffmpegProcs {
		p.Process.Kill()
	}
	b.ffmpegProcs = nil
	b.mu.Unlock()

	ua := info.HTTPHeaders["User-Agent"]
	b.vlcHTTP("pl_stop")
	b.vlcHTTP("pl_empty")
	time.Sleep(50 * time.Millisecond)
	
	b.vlcHTTP("in_play&input=" + url.QueryEscape(aud.URL) + "&option=http-user-agent=" + url.QueryEscape(ua) + "&option=http-referrer=https://www.youtube.com/")

	send(Event{"event": "playing", "video_id": videoID})
	if mlConcised {
		go b.runML(videoID, mlModel)
	}
}

func (b *Backend) OpenVideo(videoID string, language string, sponsorBlock bool) {
	sendInfo("Preparing stream...")

	if sponsorBlock {
		go func() {
			skips := fetchSponsorBlock(videoID)
			b.mu.Lock()
			b.sponsorSegments = skips
			b.mu.Unlock()
		}()
	}

	b.mu.Lock()
	info := b.cachedInfo
	if info == nil || info.ID != videoID {
		info = b.prefetch[videoID]
	}
	b.mu.Unlock()

	var err error
	if info == nil || info.ID != videoID {
		info, err = extractInfo(b.ctx, "https://www.youtube.com/watch?v=" + videoID)
		if err != nil {
			sendErr("yt-dlp: " + err.Error())
			return
		}
	}

	vid, aud := bestStreams(info, language)
	if vid == nil || aud == nil {
		sendErr("No compatible H264/AAC streams.")
		return
	}

	// Kill previous GUI ffmpeg/vlc and free old port
	b.mu.Lock()
	for _, p := range b.ffmpegProcs {
		p.Process.Kill()
	}
	b.ffmpegProcs = nil
	if b.videoListener != nil {
		b.videoListener.Close()
	}
	b.mu.Unlock()

	ua := info.HTTPHeaders["User-Agent"]
	if ua == "" && vid != nil { ua = vid.HTTPHeaders["User-Agent"] }

	vlcArgs := []string{
		"--no-one-instance",
		"--fullscreen",
		"--network-caching=300",
		"--live-caching=300",
		"--intf", "http",
		"--http-host", "127.0.0.1",
		"--http-port", "9091", // Use 9091 for GUI
		"--http-password", "secret",
		"--http-user-agent=" + ua,
		"--http-referrer=https://www.youtube.com/",
	}

	if vid != nil && aud != nil {
		vlcArgs = append(vlcArgs, vid.URL, "--input-slave", aud.URL)
	} else if vid != nil {
		vlcArgs = append(vlcArgs, vid.URL)
	} else if aud != nil {
		vlcArgs = append(vlcArgs, aud.URL)
	}
	b.mu.Lock()
	b.activeVlcPort = "9091"
	b.mu.Unlock()

	// Stop headless audio (using its port)
	b.mu.Lock(); prevPort := b.activeVlcPort; b.activeVlcPort = "9090"; b.mu.Unlock()
	b.vlcHTTP("pl_stop")
	b.mu.Lock(); b.activeVlcPort = prevPort; b.mu.Unlock()

	vlcGUI := hideCmd(exec.Command(vlcExe, vlcArgs...))
	if err := vlcGUI.Start(); err != nil {
		sendErr("VLC GUI: " + err.Error())
		return
	}

	b.mu.Lock()
	b.ffmpegProcs = append(b.ffmpegProcs, vlcGUI)
	b.activeVlcPort = "9091"
	if !sponsorBlock { b.sponsorSegments = nil }
	b.mu.Unlock()

	sendInfo("Streaming natively to VLC...")
}

func readAPIKey() string {
	data, _ := os.ReadFile(apiKeysPath)
	var keys map[string]string
	json.Unmarshal(data, &keys)
	return keys["groq"]
}

func (b *Backend) RunMLAnalysis(transcript []TranscBlock, mlModel *MLModelCfg) {
	var sb strings.Builder
	for _, t := range transcript {
		fmt.Fprintf(&sb, "[%.1f-%.1f]: %s\n", t.Start, t.Start+t.Duration, t.Text)
	}
	text := sb.String()
	if len(text) > 20000 {
		text = text[:20000]
	}
	b.callML(text, mlModel)
}

func (b *Backend) runML(videoID string, mlModel *MLModelCfg) {
	send(Event{"event": "transcript_ready", "message": "Analyzing transcript..."})
	b.callML("", mlModel)
}

func (b *Backend) callML(text string, mlModel *MLModelCfg) {
	provider, model := "groq", "llama3-70b-8192"
	if mlModel != nil {
		if mlModel.Provider != "" { provider = mlModel.Provider }
		if mlModel.Name != "" { model = mlModel.Name }
	}

	sysPrompt := "You are a YouTube audio editor. Analyze the transcript timestamps and identify only the 'core content'. Return a JSON array of start/end arrays to KEEP. Example: [[30.5,450.0],[480.0,1200.0]]. ONLY return JSON."

	payload, _ := json.Marshal(map[string]interface{}{
		"model": model,
		"messages": []map[string]string{
			{"role": "system", "content": sysPrompt},
			{"role": "user", "content": text},
		},
		"temperature": 0.1,
	})

	var apiURL string
	var headers map[string]string
	if provider == "groq" {
		key := readAPIKey()
		if key == "" { sendErr("Groq API key missing."); return }
		apiURL = "https://api.groq.com/openai/v1/chat/completions"
		headers = map[string]string{"Authorization": "Bearer " + key}
	} else {
		apiURL = "http://localhost:11434/api/generate"
	}

	req, _ := http.NewRequest("POST", apiURL, bytes.NewReader(payload))
	req.Header.Set("Content-Type", "application/json")
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := (&http.Client{Timeout: 30 * time.Second}).Do(req)
	if err != nil { sendErr("ML API: " + err.Error()); return }
	defer resp.Body.Close()

	var result map[string]interface{}
	json.NewDecoder(resp.Body).Decode(&result)

	var output string
	if c, ok := result["choices"].([]interface{}); ok && len(c) > 0 {
		if m, ok := c[0].(map[string]interface{})["message"].(map[string]interface{}); ok {
			output, _ = m["content"].(string)
		}
	} else if r, ok := result["response"].(string); ok {
		output = r
	}

	flat := strings.ReplaceAll(output, "\n", "")
	match := regexp.MustCompile(`\[\s*\[.*?\]\s*\]`).FindString(flat)
	if match == "" {
		match = regexp.MustCompile(`\[.*\]`).FindString(flat)
	}
	if match == "" { sendErr("ML produced no JSON."); return }

	var segs [][2]float64
	if json.Unmarshal([]byte(match), &segs) != nil { sendErr("ML JSON parse failed."); return }

	b.mu.Lock()
	b.keepSegments = segs
	b.segIdx = 0
	b.mu.Unlock()
	send(Event{"event": "skipped_filler", "to": 0.0})
}

func (b *Backend) monitorLoop() {
	lastState := ""
	for {
		time.Sleep(500 * time.Millisecond)
		st := b.vlcStatus()
		if st == nil {
			if lastState != "stopped" && lastState != "ended" && lastState != "" {
				send(Event{"event": "stopped"})
				lastState = "stopped"
				b.statMu.Lock()
				b.statPos = 0
				b.statLen = 0
				b.statPlaying = false
				b.statMu.Unlock()
			}
			continue
		}
		state, _ := st["state"].(string)
		pos, _ := st["time"].(float64)
		ln, _ := st["length"].(float64)

		isPlaying := state == "playing"
		b.statMu.Lock()
		b.statPos = pos
		b.statLen = ln
		b.statPlaying = isPlaying
		b.statMu.Unlock()

		if (state == "stopped" || state == "ended") && lastState != "stopped" && lastState != "ended" {
			b.mu.Lock(); repeat := b.repeatMode; b.mu.Unlock()
			if repeat {
				b.vlcHTTP("pl_play")
			} else {
				send(Event{"event": "stopped"})
			}
		}
		lastState = state

		b.mu.Lock()
		segs := b.keepSegments; idx := b.segIdx; ml := b.mlConcised
		spSkips := b.sponsorSegments
		b.mu.Unlock()

		if isPlaying && len(spSkips) > 0 {
			for _, skip := range spSkips {
				if pos >= skip[0] && pos < skip[1] {
					b.vlcHTTP("seek&val=" + strconv.Itoa(int(skip[1])))
					send(Event{"event": "skipped_sponsor", "to": skip[1]})
					break
				}
			}
		}

		if ml && isPlaying && idx < len(segs) {
			if pos > segs[idx][1] {
				b.mu.Lock(); b.segIdx++; ni := b.segIdx; b.mu.Unlock()
				if ni < len(segs) {
					b.vlcHTTP("seek&val=" + strconv.Itoa(int(segs[ni][0])))
					send(Event{"event": "skipped_filler", "to": segs[ni][0]})
				} else {
					b.vlcHTTP("pl_stop")
				}
			}
		}
	}
}

func killZombiesOnPort(port string) {
	out, err := hideCmd(exec.Command("cmd", "/C", fmt.Sprintf("netstat -ano | findstr :%s", port))).Output()
	if err == nil {
		lines := strings.Split(string(out), "\n")
		for _, line := range lines {
			if strings.Contains(line, "LISTENING") {
				fields := strings.Fields(line)
				if len(fields) >= 5 {
					pid := fields[len(fields)-1]
					hideCmd(exec.Command("taskkill", "/F", "/PID", pid)).Run()
				}
			}
		}
	}
}

func main() {
	killZombiesOnPort("9090")
	killZombiesOnPort("9091")

	bk = &Backend{prefetch: make(map[string]*YTInfo)}
	bk.ctx, bk.cancel = context.WithCancel(context.Background())
	defer bk.cancel()

	// Start headless VLC with HTTP interface (will be restarted on Play)
	vlcProc := hideCmd(exec.Command(vlcExe,
		"--intf", "http",
		"--http-host", "127.0.0.1",
		"--http-port", vlcPort,
		"--http-password", "secret",
		"--no-video", "--quiet",
		"--no-one-instance",
		"--network-caching=3000",
		"--live-caching=3000",
		"--http-user-agent=Mozilla/5.0 (Windows NT 10.0; Win64; x64)",
	))
	vlcProc.Stdout = io.Discard
	vlcProc.Stderr = io.Discard
	vlcProc.Start()
	bk.vlcProcess = vlcProc
	time.Sleep(400 * time.Millisecond)

	go bk.monitorLoop()

	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 1<<20), 10<<20)
	for scanner.Scan() {
		var req Request
		if json.Unmarshal(scanner.Bytes(), &req) != nil { continue }
		switch req.Cmd {
		case "search":
			bk.mu.Lock()
			if bk.searchCancel != nil { bk.searchCancel() }
			var searchCtx context.Context
			searchCtx, bk.searchCancel = context.WithCancel(bk.ctx)
			bk.mu.Unlock()

			go func(ctx context.Context, q string, page int, stype string) {
				if page <= 0 { page = 1 }
				r := searchYT(ctx, bk, q, page, stype)
				if r == nil { r = []map[string]interface{}{} }
				if ctx.Err() != nil { return }
				
				send(Event{"event": "search_results", "results": r, "page": page})
				
				for i := 0; i < 2 && i < len(r); i++ {
					if id, ok := r[i]["id"].(string); ok && r[i]["type"] == "video" {
						go func(vid string) {
							info, err := extractInfo(ctx, "https://www.youtube.com/watch?v=" + vid)
							if err == nil {
								bk.mu.Lock()
								bk.prefetch[vid] = info
								bk.mu.Unlock()
							}
						}(id)
					}
				}
			}(searchCtx, req.Query, req.Page, req.SearchType)
		case "playlist_videos":
			bk.mu.Lock()
			if bk.searchCancel != nil { bk.searchCancel() }
			var searchCtx context.Context
			searchCtx, bk.searchCancel = context.WithCancel(bk.ctx)
			bk.mu.Unlock()

			go func(ctx context.Context, pid string) {
				r := getPlaylistVideos(ctx, pid)
				if r == nil { r = []map[string]interface{}{} }
				if ctx.Err() != nil { return }
				send(Event{"event": "playlist_videos", "playlist_id": pid, "videos": r})
			}(searchCtx, req.PlaylistID)
		case "play":
			go bk.Play(req.VideoID, req.MLConcised, req.MLModel, req.Language, req.SponsorBlock)
		case "open_video":
			go bk.OpenVideo(req.VideoID, req.Language, req.SponsorBlock)
		case "analyze_ml":
			go bk.RunMLAnalysis(req.Transcript, req.MLModel)
		case "set_ml_segments":
			bk.mu.Lock(); bk.keepSegments = req.Segments; bk.segIdx = 0; bk.mu.Unlock()
		case "set_repeat":
			bk.mu.Lock(); bk.repeatMode = req.Enabled; bk.mu.Unlock()
		case "pause":
			go bk.vlcHTTP("pl_pause")
		case "resume":
			go bk.vlcHTTP("pl_play")
		case "stop":
			go func() {
				// Stop headless audio
				bk.mu.Lock(); prevPort := bk.activeVlcPort; bk.activeVlcPort = "9090"; bk.mu.Unlock()
				bk.vlcHTTP("pl_stop")
				bk.mu.Lock(); bk.activeVlcPort = prevPort; bk.mu.Unlock()
				
				// Kill GUI video if any
				bk.mu.Lock()
				for _, p := range bk.ffmpegProcs {
					p.Process.Kill()
				}
				bk.ffmpegProcs = nil
				bk.mu.Unlock()
			}()
		case "seek":
			go func(off float64) {
				val := ""
				if off > 0 { val = "%2B" + strconv.Itoa(int(off)) } else { val = strconv.Itoa(int(off)) }
				bk.vlcHTTP("seek&val=" + val)
			}(req.Offset)
		case "seek_abs":
			go func(time float64) {
				bk.vlcHTTP("seek&val=" + strconv.Itoa(int(time)))
			}(req.Offset) // Reuse req.Offset as the time parameter from Lua
		case "status":
			bk.statMu.Lock()
			pos, ln, pl := bk.statPos, bk.statLen, bk.statPlaying
			bk.statMu.Unlock()
			bk.mu.Lock(); ml := bk.mlConcised; bk.mu.Unlock()
			send(Event{"event":"status","time":pos,"length":ln,"playing":pl,"ml_concised":ml})
		}
	}

	if err := scanner.Err(); err != nil {
		os.WriteFile("yt_crash.log", []byte(err.Error()), 0644)
	}

	// Cleanup
	bk.mu.Lock()
	for _, p := range bk.ffmpegProcs { p.Process.Kill() }
	if bk.videoListener != nil { bk.videoListener.Close() }
	bk.mu.Unlock()
	if vlcProc.Process != nil { vlcProc.Process.Kill() }
}

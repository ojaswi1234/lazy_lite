#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <ctype.h>
#include <signal.h>
#include <time.h>
#include <sys/stat.h>
#include <fcntl.h>

#ifdef _WIN32
  #include <winsock2.h>
  #include <ws2tcpip.h>
  #include <windows.h>
  #define close closesocket
  #define sleep(x) Sleep((x)*1000)
  #define msleep(x) Sleep(x)
  #define PATH_SEP '\\'
  typedef HANDLE thread_t;
  #ifndef S_ISDIR
    #define S_ISDIR(m) (((m) & S_IFMT) == S_IFDIR)
  #endif
#else
  #include <unistd.h>
  #include <sys/socket.h>
  #include <netinet/in.h>
  #include <arpa/inet.h>
  #include <pthread.h>
  #include <dirent.h>
  #include <sys/time.h>
  #define PATH_SEP '/'
  #define msleep(x) usleep((x)*1000)
  typedef pthread_t thread_t;
#endif

#define MAX_THREADS 256
#define BUF_SIZE 8192
#define MAX_PATH_LEN 4096

static int server_socket = -1;
static volatile bool keep_running = true;

static char root_dir[MAX_PATH_LEN];
static int port = 8080;
static char host[256] = "127.0.0.1";
static bool spa_fallback = false;
static bool live_reload = true;
static char ignore_dirs_str[1024] = ".git,node_modules";
static char *ignore_dirs[64];
static int ignore_dirs_count = 0;

#ifdef _WIN32
static volatile LONG thread_count = 0;
#else
static volatile int thread_count = 0;
static pthread_mutex_t thread_count_mutex = PTHREAD_MUTEX_INITIALIZER;
#endif

static void inc_thread_count() {
#ifdef _WIN32
    InterlockedIncrement(&thread_count);
#else
    pthread_mutex_lock(&thread_count_mutex);
    thread_count++;
    pthread_mutex_unlock(&thread_count_mutex);
#endif
}

static void dec_thread_count() {
#ifdef _WIN32
    InterlockedDecrement(&thread_count);
#else
    pthread_mutex_lock(&thread_count_mutex);
    thread_count--;
    pthread_mutex_unlock(&thread_count_mutex);
#endif
}

static void handle_sig(int sig) {
    keep_running = false;
    if (server_socket != -1) {
        close(server_socket);
        server_socket = -1;
    }
}

static void parse_ignore_dirs() {
    char *tok = strtok(ignore_dirs_str, ",");
    while (tok && ignore_dirs_count < 64) {
        ignore_dirs[ignore_dirs_count++] = tok;
        tok = strtok(NULL, ",");
    }
}

static bool should_ignore(const char *name) {
    if (name[0] == '.') return true;
    for (int i = 0; i < ignore_dirs_count; i++) {
        if (strcmp(name, ignore_dirs[i]) == 0) return true;
    }
    return false;
}

#ifdef _WIN32
static time_t get_mtime_recursive(const char *dir) {
    char search_path[MAX_PATH_LEN];
    snprintf(search_path, sizeof(search_path), "%s\\*", dir);
    WIN32_FIND_DATAA fd;
    HANDLE hFind = FindFirstFileA(search_path, &fd);
    if (hFind == INVALID_HANDLE_VALUE) return 0;
    
    time_t max_mtime = 0;
    do {
        if (strcmp(fd.cFileName, ".") == 0 || strcmp(fd.cFileName, "..") == 0) continue;
        
        char path[MAX_PATH_LEN];
        snprintf(path, sizeof(path), "%s\\%s", dir, fd.cFileName);
        
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
            if (should_ignore(fd.cFileName)) continue;
            time_t sub_mtime = get_mtime_recursive(path);
            if (sub_mtime > max_mtime) max_mtime = sub_mtime;
        } else {
            ULARGE_INTEGER ull;
            ull.LowPart = fd.ftLastWriteTime.dwLowDateTime;
            ull.HighPart = fd.ftLastWriteTime.dwHighDateTime;
            time_t mtime = (ull.QuadPart / 10000000ULL - 11644473600ULL);
            if (mtime > max_mtime) max_mtime = mtime;
        }
    } while (FindNextFileA(hFind, &fd));
    FindClose(hFind);
    return max_mtime;
}
#else
static time_t get_mtime_recursive(const char *dir) {
    DIR *d = opendir(dir);
    if (!d) return 0;
    time_t max_mtime = 0;
    struct dirent *ent;
    while ((ent = readdir(d)) != NULL) {
        if (strcmp(ent->d_name, ".") == 0 || strcmp(ent->d_name, "..") == 0) continue;
        
        char path[MAX_PATH_LEN];
        snprintf(path, sizeof(path), "%s/%s", dir, ent->d_name);
        
        struct stat st;
        if (stat(path, &st) == 0) {
            if (S_ISDIR(st.st_mode)) {
                if (should_ignore(ent->d_name)) continue;
                time_t sub_mtime = get_mtime_recursive(path);
                if (sub_mtime > max_mtime) max_mtime = sub_mtime;
            } else {
                if (st.st_mtime > max_mtime) max_mtime = st.st_mtime;
            }
        }
    }
    closedir(d);
    return max_mtime;
}
#endif

static void url_decode(char *dst, const char *src) {
    char a, b;
    while (*src) {
        if ((*src == '%') &&
            ((a = src[1]) && (b = src[2])) &&
            (isxdigit(a) && isxdigit(b))) {
            if (a >= 'a') a -= 'a'-'A';
            if (a >= 'A') a -= ('A' - 10);
            else a -= '0';
            if (b >= 'a') b -= 'a'-'A';
            if (b >= 'A') b -= ('A' - 10);
            else b -= '0';
            *dst++ = 16*a+b;
            src+=3;
        } else if (*src == '+') {
            *dst++ = ' ';
            src++;
        } else {
            *dst++ = *src++;
        }
    }
    *dst++ = '\0';
}

static const char* get_mime_type(const char *path) {
    const char *ext = strrchr(path, '.');
    if (!ext) return "application/octet-stream";
    if (strcasecmp(ext, ".html") == 0 || strcasecmp(ext, ".htm") == 0) return "text/html";
    if (strcasecmp(ext, ".css") == 0) return "text/css";
    if (strcasecmp(ext, ".js") == 0 || strcasecmp(ext, ".mjs") == 0) return "application/javascript";
    if (strcasecmp(ext, ".json") == 0) return "application/json";
    if (strcasecmp(ext, ".svg") == 0) return "image/svg+xml";
    if (strcasecmp(ext, ".png") == 0) return "image/png";
    if (strcasecmp(ext, ".jpg") == 0 || strcasecmp(ext, ".jpeg") == 0) return "image/jpeg";
    if (strcasecmp(ext, ".gif") == 0) return "image/gif";
    if (strcasecmp(ext, ".webp") == 0) return "image/webp";
    if (strcasecmp(ext, ".ico") == 0) return "image/x-icon";
    if (strcasecmp(ext, ".woff") == 0) return "font/woff";
    if (strcasecmp(ext, ".woff2") == 0) return "font/woff2";
    if (strcasecmp(ext, ".ttf") == 0) return "font/ttf";
    if (strcasecmp(ext, ".txt") == 0) return "text/plain";
    if (strcasecmp(ext, ".wasm") == 0) return "application/wasm";
    if (strcasecmp(ext, ".map") == 0) return "application/json";
    return "application/octet-stream";
}

static void send_response(int client, const char *status, const char *content_type, const char *body, int body_len) {
    char headers[1024];
    int hlen = snprintf(headers, sizeof(headers),
        "HTTP/1.1 %s\r\n"
        "Content-Type: %s\r\n"
        "Content-Length: %d\r\n"
        "Access-Control-Allow-Origin: *\r\n"
        "Cache-Control: no-store\r\n"
        "Connection: close\r\n\r\n",
        status, content_type, body_len);
    send(client, headers, hlen, 0);
    if (body && body_len > 0) {
        send(client, body, body_len, 0);
    }
}

static const char* RELOAD_SCRIPT = 
"<script>\n"
"(function() {\n"
"    let lastMtime = 0;\n"
"    function poll() {\n"
"        fetch('/__lazylite_reload', {headers: {'X-Last-Mtime': lastMtime.toString()}})\n"
"        .then(res => res.text())\n"
"        .then(text => {\n"
"            let mtime = parseInt(text);\n"
"            if (lastMtime === 0) { lastMtime = mtime; }\n"
"            else if (mtime > lastMtime) { location.reload(); }\n"
"            setTimeout(poll, 500);\n"
"        })\n"
"        .catch(() => setTimeout(poll, 2000));\n"
"    }\n"
"    poll();\n"
"})();\n"
"</script>\n";

static void serve_file(int client, const char *req_path) {
    char decoded_path[MAX_PATH_LEN];
    url_decode(decoded_path, req_path);
    
    if (strstr(decoded_path, "..") != NULL) {
        send_response(client, "403 Forbidden", "text/plain", "Forbidden", 9);
        return;
    }
    
    char local_path[MAX_PATH_LEN * 2];
    snprintf(local_path, sizeof(local_path), "%s%s", root_dir, decoded_path);
    
#ifdef _WIN32
    for(int i = 0; local_path[i]; i++) if(local_path[i] == '/') local_path[i] = '\\';
#endif
    
    struct stat st;
    if (stat(local_path, &st) == 0 && S_ISDIR(st.st_mode)) {
        if (local_path[strlen(local_path)-1] != PATH_SEP) {
            snprintf(local_path + strlen(local_path), sizeof(local_path) - strlen(local_path), "%cindex.html", PATH_SEP);
        } else {
            snprintf(local_path + strlen(local_path), sizeof(local_path) - strlen(local_path), "index.html");
        }
    }
    
    FILE *f = fopen(local_path, "rb");
    if (!f && spa_fallback) {
        snprintf(local_path, sizeof(local_path), "%s%cindex.html", root_dir, PATH_SEP);
        f = fopen(local_path, "rb");
    }
    
    if (!f) {
        send_response(client, "404 Not Found", "text/plain", "Not Found", 9);
        return;
    }
    
    fseek(f, 0, SEEK_END);
    long fsize = ftell(f);
    fseek(f, 0, SEEK_SET);
    
    char *buf = malloc(fsize + 1);
    if (!buf) {
        fclose(f);
        send_response(client, "500 Internal Error", "text/plain", "OOM", 3);
        return;
    }
    fread(buf, 1, fsize, f);
    fclose(f);
    buf[fsize] = '\0';
    
    const char *mime = get_mime_type(local_path);
    int inject_len = 0;
    
    if (live_reload && strcmp(mime, "text/html") == 0) {
        // Find </body> to inject
        char *body_close = strstr(buf, "</body>");
        if (!body_close) body_close = strstr(buf, "</BODY>");
        
        inject_len = strlen(RELOAD_SCRIPT);
        char *new_buf = malloc(fsize + inject_len + 1);
        if (body_close) {
            int pre_len = body_close - buf;
            memcpy(new_buf, buf, pre_len);
            memcpy(new_buf + pre_len, RELOAD_SCRIPT, inject_len);
            memcpy(new_buf + pre_len + inject_len, body_close, fsize - pre_len);
        } else {
            memcpy(new_buf, buf, fsize);
            memcpy(new_buf + fsize, RELOAD_SCRIPT, inject_len);
        }
        free(buf);
        buf = new_buf;
        fsize += inject_len;
    }
    
    send_response(client, "200 OK", mime, buf, fsize);
    free(buf);
}

#ifdef _WIN32
static DWORD WINAPI handle_client(LPVOID arg) {
#else
static void* handle_client(void *arg) {
#endif
    int client = (int)(intptr_t)arg;
    char req[BUF_SIZE];
    int recv_len = recv(client, req, sizeof(req)-1, 0);
    
    if (recv_len > 0) {
        req[recv_len] = '\0';
        char method[16], path[1024];
        if (sscanf(req, "%15s %1023s", method, path) == 2) {
            if (strcmp(method, "GET") != 0) {
                send_response(client, "405 Method Not Allowed", "text/plain", "Method Not Allowed", 18);
            } else if (strncmp(path, "/__lazylite_reload", 18) == 0) {
                // Long poll
                time_t current_mtime = get_mtime_recursive(root_dir);
                time_t client_mtime = 0;
                char *hdr = strstr(req, "X-Last-Mtime: ");
                if (hdr) client_mtime = atoll(hdr + 14);
                
                int elapsed = 0;
                while (keep_running && elapsed < 30000) {
                    time_t new_mtime = get_mtime_recursive(root_dir);
                    if (new_mtime > client_mtime) {
                        current_mtime = new_mtime;
                        break;
                    }
                    msleep(500);
                    elapsed += 500;
                }
                char resp[64];
                int rlen = snprintf(resp, sizeof(resp), "%lld", (long long)current_mtime);
                send_response(client, "200 OK", "text/plain", resp, rlen);
            } else {
                serve_file(client, path);
            }
        } else {
            send_response(client, "400 Bad Request", "text/plain", "Bad Request", 11);
        }
    }
    
    close(client);
    dec_thread_count();
    return 0;
}

int main(int argc, char *argv[]) {
    signal(SIGINT, handle_sig);
    signal(SIGTERM, handle_sig);
    
    if (argc > 1) {
        strncpy(root_dir, argv[1], sizeof(root_dir)-1);
    } else {
        strcpy(root_dir, ".");
    }
    
    // Resolve absolute path
#ifdef _WIN32
    char abs_path[MAX_PATH_LEN];
    if (_fullpath(abs_path, root_dir, MAX_PATH_LEN)) {
        strncpy(root_dir, abs_path, sizeof(root_dir)-1);
    }
#else
    char *abs_path = realpath(root_dir, NULL);
    if (abs_path) {
        strncpy(root_dir, abs_path, sizeof(root_dir)-1);
        free(abs_path);
    }
#endif

    struct stat st;
    if (stat(root_dir, &st) != 0 || !S_ISDIR(st.st_mode)) {
        fprintf(stderr, "Error: Root directory '%s' does not exist or is not a directory.\n", root_dir);
        return 1;
    }

    if (argc > 2) port = atoi(argv[2]);
    
    for (int i = 3; i < argc; i++) {
        if (strcmp(argv[i], "--spa") == 0) spa_fallback = true;
        else if (strcmp(argv[i], "--no-reload") == 0) live_reload = false;
        else if (strncmp(argv[i], "--ignore=", 9) == 0) {
            strncpy(ignore_dirs_str, argv[i] + 9, sizeof(ignore_dirs_str)-1);
        }
        else if (strncmp(argv[i], "--host=", 7) == 0) {
            strncpy(host, argv[i] + 7, sizeof(host)-1);
        }
    }
    parse_ignore_dirs();
    
#ifdef _WIN32
    WSADATA wsa;
    WSAStartup(MAKEWORD(2,2), &wsa);
#endif

    server_socket = socket(AF_INET, SOCK_STREAM, 0);
    int opt = 1;
    setsockopt(server_socket, SOL_SOCKET, SO_REUSEADDR, (const char*)&opt, sizeof(opt));
    
    struct sockaddr_in addr;
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = inet_addr(host);
    
    int bound = 0;
    for (int p = port; p < port + 10; p++) {
        addr.sin_port = htons(p);
        if (bind(server_socket, (struct sockaddr*)&addr, sizeof(addr)) == 0) {
            port = p;
            bound = 1;
            break;
        }
    }
    
    if (!bound) {
        fprintf(stderr, "Error: Could not bind to any port in range %d-%d\n", port, port+9);
        return 1;
    }
    
    listen(server_socket, 128);
    printf("PORT_BOUND:%d\n", port);
    fflush(stdout);
    
    while (keep_running) {
        struct sockaddr_in caddr;
        socklen_t clen = sizeof(caddr);
        int client = accept(server_socket, (struct sockaddr*)&caddr, &clen);
        if (client < 0) continue;
        
        if (thread_count >= MAX_THREADS) {
            send_response(client, "503 Service Unavailable", "text/plain", "Too Many Connections", 20);
            close(client);
            continue;
        }
        
        inc_thread_count();
        
#ifdef _WIN32
        HANDLE hThread = CreateThread(NULL, 0, handle_client, (LPVOID)(intptr_t)client, 0, NULL);
        if (hThread) CloseHandle(hThread);
        else { dec_thread_count(); close(client); }
#else
        pthread_t t;
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
        if (pthread_create(&t, &attr, handle_client, (void*)(intptr_t)client) != 0) {
            dec_thread_count();
            close(client);
        }
        pthread_attr_destroy(&attr);
#endif
    }
    
#ifdef _WIN32
    WSACleanup();
#endif
    return 0;
}


CC ?= gcc
CFLAGS = -O2 -Wall
WIN_CC = x86_64-w64-mingw32-gcc

# Output names
OUT_LINUX = lazy_lite_preview_server
OUT_MAC = lazy_lite_preview_server_mac
OUT_WIN = lazy_lite_preview_server.exe

all: linux

linux:
	$(CC) $(CFLAGS) lazy_lite_preview_server.c -o $(OUT_LINUX) -lpthread

mac:
	$(CC) $(CFLAGS) lazy_lite_preview_server.c -o $(OUT_MAC) -lpthread

windows:
	$(WIN_CC) $(CFLAGS) lazy_lite_preview_server.c -o $(OUT_WIN) -lws2_32

clean:
	rm -f $(OUT_LINUX) $(OUT_MAC) $(OUT_WIN)

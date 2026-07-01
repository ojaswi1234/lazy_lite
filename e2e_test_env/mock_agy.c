#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <unistd.h>
#endif

void sleep_ms(int ms) {
    if (ms <= 0) return;
#ifdef _WIN32
    Sleep(ms);
#else
    usleep(ms * 1000);
#endif
}

int main(int argc, char *argv[]) {
    // Check if arguments have "models"
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "models") == 0) {
            printf("gemini-2.5-flash\n");
            printf("gemini-2.5-pro\n");
            printf("gemini-2.5-flash-thinking (quota exhausted)\n");
            return 0;
        }
    }

    // Try opening mock_config.txt in e2e_test_env/mock_config.txt or mock_config.txt
    FILE *f = fopen("e2e_test_env/mock_config.txt", "r");
    if (!f) {
        f = fopen("mock_config.txt", "r");
    }

    int exit_code = 0;
    int delay_ms = 0;
    char *stdout_text = NULL;
    char *stderr_text = NULL;

    if (f) {
        char line[1024];
        char section[50] = "";
        size_t stdout_cap = 4096, stdout_len = 0;
        size_t stderr_cap = 4096, stderr_len = 0;
        stdout_text = malloc(stdout_cap);
        stdout_text[0] = '\0';
        stderr_text = malloc(stderr_cap);
        stderr_text[0] = '\0';

        while (fgets(line, sizeof(line), f)) {
            if (line[0] == '[') {
                // Section header (strip brackets and newline)
                size_t len = strlen(line);
                if (line[len - 1] == '\n') line[len - 1] = '\0';
                len = strlen(line);
                if (line[len - 1] == '\r') line[len - 1] = '\0';
                
                sscanf(line, "[%49[^]]]", section);
                continue;
            }
            if (strcmp(section, "ExitCode") == 0) {
                exit_code = atoi(line);
            } else if (strcmp(section, "Delay") == 0) {
                delay_ms = atoi(line);
            } else if (strcmp(section, "Stdout") == 0) {
                size_t len = strlen(line);
                if (stdout_len + len + 1 >= stdout_cap) {
                    stdout_cap *= 2;
                    stdout_text = realloc(stdout_text, stdout_cap);
                }
                strcpy(stdout_text + stdout_len, line);
                stdout_len += len;
            } else if (strcmp(section, "Stderr") == 0) {
                size_t len = strlen(line);
                if (stderr_len + len + 1 >= stderr_cap) {
                    stderr_cap *= 2;
                    stderr_text = realloc(stderr_text, stderr_cap);
                }
                strcpy(stderr_text + stderr_len, line);
                stderr_len += len;
            }
        }
        fclose(f);
    } else {
        // Default values if no config file is found
        stdout_text = malloc(4096);
        sprintf(stdout_text, "Mock default stdout response. Args: ");
        for (int i = 1; i < argc; i++) {
            strcat(stdout_text, argv[i]);
            strcat(stdout_text, " ");
        }
        strcat(stdout_text, "\n");
        stderr_text = malloc(1024);
        stderr_text[0] = '\0';
    }

    // Now stream the output
    // Print stderr if any
    if (stderr_text && strlen(stderr_text) > 0) {
        char *p = stderr_text;
        while (*p) {
            fputc(*p, stderr);
            fflush(stderr);
            if (delay_ms > 0) {
                sleep_ms(delay_ms);
            }
            p++;
        }
    }

    // Print stdout if any
    if (stdout_text && strlen(stdout_text) > 0) {
        char *p = stdout_text;
        while (*p) {
            fputc(*p, stdout);
            fflush(stdout);
            if (delay_ms > 0) {
                sleep_ms(delay_ms);
            }
            p++;
        }
    }

    free(stdout_text);
    free(stderr_text);
    return exit_code;
}

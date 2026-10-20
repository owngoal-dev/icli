#include <stdio.h>
#include <unistd.h>

// A launchd fixture whose observable version changes when its executable is
// replaced. The old process keeps running until kickstart actually replaces it.
int main(int argc, char **argv) {
    if (argc != 2) return 64;
    FILE *output = fopen(argv[1], "w");
    if (!output) return 1;
    fprintf(output, "%d %d\n", ICLI_DAEMON_VERSION, getpid());
    if (fclose(output) != 0) return 1;
    for (;;) pause();
}

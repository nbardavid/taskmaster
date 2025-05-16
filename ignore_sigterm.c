#include <stdio.h>
#include <signal.h>
#include <unistd.h>

int main(void) {
    signal(SIGTERM, SIG_IGN);
    while (1)
        pause();
    return 0;
}

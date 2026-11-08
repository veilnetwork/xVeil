
#define _POSIX_C_SOURCE 200809L
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

static long long now_ms(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t) != 0) return -1;
    return (long long)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
static int number(const char *s, int min, int max, int *out) {
    char *end = NULL;
    errno = 0;
    long value = strtol(s, &end, 10);
    if (errno || end == s || *end || value < min || value > max) return 0;
    *out = (int)value;
    return 1;
}
static int emit(const char *stage, int error, int mss, int applied,
                int actual_mss, long long started) {
    long long ended = now_ms();
    printf("{\"stage\":\"%s\",\"success\":%s,\"errno\":%d,"
           "\"requested_mss\":%d,\"mss_applied\":%s,\"actual_mss\":%d,"
           "\"elapsed_ms\":%lld}\n",
           stage, error == 0 ? "true" : "false", error, mss,
           applied ? "true" : "false", actual_mss,
           started >= 0 && ended >= started ? ended - started : -1);
    return error == 0 ? 0 : 1;
}
int main(int argc, char **argv) {
    int port = 0, mss = 0, deadline_ms = 0;
    if (argc != 5 || !number(argv[2], 1, 65535, &port)
        || !number(argv[3], 0, 65535, &mss)
        || !number(argv[4], 1, 10000, &deadline_ms)) {
        fputs("usage: android_tcp_connect_probe IPv4 port MSS timeout_ms\n", stderr);
        return 2;
    }
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons((unsigned short)port);
    if (inet_pton(AF_INET, argv[1], &addr.sin_addr) != 1) return 2;
    long long started = now_ms();
    if (started < 0) return emit("clock", errno, mss, 0, -1, started);
    int fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, IPPROTO_TCP);
    if (fd < 0) return emit("socket", errno, mss, 0, -1, started);
    int applied = 0;
    if (mss != 0) {
        if (setsockopt(fd, IPPROTO_TCP, TCP_MAXSEG, &mss, sizeof(mss)) < 0) {
            int e = errno; close(fd); return emit("socket_option", e, mss, 0, -1, started);
        }
        applied = 1;
    }
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
        int e = errno; close(fd); return emit("fcntl", e, mss, applied, -1, started);
    }
    int rc = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
    int e = rc == 0 ? 0 : errno;
    if (rc < 0 && (e == EINPROGRESS || e == EINTR)) {
        struct pollfd ready = {.fd = fd, .events = POLLOUT, .revents = 0};
        long long end = started + deadline_ms;
        for (;;) {
            long long current = now_ms();
            if (current < 0) { e = errno; break; }
            long long left = end - current;
            if (left <= 0) { e = ETIMEDOUT; break; }
            rc = poll(&ready, 1, (int)left);
            if (rc < 0 && errno == EINTR) continue;
            if (rc < 0) { e = errno; break; }
            if (rc == 0) { e = ETIMEDOUT; break; }
            socklen_t length = sizeof(e);
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &e, &length) < 0) e = errno;
            break;
        }
    }
    int actual_mss = -1;
    socklen_t length = sizeof(actual_mss);
    if (getsockopt(fd, IPPROTO_TCP, TCP_MAXSEG, &actual_mss, &length) < 0) actual_mss = -1;
    /* Intentionally never send application bytes, not even a protocol greeting. */
    close(fd);
    return emit("connect", e, mss, applied, actual_mss, started);
}

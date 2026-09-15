/* Local TCP/io_uring experiments; deliberately excludes HTTP and server timers.
 * Build: cc -O2 -Wall -Wextra bench/kernel_path.c -luring -o /tmp/kernel-path
 * Run: /tmp/kernel-path {recv,multishot,zc,busy,accept,direct} bytes iterations
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <liburing.h>
#include <netinet/tcp.h>
#include <sched.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define CHECK(x) do { if (!(x)) { fprintf(stderr, "%s:%d: %s (errno %d)\n", __FILE__, __LINE__, #x, errno); exit(1); } } while (0)
static uint64_t ns(clockid_t clock) {
    struct timespec t;
    CHECK(clock_gettime(clock, &t) == 0);
    return (uint64_t)t.tv_sec * 1000000000 + t.tv_nsec;
}
static void pin(int cpu) {
    cpu_set_t set;
    CPU_ZERO(&set); CPU_SET(cpu, &set);
    CHECK(sched_setaffinity(0, sizeof(set), &set) == 0);
}
static void transfer(int fd, char *bytes, size_t len, int writing) {
    while (len) {
        ssize_t n = writing ? send(fd, bytes, len, MSG_NOSIGNAL) : recv(fd, bytes, len, 0);
        if (n < 0 && errno == EINTR) continue;
        CHECK(n > 0); bytes += n; len -= n;
    }
}
static struct io_uring_cqe completion(struct io_uring *ring) {
    struct io_uring_cqe *ptr;
    int r;
    do { r = io_uring_wait_cqe(ring, &ptr); } while (r == -EINTR);
    CHECK(r == 0);
    struct io_uring_cqe cqe = *ptr;
    io_uring_cqe_seen(ring, ptr);
    return cqe;
}
struct fragment { int bid, len, sent; };

int main(int argc, char **argv) {
    CHECK(argc == 4 || argc == 6);
    const char *mode = argv[1];
    int multi = !strcmp(mode, "multishot"), zc = !strcmp(mode, "zc");
    int direct = !strcmp(mode, "direct"), churn = direct || !strcmp(mode, "accept");
    int busy = !strcmp(mode, "busy");
    size_t size = strtoul(argv[2], NULL, 10), iterations = strtoul(argv[3], NULL, 10);
    CHECK(size > 0 && size <= 65536 && iterations > 0);
    signal(SIGPIPE, SIG_IGN); alarm(40);
    int listener = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0), one = 1;
    CHECK(listener >= 0);
    CHECK(setsockopt(listener, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one)) == 0);
    struct sockaddr_in address = {.sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    if (argc == 6) CHECK(inet_pton(AF_INET, argv[4], &address.sin_addr) == 1);
    CHECK(bind(listener, (void *)&address, sizeof(address)) == 0);
    socklen_t address_len = sizeof(address);
    CHECK(getsockname(listener, (void *)&address, &address_len) == 0);
    CHECK(listen(listener, 128) == 0);
    pid_t client = fork(); CHECK(client >= 0);
    if (!client) {
        pin(4); close(listener);
        if (argc == 6) {
            char path[128];
            CHECK(snprintf(path, sizeof(path), "/proc/%s/ns/net", argv[5]) > 0);
            int namespace = open(path, O_RDONLY | O_CLOEXEC); CHECK(namespace >= 0);
            CHECK(setns(namespace, CLONE_NEWNET) == 0); close(namespace);
        }
        char *input = malloc(size), *output = malloc(size); CHECK(input && output);
        int fd = -1;
        for (size_t i = 0; i < iterations; i++) {
            if (fd < 0) {
                fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0); CHECK(fd >= 0);
                CHECK(setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one)) == 0);
                CHECK(connect(fd, (void *)&address, sizeof(address)) == 0);
            }
            for (size_t j = 0; j < size; j++) input[j] = (char)(i + j);
            transfer(fd, input, size, 1); transfer(fd, output, size, 0);
            CHECK(memcmp(input, output, size) == 0);
            if (churn) { close(fd); fd = -1; }
        }
        if (fd >= 0) close(fd);
        free(input); free(output); _exit(0);
    }
    pin(2);
    struct io_uring ring;
    CHECK(io_uring_queue_init(512, &ring, IORING_SETUP_COOP_TASKRUN) == 0);
    if (busy) {
        struct io_uring_napi napi = {.busy_poll_to = 50};
        CHECK(io_uring_register_napi(&ring, &napi) == 0);
    }
    if (direct) CHECK(io_uring_register_files_sparse(&ring, 1) == 0);
    char *storage;
    CHECK(posix_memalign((void **)&storage, 4096, 128 * 65536) == 0);
    memset(storage, 0, 128 * 65536);
    struct io_uring_buf_ring *buffers = NULL;
    if (multi) {
        int error;
        buffers = io_uring_setup_buf_ring(&ring, 128, 7, 0, &error);
        CHECK(buffers != NULL);
        for (int i = 0; i < 128; i++)
            io_uring_buf_ring_add(buffers, storage + i * 65536, 65536, i, 127, i);
        io_uring_buf_ring_advance(buffers, 128);
    }
    uint64_t submissions = 0, cqes = 0, notifications = 0, copied = 0;
    uint64_t start_cpu = ns(CLOCK_THREAD_CPUTIME_ID), start_wall = ns(CLOCK_MONOTONIC);
    int incoming_napi = -1, busy_effective = -1;
    size_t connections = churn ? iterations : 1;
    for (size_t connection = 0; connection < connections; connection++) {
        struct io_uring_sqe *sqe = io_uring_get_sqe(&ring); CHECK(sqe);
        if (direct) io_uring_prep_accept_direct(sqe, listener, NULL, NULL, 0, 0);
        else io_uring_prep_accept(sqe, listener, NULL, NULL, SOCK_CLOEXEC);
        CHECK(io_uring_submit(&ring) == 1); submissions++;
        struct io_uring_cqe cqe = completion(&ring); cqes++; CHECK(cqe.res >= 0);
        int fd = cqe.res;
        if (busy) {
            int usecs = 50; socklen_t len = sizeof(usecs);
            CHECK(setsockopt(fd, SOL_SOCKET, SO_BUSY_POLL, &usecs, len) == 0);
            CHECK(getsockopt(fd, SOL_SOCKET, SO_BUSY_POLL, &busy_effective, &len) == 0);
        }
        size_t total = size * (churn ? 1 : iterations), received = 0, sent = 0;
        struct fragment queue[128]; unsigned head = 0, count = 0;
        int receiving = 0, sending = 0, zc_result = 0;
        while (sent < total) {
            unsigned queued = 0;
            if (!receiving && received < total && (multi || !count)) {
                sqe = io_uring_get_sqe(&ring); CHECK(sqe);
                if (multi) {
                    io_uring_prep_recv_multishot(sqe, fd, NULL, 0, 0);
                    sqe->flags |= IOSQE_BUFFER_SELECT; sqe->buf_group = 7;
                } else io_uring_prep_recv(sqe, fd, storage, size, 0);
                if (direct) sqe->flags |= IOSQE_FIXED_FILE;
                sqe->user_data = 1; receiving = 1; queued++;
            }
            if (!sending && count) {
                struct fragment *f = &queue[head];
                sqe = io_uring_get_sqe(&ring); CHECK(sqe);
                char *ptr = storage + f->bid * 65536 + f->sent;
                if (zc) io_uring_prep_send_zc(sqe, fd, ptr, f->len - f->sent, MSG_NOSIGNAL, IORING_SEND_ZC_REPORT_USAGE);
                else io_uring_prep_send(sqe, fd, ptr, f->len - f->sent, MSG_NOSIGNAL);
                if (direct) sqe->flags |= IOSQE_FIXED_FILE;
                sqe->user_data = 2; sending = 1; queued++;
            }
            if (queued) { CHECK(io_uring_submit(&ring) == (int)queued); submissions += queued; }
            cqe = completion(&ring); cqes++;
            if (cqe.user_data == 1) {
                if (!(cqe.flags & IORING_CQE_F_MORE)) receiving = 0;
                CHECK(cqe.res >= 0);
                if (!cqe.res) { CHECK(received == total); continue; }
                CHECK(count < 128);
                int bid = multi ? (int)(cqe.flags >> IORING_CQE_BUFFER_SHIFT) : 0;
                if (multi) CHECK(cqe.flags & IORING_CQE_F_BUFFER);
                queue[(head + count++) % 128] = (struct fragment){.bid = bid, .len = cqe.res};
                received += cqe.res; CHECK(received <= total);
            } else {
                CHECK(cqe.user_data == 2 && sending);
                if (cqe.flags & IORING_CQE_F_MORE) { CHECK(cqe.res > 0); zc_result = cqe.res; continue; }
                int result = cqe.res;
                if (cqe.flags & IORING_CQE_F_NOTIF) {
                    notifications++; copied += !!((unsigned)cqe.res & IORING_NOTIF_USAGE_ZC_COPIED);
                    result = zc_result;
                }
                CHECK(result > 0);
                struct fragment *f = &queue[head]; f->sent += result; sent += result;
                CHECK(f->sent <= f->len); sending = 0;
                if (f->sent == f->len) {
                    if (multi) {
                        io_uring_buf_ring_add(buffers, storage + f->bid * 65536, 65536, f->bid, 127, 0);
                        io_uring_buf_ring_advance(buffers, 1);
                    }
                    head = (head + 1) % 128; count--;
                }
            }
        }
        if (receiving) {
            sqe = io_uring_get_sqe(&ring); CHECK(sqe);
            io_uring_prep_cancel64(sqe, 1, 0); sqe->user_data = 3;
            CHECK(io_uring_submit(&ring) == 1); submissions++;
            int canceled = 0;
            while (receiving || !canceled) {
                cqe = completion(&ring); cqes++;
                if (cqe.user_data == 3) { CHECK(cqe.res == 0 || cqe.res == -ENOENT || cqe.res == -EALREADY); canceled = 1; }
                else { CHECK(cqe.user_data == 1 && cqe.res <= 0); if (!(cqe.flags & IORING_CQE_F_MORE)) receiving = 0; }
            }
        }
        CHECK(!count && !sending && received == total);
        if (direct) {
            sqe = io_uring_get_sqe(&ring); CHECK(sqe);
            io_uring_prep_close_direct(sqe, fd);
            CHECK(io_uring_submit(&ring) == 1); submissions++;
            cqe = completion(&ring); cqes++; CHECK(cqe.res == 0);
        } else {
            if (connection + 1 == connections) {
                socklen_t len = sizeof(incoming_napi);
                CHECK(getsockopt(fd, SOL_SOCKET, SO_INCOMING_NAPI_ID, &incoming_napi, &len) == 0);
            }
            close(fd);
        }
    }
    uint64_t cpu = ns(CLOCK_THREAD_CPUTIME_ID) - start_cpu, wall = ns(CLOCK_MONOTONIC) - start_wall;
    int status; CHECK(waitpid(client, &status, 0) == client); CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    printf("{\"mode\":\"%s\",\"http\":false,\"size\":%zu,\"iterations\":%zu,\"server_cpu_ns\":%llu,\"wall_ns\":%llu,\"sqes\":%llu,\"cqes\":%llu,\"zc_notifications\":%llu,\"zc_copied\":%llu,\"incoming_napi_id\":%d,\"busy_poll_us\":%d}\n",
           mode, size, iterations, (unsigned long long)cpu, (unsigned long long)wall,
           (unsigned long long)submissions, (unsigned long long)cqes,
           (unsigned long long)notifications, (unsigned long long)copied, incoming_napi, busy_effective);
    if (buffers) CHECK(io_uring_free_buf_ring(&ring, buffers, 128, 7) == 0);
    io_uring_queue_exit(&ring); free(storage); close(listener); return 0;
}

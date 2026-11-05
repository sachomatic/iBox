// ibox-launch: opens iBox from the command line, and with --watch keeps it alive:
//  - relaunches it whenever the phone falls back to the home screen (crash, reboot);
//  - restarts it when it stops answering while on screen (frozen main thread);
//  - serves a tiny restart page/endpoint on port 8081, which works even when iBox
//    itself is frozen (iBox's own web remote lives inside the app).
// Uses SpringBoardServices, loaded at runtime.
#include <CoreFoundation/CoreFoundation.h>
#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <notify.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>

#define APP_ID "com.ibox.tv"
#define APP_PROCESS "iBox"
#define APP_PORT 8080
#define WATCHDOG_PORT 8081
#define CHECK_SECONDS 15
#define FAILURES_BEFORE_RESTART 4  // ~1 minute without an answer

typedef int (*LaunchFn)(CFStringRef identifier, Boolean suspended);
typedef CFStringRef (*FrontmostFn)(void);

static LaunchFn launch;
static FrontmostFn frontmost;
static pthread_mutex_t restartLock = PTHREAD_MUTEX_INITIALIZER;

static void logLine(const char *msg) {
    time_t t = time(NULL);
    fprintf(stderr, "ibox-watchdog %.24s: %s\n", ctime(&t), msg);
}

static pid_t findApp(void) {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t size = 0;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) < 0) return -1;
    struct kinfo_proc *procs = malloc(size);
    if (!procs || sysctl(mib, 4, procs, &size, NULL, 0) < 0) { free(procs); return -1; }
    pid_t pid = -1;
    for (size_t i = 0; i < size / sizeof *procs; i++) {
        if (strcmp(procs[i].kp_proc.p_comm, APP_PROCESS) == 0) { pid = procs[i].kp_proc.p_pid; break; }
    }
    free(procs);
    return pid;
}

static void restartApp(const char *why) {
    pthread_mutex_lock(&restartLock);
    logLine(why);
    pid_t pid = findApp();
    if (pid > 0) {
        kill(pid, SIGKILL);
        for (int i = 0; i < 30 && findApp() > 0; i++) usleep(100000);
    }
    sleep(1);
    launch(CFSTR(APP_ID), false);
    pthread_mutex_unlock(&restartLock);
}

// Locked phone: iBox is suspended (so it doesn't answer) and SpringBoard refuses to
// launch apps. Restarting it then would kill it with no way back until unlock.
static int phoneLocked(void) {
    static int token = -1;
    if (token < 0 && notify_register_check("com.apple.springboard.lockstate", &token) != NOTIFY_STATUS_OK) return 0;
    uint64_t state = 0;
    notify_get_state(token, &state);
    return state != 0;
}

static int appIsFrontmost(void) {
    CFStringRef front = frontmost ? frontmost() : NULL;
    if (!front) return 0;
    int yes = CFStringCompare(front, CFSTR(APP_ID), 0) == kCFCompareEqualTo;
    CFRelease(front);
    return yes;
}

// Asks iBox for /api/ping, which is answered on its main thread: no answer within
// 10 s means the app is frozen, not just busy with the network.
static int appAnswers(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return 1;  // can't test: assume fine
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
    struct timeval tv = {10, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_len = sizeof a;
    a.sin_family = AF_INET;
    a.sin_port = htons(APP_PORT);
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    int ok = 0;
    if (connect(fd, (struct sockaddr *)&a, sizeof a) == 0) {
        const char *req = "GET /api/ping HTTP/1.0\r\n\r\n";
        char buf[64];
        if (write(fd, req, strlen(req)) > 0 && read(fd, buf, sizeof buf) > 0 && strncmp(buf, "HTTP/1.1 200", 12) == 0) ok = 1;
    }
    close(fd);
    return ok;
}

static const char *kPage =
    "<!doctype html><html><head><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'>"
    "<title>iBox watchdog</title><style>body{margin:0;background:#0b0f1a;color:#eef1f8;font:16px -apple-system,Segoe UI,Roboto,Arial,sans-serif;"
    "display:flex;min-height:100vh;align-items:center;justify-content:center}main{max-width:340px;padding:24px;text-align:center}"
    "button{font:inherit;font-weight:600;color:#fff;background:#e5484d;border:0;border-radius:12px;padding:14px 22px;width:100%}"
    "p{color:#8c95ad}a{color:#00a4dc}</style></head><body><main><h1>iBox</h1>"
    "<p>If iBox is frozen or the remote stopped answering, restart it here. It takes about 10 seconds.</p>"
    "<button onclick=\"this.disabled=true;this.textContent='Restarting\\u2026';fetch('/restart',{method:'POST'})"
    ".then(function(){setTimeout(function(){location.href='http://'+location.hostname+':8080/'},12000)})\">Restart iBox</button>"
    "<p><a href=/ onclick=\"location.href='http://'+location.hostname+':8080/';return false\">Back to the remote</a></p>"
    "</main></body></html>";

static void reply(int fd, const char *status, const char *type, const char *body) {
    char head[256];
    int n = snprintf(head, sizeof head, "HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %zu\r\n"
                     "Access-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n", status, type, strlen(body));
    write(fd, head, (size_t)n);
    write(fd, body, strlen(body));
}

static void *serve(void *arg) {
    (void)arg;
    for (;;) {
        int lfd = socket(AF_INET, SOCK_STREAM, 0);
        int on = 1;
        setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof on);
        struct sockaddr_in a;
        memset(&a, 0, sizeof a);
        a.sin_len = sizeof a;
        a.sin_family = AF_INET;
        a.sin_port = htons(WATCHDOG_PORT);
        a.sin_addr.s_addr = htonl(INADDR_ANY);
        if (lfd < 0 || bind(lfd, (struct sockaddr *)&a, sizeof a) < 0 || listen(lfd, 8) < 0) {
            if (lfd >= 0) close(lfd);
            sleep(5);
            continue;
        }
        for (;;) {
            int fd = accept(lfd, NULL, NULL);
            if (fd < 0) { if (errno == EINTR) continue; break; }
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
            struct timeval tv = {5, 0};
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
            char req[2048] = {0};
            ssize_t n = read(fd, req, sizeof req - 1);
            if (n <= 0) { close(fd); continue; }
            if (strncmp(req, "OPTIONS ", 8) == 0) {
                reply(fd, "204 No Content", "text/plain",  "");
            } else if (strstr(req, " /restart") && (strncmp(req, "POST ", 5) == 0 || strncmp(req, "GET ", 4) == 0)) {
                reply(fd, "200 OK", "application/json", "{\"ok\":true}");
                close(fd);
                restartApp("restart requested from the remote");
                continue;
            } else if (strncmp(req, "GET / ", 6) == 0 || strncmp(req, "GET /index", 10) == 0) {
                reply(fd, "200 OK", "text/html; charset=utf-8", kPage);
            } else {
                reply(fd, "404 Not Found", "text/plain", "not found");
            }
            close(fd);
        }
        close(lfd);
    }
    return NULL;
}

int main(int argc, char **argv) {
    signal(SIGPIPE, SIG_IGN);
    void *sbs = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
    if (!sbs) {
        fprintf(stderr, "ibox-launch: SpringBoardServices not available\n");
        return 1;
    }
    launch = (LaunchFn)dlsym(sbs, "SBSLaunchApplicationWithIdentifier");
    frontmost = (FrontmostFn)dlsym(sbs, "SBSCopyFrontmostApplicationDisplayIdentifier");
    if (!launch) {
        fprintf(stderr, "ibox-launch: SBSLaunchApplicationWithIdentifier missing\n");
        return 1;
    }
    int watch = argc > 1 && strcmp(argv[1], "--watch") == 0;

    if (!watch) {
        if (argc > 1 && strcmp(argv[1], "--status") == 0) {
            CFStringRef front = frontmost ? frontmost() : NULL;
            char name[128] = "home screen";
            if (front) { CFStringGetCString(front, name, sizeof name, kCFStringEncodingUTF8); CFRelease(front); }
            printf("locked=%d frontmost=%s ibox_pid=%d\n", phoneLocked(), name, (int)findApp());
            return 0;
        }
        if (argc > 1 && strcmp(argv[1], "--restart") == 0) {
            restartApp("restart requested from the command line");
            return 0;
        }
        // Optional bundle id (e.g. com.apple.Preferences), handy for testing iBox in the background.
        CFStringRef target = argc > 1 ? CFStringCreateWithCString(NULL, argv[1], kCFStringEncodingUTF8) : CFSTR(APP_ID);
        int rc = launch(target, false);
        if (rc != 0) fprintf(stderr, "ibox-launch: SpringBoard returned %d\n", rc);
        return rc == 0 ? 0 : 1;
    }

    pthread_t server;
    pthread_create(&server, NULL, serve, NULL);

    sleep(25);  // let SpringBoard finish booting
    int failures = 0;
    for (;;) {
        CFStringRef front = frontmost ? frontmost() : NULL;
        if (front == NULL) {
            failures = 0;
            launch(CFSTR(APP_ID), false);  // home screen (or nothing) in front: bring iBox back
        } else {
            CFRelease(front);  // another app the user opened on purpose is left alone
            if (phoneLocked()) {
                failures = 0;
            } else if (appIsFrontmost()) {
                failures = appAnswers() ? 0 : failures + 1;
                if (failures >= FAILURES_BEFORE_RESTART) {
                    failures = 0;
                    restartApp("iBox stopped answering, restarting it");
                }
            } else {
                failures = 0;
            }
        }
        sleep(CHECK_SECONDS);
    }
}

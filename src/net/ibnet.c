#include "ibnet.h"
#include "bearssl.h"

#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

struct ib_conn {
    int fd;
    int tls;  // 0 plain, 1 client, 2 server
    br_ssl_client_context *cc;
    br_x509_minimal_context *xc;
    br_ssl_server_context *sc;
    br_sslio_context ioc;
    unsigned char *iobuf;
};

static br_x509_trust_anchor *g_anchors;
static size_t g_anchor_count;
static br_x509_certificate g_server_chain[1];
static br_rsa_private_key g_server_key;
static int g_server_ready;

/* ---------- helpers ---------- */

typedef struct {
    unsigned char *buf;
    size_t len, cap;
} bvec;

static void bvec_append(void *ctx, const void *data, size_t len) {
    bvec *v = ctx;
    if (v->len + len > v->cap) {
        size_t cap = v->cap ? v->cap * 2 : 1024;
        while (cap < v->len + len) cap *= 2;
        v->buf = realloc(v->buf, cap);
        v->cap = cap;
    }
    memcpy(v->buf + v->len, data, len);
    v->len += len;
}

static void discard(void *ctx, const void *data, size_t len) {
    (void)ctx; (void)data; (void)len;
}

static unsigned char *memdup(const void *src, size_t len) {
    unsigned char *p = malloc(len ? len : 1);
    memcpy(p, src, len);
    return p;
}

static void set_sock_opts(int fd, int timeout_sec) {
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, sizeof on);
    struct timeval tv = { timeout_sec, 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
}

static int sock_read(void *ctx, unsigned char *buf, size_t len) {
    int fd = *(int *)ctx;
    for (;;) {
        ssize_t r = read(fd, buf, len);
        if (r < 0 && errno == EINTR) continue;
        return r <= 0 ? -1 : (int)r;
    }
}

static int sock_write(void *ctx, const unsigned char *buf, size_t len) {
    int fd = *(int *)ctx;
    for (;;) {
        ssize_t w = write(fd, buf, len);
        if (w < 0 && errno == EINTR) continue;
        return w <= 0 ? -1 : (int)w;
    }
}

/* ---------- trust anchors ---------- */

static int der_to_anchor(const unsigned char *der, size_t len, br_x509_trust_anchor *ta) {
    br_x509_decoder_context dc;
    bvec dn = { 0 };
    br_x509_decoder_init(&dc, bvec_append, &dn);
    br_x509_decoder_push(&dc, der, len);
    br_x509_pkey *pk = br_x509_decoder_get_pkey(&dc);
    if (pk == NULL || br_x509_decoder_last_error(&dc) != 0) {
        free(dn.buf);
        return 0;
    }
    memset(ta, 0, sizeof *ta);
    ta->dn.data = dn.buf;
    ta->dn.len = dn.len;
    ta->flags = br_x509_decoder_isCA(&dc) ? BR_X509_TA_CA : 0;
    if (pk->key_type == BR_KEYTYPE_RSA) {
        ta->pkey.key_type = BR_KEYTYPE_RSA;
        ta->pkey.key.rsa.n = memdup(pk->key.rsa.n, pk->key.rsa.nlen);
        ta->pkey.key.rsa.nlen = pk->key.rsa.nlen;
        ta->pkey.key.rsa.e = memdup(pk->key.rsa.e, pk->key.rsa.elen);
        ta->pkey.key.rsa.elen = pk->key.rsa.elen;
    } else if (pk->key_type == BR_KEYTYPE_EC) {
        ta->pkey.key_type = BR_KEYTYPE_EC;
        ta->pkey.key.ec.curve = pk->key.ec.curve;
        ta->pkey.key.ec.q = memdup(pk->key.ec.q, pk->key.ec.qlen);
        ta->pkey.key.ec.qlen = pk->key.ec.qlen;
    } else {
        free(dn.buf);
        return 0;
    }
    return 1;
}

int ib_tls_load_anchors(const char *pem, size_t len) {
    br_pem_decoder_context pc;
    br_pem_decoder_init(&pc);
    bvec der = { 0 };
    int in_cert = 0;
    size_t cap = 0, count = 0;
    br_x509_trust_anchor *list = NULL;
    const unsigned char *p = (const unsigned char *)pem;

    while (len > 0) {
        size_t n = br_pem_decoder_push(&pc, p, len);
        p += n;
        len -= n;
        switch (br_pem_decoder_event(&pc)) {
        case BR_PEM_BEGIN_OBJ:
            in_cert = strcmp(br_pem_decoder_name(&pc), "CERTIFICATE") == 0 ||
                      strcmp(br_pem_decoder_name(&pc), "X509 CERTIFICATE") == 0;
            der.len = 0;
            br_pem_decoder_setdest(&pc, in_cert ? bvec_append : discard, &der);
            break;
        case BR_PEM_END_OBJ:
            if (in_cert) {
                if (count == cap) {
                    cap = cap ? cap * 2 : 64;
                    list = realloc(list, cap * sizeof *list);
                }
                if (der_to_anchor(der.buf, der.len, &list[count])) count++;
            }
            in_cert = 0;
            break;
        case BR_PEM_ERROR:
            free(der.buf);
            free(list);
            return -1;
        }
    }
    free(der.buf);
    g_anchors = list;
    g_anchor_count = count;
    return (int)count;
}

int ib_tls_load_server_identity(const unsigned char *cert_der, size_t cert_len,
                                const unsigned char *key_der, size_t key_len) {
    br_skey_decoder_context kd;
    br_skey_decoder_init(&kd);
    br_skey_decoder_push(&kd, key_der, key_len);
    if (br_skey_decoder_last_error(&kd) != 0 || br_skey_decoder_key_type(&kd) != BR_KEYTYPE_RSA)
        return -1;
    const br_rsa_private_key *sk = br_skey_decoder_get_rsa(&kd);
    g_server_key.n_bitlen = sk->n_bitlen;
    g_server_key.p = memdup(sk->p, sk->plen);   g_server_key.plen = sk->plen;
    g_server_key.q = memdup(sk->q, sk->qlen);   g_server_key.qlen = sk->qlen;
    g_server_key.dp = memdup(sk->dp, sk->dplen); g_server_key.dplen = sk->dplen;
    g_server_key.dq = memdup(sk->dq, sk->dqlen); g_server_key.dqlen = sk->dqlen;
    g_server_key.iq = memdup(sk->iq, sk->iqlen); g_server_key.iqlen = sk->iqlen;
    g_server_chain[0].data = memdup(cert_der, cert_len);
    g_server_chain[0].data_len = cert_len;
    g_server_ready = 1;
    return 0;
}

/* ---------- connections ---------- */

static int connect_with_timeout(int fd, const struct sockaddr *addr, socklen_t alen, int timeout_sec) {
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    int rc = connect(fd, addr, alen);
    if (rc < 0 && errno == EINPROGRESS) {
        struct pollfd pfd = { fd, POLLOUT, 0 };
        rc = poll(&pfd, 1, timeout_sec * 1000);
        if (rc == 1) {
            int soerr = 0;
            socklen_t sl = sizeof soerr;
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &sl);
            rc = soerr ? -1 : 0;
            if (soerr) errno = soerr;
        } else {
            if (rc == 0) errno = ETIMEDOUT;
            rc = -1;
        }
    }
    fcntl(fd, F_SETFL, flags);
    return rc;
}

static ib_conn *conn_new(int fd) {
    ib_conn *c = calloc(1, sizeof *c);
    c->fd = fd;
    return c;
}

ib_conn *ib_connect(const char *host, int port, int use_tls, int timeout_sec,
                    char *err, size_t errlen) {
    struct addrinfo hints, *res = NULL, *ai;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_INET;  // the iPhone's LAN/WAN is IPv4; avoids slow v6 fallbacks
    hints.ai_socktype = SOCK_STREAM;
    char portstr[8];
    snprintf(portstr, sizeof portstr, "%d", port);
    int rc = getaddrinfo(host, portstr, &hints, &res);
    if (rc != 0) {
        hints.ai_family = AF_UNSPEC;
        rc = getaddrinfo(host, portstr, &hints, &res);
    }
    if (rc != 0) {
        snprintf(err, errlen, "DNS lookup failed for %s (%s)", host, gai_strerror(rc));
        return NULL;
    }
    int fd = -1;
    for (ai = res; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) continue;
        set_sock_opts(fd, timeout_sec);
        if (connect_with_timeout(fd, ai->ai_addr, ai->ai_addrlen, timeout_sec) == 0) break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    if (fd < 0) {
        snprintf(err, errlen, "Cannot connect to %s:%d (%s)", host, port, strerror(errno));
        return NULL;
    }

    ib_conn *c = conn_new(fd);
    if (!use_tls) return c;

    if (g_anchor_count == 0) {
        snprintf(err, errlen, "TLS trust store not loaded");
        ib_close(c);
        return NULL;
    }
    c->tls = 1;
    c->cc = calloc(1, sizeof *c->cc);
    c->xc = calloc(1, sizeof *c->xc);
    c->iobuf = malloc(BR_SSL_BUFSIZE_BIDI);
    br_ssl_client_init_full(c->cc, c->xc, g_anchors, g_anchor_count);
    br_ssl_engine_set_buffer(&c->cc->eng, c->iobuf, BR_SSL_BUFSIZE_BIDI, 1);
    if (!br_ssl_client_reset(c->cc, host, 0)) {
        snprintf(err, errlen, "TLS init failed (%d)", br_ssl_engine_last_error(&c->cc->eng));
        ib_close(c);
        return NULL;
    }
    br_sslio_init(&c->ioc, &c->cc->eng, sock_read, &c->fd, sock_write, &c->fd);
    if (br_sslio_flush(&c->ioc) < 0 || br_ssl_engine_last_error(&c->cc->eng) != 0) {
        snprintf(err, errlen, "TLS handshake with %s failed (BearSSL error %d)", host,
                 br_ssl_engine_last_error(&c->cc->eng));
        ib_close(c);
        return NULL;
    }
    return c;
}

ib_conn *ib_wrap_accepted(int fd, int use_tls) {
    set_sock_opts(fd, 30);
    ib_conn *c = conn_new(fd);
    if (!use_tls) return c;
    if (!g_server_ready) {
        ib_close(c);
        return NULL;
    }
    c->tls = 2;
    c->sc = calloc(1, sizeof *c->sc);
    c->iobuf = malloc(BR_SSL_BUFSIZE_BIDI);
    br_ssl_server_init_full_rsa(c->sc, g_server_chain, 1, &g_server_key);
    br_ssl_engine_set_buffer(&c->sc->eng, c->iobuf, BR_SSL_BUFSIZE_BIDI, 1);
    if (!br_ssl_server_reset(c->sc)) {
        ib_close(c);
        return NULL;
    }
    br_sslio_init(&c->ioc, &c->sc->eng, sock_read, &c->fd, sock_write, &c->fd);
    return c;
}

static br_ssl_engine_context *engine(ib_conn *c) {
    if (c->tls == 1) return &c->cc->eng;
    if (c->tls == 2) return &c->sc->eng;
    return NULL;
}

int ib_write_all(ib_conn *c, const void *buf, size_t len) {
    if (!c->tls) {
        const unsigned char *p = buf;
        while (len > 0) {
            int w = sock_write(&c->fd, p, len);
            if (w < 0) return -1;
            p += w;
            len -= (size_t)w;
        }
        return 0;
    }
    return br_sslio_write_all(&c->ioc, buf, len) < 0 ? -1 : 0;
}

int ib_flush(ib_conn *c) {
    if (!c->tls) return 0;
    return br_sslio_flush(&c->ioc) < 0 ? -1 : 0;
}

long ib_read(ib_conn *c, void *buf, size_t len) {
    if (!c->tls) {
        for (;;) {
            ssize_t r = read(c->fd, buf, len);
            if (r < 0 && errno == EINTR) continue;
            return r < 0 ? -1 : (long)r;
        }
    }
    int r = br_sslio_read(&c->ioc, buf, len);
    if (r > 0) return r;
    // A clean close_notify leaves no error; many servers just drop the socket.
    int e = br_ssl_engine_last_error(engine(c));
    return (e == BR_ERR_OK || e == BR_ERR_IO) ? 0 : -1;
}

void ib_set_timeout(ib_conn *c, int seconds) {
    struct timeval tv = { seconds, 0 };
    setsockopt(c->fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    setsockopt(c->fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
}

int ib_tls_error(ib_conn *c) {
    br_ssl_engine_context *e = engine(c);
    return e ? br_ssl_engine_last_error(e) : 0;
}

void ib_close(ib_conn *c) {
    if (!c) return;
    // No close_notify round-trip: br_sslio_close() can block on a dead peer.
    if (c->fd >= 0) close(c->fd);
    free(c->cc);
    free(c->xc);
    free(c->sc);
    free(c->iobuf);
    free(c);
}

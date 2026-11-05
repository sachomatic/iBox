// Low-level TCP + TLS connections for iBox.
// iOS 6's SecureTransport can't negotiate with many modern servers (no AES-GCM /
// ChaCha20, outdated roots), so every HTTPS connection goes through BearSSL with
// a CA bundle shipped in the app.
#ifndef IBNET_H
#define IBNET_H

#include <stddef.h>

typedef struct ib_conn ib_conn;

// Loads PEM certificates as trust anchors. Returns the number loaded, or -1.
int ib_tls_load_anchors(const char *pem, size_t len);

// Loads the RSA identity used by the HTTPS side of the built-in server.
int ib_tls_load_server_identity(const unsigned char *cert_der, size_t cert_len,
                                const unsigned char *key_der, size_t key_len);

// Opens a client connection. use_tls verifies the server against the anchors.
ib_conn *ib_connect(const char *host, int port, int use_tls, int timeout_sec,
                    char *err, size_t errlen);

// Wraps a socket returned by accept(). use_tls performs a server handshake.
ib_conn *ib_wrap_accepted(int fd, int use_tls);

int ib_write_all(ib_conn *c, const void *buf, size_t len);  // 0 ok, -1 error
int ib_flush(ib_conn *c);                                    // 0 ok, -1 error
long ib_read(ib_conn *c, void *buf, size_t len);             // >0 bytes, 0 EOF, -1 error
void ib_set_timeout(ib_conn *c, int seconds);
int ib_tls_error(ib_conn *c);  // BearSSL error code of the last failure (0 = none)
void ib_close(ib_conn *c);

#endif

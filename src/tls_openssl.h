#include <openssl/ssl.h>
#include <openssl/err.h>

/* Let Clang evaluate OpenSSL's uint64_t shift macros: Zig 0.16's macro
 * translator gives their shift operand a u64 instead of a u6. */
enum {
    zhtps_ssl_options = SSL_OP_NO_COMPRESSION | SSL_OP_NO_RENEGOTIATION,
};

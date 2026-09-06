// Board side of common/auth.zig: PSK in NVS, mutual HMAC handshake on the HCI
// socket, signed discovery announces, HTTP request auth, and X25519 claim.
#include "glue.h"

#include <string.h>

#include "esp_err.h"
#include "esp_log.h"
#include "esp_random.h"
#include "lwip/sockets.h"
#include "mbedtls/ecdh.h"
#include "mbedtls/ecp.h"
#include "mbedtls/md.h"
#include "mbedtls/sha256.h"
#include "nvs.h"

static const char *TAG = "auth";

#define PSK_LEN 32
#define NONCE_LEN 32
#define MAC_LEN 32
static const char DOM_CLIENT[] = "esp-hci-client";
static const char DOM_BOARD[] = "esp-hci-board";

static uint8_t g_psk[PSK_LEN];
static bool g_claimed = false;

static int rng(void *ctx, unsigned char *out, size_t len)
{
    (void)ctx;
    esp_fill_random(out, len);
    return 0;
}

bool auth_ct_equal(const uint8_t *a, const uint8_t *b, size_t n)
{
    uint8_t d = 0;
    for (size_t i = 0; i < n; i++) d |= a[i] ^ b[i];
    return d == 0;
}

// HMAC-SHA256 over several parts.
static bool hmac_parts(const uint8_t *key, size_t klen, const uint8_t *const *parts, const size_t *lens, int n, uint8_t out[MAC_LEN])
{
    const mbedtls_md_info_t *info = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
    mbedtls_md_context_t ctx;
    mbedtls_md_init(&ctx);
    bool ok = mbedtls_md_setup(&ctx, info, 1) == 0 && mbedtls_md_hmac_starts(&ctx, key, klen) == 0;
    for (int i = 0; ok && i < n; i++) ok = mbedtls_md_hmac_update(&ctx, parts[i], lens[i]) == 0;
    ok = ok && mbedtls_md_hmac_finish(&ctx, out) == 0;
    mbedtls_md_free(&ctx);
    return ok;
}

bool auth_init(void)
{
    nvs_handle_t h;
    if (nvs_open("bridge", NVS_READONLY, &h) == ESP_OK) {
        size_t len = PSK_LEN;
        if (nvs_get_blob(h, "psk", g_psk, &len) == ESP_OK && len == PSK_LEN) g_claimed = true;
        nvs_close(h);
    }
    if (g_claimed) ESP_LOGI(TAG, "board is claimed");
    else ESP_LOGW(TAG, "board is UNCLAIMED: run `hcibridge claim <ip>`");
    return g_claimed;
}

bool auth_claimed(void)
{
    return g_claimed;
}

static void hexlify(const uint8_t *in, size_t n, char *out)
{
    static const char hx[] = "0123456789abcdef";
    for (size_t i = 0; i < n; i++) {
        out[2 * i] = hx[in[i] >> 4];
        out[2 * i + 1] = hx[in[i] & 15];
    }
    out[2 * n] = '\0';
}

static int unhex(const char *s, size_t n, uint8_t *out)
{
    for (size_t i = 0; i < n; i++) {
        int hi = s[2 * i], lo = s[2 * i + 1];
        int h = hi >= '0' && hi <= '9' ? hi - '0' : (hi | 0x20) >= 'a' && (hi | 0x20) <= 'f' ? (hi | 0x20) - 'a' + 10 : -1;
        int l = lo >= '0' && lo <= '9' ? lo - '0' : (lo | 0x20) >= 'a' && (lo | 0x20) <= 'f' ? (lo | 0x20) - 'a' + 10 : -1;
        if (h < 0 || l < 0) return -1;
        out[i] = (uint8_t)(h * 16 + l);
    }
    return 0;
}

// --- HCI socket handshake ---------------------------------------------------

static bool recv_exact(int fd, uint8_t *buf, size_t n)
{
    size_t got = 0;
    while (got < n) {
        int r = recv(fd, buf + got, n - got, 0);
        if (r <= 0) return false;
        got += (size_t)r;
    }
    return true;
}

bool auth_handshake(int fd)
{
    if (!g_claimed) {
        ESP_LOGW(TAG, "refusing HCI connection: board unclaimed");
        return false;
    }
    struct timeval tv = { .tv_sec = 3, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    uint8_t sn[NONCE_LEN];
    esp_fill_random(sn, sizeof(sn));
    if (send(fd, sn, sizeof(sn), 0) != (int)sizeof(sn)) return false;

    uint8_t msg[NONCE_LEN + MAC_LEN];
    if (!recv_exact(fd, msg, sizeof(msg))) return false;
    const uint8_t *cn = msg;
    const uint8_t *cmac = msg + NONCE_LEN;

    uint8_t expect[MAC_LEN];
    const uint8_t *p1[] = { sn, cn, (const uint8_t *)DOM_CLIENT };
    const size_t l1[] = { NONCE_LEN, NONCE_LEN, sizeof(DOM_CLIENT) - 1 };
    if (!hmac_parts(g_psk, PSK_LEN, p1, l1, 3, expect)) return false;
    if (!auth_ct_equal(cmac, expect, MAC_LEN)) {
        ESP_LOGW(TAG, "handshake failed: bad client proof");
        return false;
    }

    uint8_t bmac[MAC_LEN];
    const uint8_t *p2[] = { cn, sn, (const uint8_t *)DOM_BOARD };
    const size_t l2[] = { NONCE_LEN, NONCE_LEN, sizeof(DOM_BOARD) - 1 };
    if (!hmac_parts(g_psk, PSK_LEN, p2, l2, 3, bmac)) return false;
    if (send(fd, bmac, sizeof(bmac), 0) != (int)sizeof(bmac)) return false;

    // Back to blocking for the HCI pump.
    tv.tv_sec = 0;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    return true;
}

// --- discovery announce signature -------------------------------------------

// hex of first 16 bytes of HMAC(psk, "bdaddr\tport\tname"), or "-" if unclaimed.
size_t auth_announce_sig(const char *bdaddr, unsigned port, const char *name, char *out, size_t outlen)
{
    if (!g_claimed || outlen < 33) {
        if (outlen >= 2) { out[0] = '-'; out[1] = '\0'; }
        return 1;
    }
    char ps[8];
    int pn = snprintf(ps, sizeof(ps), "%u", port);
    uint8_t mac[MAC_LEN];
    const uint8_t *p[] = { (const uint8_t *)bdaddr, (const uint8_t *)"\t", (const uint8_t *)ps, (const uint8_t *)"\t", (const uint8_t *)name };
    const size_t l[] = { strlen(bdaddr), 1, (size_t)pn, 1, strlen(name) };
    if (!hmac_parts(g_psk, PSK_LEN, p, l, 5, mac)) { out[0] = '-'; out[1] = '\0'; return 1; }
    hexlify(mac, 16, out);
    return 32;
}

// --- HTTP request auth --------------------------------------------------------

// header_hex must equal hex(HMAC(psk, "<METHOD> <path>\n" || body_sha256)).
bool auth_check_http(const char *method, const char *path, const uint8_t body_sha[32], const char *header_hex)
{
    if (!g_claimed || !header_hex || strlen(header_hex) != 64) return false;
    uint8_t given[MAC_LEN];
    if (unhex(header_hex, MAC_LEN, given) != 0) return false;
    uint8_t mac[MAC_LEN];
    const uint8_t *p[] = { (const uint8_t *)method, (const uint8_t *)" ", (const uint8_t *)path, (const uint8_t *)"\n", body_sha };
    const size_t l[] = { strlen(method), 1, strlen(path), 1, 32 };
    if (!hmac_parts(g_psk, PSK_LEN, p, l, 5, mac)) return false;
    return auth_ct_equal(given, mac, MAC_LEN);
}

// --- claim: X25519, psk = SHA256(shared) --------------------------------------

int auth_claim(const uint8_t peer_pub[32], uint8_t our_pub[32])
{
    if (g_claimed) return -1;

    mbedtls_ecp_group grp;
    mbedtls_mpi d, z;
    mbedtls_ecp_point Q, Qp;
    mbedtls_ecp_group_init(&grp);
    mbedtls_mpi_init(&d);
    mbedtls_mpi_init(&z);
    mbedtls_ecp_point_init(&Q);
    mbedtls_ecp_point_init(&Qp);

    esp_err_t err = ESP_FAIL;
    uint8_t shared[32];
    do {
        if (mbedtls_ecp_group_load(&grp, MBEDTLS_ECP_DP_CURVE25519) != 0) break;
        if (mbedtls_ecdh_gen_public(&grp, &d, &Q, rng, NULL) != 0) break;
        if (mbedtls_mpi_write_binary_le(&Q.MBEDTLS_PRIVATE(X), our_pub, 32) != 0) break;
        // Peer point: X from the wire (little-endian u-coordinate), Z = 1.
        if (mbedtls_mpi_read_binary_le(&Qp.MBEDTLS_PRIVATE(X), peer_pub, 32) != 0) break;
        if (mbedtls_mpi_lset(&Qp.MBEDTLS_PRIVATE(Z), 1) != 0) break;
        if (mbedtls_ecdh_compute_shared(&grp, &z, &Qp, &d, rng, NULL) != 0) break;
        if (mbedtls_mpi_write_binary_le(&z, shared, 32) != 0) break;
        if (mbedtls_sha256(shared, 32, g_psk, 0) != 0) break;
        err = ESP_OK;
    } while (0);

    mbedtls_ecp_point_free(&Qp);
    mbedtls_ecp_point_free(&Q);
    mbedtls_mpi_free(&z);
    mbedtls_mpi_free(&d);
    mbedtls_ecp_group_free(&grp);
    memset(shared, 0, sizeof(shared));
    if (err != ESP_OK) return err;

    nvs_handle_t h;
    if (nvs_open("bridge", NVS_READWRITE, &h) != ESP_OK) return ESP_FAIL;
    err = nvs_set_blob(h, "psk", g_psk, PSK_LEN);
    if (err == ESP_OK) err = nvs_commit(h);
    nvs_close(h);
    if (err != ESP_OK) return err;
    g_claimed = true;
    ESP_LOGI(TAG, "board claimed, key stored");
    return ESP_OK;
}

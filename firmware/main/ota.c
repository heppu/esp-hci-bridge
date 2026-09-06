#include "glue.h"

#include <string.h>

#include "esp_app_desc.h"
#include "esp_http_server.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_ota_ops.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "mbedtls/sha256.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "ota";

#define OTA_MAX_RECV_TIMEOUTS 6
#define ROLLBACK_GRACE_US (5 * 60 * 1000000LL)

static esp_timer_handle_t g_rollback_timer;

static esp_err_t status_get(httpd_req_t *req)
{
    const esp_app_desc_t *app = esp_app_get_description();
    const esp_partition_t *running = esp_ota_get_running_partition();
    uint8_t mac[6] = {0};
    esp_read_mac(mac, ESP_MAC_BT);

    char stats[256];
    bridge_stats_json(stats, sizeof(stats));
    char nonce[41];
    auth_nonce_hex(nonce, sizeof(nonce));

    char body[576];
    int n = snprintf(body, sizeof(body),
                     "{\"version\":\"%s\",\"idf\":\"%s\",\"partition\":\"%s\","
                     "\"bdaddr\":\"%02x:%02x:%02x:%02x:%02x:%02x\",\"claimed\":%s,\"nonce\":\"%s\",\"uptime_s\":%lld,"
                     "\"free_heap\":%lu,\"stats\":%s}\n",
                     app->version, app->idf_ver, running ? running->label : "?",
                     mac[0], mac[1], mac[2], mac[3], mac[4], mac[5],
                     auth_claimed() ? "true" : "false", nonce,
                     (long long)(esp_timer_get_time() / 1000000),
                     (unsigned long)esp_get_free_heap_size(), stats);
    httpd_resp_set_type(req, "application/json");
    return httpd_resp_send(req, body, n);
}

static bool get_header(httpd_req_t *req, const char *name, char *out, size_t outlen)
{
    size_t n = httpd_req_get_hdr_value_len(req, name);
    if (n == 0 || n + 1 > outlen) return false;
    return httpd_req_get_hdr_value_str(req, name, out, outlen) == ESP_OK;
}

// Both proofs are bound to the nonce published by GET /, so each is only
// good for one accepted request.
static bool get_proofs(httpd_req_t *req, char *auth, char *pre, size_t len)
{
    return auth_claimed() && get_header(req, "X-Bridge-Auth", auth, len) && get_header(req, "X-Bridge-Pre", pre, len);
}

static esp_err_t ota_post(httpd_req_t *req)
{
    char auth[80], pre[80];
    if (!get_proofs(req, auth, pre, sizeof(auth))) {
        httpd_resp_send_err(req, HTTPD_401_UNAUTHORIZED, "X-Bridge-Auth and X-Bridge-Pre required (claim the board first)");
        return ESP_FAIL;
    }
    const esp_partition_t *part = esp_ota_get_next_update_partition(NULL);
    if (!part) {
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "no ota partition");
        return ESP_FAIL;
    }
    if (req->content_len > part->size) {
        httpd_resp_send_err(req, HTTPD_413_CONTENT_TOO_LARGE, "image larger than the ota partition");
        return ESP_FAIL;
    }
    if (!auth_check_http_pre("POST", "/ota", (uint32_t)req->content_len, pre)) {
        ESP_LOGW(TAG, "rejected OTA: bad pre-upload proof");
        httpd_resp_send_err(req, HTTPD_403_FORBIDDEN, "bad X-Bridge-Pre");
        return ESP_FAIL;
    }
    ESP_LOGI(TAG, "update of %d bytes into %s", req->content_len, part->label);

    esp_ota_handle_t handle;
    esp_err_t err = esp_ota_begin(part, OTA_WITH_SEQUENTIAL_WRITES, &handle);
    if (err != ESP_OK) {
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, esp_err_to_name(err));
        return ESP_FAIL;
    }

    mbedtls_sha256_context sha;
    mbedtls_sha256_init(&sha);
    mbedtls_sha256_starts(&sha, 0);
    char buf[1024];
    int remaining = req->content_len;
    int timeouts = 0;
    while (remaining > 0) {
        int n = httpd_req_recv(req, buf, remaining < (int)sizeof(buf) ? remaining : (int)sizeof(buf));
        if (n == HTTPD_SOCK_ERR_TIMEOUT) {
            if (++timeouts < OTA_MAX_RECV_TIMEOUTS) continue;
            esp_ota_abort(handle);
            mbedtls_sha256_free(&sha);
            httpd_resp_send_err(req, HTTPD_408_REQ_TIMEOUT, "upload stalled");
            return ESP_FAIL;
        }
        if (n <= 0) {
            esp_ota_abort(handle);
            mbedtls_sha256_free(&sha);
            httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "upload interrupted");
            return ESP_FAIL;
        }
        timeouts = 0;
        mbedtls_sha256_update(&sha, (const unsigned char *)buf, n);
        err = esp_ota_write(handle, buf, n);
        if (err != ESP_OK) {
            esp_ota_abort(handle);
            mbedtls_sha256_free(&sha);
            httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, esp_err_to_name(err));
            return ESP_FAIL;
        }
        remaining -= n;
    }

    uint8_t digest[32];
    mbedtls_sha256_finish(&sha, digest);
    mbedtls_sha256_free(&sha);
    if (!auth_check_http("POST", "/ota", digest, auth)) {
        esp_ota_abort(handle);
        ESP_LOGW(TAG, "rejected OTA: bad auth");
        httpd_resp_send_err(req, HTTPD_403_FORBIDDEN, "bad X-Bridge-Auth");
        return ESP_FAIL;
    }

    err = esp_ota_end(handle);
    if (err != ESP_OK) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, esp_err_to_name(err));
        return ESP_FAIL;
    }
    err = esp_ota_set_boot_partition(part);
    if (err != ESP_OK) {
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, esp_err_to_name(err));
        return ESP_FAIL;
    }
    auth_nonce_bump();

    httpd_resp_sendstr(req, "ok, rebooting\n");
    ESP_LOGI(TAG, "update written, rebooting");
    vTaskDelay(pdMS_TO_TICKS(500));
    esp_restart();
    return ESP_OK;
}

static esp_err_t reboot_post(httpd_req_t *req)
{
    char auth[80], pre[80];
    uint8_t empty_sha[32];
    mbedtls_sha256((const unsigned char *)"", 0, empty_sha, 0);
    if (!get_proofs(req, auth, pre, sizeof(auth)) || !auth_check_http_pre("POST", "/reboot", 0, pre) ||
        !auth_check_http("POST", "/reboot", empty_sha, auth)) {
        httpd_resp_send_err(req, HTTPD_403_FORBIDDEN, "bad or missing X-Bridge-Auth / X-Bridge-Pre");
        return ESP_FAIL;
    }
    auth_nonce_bump();
    httpd_resp_sendstr(req, "rebooting\n");
    ESP_LOGI(TAG, "reboot requested");
    vTaskDelay(pdMS_TO_TICKS(300));
    esp_restart();
    return ESP_OK;
}

// POST /claim, body = 64 hex chars (client X25519 public key). Only while
// unclaimed. Replies with the board's public key; both sides derive the PSK.
static esp_err_t claim_post(httpd_req_t *req)
{
    if (auth_claimed()) {
        httpd_resp_send_err(req, HTTPD_403_FORBIDDEN, "already claimed; factory-reset to re-key");
        return ESP_FAIL;
    }
    char body[80];
    int n = httpd_req_recv(req, body, sizeof(body) - 1);
    if (n < 64) {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "expected 64 hex chars");
        return ESP_FAIL;
    }
    body[64] = '\0';
    uint8_t peer[32], ours[32];
    for (int i = 0; i < 32; i++) {
        unsigned v;
        if (sscanf(body + 2 * i, "%2x", &v) != 1) {
            httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "bad hex");
            return ESP_FAIL;
        }
        peer[i] = (uint8_t)v;
    }
    if (auth_claim(peer, ours) != 0) {
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "claim failed");
        return ESP_FAIL;
    }
    char out[66];
    static const char hx[] = "0123456789abcdef";
    for (int i = 0; i < 32; i++) { out[2 * i] = hx[ours[i] >> 4]; out[2 * i + 1] = hx[ours[i] & 15]; }
    out[64] = '\n'; out[65] = '\0';
    return httpd_resp_send(req, out, 65);
}

static bool pending_verify(void)
{
    esp_ota_img_states_t state;
    const esp_partition_t *running = esp_ota_get_running_partition();
    return esp_ota_get_state_partition(running, &state) == ESP_OK && state == ESP_OTA_IMG_PENDING_VERIFY;
}

// A fresh image that never gets an address would otherwise stay unconfirmed
// forever, the reboot lets the bootloader roll back.
static void rollback_timeout(void *arg)
{
    if (!pending_verify()) return;
    ESP_LOGE(TAG, "no ip within the grace period, rebooting to roll back");
    esp_restart();
}

void ota_init(void)
{
    if (pending_verify()) {
        const esp_timer_create_args_t args = { .callback = rollback_timeout, .name = "ota_rollback" };
        ESP_ERROR_CHECK(esp_timer_create(&args, &g_rollback_timer));
        ESP_ERROR_CHECK(esp_timer_start_once(g_rollback_timer, ROLLBACK_GRACE_US));
    }

    httpd_config_t config = HTTPD_DEFAULT_CONFIG();
    config.stack_size = 8192;
    config.lru_purge_enable = true;

    httpd_handle_t server = NULL;
    ESP_ERROR_CHECK(httpd_start(&server, &config));

    const httpd_uri_t status_uri = { .uri = "/", .method = HTTP_GET, .handler = status_get };
    const httpd_uri_t ota_uri = { .uri = "/ota", .method = HTTP_POST, .handler = ota_post };
    const httpd_uri_t reboot_uri = { .uri = "/reboot", .method = HTTP_POST, .handler = reboot_post };
    const httpd_uri_t claim_uri = { .uri = "/claim", .method = HTTP_POST, .handler = claim_post };
    ESP_ERROR_CHECK(httpd_register_uri_handler(server, &status_uri));
    ESP_ERROR_CHECK(httpd_register_uri_handler(server, &ota_uri));
    ESP_ERROR_CHECK(httpd_register_uri_handler(server, &reboot_uri));
    ESP_ERROR_CHECK(httpd_register_uri_handler(server, &claim_uri));
    ESP_LOGI(TAG, "http status on /, updates via POST /ota");
}

// A new image is only kept once it has come this far: network up with an
// address. Otherwise the bootloader rolls back on the next reset.
void ota_confirm(void)
{
    if (pending_verify()) {
        esp_ota_mark_app_valid_cancel_rollback();
        ESP_LOGI(TAG, "image confirmed");
    }
    if (g_rollback_timer) esp_timer_stop(g_rollback_timer);
}

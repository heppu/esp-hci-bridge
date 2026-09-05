#include "glue.h"

#include <string.h>

#include "esp_app_desc.h"
#include "esp_http_server.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_ota_ops.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

static const char *TAG = "ota";

static esp_err_t status_get(httpd_req_t *req)
{
    const esp_app_desc_t *app = esp_app_get_description();
    const esp_partition_t *running = esp_ota_get_running_partition();
    uint8_t mac[6] = {0};
    esp_read_mac(mac, ESP_MAC_BT);

    char stats[256];
    bridge_stats_json(stats, sizeof(stats));

    char body[512];
    int n = snprintf(body, sizeof(body),
                     "{\"version\":\"%s\",\"idf\":\"%s\",\"partition\":\"%s\","
                     "\"bdaddr\":\"%02x:%02x:%02x:%02x:%02x:%02x\",\"uptime_s\":%lld,"
                     "\"free_heap\":%lu,\"stats\":%s}\n",
                     app->version, app->idf_ver, running ? running->label : "?",
                     mac[0], mac[1], mac[2], mac[3], mac[4], mac[5],
                     (long long)(esp_timer_get_time() / 1000000),
                     (unsigned long)esp_get_free_heap_size(), stats);
    httpd_resp_set_type(req, "application/json");
    return httpd_resp_send(req, body, n);
}

static esp_err_t ota_post(httpd_req_t *req)
{
    const esp_partition_t *part = esp_ota_get_next_update_partition(NULL);
    if (!part) {
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, "no ota partition");
        return ESP_FAIL;
    }
    ESP_LOGI(TAG, "update of %d bytes into %s", req->content_len, part->label);

    esp_ota_handle_t handle;
    esp_err_t err = esp_ota_begin(part, OTA_WITH_SEQUENTIAL_WRITES, &handle);
    if (err != ESP_OK) {
        httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, esp_err_to_name(err));
        return ESP_FAIL;
    }

    char buf[1024];
    int remaining = req->content_len;
    while (remaining > 0) {
        int n = httpd_req_recv(req, buf, remaining < (int)sizeof(buf) ? remaining : (int)sizeof(buf));
        if (n == HTTPD_SOCK_ERR_TIMEOUT) {
            continue;
        }
        if (n <= 0) {
            esp_ota_abort(handle);
            httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "upload interrupted");
            return ESP_FAIL;
        }
        err = esp_ota_write(handle, buf, n);
        if (err != ESP_OK) {
            esp_ota_abort(handle);
            httpd_resp_send_err(req, HTTPD_500_INTERNAL_SERVER_ERROR, esp_err_to_name(err));
            return ESP_FAIL;
        }
        remaining -= n;
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

    httpd_resp_sendstr(req, "ok, rebooting\n");
    ESP_LOGI(TAG, "update written, rebooting");
    vTaskDelay(pdMS_TO_TICKS(500));
    esp_restart();
    return ESP_OK;
}

void ota_init(void)
{
    httpd_config_t config = HTTPD_DEFAULT_CONFIG();
    config.stack_size = 8192;
    config.lru_purge_enable = true;

    httpd_handle_t server = NULL;
    ESP_ERROR_CHECK(httpd_start(&server, &config));

    const httpd_uri_t status_uri = { .uri = "/", .method = HTTP_GET, .handler = status_get };
    const httpd_uri_t ota_uri = { .uri = "/ota", .method = HTTP_POST, .handler = ota_post };
    ESP_ERROR_CHECK(httpd_register_uri_handler(server, &status_uri));
    ESP_ERROR_CHECK(httpd_register_uri_handler(server, &ota_uri));
    ESP_LOGI(TAG, "http status on /, updates via POST /ota");
}

// A new image is only kept once it has come this far: network up with an
// address. Otherwise the bootloader rolls back on the next reset.
void ota_confirm(void)
{
    esp_ota_img_states_t state;
    const esp_partition_t *running = esp_ota_get_running_partition();
    if (esp_ota_get_state_partition(running, &state) == ESP_OK && state == ESP_OTA_IMG_PENDING_VERIFY) {
        esp_ota_mark_app_valid_cancel_rollback();
        ESP_LOGI(TAG, "image confirmed");
    }
}

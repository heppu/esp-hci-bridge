#include "glue.h"

#include <string.h>

#include "esp_eth.h"
#include "esp_eth_mac_esp.h"
#include "esp_event.h"
#include "esp_http_server.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_netif.h"
#include "esp_system.h"
#include "esp_wifi.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "nvs.h"
#include "nvs_flash.h"
#include "sdkconfig.h"

static const char *TAG = "net";

static void on_got_ip(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    const ip_event_got_ip_t *ev = data;
    ESP_LOGI(TAG, "ip " IPSTR " gw " IPSTR, IP2STR(&ev->ip_info.ip), IP2STR(&ev->ip_info.gw));
    // Network is up: confirm this image so rollback is cancelled and OTA is allowed.
    ota_confirm();
}

// ---------------------------------------------------------------------------
// Ethernet (internal EMAC + RMII PHY), fully configurable per board.
// ---------------------------------------------------------------------------
#if !CONFIG_BRIDGE_NET_WIFI

static void eth_event(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    switch (id) {
    case ETHERNET_EVENT_CONNECTED: ESP_LOGI(TAG, "ethernet link up"); break;
    case ETHERNET_EVENT_DISCONNECTED: ESP_LOGW(TAG, "ethernet link down"); break;
    default: break;
    }
}

static esp_eth_phy_t *make_phy(const eth_phy_config_t *cfg)
{
#if CONFIG_BRIDGE_ETH_PHY_RTL8201
    return esp_eth_phy_new_rtl8201(cfg);
#elif CONFIG_BRIDGE_ETH_PHY_IP101
    return esp_eth_phy_new_ip101(cfg);
#elif CONFIG_BRIDGE_ETH_PHY_KSZ80XX
    return esp_eth_phy_new_ksz80xx(cfg);
#elif CONFIG_BRIDGE_ETH_PHY_DP83848
    return esp_eth_phy_new_dp83848(cfg);
#else
    return esp_eth_phy_new_lan87xx(cfg); // LAN8710/8720 and compatibles
#endif
}

static void net_start_eth(void)
{
    eth_mac_config_t mac_config = ETH_MAC_DEFAULT_CONFIG();
    eth_esp32_emac_config_t emac_config = ETH_ESP32_EMAC_DEFAULT_CONFIG();
    emac_config.smi_gpio.mdc_num = CONFIG_BRIDGE_ETH_MDC_GPIO;
    emac_config.smi_gpio.mdio_num = CONFIG_BRIDGE_ETH_MDIO_GPIO;
    emac_config.interface = EMAC_DATA_INTERFACE_RMII;
#if CONFIG_BRIDGE_ETH_CLK_IN
    emac_config.clock_config.rmii.clock_mode = EMAC_CLK_EXT_IN;
#else
    emac_config.clock_config.rmii.clock_mode = EMAC_CLK_OUT;
#endif
    emac_config.clock_config.rmii.clock_gpio = CONFIG_BRIDGE_ETH_CLK_GPIO;
    esp_eth_mac_t *mac = esp_eth_mac_new_esp32(&emac_config, &mac_config);

    eth_phy_config_t phy_config = ETH_PHY_DEFAULT_CONFIG();
    phy_config.phy_addr = CONFIG_BRIDGE_ETH_PHY_ADDR;
    phy_config.reset_gpio_num = CONFIG_BRIDGE_ETH_PHY_POWER_GPIO;
    esp_eth_phy_t *phy = make_phy(&phy_config);

    esp_eth_config_t eth_config = ETH_DEFAULT_CONFIG(mac, phy);
    esp_eth_handle_t eth_handle = NULL;
    ESP_ERROR_CHECK(esp_eth_driver_install(&eth_config, &eth_handle));

    esp_netif_config_t netif_config = ESP_NETIF_DEFAULT_ETH();
    esp_netif_t *netif = esp_netif_new(&netif_config);
    esp_netif_set_hostname(netif, CONFIG_BRIDGE_HOSTNAME);
    ESP_ERROR_CHECK(esp_netif_attach(netif, esp_eth_new_netif_glue(eth_handle)));
    ESP_ERROR_CHECK(esp_event_handler_register(ETH_EVENT, ESP_EVENT_ANY_ID, eth_event, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_ETH_GOT_IP, on_got_ip, NULL));
    ESP_ERROR_CHECK(esp_eth_start(eth_handle));
    ESP_LOGI(TAG, "ethernet started (MDC=%d MDIO=%d clk_gpio=%d addr=%d)",
             CONFIG_BRIDGE_ETH_MDC_GPIO, CONFIG_BRIDGE_ETH_MDIO_GPIO,
             CONFIG_BRIDGE_ETH_CLK_GPIO, CONFIG_BRIDGE_ETH_PHY_ADDR);
}

bool net_start(void)
{
    net_start_eth();
    return true;
}

#else // CONFIG_BRIDGE_NET_WIFI

// ---------------------------------------------------------------------------
// WiFi station, with credentials in NVS (namespace "bridge"). If none are
// stored (and none baked in), fall back to a SoftAP setup portal.
// ---------------------------------------------------------------------------

static void wifi_event(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    if (base == WIFI_EVENT && id == WIFI_EVENT_STA_START) {
        esp_wifi_connect();
    } else if (base == WIFI_EVENT && id == WIFI_EVENT_STA_DISCONNECTED) {
        ESP_LOGW(TAG, "wifi disconnected, retrying");
        esp_wifi_connect();
    }
}

// Returns true if a credential was found (in NVS, else baked-in Kconfig).
static bool load_creds(char *ssid, size_t ssid_len, char *pass, size_t pass_len)
{
    nvs_handle_t h;
    if (nvs_open("bridge", NVS_READONLY, &h) == ESP_OK) {
        size_t sl = ssid_len, pl = pass_len;
        esp_err_t e1 = nvs_get_str(h, "ssid", ssid, &sl);
        esp_err_t e2 = nvs_get_str(h, "pass", pass, &pl);
        nvs_close(h);
        if (e1 == ESP_OK && ssid[0] != '\0') {
            if (e2 != ESP_OK) pass[0] = '\0';
            return true;
        }
    }
    if (strlen(CONFIG_BRIDGE_WIFI_SSID) > 0) {
        strlcpy(ssid, CONFIG_BRIDGE_WIFI_SSID, ssid_len);
        strlcpy(pass, CONFIG_BRIDGE_WIFI_PASS, pass_len);
        return true;
    }
    return false;
}

static void wifi_connect(const char *ssid, const char *pass)
{
    esp_netif_t *netif = esp_netif_create_default_wifi_sta();
    esp_netif_set_hostname(netif, CONFIG_BRIDGE_HOSTNAME);
    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&cfg));
    ESP_ERROR_CHECK(esp_event_handler_register(WIFI_EVENT, ESP_EVENT_ANY_ID, wifi_event, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_STA_GOT_IP, on_got_ip, NULL));

    wifi_config_t wc = {0};
    strlcpy((char *)wc.sta.ssid, ssid, sizeof(wc.sta.ssid));
    strlcpy((char *)wc.sta.password, pass, sizeof(wc.sta.password));
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_STA));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_STA, &wc));
    ESP_ERROR_CHECK(esp_wifi_start());
    ESP_LOGI(TAG, "connecting to wifi \"%s\"", ssid);
}

// --- SoftAP setup portal ---------------------------------------------------

static esp_err_t portal_get(httpd_req_t *req)
{
    static const char page[] =
        "<!doctype html><meta name=viewport content='width=device-width,initial-scale=1'>"
        "<title>esp-hci-bridge setup</title>"
        "<h2>esp-hci-bridge WiFi setup</h2>"
        "<form method=POST action=/save>"
        "<p>SSID:<br><input name=ssid maxlength=31 required>"
        "<p>Password:<br><input name=pass type=password maxlength=63>"
        "<p><button>Save &amp; reboot</button></form>";
    httpd_resp_set_type(req, "text/html");
    return httpd_resp_send(req, page, HTTPD_RESP_USE_STRLEN);
}

static void url_decode(char *s)
{
    char *o = s;
    for (char *p = s; *p; p++) {
        if (*p == '+') {
            *o++ = ' ';
        } else if (*p == '%' && p[1] && p[2]) {
            int hi = p[1], lo = p[2];
            hi = hi <= '9' ? hi - '0' : (hi | 0x20) - 'a' + 10;
            lo = lo <= '9' ? lo - '0' : (lo | 0x20) - 'a' + 10;
            *o++ = (char)(hi * 16 + lo);
            p += 2;
        } else {
            *o++ = *p;
        }
    }
    *o = '\0';
}

static bool form_field(const char *body, const char *key, char *out, size_t out_len)
{
    char pat[24];
    int n = snprintf(pat, sizeof(pat), "%s=", key);
    const char *p = strstr(body, pat);
    if (!p) return false;
    p += n;
    const char *end = strchr(p, '&');
    size_t len = end ? (size_t)(end - p) : strlen(p);
    if (len >= out_len) len = out_len - 1;
    memcpy(out, p, len);
    out[len] = '\0';
    url_decode(out);
    return true;
}

static esp_err_t portal_save(httpd_req_t *req)
{
    char body[256];
    int n = httpd_req_recv(req, body, sizeof(body) - 1);
    if (n <= 0) return ESP_FAIL;
    body[n] = '\0';

    char ssid[33] = {0}, pass[65] = {0};
    if (!form_field(body, "ssid", ssid, sizeof(ssid)) || ssid[0] == '\0') {
        httpd_resp_send_err(req, HTTPD_400_BAD_REQUEST, "ssid required");
        return ESP_FAIL;
    }
    form_field(body, "pass", pass, sizeof(pass));

    nvs_handle_t h;
    ESP_ERROR_CHECK(nvs_open("bridge", NVS_READWRITE, &h));
    nvs_set_str(h, "ssid", ssid);
    nvs_set_str(h, "pass", pass);
    nvs_commit(h);
    nvs_close(h);

    httpd_resp_sendstr(req, "saved, rebooting");
    ESP_LOGI(TAG, "wifi credentials saved for \"%s\", rebooting", ssid);
    vTaskDelay(pdMS_TO_TICKS(500));
    esp_restart();
    return ESP_OK;
}

static void start_portal(void)
{
    esp_netif_create_default_wifi_ap();
    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_wifi_init(&cfg));
    wifi_config_t ap = {0};
    strlcpy((char *)ap.ap.ssid, "esp-hci-bridge-setup", sizeof(ap.ap.ssid));
    ap.ap.ssid_len = strlen("esp-hci-bridge-setup");
    ap.ap.max_connection = 2;
    ap.ap.authmode = WIFI_AUTH_OPEN;
    ESP_ERROR_CHECK(esp_wifi_set_mode(WIFI_MODE_AP));
    ESP_ERROR_CHECK(esp_wifi_set_config(WIFI_IF_AP, &ap));
    ESP_ERROR_CHECK(esp_wifi_start());

    httpd_config_t hc = HTTPD_DEFAULT_CONFIG();
    httpd_handle_t server = NULL;
    ESP_ERROR_CHECK(httpd_start(&server, &hc));
    const httpd_uri_t get = {.uri = "/", .method = HTTP_GET, .handler = portal_get};
    const httpd_uri_t save = {.uri = "/save", .method = HTTP_POST, .handler = portal_save};
    httpd_register_uri_handler(server, &get);
    httpd_register_uri_handler(server, &save);
    ESP_LOGW(TAG, "no wifi credentials: join AP \"esp-hci-bridge-setup\" and open http://192.168.4.1/");
}

// Returns false when it entered provisioning (caller must not start the bridge).
bool net_start(void)
{
    char ssid[33] = {0}, pass[65] = {0};
    if (!load_creds(ssid, sizeof(ssid), pass, sizeof(pass))) {
        start_portal();
        return false;
    }
    wifi_connect(ssid, pass);
    return true;
}

#endif

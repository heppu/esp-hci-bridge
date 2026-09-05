#include "glue.h"

#include <string.h>

#include "esp_bt.h"
#include "esp_eth.h"
#include "esp_eth_mac_esp.h"
#include "esp_event.h"
#include "esp_log.h"
#include "esp_mac.h"
#include "esp_netif.h"
#include "esp_system.h"
#include "esp_task_wdt.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/stream_buffer.h"
#include "freertos/task.h"
#include "lwip/sockets.h"
#include "nvs_flash.h"
#include "sdkconfig.h"

static const char *TAG = "bridge";

// ---------------------------------------------------------------------------
// Sockets
// ---------------------------------------------------------------------------

int glue_listen(uint16_t port)
{
    int fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (fd < 0) {
        return -1;
    }
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_port = htons(port),
        .sin_addr.s_addr = htonl(INADDR_ANY),
    };
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0 || listen(fd, 1) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

int glue_accept(int lfd)
{
    struct sockaddr_in peer;
    socklen_t len = sizeof(peer);
    int fd = accept(lfd, (struct sockaddr *)&peer, &len);
    if (fd < 0) {
        return -1;
    }
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof(one));
    int idle = 5, intvl = 2, cnt = 3;
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPIDLE, &idle, sizeof(idle));
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL, &intvl, sizeof(intvl));
    setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &cnt, sizeof(cnt));

    char ip[16];
    inet_ntoa_r(peer.sin_addr, ip, sizeof(ip));
    ESP_LOGI(TAG, "connection from %s:%u", ip, ntohs(peer.sin_port));
    return fd;
}

// Returns a bitmask: bit0 fd_a readable, bit1 fd_b readable or errored.
int glue_poll2(int fd_a, int fd_b, int timeout_ms)
{
    fd_set rd;
    FD_ZERO(&rd);
    int maxfd = -1;
    if (fd_a >= 0) {
        FD_SET(fd_a, &rd);
        maxfd = fd_a;
    }
    if (fd_b >= 0) {
        FD_SET(fd_b, &rd);
        if (fd_b > maxfd) {
            maxfd = fd_b;
        }
    }
    if (maxfd < 0) {
        glue_delay_ms(timeout_ms);
        return 0;
    }
    struct timeval tv = { .tv_sec = timeout_ms / 1000, .tv_usec = (timeout_ms % 1000) * 1000 };
    int n = select(maxfd + 1, &rd, NULL, NULL, &tv);
    if (n < 0) {
        return -1;
    }
    int mask = 0;
    if (fd_a >= 0 && FD_ISSET(fd_a, &rd)) {
        mask |= 1;
    }
    if (fd_b >= 0 && FD_ISSET(fd_b, &rd)) {
        mask |= 2;
    }
    return mask;
}

int glue_recv(int fd, void *buf, size_t len)
{
    return recv(fd, buf, len, 0);
}

int glue_send(int fd, const void *buf, size_t len)
{
    const uint8_t *p = buf;
    size_t left = len;
    while (left > 0) {
        int n = send(fd, p, left, 0);
        if (n <= 0) {
            return -1;
        }
        p += n;
        left -= n;
    }
    return (int)len;
}

void glue_close(int fd)
{
    shutdown(fd, SHUT_RDWR);
    close(fd);
}

// ---------------------------------------------------------------------------
// FreeRTOS objects
// ---------------------------------------------------------------------------

void *glue_sb_create(size_t size)
{
    return xStreamBufferCreate(size, 1);
}

size_t glue_sb_send(void *sb, const void *data, size_t len, uint32_t timeout_ms)
{
    return xStreamBufferSend((StreamBufferHandle_t)sb, data, len, pdMS_TO_TICKS(timeout_ms));
}

size_t glue_sb_recv(void *sb, void *buf, size_t len, uint32_t timeout_ms)
{
    return xStreamBufferReceive((StreamBufferHandle_t)sb, buf, len, pdMS_TO_TICKS(timeout_ms));
}

size_t glue_sb_space(void *sb)
{
    return xStreamBufferSpacesAvailable((StreamBufferHandle_t)sb);
}

void *glue_sem_create(void)
{
    return xSemaphoreCreateBinary();
}

bool glue_sem_take(void *sem, uint32_t timeout_ms)
{
    return xSemaphoreTake((SemaphoreHandle_t)sem, pdMS_TO_TICKS(timeout_ms)) == pdTRUE;
}

void glue_sem_give(void *sem)
{
    xSemaphoreGive((SemaphoreHandle_t)sem);
}

bool glue_task_create(glue_task_fn fn, const char *name, uint32_t stack, uint32_t prio, int core)
{
    return xTaskCreatePinnedToCore(fn, name, stack, NULL, prio, NULL, core) == pdPASS;
}

void glue_delay_ms(uint32_t ms)
{
    vTaskDelay(pdMS_TO_TICKS(ms));
}

uint32_t glue_millis(void)
{
    return (uint32_t)(esp_timer_get_time() / 1000);
}

void glue_log(int level, const char *msg)
{
    switch (level) {
    case 1: ESP_LOGE(TAG, "%s", msg); break;
    case 2: ESP_LOGW(TAG, "%s", msg); break;
    case 3: ESP_LOGI(TAG, "%s", msg); break;
    default: ESP_LOGD(TAG, "%s", msg); break;
    }
}

void glue_abort(const char *msg)
{
    esp_system_abort(msg);
}

void glue_wdt_add(void)
{
    esp_task_wdt_add(NULL);
}

void glue_wdt_feed(void)
{
    esp_task_wdt_reset();
}

// ---------------------------------------------------------------------------
// Bluetooth controller
// ---------------------------------------------------------------------------

bool glue_bt_send_available(void)
{
    return esp_vhci_host_check_send_available();
}

void glue_bt_send(const uint8_t *data, uint16_t len)
{
    esp_vhci_host_send_packet((uint8_t *)data, len);
}

uint16_t glue_tcp_port(void)
{
    return CONFIG_BRIDGE_TCP_PORT;
}

static const esp_vhci_host_callback_t vhci_cb = {
    .notify_host_send_available = bridge_on_controller_send_available,
    .notify_host_recv = bridge_on_controller_packet,
};

static void bt_init(void)
{
    esp_bt_controller_config_t cfg = BT_CONTROLLER_INIT_CONFIG_DEFAULT();
    ESP_ERROR_CHECK(esp_bt_controller_init(&cfg));
    ESP_ERROR_CHECK(esp_bt_controller_enable(ESP_BT_MODE_BTDM));
    ESP_ERROR_CHECK(esp_vhci_host_register_callback(&vhci_cb));

    uint8_t mac[6];
    ESP_ERROR_CHECK(esp_read_mac(mac, ESP_MAC_BT));
    ESP_LOGI(TAG, "bt controller up, address %02x:%02x:%02x:%02x:%02x:%02x",
             mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
}

// ---------------------------------------------------------------------------
// Ethernet
// ---------------------------------------------------------------------------

static void eth_event(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    switch (id) {
    case ETHERNET_EVENT_CONNECTED: ESP_LOGI(TAG, "ethernet link up"); break;
    case ETHERNET_EVENT_DISCONNECTED: ESP_LOGW(TAG, "ethernet link down"); break;
    case ETHERNET_EVENT_START: ESP_LOGI(TAG, "ethernet started"); break;
    case ETHERNET_EVENT_STOP: ESP_LOGW(TAG, "ethernet stopped"); break;
    default: break;
    }
}

static void ip_event(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    const ip_event_got_ip_t *ev = data;
    ESP_LOGI(TAG, "ip " IPSTR " mask " IPSTR " gw " IPSTR,
             IP2STR(&ev->ip_info.ip), IP2STR(&ev->ip_info.netmask), IP2STR(&ev->ip_info.gw));
    ota_confirm();
}

static void eth_init(void)
{
    eth_mac_config_t mac_config = ETH_MAC_DEFAULT_CONFIG();
    eth_esp32_emac_config_t emac_config = ETH_ESP32_EMAC_DEFAULT_CONFIG();
    emac_config.smi_gpio.mdc_num = CONFIG_BRIDGE_ETH_MDC_GPIO;
    emac_config.smi_gpio.mdio_num = CONFIG_BRIDGE_ETH_MDIO_GPIO;
    emac_config.interface = EMAC_DATA_INTERFACE_RMII;
    emac_config.clock_config.rmii.clock_mode = EMAC_CLK_OUT;
    emac_config.clock_config.rmii.clock_gpio = EMAC_CLK_OUT_180_GPIO;
    esp_eth_mac_t *mac = esp_eth_mac_new_esp32(&emac_config, &mac_config);

    eth_phy_config_t phy_config = ETH_PHY_DEFAULT_CONFIG();
    phy_config.phy_addr = CONFIG_BRIDGE_ETH_PHY_ADDR;
    // On ESP32-POE this GPIO is the PHY power enable, the reset sequence doubles as power up.
    phy_config.reset_gpio_num = CONFIG_BRIDGE_ETH_PHY_POWER_GPIO;
    esp_eth_phy_t *phy = esp_eth_phy_new_lan87xx(&phy_config);

    esp_eth_config_t eth_config = ETH_DEFAULT_CONFIG(mac, phy);
    esp_eth_handle_t eth_handle = NULL;
    ESP_ERROR_CHECK(esp_eth_driver_install(&eth_config, &eth_handle));

    esp_netif_config_t netif_config = ESP_NETIF_DEFAULT_ETH();
    esp_netif_t *netif = esp_netif_new(&netif_config);
    ESP_ERROR_CHECK(esp_netif_set_hostname(netif, CONFIG_BRIDGE_HOSTNAME));
    ESP_ERROR_CHECK(esp_netif_attach(netif, esp_eth_new_netif_glue(eth_handle)));

    ESP_ERROR_CHECK(esp_event_handler_register(ETH_EVENT, ESP_EVENT_ANY_ID, eth_event, NULL));
    ESP_ERROR_CHECK(esp_event_handler_register(IP_EVENT, IP_EVENT_ETH_GOT_IP, ip_event, NULL));
    ESP_ERROR_CHECK(esp_eth_start(eth_handle));
}

void app_main(void)
{
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        err = nvs_flash_init();
    }
    ESP_ERROR_CHECK(err);
    ESP_ERROR_CHECK(esp_netif_init());
    ESP_ERROR_CHECK(esp_event_loop_create_default());

    eth_init();
    bt_init();
    bridge_start();
    ota_init();
}

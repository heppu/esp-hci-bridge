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

void glue_shutdown(int fd)
{
    shutdown(fd, SHUT_RDWR);
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

bool glue_auth_handshake(int fd)
{
    return auth_handshake(fd);
}

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
// LAN discovery: broadcast an announce and answer probes, matching
// common/discovery.zig ("ESPHCI1\tANNOUNCE\t<bdaddr>\t<port>\t<name>\n").
// ---------------------------------------------------------------------------

#define DISCOVERY_PORT 4445
#define ANNOUNCE_INTERVAL_MS 2000
#define PROBE_REPLIES_PER_S 5

static void discovery_task(void *arg)
{
    (void)arg;
    uint8_t mac[6] = {0};
    esp_read_mac(mac, ESP_MAC_BT);
    char bdaddr[18];
    snprintf(bdaddr, sizeof(bdaddr), "%02x:%02x:%02x:%02x:%02x:%02x", mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
    char announce[224];
    int alen = 0;

    int fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (fd < 0) {
        ESP_LOGE(TAG, "discovery socket failed");
        vTaskDelete(NULL);
        return;
    }
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, sizeof(one));
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    struct sockaddr_in local = {
        .sin_family = AF_INET,
        .sin_port = htons(DISCOVERY_PORT),
        .sin_addr.s_addr = htonl(INADDR_ANY),
    };
    bind(fd, (struct sockaddr *)&local, sizeof(local));

    struct sockaddr_in bcast = {
        .sin_family = AF_INET,
        .sin_port = htons(DISCOVERY_PORT),
        .sin_addr.s_addr = htonl(INADDR_BROADCAST),
    };

    struct timeval tv = { .tv_sec = 1, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    ESP_LOGI(TAG, "discovery announcing on udp %d", DISCOVERY_PORT);
    uint32_t last_announce = glue_millis() - ANNOUNCE_INTERVAL_MS;
    uint32_t reply_window = 0;
    int replies = 0;
    while (1) {
        uint32_t now = glue_millis();
        if (now - last_announce >= ANNOUNCE_INTERVAL_MS) {
            last_announce = now;
            // The signature binds the board address, so nothing goes out until there is one.
            char ip[16], sig[40];
            alen = 0;
            if (net_ip_str(ip, sizeof(ip))) {
                auth_announce_sig(bdaddr, (unsigned)CONFIG_BRIDGE_TCP_PORT, CONFIG_BRIDGE_HOSTNAME, ip, sig, sizeof(sig));
                alen = snprintf(announce, sizeof(announce), "ESPHCI1\tANNOUNCE\t%s\t%u\t%s\t%s\n",
                                bdaddr, (unsigned)CONFIG_BRIDGE_TCP_PORT, CONFIG_BRIDGE_HOSTNAME, sig);
                sendto(fd, announce, alen, 0, (struct sockaddr *)&bcast, sizeof(bcast));
            }
        }

        char buf[64];
        struct sockaddr_in from;
        socklen_t flen = sizeof(from);
        int n = recvfrom(fd, buf, sizeof(buf) - 1, 0, (struct sockaddr *)&from, &flen);
        if (n <= 0 || alen == 0) continue;
        buf[n] = 0;
        if (strncmp(buf, "ESPHCI1\tPROBE", 13) != 0) continue;
        now = glue_millis();
        if (now - reply_window >= 1000) {
            reply_window = now;
            replies = 0;
        }
        if (replies < PROBE_REPLIES_PER_S) {
            replies++;
            sendto(fd, announce, alen, 0, (struct sockaddr *)&from, flen);
        }
    }
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
    auth_init();

    if (!net_start()) {
        // Entered WiFi setup portal; do not start the bridge until configured.
        return;
    }
    bt_init();
    bridge_start();
    ota_init();
    xTaskCreate(discovery_task, "discovery", 4096, NULL, 4, NULL);
}

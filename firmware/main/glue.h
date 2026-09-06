#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Implemented in bridge.zig
void bridge_start(void);
int bridge_on_controller_packet(uint8_t *data, uint16_t len);
void bridge_on_controller_send_available(void);
size_t bridge_stats_json(char *buf, size_t len);

// Implemented in auth.c
bool auth_init(void);
bool auth_claimed(void);
bool auth_handshake(int fd);
size_t auth_announce_sig(const char *bdaddr, unsigned port, const char *name, const char *ip, char *out, size_t outlen);
size_t auth_nonce_hex(char *out, size_t outlen);
void auth_nonce_bump(void);
bool auth_check_http(const char *method, const char *path, const uint8_t body_sha[32], const char *header_hex);
bool auth_check_http_pre(const char *method, const char *path, uint32_t content_len, const char *header_hex);
bool auth_ct_equal(const uint8_t *a, const uint8_t *b, size_t n);
int auth_claim(const uint8_t peer_pub[32], uint8_t our_pub[32]);
int auth_unclaim(void);

// Implemented in net.c
bool net_start(void);
bool net_ip_str(char *out, size_t len);

// Implemented in ota.c
void ota_init(void);
void ota_confirm(void);

// Implemented in glue.c, consumed by bridge.zig
int glue_listen(uint16_t port);
int glue_accept(int lfd);
int glue_poll2(int fd_a, int fd_b, int timeout_ms);
int glue_recv(int fd, void *buf, size_t len);
int glue_send(int fd, const void *buf, size_t len);
void glue_shutdown(int fd);
void glue_close(int fd);

void *glue_sb_create(size_t size);
size_t glue_sb_send(void *sb, const void *data, size_t len, uint32_t timeout_ms);
size_t glue_sb_recv(void *sb, void *buf, size_t len, uint32_t timeout_ms);
size_t glue_sb_space(void *sb);

void *glue_sem_create(void);
bool glue_sem_take(void *sem, uint32_t timeout_ms);
void glue_sem_give(void *sem);

typedef void (*glue_task_fn)(void *);
bool glue_task_create(glue_task_fn fn, const char *name, uint32_t stack, uint32_t prio, int core);
void glue_delay_ms(uint32_t ms);
uint32_t glue_millis(void);
void glue_log(int level, const char *msg);
void glue_abort(const char *msg) __attribute__((noreturn));
void glue_wdt_add(void);
void glue_wdt_feed(void);

bool glue_bt_send_available(void);
void glue_bt_send(const uint8_t *data, uint16_t len);
uint16_t glue_tcp_port(void);

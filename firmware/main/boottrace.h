#pragma once
#include <stdint.h>

// Startup progress kept in RTC memory so a crash during boot can be read
// back from the image that boots next, even after an OTA rollback.
void boottrace_init(void);
void boottrace_mark(uint32_t stage);
uint32_t boottrace_prev_stage(void);
int boottrace_reset_reason(void);

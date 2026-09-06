#include "boottrace.h"
#include "esp_attr.h"
#include "esp_system.h"

#define MAGIC 0x42007ace

static RTC_NOINIT_ATTR uint32_t s_magic;
static RTC_NOINIT_ATTR uint32_t s_stage;
static uint32_t s_prev_stage;
static int s_reset;

void boottrace_init(void)
{
    s_reset = (int)esp_reset_reason();
    s_prev_stage = (s_magic == MAGIC) ? s_stage : 0xffffffffu;
    s_magic = MAGIC;
    s_stage = 0;
}

void boottrace_mark(uint32_t stage)
{
    s_stage = stage;
}

uint32_t boottrace_prev_stage(void)
{
    return s_prev_stage;
}

int boottrace_reset_reason(void)
{
    return s_reset;
}

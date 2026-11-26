// Тонкая обёртка llama.cpp для «Продвинутой» (ADR-046): простые типы на
// границе dart:ffi вместо структур llama.h, которые меняются от версии к
// версии.
#ifndef TRIDOT_LLAMA_H
#define TRIDOT_LLAMA_H

#include <stdint.h>

#ifdef _WIN32
#define TL_API __declspec(dllexport)
#else
#define TL_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct tl_ctx tl_ctx;

// Ошибки tl_complete (отрицательные).
#define TL_ERR_TOKENIZE -1
#define TL_ERR_TOO_LONG -2
#define TL_ERR_GRAMMAR -3
#define TL_ERR_DECODE -4
#define TL_ERR_CANCELLED -5

// NULL — модель не загрузилась.
TL_API tl_ctx *tl_load(const char *path, int32_t n_ctx, int32_t threads);

// Жадный ответ на [prompt] (уже в шаблоне чата, служебные токены
// разбираются). [grammar] — GBNF или NULL. Пишет UTF-8 в [out] (с нулём в
// конце), возвращает число байт или TL_ERR_*. Общее начало с прошлым
// запросом не пересчитывается. [cancel] != 0 — остановиться.
TL_API int32_t tl_complete(tl_ctx *ctx, const char *prompt, const char *grammar,
                           int32_t max_tokens, char *out, int32_t out_cap,
                           volatile int32_t *cancel);

TL_API void tl_free(tl_ctx *ctx);

#ifdef __cplusplus
}
#endif

#endif

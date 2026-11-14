/*
 * tridot_lame — тонкая обёртка над LAME 3.100 для Tridot (ADR-026):
 * PCM 16 бит → MP3 с постоянным битрейтом (CBR).
 *
 * Copyright (C) 2026 авторы Tridot.
 *
 * This library is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Library General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or (at your
 * option) any later version. See ../third_party/lame-3.100/COPYING.
 *
 * Библиотека собирается отдельным разделяемым файлом (libtridot_mp3.so,
 * tridot_mp3.framework): его можно пересобрать из этих исходников и
 * заменить — так соблюдается LGPL.
 */
#ifndef TRIDOT_LAME_H
#define TRIDOT_LAME_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#define TL_API __declspec(dllexport)
#else
#define TL_API __attribute__((visibility("default")))
#endif

/* Коды ошибок: всегда отрицательные. */
#define TL_EARG (-1)    /* неверный аргумент */
#define TL_ENOMEM (-2)  /* нет памяти */
#define TL_EPARAMS (-3) /* LAME не принял настройки */
#define TL_ESPACE (-4)  /* мал буфер результата */
#define TL_EENCODE (-5) /* ошибка кодирования */

/* Самое большое число кадров PCM за один вызов tl_encode. */
#define TL_MAX_FRAMES (1 << 20)

/* Частота MP3 для входа rate и битрейта kbps (0 — оставить как у входа):
 * 256 и 320 кбит/с есть только у MPEG-1 (32/44,1/48 кГц). */
TL_API int tl_auto_rate(int rate, int kbps);

/* Открывает кодировщик: rate — частота входа, channels — 1 или 2, kbps —
 * битрейт (32…320), out_rate — частота MP3 или 0 (tl_auto_rate). 0 —
 * успех, *handle — кодировщик; иначе код ошибки. */
TL_API int tl_open(int rate, int channels, int kbps, int out_rate,
                   void **handle);

/* Сколько байт нужно буферу результата для frames кадров без
 * пересэмплирования. */
TL_API int tl_out_cap(int frames);

/* То же для входа in_rate и MP3 out_rate: при out_rate > in_rate кадров
 * MP3 больше, чем кадров входа (8 кГц на 320 кбит/с → 44,1 кГц). */
TL_API int tl_out_cap_rate(int frames, int in_rate, int out_rate);

/* Сколько байт нужно буферу результата tl_encode у этого кодировщика. */
TL_API int tl_out_cap_h(void *handle, int frames);

/* Кодирует frames кадров PCM (чередование каналов, int16): число байт MP3
 * в out (может быть 0) или код ошибки. */
TL_API int tl_encode(void *handle, const int16_t *pcm, int frames,
                     uint8_t *out, int cap);

/* Дописывает остаток: число байт в out или код ошибки. */
TL_API int tl_flush(void *handle, uint8_t *out, int cap);

/* Кадр Xing/LAME («Info») для начала файла — точная длительность у
 * плееров: число байт в out, 0 — кадра нет, или код ошибки. Вызывать
 * после tl_flush; кадр записывается поверх первых байт файла. */
TL_API int tl_lametag(void *handle, uint8_t *out, int cap);

/* Частота MP3 после tl_open. */
TL_API int tl_out_rate(void *handle);

/* Закрывает кодировщик; NULL — ничего. */
TL_API void tl_close(void *handle);

/* Версия LAME: "3.100". */
TL_API const char *tl_version(void);

#ifdef __cplusplus
}
#endif

#endif

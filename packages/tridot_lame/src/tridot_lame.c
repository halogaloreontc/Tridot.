/*
 * tridot_lame — тонкая обёртка над LAME 3.100 для Tridot (ADR-026).
 *
 * Copyright (C) 2026 авторы Tridot.
 *
 * This library is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Library General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or (at your
 * option) any later version. See ../third_party/lame-3.100/COPYING.
 */
#include "tridot_lame.h"

#include <stdlib.h>

#include "lame.h"

typedef struct {
  lame_t lame;
  int channels;
  int in_rate;
  int out_rate;
} tl_handle;

static int tl_valid_kbps(int kbps) {
  static const int rates[] = {32,  40,  48,  56,  64,  80,  96,
                              112, 128, 160, 192, 224, 256, 320};
  for (unsigned i = 0; i < sizeof(rates) / sizeof(rates[0]); i++) {
    if (rates[i] == kbps) return 1;
  }
  return 0;
}

static int tl_mpeg1(int rate) {
  return rate == 32000 || rate == 44100 || rate == 48000;
}

static int tl_mpeg2(int rate) {
  return rate == 16000 || rate == 22050 || rate == 24000;
}

static int tl_mpeg25(int rate) {
  return rate == 8000 || rate == 11025 || rate == 12000;
}

TL_API int tl_auto_rate(int rate, int kbps) {
  if (tl_mpeg1(rate)) return 0;
  /* Больше 160 кбит/с — только MPEG-1. */
  if (kbps > 160) return 44100;
  /* MPEG-2: до 160 кбит/с. */
  if (tl_mpeg2(rate)) return 0;
  /* MPEG-2.5: до 64 кбит/с. */
  if (tl_mpeg25(rate) && kbps <= 64) return 0;
  /* Частота выше 48 кГц или нестандартная. */
  return rate > 48000 ? 48000 : 44100;
}

TL_API int tl_open(int rate, int channels, int kbps, int out_rate,
                   void **handle) {
  if (handle == NULL) return TL_EARG;
  *handle = NULL;
  if (rate < 8000 || rate > 192000) return TL_EARG;
  if (channels != 1 && channels != 2) return TL_EARG;
  if (!tl_valid_kbps(kbps)) return TL_EARG;
  if (out_rate != 0 && !tl_mpeg1(out_rate) && !tl_mpeg2(out_rate) &&
      !tl_mpeg25(out_rate)) {
    return TL_EARG;
  }
  tl_handle *h = (tl_handle *)calloc(1, sizeof(tl_handle));
  if (h == NULL) return TL_ENOMEM;
  h->lame = lame_init();
  if (h->lame == NULL) {
    free(h);
    return TL_ENOMEM;
  }
  h->channels = channels;
  h->in_rate = rate;
  int out = out_rate != 0 ? out_rate : tl_auto_rate(rate, kbps);
  lame_set_in_samplerate(h->lame, rate);
  lame_set_num_channels(h->lame, channels);
  if (out != 0) lame_set_out_samplerate(h->lame, out);
  lame_set_mode(h->lame, channels == 1 ? MONO : JOINT_STEREO);
  lame_set_VBR(h->lame, vbr_off);
  lame_set_brate(h->lame, kbps);
  lame_set_quality(h->lame, 2);
  /* Кадр «Info» в начале: точная длительность у плееров (tl_lametag). */
  lame_set_bWriteVbrTag(h->lame, 1);
  /* Без ID3: имя файла и прочее в тег не пишутся. */
  if (lame_init_params(h->lame) < 0 ||
      lame_get_brate(h->lame) != kbps) {
    lame_close(h->lame);
    free(h);
    return TL_EPARAMS;
  }
  h->out_rate = lame_get_out_samplerate(h->lame);
  *handle = h;
  return 0;
}

TL_API int tl_out_cap(int frames) {
  if (frames < 0 || frames > TL_MAX_FRAMES) return TL_EARG;
  /* Оценка из lame.h: 1,25 · кадры + 7200. */
  return frames + frames / 4 + 7200;
}

TL_API int tl_out_cap_rate(int frames, int in_rate, int out_rate) {
  if (frames < 0 || frames > TL_MAX_FRAMES) return TL_EARG;
  if (in_rate <= 0 || out_rate <= 0) return TL_EARG;
  /* Оценка lame.h считается в кадрах MP3: при пересэмплировании вверх
   * (8 кГц → 44,1 кГц) их больше, чем кадров входа. */
  int64_t scaled = frames;
  if (out_rate > in_rate) {
    scaled = ((int64_t)frames * out_rate + in_rate - 1) / in_rate;
  }
  int64_t cap = scaled + scaled / 4 + 7200;
  return cap > 0x7fffffff ? TL_EARG : (int)cap;
}

TL_API int tl_out_cap_h(void *handle, int frames) {
  tl_handle *h = (tl_handle *)handle;
  if (h == NULL) return TL_EARG;
  return tl_out_cap_rate(frames, h->in_rate, h->out_rate);
}

TL_API int tl_encode(void *handle, const int16_t *pcm, int frames,
                     uint8_t *out, int cap) {
  tl_handle *h = (tl_handle *)handle;
  if (h == NULL || out == NULL || frames < 0 || frames > TL_MAX_FRAMES) {
    return TL_EARG;
  }
  if (frames == 0) return 0;
  if (pcm == NULL) return TL_EARG;
  int need = tl_out_cap_h(h, frames);
  if (need < 0) return need;
  if (cap < need) return TL_ESPACE;
  int n;
  if (h->channels == 2) {
    n = lame_encode_buffer_interleaved(h->lame, (short *)pcm, frames, out,
                                       cap);
  } else {
    n = lame_encode_buffer(h->lame, (const short *)pcm, (const short *)pcm,
                           frames, out, cap);
  }
  if (n == -1) return TL_ESPACE;
  if (n == -2) return TL_ENOMEM;
  return n < 0 ? TL_EENCODE : n;
}

TL_API int tl_flush(void *handle, uint8_t *out, int cap) {
  tl_handle *h = (tl_handle *)handle;
  if (h == NULL || out == NULL) return TL_EARG;
  if (cap < 7200) return TL_ESPACE;
  int n = lame_encode_flush(h->lame, out, cap);
  return n < 0 ? TL_EENCODE : n;
}

TL_API int tl_lametag(void *handle, uint8_t *out, int cap) {
  tl_handle *h = (tl_handle *)handle;
  if (h == NULL || out == NULL || cap <= 0) return TL_EARG;
  size_t n = lame_get_lametag_frame(h->lame, out, (size_t)cap);
  if (n > (size_t)cap) return TL_ESPACE;
  return (int)n;
}

TL_API int tl_out_rate(void *handle) {
  tl_handle *h = (tl_handle *)handle;
  if (h == NULL) return TL_EARG;
  return lame_get_out_samplerate(h->lame);
}

TL_API void tl_close(void *handle) {
  tl_handle *h = (tl_handle *)handle;
  if (h == NULL) return;
  lame_close(h->lame);
  free(h);
}

TL_API const char *tl_version(void) { return get_lame_version(); }

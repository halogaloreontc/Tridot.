/*
 * JNI для tridot_lame (только Android, ADR-026): методы класса
 * com.example.local_assistant.media.Mp3Native регистрируются в
 * JNI_OnLoad через RegisterNatives. PCM и MP3 — прямые ByteBuffer, без
 * копий; размеры проверяются по ёмкости буферов.
 *
 * Copyright (C) 2026 авторы Tridot.
 *
 * This library is free software; you can redistribute it and/or modify it
 * under the terms of the GNU Library General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or (at your
 * option) any later version. See ../third_party/lame-3.100/COPYING.
 */
#include <jni.h>
#include <stdint.h>

#include "tridot_lame.h"

#define TL_CLASS "com/example/local_assistant/media/Mp3Native"

static void *tl_ptr(jlong handle) { return (void *)(intptr_t)handle; }

/* Адрес и ёмкость прямого буфера; не прямой — NULL. */
static uint8_t *tl_buffer(JNIEnv *env, jobject buffer, jlong *cap) {
  *cap = 0;
  if (buffer == NULL) return NULL;
  void *address = (*env)->GetDirectBufferAddress(env, buffer);
  jlong capacity = (*env)->GetDirectBufferCapacity(env, buffer);
  if (address == NULL || capacity <= 0) return NULL;
  *cap = capacity > 0x7fffffff ? 0x7fffffff : capacity;
  return (uint8_t *)address;
}

static jlong JNICALL tl_jni_open(JNIEnv *env, jclass cls, jint rate,
                                 jint channels, jint kbps, jint out_rate) {
  (void)env;
  (void)cls;
  void *handle = NULL;
  if (tl_open(rate, channels, kbps, out_rate, &handle) != 0) return 0;
  return (jlong)(intptr_t)handle;
}

static jint JNICALL tl_jni_encode(JNIEnv *env, jclass cls, jlong handle,
                                  jobject pcm, jint frames, jint channels,
                                  jobject out) {
  (void)cls;
  if (handle == 0 || frames < 0 || (channels != 1 && channels != 2)) {
    return TL_EARG;
  }
  jlong pcm_cap = 0;
  jlong out_cap = 0;
  uint8_t *in = tl_buffer(env, pcm, &pcm_cap);
  uint8_t *dst = tl_buffer(env, out, &out_cap);
  if (in == NULL || dst == NULL) return TL_EARG;
  if ((jlong)frames * channels * 2 > pcm_cap) return TL_EARG;
  return tl_encode(tl_ptr(handle), (const int16_t *)in, frames, dst,
                   (int)out_cap);
}

static jint JNICALL tl_jni_flush(JNIEnv *env, jclass cls, jlong handle,
                                 jobject out) {
  (void)cls;
  if (handle == 0) return TL_EARG;
  jlong cap = 0;
  uint8_t *dst = tl_buffer(env, out, &cap);
  if (dst == NULL) return TL_EARG;
  return tl_flush(tl_ptr(handle), dst, (int)cap);
}

static jint JNICALL tl_jni_lametag(JNIEnv *env, jclass cls, jlong handle,
                                   jobject out) {
  (void)cls;
  if (handle == 0) return TL_EARG;
  jlong cap = 0;
  uint8_t *dst = tl_buffer(env, out, &cap);
  if (dst == NULL) return TL_EARG;
  return tl_lametag(tl_ptr(handle), dst, (int)cap);
}

static jint JNICALL tl_jni_out_rate(JNIEnv *env, jclass cls, jlong handle) {
  (void)env;
  (void)cls;
  if (handle == 0) return TL_EARG;
  return tl_out_rate(tl_ptr(handle));
}

static void JNICALL tl_jni_close(JNIEnv *env, jclass cls, jlong handle) {
  (void)env;
  (void)cls;
  if (handle != 0) tl_close(tl_ptr(handle));
}

static jstring JNICALL tl_jni_version(JNIEnv *env, jclass cls) {
  (void)cls;
  return (*env)->NewStringUTF(env, tl_version());
}

static const JNINativeMethod tl_methods[] = {
    {"open", "(IIII)J", (void *)tl_jni_open},
    {"encode", "(JLjava/nio/ByteBuffer;IILjava/nio/ByteBuffer;)I",
     (void *)tl_jni_encode},
    {"flush", "(JLjava/nio/ByteBuffer;)I", (void *)tl_jni_flush},
    {"lametag", "(JLjava/nio/ByteBuffer;)I", (void *)tl_jni_lametag},
    {"outRate", "(J)I", (void *)tl_jni_out_rate},
    {"close", "(J)V", (void *)tl_jni_close},
    {"version", "()Ljava/lang/String;", (void *)tl_jni_version},
};

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {
  (void)reserved;
  JNIEnv *env = NULL;
  if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) {
    return JNI_ERR;
  }
  jclass cls = (*env)->FindClass(env, TL_CLASS);
  if (cls == NULL) return JNI_ERR;
  jint ok = (*env)->RegisterNatives(
      env, cls, tl_methods, sizeof(tl_methods) / sizeof(tl_methods[0]));
  (*env)->DeleteLocalRef(env, cls);
  return ok == 0 ? JNI_VERSION_1_6 : JNI_ERR;
}

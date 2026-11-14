# LAME 3.100 — откуда эти файлы

Здесь лежит часть исходников LAME 3.100, только кодировщик MP3. Лицензия —
LGPL-2.0-or-later, текст в `lame-3.100/COPYING`. Решение описано в ADR-026
(docs/DECISIONS.md).

## Где эти исходники

Папка `packages/tridot_lame` открытого репозитория приложения:
https://github.com/halogaloreontc/qenqritec/tree/main/packages/tridot_lame
(у выпущенной версии — тег с её номером). Запрос исходников для LGPL —
через https://github.com/halogaloreontc/qenqritec/issues.

## Источник

- Архив: `lame-3.100.tar.gz` с https://sourceforge.net/projects/lame/files/lame/3.100/
- Тот же архив, байт в байт: Debian `lame_3.100.orig.tar.gz`.
- Домашняя страница проекта: https://lame.sourceforge.io/
- SHA-256 архива:
  `ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e`

Архив был проверен по этой сумме и распакован в новую пустую папку. Из неё
скопированы файлы без изменений.

## Что взято

- `libmp3lame/*.c`: 19 файлов кодировщика. Их список совпадает со списком
  в `hook/build.dart`.
- `libmp3lame/*.h`: все 21 заголовок, и ещё `libmp3lame/vector/lame_intrin.h`
  (его подключает `fft.c`).
- `include/lame.h`.
- `COPYING`, `LICENSE`, `README`.

Сумма SHA-256 каждого файла записана в `SHA256SUMS`. Тест
`test/lame/lame_vendor_checksum_test.dart` сверяет файлы с этим списком.
Он падает, если файл изменён, пропал или появился лишний.

## Чего нет

- `mpglib/` и `libmp3lame/mpglib_interface.c`: декодер MP3 не нужен,
  декодирует система.
- `libmp3lame/i386/` и `libmp3lame/vector/xmm_quantize_sub.c`: ассемблер и
  SSE.
- `frontend/`: программа `lame` для командной строки.
- `configure`, Makefile, проекты Visual Studio, `doc/`, `debian/`, тестовые
  файлы. Сборку делает `hook/build.dart`, настройки из `config.h` заданы там
  как defines.

## Как заменить библиотеку (LGPL)

Кодировщик собирается в отдельную разделяемую библиотеку:
`libtridot_mp3.so` на Android и Linux, `tridot_mp3.framework` на macOS.
Порядок такой:

1. Изменить исходники здесь или в `src/`.
2. Собрать приложение заново: `flutter build apk` или `flutter build macos`.
   Сборщик пересоберёт библиотеку.
3. Либо собрать только библиотеку тем же NDK или clang с теми же defines и
   положить её в APK (`lib/arm64-v8a/libtridot_mp3.so`) или в бандл вместо
   старой.

Приложение вызывает только функции `tl_*` из `src/tridot_lame.h`.

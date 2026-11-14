import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Свободное место в папке [path] в байтах или `null`, если его не узнать.
///
/// Только 64-битные Linux и Android: там `statvfs` из libc с одинаковой
/// раскладкой структуры (все поля по 8 байт). На macOS и Windows место не
/// проверяется заранее — нехватку покажет ошибка записи (ADR-024).
int? freeBytes(String path) {
  if (!(Platform.isLinux || Platform.isAndroid) || sizeOf<IntPtr>() != 8) {
    return null;
  }
  try {
    final libc = DynamicLibrary.process();
    final statvfs = libc.lookupFunction<
        Int32 Function(Pointer<Utf8>, Pointer<Uint8>),
        int Function(Pointer<Utf8>, Pointer<Uint8>)>('statvfs');
    final name = path.toNativeUtf8();
    final buffer = calloc<Uint8>(256);
    try {
      if (statvfs(name, buffer) != 0) return null;
      final fields = buffer.cast<Uint64>();
      // f_bsize, f_frsize, f_blocks, f_bfree, f_bavail…
      final frsize = fields[1];
      final available = fields[4];
      if (frsize <= 0 || available < 0) return null;
      return frsize * available;
    } finally {
      calloc.free(buffer);
      calloc.free(name);
    }
  } on Object {
    return null;
  }
}

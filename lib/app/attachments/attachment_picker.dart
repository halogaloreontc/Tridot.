import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../core/chats/attachments.dart';

/// Что прикрепить из «+» → «Прикрепить файл» (ADR-019).
enum PickKind {
  photo('Фото', Icons.image_outlined),
  video('Видео', Icons.movie_outlined),
  audio('Аудио', Icons.audiotrack_outlined),
  document('Документ', Icons.description_outlined),
  any('Любой файл', Icons.insert_drive_file_outlined);

  const PickKind(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// Выбор файлов на устройстве. В приложении — системный выбор
/// ([FileSelectorAttachmentPicker]), в тестах — подделка.
abstract interface class AttachmentPicker {
  /// Файлы, которые выбрал пользователь; отменил — пустой список.
  Future<List<AttachmentSource>> pick(PickKind kind);
}

/// Системный выбор файлов (пакет file_selector: на Android — Storage
/// Access Framework, без разрешений). Файлы никуда не отправляются: их
/// копирует в папку сессии `ChatBook.attach`.
final class FileSelectorAttachmentPicker implements AttachmentPicker {
  const FileSelectorAttachmentPicker();

  static List<XTypeGroup> groupsFor(PickKind kind) => switch (kind) {
        PickKind.photo => const <XTypeGroup>[
            XTypeGroup(
              label: 'Фото',
              mimeTypes: <String>['image/*'],
              extensions: <String>[
                'jpg',
                'jpeg',
                'png',
                'webp',
                'heic',
                'gif',
              ],
              uniformTypeIdentifiers: <String>['public.image'],
            ),
          ],
        PickKind.video => const <XTypeGroup>[
            XTypeGroup(
              label: 'Видео',
              mimeTypes: <String>['video/*'],
              extensions: <String>['mp4', 'mov', 'mkv', 'webm', '3gp'],
              uniformTypeIdentifiers: <String>['public.movie'],
            ),
          ],
        PickKind.audio => const <XTypeGroup>[
            XTypeGroup(
              label: 'Аудио',
              mimeTypes: <String>['audio/*'],
              extensions: <String>['mp3', 'm4a', 'aac', 'ogg', 'opus', 'wav'],
              uniformTypeIdentifiers: <String>['public.audio'],
            ),
          ],
        PickKind.document => const <XTypeGroup>[
            XTypeGroup(
              label: 'Документы',
              mimeTypes: <String>[
                'application/pdf',
                'text/*',
                'application/msword',
                'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
                'application/vnd.ms-excel',
                'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
                'application/vnd.oasis.opendocument.text',
              ],
              extensions: <String>[
                'pdf',
                'txt',
                'doc',
                'docx',
                'xls',
                'xlsx',
                'odt',
              ],
              uniformTypeIdentifiers: <String>['public.content'],
            ),
          ],
        PickKind.any => const <XTypeGroup>[],
      };

  @override
  Future<List<AttachmentSource>> pick(PickKind kind) async {
    final files = await openFiles(acceptedTypeGroups: groupsFor(kind));
    return <AttachmentSource>[for (final file in files) XFileSource(file)];
  }
}

/// [XFile] как источник вложения: копируется [XFile.saveTo] (на диске —
/// копированием файла, без чтения в память).
final class XFileSource implements AttachmentSource {
  const XFileSource(this.file);

  final XFile file;

  @override
  String get name => file.name;

  @override
  String? get mimeType => file.mimeType;

  @override
  Future<int> length() => file.length();

  @override
  Future<void> saveTo(String path) => file.saveTo(path);

  @override
  Future<Uint8List> readAsBytes() => file.readAsBytes();
}

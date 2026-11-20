import 'package:flutter/material.dart';

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

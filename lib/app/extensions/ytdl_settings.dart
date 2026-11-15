import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../assistant_theme.dart';
import 'ytdl_kit.dart';
import '../widgets/whole_word_text.dart';

/// Предупреждение перед включением загрузчика видео (решение владельца):
/// правила площадок. `true` — «Понятно, включить».
Future<bool> showYtdlWarning(BuildContext context) async {
  final accepted = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      scrollable: true,
      title: const WholeWordText('Включить загрузчик видео?'),
      content: const Text(
        'Правила YouTube и других площадок запрещают скачивание без '
        'разрешения. Скачивайте только своё или то, на что есть права.\n\n'
        'Видео скачивает программа yt-dlp: она скачивается отдельно, по '
        'кнопке. Ссылка уходит только в неё — помощники и подключения её не '
        'видят.',
        key: ValueKey<String>('ytdl-warning-text'),
      ),
      actions: <Widget>[
        TextButton(
          key: const ValueKey<String>('ytdl-warning-cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Отмена'),
        ),
        TextButton(
          key: const ValueKey<String>('ytdl-warning-accept'),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Понятно, включить'),
        ),
      ],
    ),
  );
  return accepted ?? false;
}

/// Выбор папки загрузок; в тестах — подделка.
typedef FolderPicker = Future<String?> Function(String? initialDirectory);

Future<String?> _pickFolder(String? initialDirectory) =>
    getDirectoryPath(initialDirectory: initialDirectory);

/// Папка загрузок на экране «Загрузчик видео: yt-dlp»: где лежат
/// скачанные файлы, «Изменить» и «По умолчанию».
final class YtdlFolderSetting extends StatefulWidget {
  const YtdlFolderSetting({
    super.key,
    required this.kit,
    this.pickFolder = _pickFolder,
  });

  final YtdlKit kit;
  final FolderPicker pickFolder;

  @override
  State<YtdlFolderSetting> createState() => _YtdlFolderSettingState();
}

final class _YtdlFolderSettingState extends State<YtdlFolderSetting> {
  String? _folder;

  @override
  void initState() {
    super.initState();
    widget.kit.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    widget.kit.removeListener(_load);
    super.dispose();
  }

  void _load() {
    unawaited(
      widget.kit.folder().then((String? folder) {
        if (mounted) setState(() => _folder = folder);
      }),
    );
  }

  Future<void> _change() async {
    final picked = await widget.pickFolder(_folder);
    if (picked == null || picked.isEmpty) return;
    await widget.kit.setFolder(picked);
  }

  @override
  Widget build(BuildContext context) {
    final custom = widget.kit.customFolder != null;
    return Padding(
      padding: const EdgeInsets.only(top: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Папка загрузок',
            style: TextStyle(
              color: context.colors.textStrong,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _folder ?? 'Папка загрузок не найдена — выберите её',
            key: const ValueKey<String>('ytdl-folder'),
            style: metaStyle(context),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              OutlinedButton(
                key: const ValueKey<String>('ytdl-folder-change'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 44),
                ),
                onPressed: _change,
                child: const Text('Изменить'),
              ),
              if (custom)
                TextButton(
                  key: const ValueKey<String>('ytdl-folder-reset'),
                  style: TextButton.styleFrom(minimumSize: const Size(0, 44)),
                  onPressed: () => unawaited(widget.kit.setFolder(null)),
                  child: const Text('По умолчанию'),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            'Для «Только звук (mp3)» и качества выше цельного файла нужен '
            'ffmpeg: Настройки → Расширения → Конвертер → Настроить. Полная '
            'поддержка YouTube требует JavaScript-движка deno — приложение '
            'его не ставит, поэтому часть роликов YouTube может не скачаться.',
            style: metaStyle(context),
          ),
        ],
      ),
    );
  }
}

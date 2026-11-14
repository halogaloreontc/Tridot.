import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/extensions/tools/tool_spec.dart';
import '../assistant_theme.dart';
import 'tool_kit.dart';

/// Мегабайты для подписей: «12 из 161 МБ».
String toolMegabytes(int bytes) => (bytes / (1024 * 1024)).round().toString();

/// Сколько места нужно на время установки: архив и распакованный архив
/// (tar) рядом с программой.
int toolInstallBytes(ToolSpec spec) => switch (spec.archive) {
      ToolArchive.tarXz => spec.bytes + 3 * spec.binaryBytes + spec.binaryBytes,
      ToolArchive.zip => spec.bytes + spec.binaryBytes,
      // Скачанный файл и есть программа.
      ToolArchive.none => spec.bytes,
    };

/// Тексты экрана и предложения для одной внешней программы: ffmpeg
/// конвертера или yt-dlp загрузчика видео.
final class ToolCopy {
  const ToolCopy({
    required this.name,
    required this.screenTitle,
    required this.intro,
    required this.source,
    required this.offerBody,
    required this.deleteBody,
    required this.missing,
    required this.installed,
    this.updatable = false,
  });

  /// Имя программы: «ffmpeg», «yt-dlp».
  final String name;

  /// Заголовок экрана «Настроить».
  final String screenTitle;

  /// Первый абзац экрана: зачем программа.
  final String intro;

  /// Источник: «сборка FFmpeg-Builds (BtbN) на GitHub».
  final String source;

  /// Текст предложения скачать: зачем и что без неё.
  final String offerBody;

  /// Что пропадёт после «Удалить».
  final String deleteBody;

  /// Статус «не скачан»: что работает без программы.
  final String missing;

  /// Статус «установлен».
  final String installed;

  /// Есть кнопка «Обновить» (yt-dlp).
  final bool updatable;

  static const ToolCopy ffmpeg = ToolCopy(
    name: 'ffmpeg',
    screenTitle: 'Конвертер: ffmpeg',
    intro: 'Картинки конвертер обрабатывает сам. Для звука и видео нужна '
        'программа ffmpeg: она не входит в приложение и скачивается один '
        'раз по кнопке ниже.',
    source: 'сборка FFmpeg-Builds (BtbN) на GitHub',
    offerBody: 'Звук и видео конвертер обрабатывает программой ffmpeg. Она '
        'не входит в приложение и скачивается один раз.',
    deleteBody: 'Звук и видео конвертировать будет нельзя, картинки — '
        'можно. Скачать заново можно в любой момент.',
    missing: 'ffmpeg не скачан — работают только картинки',
    installed: 'ffmpeg установлен: картинки, звук и видео',
  );

  static const ToolCopy ytdlp = ToolCopy(
    name: 'yt-dlp',
    screenTitle: 'Загрузчик видео: yt-dlp',
    intro: 'Видео и звук по ссылке скачивает программа yt-dlp: она не '
        'входит в приложение и скачивается один раз по кнопке ниже. '
        'Ссылка уходит только в yt-dlp — помощники и подключения её не '
        'видят.',
    source: 'официальный релиз yt-dlp на GitHub',
    offerBody: 'Видео по ссылке скачивает программа yt-dlp. Она не входит в '
        'приложение и скачивается один раз. Для mp3 и качества выше '
        'цельного файла нужен ещё ffmpeg (Конвертер).',
    deleteBody: 'Скачивать видео по ссылке будет нельзя, пока yt-dlp не '
        'скачан заново.',
    missing: 'yt-dlp не скачан — загрузка видео недоступна',
    installed: 'yt-dlp установлен',
    updatable: true,
  );
}

/// Предложение скачать программу при включении расширения: размер,
/// источник, лицензия. `true` — «Скачать».
Future<bool> showToolOffer(
  BuildContext context,
  ToolKit kit, {
  ToolCopy copy = ToolCopy.ffmpeg,
}) async {
  final spec = kit.spec;
  final download = await showDialog<bool>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      scrollable: true,
      backgroundColor: AssistantColors.raised,
      title: Text('Скачать ${copy.name}?'),
      content: Text(
        '${copy.offerBody} Загрузка ~${toolMegabytes(spec.bytes)} МБ, после '
        'установки займёт ~${toolMegabytes(spec.binaryBytes)} МБ. Источник '
        '— ${copy.source}, лицензия: ${spec.license}; файл проверяется по '
        'контрольной сумме.',
      ),
      actions: <Widget>[
        TextButton(
          key: const ValueKey<String>('tool-offer-later'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Позже'),
        ),
        TextButton(
          key: const ValueKey<String>('tool-offer-download'),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text('Скачать (~${toolMegabytes(spec.bytes)} МБ)'),
        ),
      ],
    ),
  );
  return download ?? false;
}

/// Строка состояния программы в плитке расширения.
String toolStatus(ToolKit kit, {ToolCopy copy = ToolCopy.ffmpeg}) =>
    switch (kit.phase) {
      ToolPhase.installed => copy.installed,
      ToolPhase.downloading => '${copy.name} скачивается: '
          '${toolMegabytes(kit.received)} из ${toolMegabytes(kit.spec.bytes)} МБ',
      ToolPhase.verifying => '${copy.name}: проверка контрольной суммы…',
      ToolPhase.installing => '${copy.name}: установка…',
      ToolPhase.error =>
        '${copy.name} не установлен: ${kit.error?.message ?? ''}',
      ToolPhase.notInstalled => kit.olderVersion != null
          ? '${copy.name} ${kit.olderVersion} устарел — обновите до '
              '${kit.spec.version}'
          : copy.missing,
    };

/// «Настройки → Расширения → … → Настроить»: скачать, отменить, обновить,
/// удалить программу. [autoStart] — начать загрузку сразу (из предложения
/// при включении). [extra] — настройки расширения под кнопками (папка
/// загрузок).
final class ToolScreen extends StatefulWidget {
  const ToolScreen({
    super.key,
    required this.kit,
    this.autoStart = false,
    this.copy = ToolCopy.ffmpeg,
    this.extra = const <Widget>[],
  });

  final ToolKit kit;
  final bool autoStart;
  final ToolCopy copy;
  final List<Widget> extra;

  @override
  State<ToolScreen> createState() => _ToolScreenState();
}

final class _ToolScreenState extends State<ToolScreen> {
  /// Ответ на «Обновить», когда новее закреплённой версии нет.
  String? _updateNote;

  @override
  void initState() {
    super.initState();
    widget.kit.addListener(_changed);
    if (widget.autoStart && !widget.kit.isInstalled && !widget.kit.isBusy) {
      _install();
    }
  }

  @override
  void dispose() {
    widget.kit.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// «Обновить»: ставится только версия, закреплённая в этой сборке
  /// приложения (`yt-dlp -U` обошёл бы закреплённую сумму, ADR-024).
  void _update() {
    final kit = widget.kit;
    if (kit.isInstalled) {
      setState(
        () => _updateNote = 'Установлена последняя версия, известная '
            'приложению (${kit.spec.version}). Новые версии приходят с '
            'обновлением приложения.',
      );
      return;
    }
    _install();
  }

  void _install() {
    _updateNote = null;
    // Ошибки установка показывает сама (фаза error); здесь — только
    // сборка без закреплённой суммы, её кнопки и так нет.
    unawaited(widget.kit.install().catchError((Object _) {}));
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        backgroundColor: AssistantColors.raised,
        title: Text('Удалить ${widget.copy.name}?'),
        content: Text(widget.copy.deleteBody),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Отмена'),
          ),
          TextButton(
            key: const ValueKey<String>('tool-delete-confirm'),
            style: TextButton.styleFrom(
              foregroundColor: AssistantColors.danger,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) await widget.kit.delete();
  }

  @override
  Widget build(BuildContext context) {
    final kit = widget.kit;
    final spec = kit.spec;
    final busy = kit.isBusy;
    final copy = widget.copy;
    return Scaffold(
      backgroundColor: AssistantColors.workspace,
      appBar: AppBar(title: Text(copy.screenTitle)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Text(copy.intro),
          const SizedBox(height: 12),
          Text(
            'Размер загрузки ~${toolMegabytes(spec.bytes)} МБ, после '
            'установки займёт ~${toolMegabytes(spec.binaryBytes)} МБ; на '
            'время установки нужно ~${toolMegabytes(toolInstallBytes(spec))} '
            'МБ свободного места.',
            key: const ValueKey<String>('tool-size'),
            style: metaTextStyle,
          ),
          const SizedBox(height: 6),
          Text(
            'Источник: ${copy.source}, ${spec.version}. '
            'Лицензия: ${spec.license}. Исходники и скрипты сборки: '
            '${spec.sourceUrl}. Файл проверяется по закреплённой в '
            'приложении контрольной сумме SHA-256.',
            style: metaTextStyle,
          ),
          const SizedBox(height: 16),
          Semantics(
            liveRegion: true,
            child: Text(
              toolStatus(kit, copy: copy),
              key: const ValueKey<String>('tool-status'),
              style: TextStyle(
                color: kit.phase == ToolPhase.error
                    ? AssistantColors.danger
                    : AssistantColors.textStrong,
              ),
            ),
          ),
          if (busy) ...<Widget>[
            const SizedBox(height: 8),
            LinearProgressIndicator(
              value: kit.phase == ToolPhase.downloading && spec.bytes > 0
                  ? kit.received / spec.bytes
                  : null,
            ),
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              if (!kit.isInstalled &&
                  !busy &&
                  spec.available &&
                  !(copy.updatable && kit.olderVersion != null))
                FilledButton.icon(
                  key: const ValueKey<String>('tool-download'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AssistantColors.textStrong,
                    foregroundColor: AssistantColors.workspace,
                    minimumSize: const Size(0, 44),
                  ),
                  onPressed: _install,
                  icon: const Icon(Icons.download, size: 18),
                  label: Text(
                    kit.hasPartial
                        ? 'Продолжить загрузку'
                        : 'Скачать (~${toolMegabytes(spec.bytes)} МБ)',
                  ),
                ),
              if (copy.updatable &&
                  !busy &&
                  spec.available &&
                  (kit.isInstalled || kit.olderVersion != null))
                OutlinedButton.icon(
                  key: const ValueKey<String>('tool-update'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 44),
                  ),
                  onPressed: _update,
                  icon: const Icon(Icons.system_update_alt, size: 18),
                  label: Text(
                    kit.olderVersion != null && !kit.isInstalled
                        ? 'Обновить до ${spec.version} '
                            '(~${toolMegabytes(spec.bytes)} МБ)'
                        : 'Обновить',
                  ),
                ),
              if (kit.phase == ToolPhase.downloading)
                OutlinedButton(
                  key: const ValueKey<String>('tool-cancel'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 44),
                  ),
                  onPressed: kit.cancel,
                  child: const Text('Отмена'),
                ),
              if (kit.isInstalled ||
                  (!busy && (kit.hasPartial || kit.olderVersion != null)))
                OutlinedButton(
                  key: const ValueKey<String>('tool-delete'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 44),
                    foregroundColor: AssistantColors.danger,
                  ),
                  onPressed: _delete,
                  child: const Text('Удалить'),
                ),
            ],
          ),
          if (_updateNote case final String note)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                note,
                key: const ValueKey<String>('tool-update-note'),
                style: metaTextStyle,
              ),
            ),
          if (!spec.available)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                'В этой сборке приложения ${copy.name} скачать нельзя: нет '
                'проверенной контрольной суммы.',
                key: const ValueKey<String>('tool-unavailable'),
                style: metaTextStyle,
              ),
            ),
          ...widget.extra,
        ],
      ),
    );
  }
}

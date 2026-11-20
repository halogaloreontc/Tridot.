import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/chats/attachments.dart';
import '../../core/cloud/cloud_disk.dart';
import '../../core/commands/command_catalog.dart';
import '../assistant_theme.dart';
import '../layout.dart';
import '../attachments/attachment_chip.dart';
import '../attachments/pick_kind.dart';
import 'command_finder_sheet.dart';
import 'grouped.dart' show segmentThumbShadow;
import 'whole_word_text.dart';

enum AssistantViewMode { dialogue, document }

/// Кнопка голосового ввода (ADR-023).
enum VoiceButtonMode {
  /// Движка на платформе нет: микрофона нет.
  hidden,

  /// Голосовой ввод выключен или модель не скачана: нажатие предлагает
  /// включить.
  off,

  /// Готов: нажать (или долго нажать на пустое поле) и говорить.
  idle,

  /// Загружается модель или запрашивается доступ к микрофону.
  loading,

  /// Слушает.
  listening,
}

/// Долгое нажатие на пустое поле ввода, после которого начинается
/// голосовой ввод: короче системного долгого нажатия (0,5 с), чтобы
/// успеть раньше меню «Вставить» поля.
const Duration voiceLongPressDuration = Duration(milliseconds: 400);

/// Файл, выбранный для следующего сообщения: чип над полем ввода.
final class PendingAttachmentChip {
  const PendingAttachmentChip({
    required this.name,
    required this.kind,
    required this.size,
  });

  final String name;
  final AttachmentKind kind;
  final int size;
}

/// Пункт «Найти команду» в «+» → «Шаблоны команд».
final class _FindCommand {
  const _FindCommand();
}

/// Поле команды. Не блокируется во время отправки, чтобы не терять фокус:
/// повторную отправку отсекает хозяин.
final class CommandComposer extends StatefulWidget {
  const CommandComposer({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.sending,
    required this.mode,
    required this.onModeChanged,
    required this.onSend,
    required this.onCommand,
    required this.previousCommand,
    required this.nextCommand,
    this.onAttach,
    this.onCloudDisk,
    this.onConnectDisk,
    this.cloudDisks = const <CloudDisk>[],
    this.templates = const <CommandEntry>[],
    this.onFindCommand,
    this.pending = const <PendingAttachmentChip>[],
    this.onRemovePending,
    this.header,
    this.voiceMode = VoiceButtonMode.hidden,
    this.onVoiceTap,
    this.onVoiceLongPress,
    this.onVoiceCancel,
    this.voicePartial,
    this.voiceNotice,
    this.hint = 'Сообщение',
    this.modes = true,
    this.plus = true,
    this.inputKey = const Key('assistant-input'),
    this.sendKey = const Key('assistant-send'),
    this.maxLength,
  });

  /// Подсказка в пустом поле.
  final String hint;

  /// Переключатель «Диалог / Документ» посередине нижней строки; веб-помощник
  /// склада (ADR-038) — без документа.
  final bool modes;

  /// «+» — файлы, диски, шаблоны; в веб-помощнике их нет.
  final bool plus;

  /// Ключи поля и отправки: у веб-помощника — свои (`widget-input`,
  /// `widget-send`), их ждут проверки склада.
  final Key inputKey;
  final Key sendKey;

  /// Наибольшая длина текста; `null` — без ограничения.
  final int? maxLength;

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool sending;
  final AssistantViewMode mode;
  final ValueChanged<AssistantViewMode> onModeChanged;
  final VoidCallback onSend;

  /// Команда из «+» → «Шаблоны команд» (ADR-020).
  final ValueChanged<CommandEntry> onCommand;

  /// «+» → «Прикрепить файл» → вид файла (ADR-019).
  final ValueChanged<PickKind>? onAttach;

  /// «+» → «Облачный диск» → подключённый диск.
  final ValueChanged<CloudDisk>? onCloudDisk;

  /// «+» → «Облачный диск» → «Подключить диск» (ни одного не подключено).
  final VoidCallback? onConnectDisk;

  /// Подключённые облачные диски ([CloudDiskMenu.entries]).
  final List<CloudDisk> cloudDisks;

  /// Частые команды в «+» → «Шаблоны команд» ([CommandCatalog.top]).
  final List<CommandEntry> templates;

  /// «Найти команду» — пятый пункт «Шаблонов команд»; `null` — пункта нет.
  final VoidCallback? onFindCommand;

  /// Файлы, выбранные для следующего сообщения.
  final List<PendingAttachmentChip> pending;

  /// Крестик на чипе файла [pending]`[i]`.
  final ValueChanged<int>? onRemovePending;

  /// Микрофон при пустом поле (ADR-023): голосовой ввод в поле, без
  /// озвучивания ответов.
  final VoiceButtonMode voiceMode;

  /// Нажатие на микрофон: при [VoiceButtonMode.off] — предложение
  /// включить, иначе — начать слушать, а пока слушает — закончить с
  /// итогом (на всех платформах, и для экранного диктора).
  final VoidCallback? onVoiceTap;

  /// Долгое нажатие пальцем на пустое поле ввода (только в
  /// [VoiceButtonMode.idle]): начать слушать. С текстом, с файлами и
  /// мышью — обычное выделение и меню «Вставить».
  final VoidCallback? onVoiceLongPress;

  /// Крестик на месте «+», пока слушает или готовится: прервать без
  /// итога.
  final VoidCallback? onVoiceCancel;

  /// Промежуточный распознанный текст: серой строкой над полем, пока
  /// слушает.
  final String? voicePartial;

  /// Подсказка голосового ввода («Нет доступа к микрофону…», «Микрофон
  /// выключен…»): строкой над полем, а не всплывающим уведомлением —
  /// уведомление закрыло бы сам микрофон.
  final String? voiceNotice;

  /// Прошлая и следующая команда из истории для ↑/↓; null — нет.
  final String? Function() previousCommand;
  final String? Function() nextCommand;

  /// Строка над полем: выбор адресата в дуэте помощников.
  final Widget? header;

  @override
  State<CommandComposer> createState() => _CommandComposerState();
}

final class _CommandComposerState extends State<CommandComposer>
    with WidgetsBindingObserver {
  /// Экранная клавиатура была открыта (нижний отступ окна больше нуля).
  bool _keyboardShown = false;

  @override
  void initState() {
    super.initState();
    widget.focusNode.onKeyEvent = _onKey;
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Клавиатуру на телефоне закрыли («Назад», кнопка клавиатуры) — поле
  /// теряет фокус. Иначе фокус остаётся «тихим», и после меню, листа или
  /// диалога экран вернул бы его полю, а с ним и клавиатуру, о которой
  /// никто не просил. Отступ берём у окна: у тела Scaffold его уже
  /// вычли.
  @override
  void didChangeMetrics() {
    final view = View.maybeOf(context);
    if (view == null) return;
    final shown = view.viewInsets.bottom > 0;
    final closed = _keyboardShown && !shown;
    _keyboardShown = shown;
    if (!closed || !widget.focusNode.hasPrimaryFocus) return;
    final mobile = switch (defaultTargetPlatform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      _ => false,
    };
    if (mobile) widget.focusNode.unfocus();
  }

  @override
  void didUpdateWidget(covariant CommandComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      widget.focusNode.onKeyEvent = _onKey;
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final shift = HardwareKeyboard.instance.isShiftPressed;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (shift) {
        _insert('\n');
      } else if (!widget.sending) {
        widget.onSend();
      }
      return KeyEventResult.handled;
    }
    final text = widget.controller.text;
    final singleLine = !text.contains('\n');
    if (key == LogicalKeyboardKey.arrowUp && singleLine) {
      return _recall(widget.previousCommand());
    }
    if (key == LogicalKeyboardKey.arrowDown && singleLine) {
      return _recall(widget.nextCommand());
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _recall(String? command) {
    if (command == null) return KeyEventResult.ignored;
    widget.controller.value = TextEditingValue(
      text: command,
      selection: TextSelection.collapsed(offset: command.length),
    );
    return KeyEventResult.handled;
  }

  void _insert(String text) {
    final value = widget.controller.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final updated =
        value.text.replaceRange(selection.start, selection.end, text);
    widget.controller.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: selection.start + text.length),
    );
  }

  /// «+»: три пункта со своими списками — «Облачный диск», «Прикрепить
  /// файл», «Шаблоны команд» (действия сейфа — там же, в «Найти
  /// команду»). Выбор
  /// выполняется после закрытия листа: выбор файлов и диалоги открываются
  /// уже над экраном.
  Future<void> _openPlus() async {
    final choice = await showModalBottomSheet<Object>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (BuildContext context) => _PlusSheet(
        cloudDisks: widget.cloudDisks,
        canAttach: widget.onAttach != null,
        templates: widget.templates,
        canFind: widget.onFindCommand != null,
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case CommandEntry entry:
        widget.onCommand(entry);
      case _FindCommand _:
        widget.onFindCommand?.call();
      case PickKind kind:
        widget.onAttach?.call(kind);
      case CloudDisk disk:
        widget.onCloudDisk?.call(disk);
      case CloudDiskConnect _:
        widget.onConnectDisk?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (BuildContext context, _) {
        // Файлы можно отправить и без текста.
        final hasText = widget.controller.text.trim().isNotEmpty ||
            widget.pending.isNotEmpty;
        final voiceMode = widget.voiceMode;
        final voiceActive = voiceMode == VoiceButtonMode.listening ||
            voiceMode == VoiceButtonMode.loading;
        // Пустое поле — микрофон для голосового ввода, с текстом — кнопка
        // отправки. Пока слушает, на месте микрофона — «стоп»: им же
        // заканчивают.
        final voice = voiceMode != VoiceButtonMode.hidden &&
            (voiceActive || (!hasText && !widget.sending));
        // Долгое нажатие на пустое поле — тоже голосовой ввод, но только
        // когда он готов: выключенный не перехватывает «Вставить».
        // Именно пустое: пробелы в поле — уже текст, долгое нажатие
        // оставляет меню «Вставить».
        final longPressVoice = voiceMode == VoiceButtonMode.idle &&
            widget.controller.text.isEmpty &&
            widget.pending.isEmpty &&
            !widget.sending &&
            widget.onVoiceLongPress != null;
        final partial = widget.voicePartial?.trim() ?? '';
        final notice = widget.voiceNotice?.trim() ?? '';
        final showPartial =
            voiceMode == VoiceButtonMode.listening && partial.isNotEmpty;
        final hintStyle = TextStyle(
          fontSize: 16,
          color: context.colors.faint,
        );
        final hint = switch (voiceMode) {
          VoiceButtonMode.listening => 'Говорите…',
          VoiceButtonMode.loading => 'Готовлю распознавание…',
          _ => widget.hint,
        };
        final plus = Tooltip(
          message: 'Файлы, диски и шаблоны команд',
          child: InkResponse(
            key: const Key('templates-button'),
            onTap: _openPlus,
            radius: 24,
            child: const _RoundIcon(icon: Icons.add),
          ),
        );
        // Пока слушает или готовится, на месте «+» — крестик: прервать без
        // итога.
        final Widget left = voiceActive
            ? Tooltip(
                message: 'Отменить без текста',
                // Подсказка — только наведением мыши: долгое касание у
                // Tooltip отняло бы нажатие.
                triggerMode: TooltipTriggerMode.manual,
                child: Semantics(
                  button: true,
                  label: 'Отменить голосовой ввод',
                  onTap: widget.onVoiceCancel,
                  excludeSemantics: true,
                  child: InkResponse(
                    key: const Key('voice-abort'),
                    onTap: widget.onVoiceCancel,
                    onLongPress: widget.onVoiceCancel,
                    radius: 24,
                    child: const _RoundIcon(icon: Icons.close),
                  ),
                ),
              )
            : plus;
        // Пустое поле — микрофон (если голос есть), с текстом — круг
        // акцента со стрелкой.
        final send = voice
            ? _VoiceButton(mode: voiceMode, onTap: widget.onVoiceTap)
            : DecoratedBox(
                // Та же тень, что у «+»: круги одного вида.
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  boxShadow: hasText ? null : _controlShadow(context),
                ),
                child: IconButton(
                  key: widget.sendKey,
                  // Пустое поле отправка и так пропускает; кнопка лишь тише,
                  // а не выключена: набранный только что текст уходит, даже
                  // если кадр ещё не перерисован.
                  onPressed: widget.sending ? null : widget.onSend,
                  tooltip: 'Отправить',
                  style: IconButton.styleFrom(
                    // Тема даёт кнопкам minimumSize 48 — тогда круг крупнее «+».
                    fixedSize: const Size.square(AppSize.sendButton),
                    minimumSize: const Size.square(AppSize.sendButton),
                    // Пустое — круг цвета выбранного сегмента «Диалог /
                    // Документ»: на панели поля ([AppPalette.raised]) он
                    // виден, а не сливается с ней.
                    backgroundColor: hasText
                        ? context.colors.accent
                        : context.colors.fieldOnRaised,
                    foregroundColor: hasText
                        ? context.colors.onAccent
                        : context.colors.faint,
                    disabledBackgroundColor: context.colors.fieldOnRaised,
                    shadowColor: context.colors.shadow,
                    surfaceTintColor: Colors.transparent,
                    elevation: 0,
                    disabledForegroundColor: context.colors.faint,
                  ),
                  icon: widget.sending
                      ? SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: context.colors.muted,
                          ),
                        )
                      : const Icon(Icons.arrow_upward, size: 22),
                ),
              );
        // Поле ввода — одна панель заливкой без рамок (ADR-027): сверху
        // текст во всю ширину, снизу «+», переключатель «Диалог /
        // Документ» ровно посередине и отправка или микрофон. Текст во всю
        // ширину не рвёт слова и при крупном шрифте.
        final Widget input = RawGestureDetector(
          key: const Key('assistant-input-gestures'),
          behavior: HitTestBehavior.deferToChild,
          gestures: longPressVoice
              ? <Type, GestureRecognizerFactory>{
                  LongPressGestureRecognizer:
                      GestureRecognizerFactoryWithHandlers<
                          LongPressGestureRecognizer>(
                    () => LongPressGestureRecognizer(
                      duration: voiceLongPressDuration,
                      // Мышью долгое нажатие — обычное выделение.
                      supportedDevices: const <PointerDeviceKind>{
                        PointerDeviceKind.touch,
                        PointerDeviceKind.stylus,
                      },
                      debugOwner: this,
                    ),
                    (LongPressGestureRecognizer recognizer) {
                      recognizer.onLongPress = () {
                        Feedback.forLongPress(context);
                        widget.onVoiceLongPress?.call();
                      };
                    },
                  ),
                }
              : const <Type, GestureRecognizerFactory>{},
          // Тоже всегда на месте (меняется только подсказка): жест
          // для экранного диктора.
          child: Semantics(
            key: const Key('assistant-input-semantics'),
            hint: longPressVoice
                ? 'Долгое нажатие на пустое поле — голосовой ввод'
                : null,
            child: TextField(
              key: widget.inputKey,
              controller: widget.controller,
              maxLength: widget.maxLength,
              focusNode: widget.focusNode,
              // Одна строка растёт до шести (ADR-027).
              minLines: 1,
              maxLines: 6,
              textInputAction: TextInputAction.send,
              textCapitalization: TextCapitalization.sentences,
              onSubmitted: (_) {
                if (!widget.sending) widget.onSend();
              },
              style: TextStyle(
                fontSize: 16,
                color: context.colors.textStrong,
              ),
              decoration: InputDecoration(
                // Подсказка не рвёт слово: одно слово на узкой
                // капсуле с шрифтом 200 % уменьшается целиком,
                // фраза переносится по словам (до трёх строк).
                hint: hint.contains(' ')
                    ? WholeWordText(
                        hint,
                        maxLines: 3,
                        style: hintStyle,
                      )
                    : fitSingleWord(hint, style: hintStyle),
                // Ни рамки, ни рамки фокуса: поле — заливкой.
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                errorBorder: InputBorder.none,
                focusedErrorBorder: InputBorder.none,
                filled: false,
                contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                isDense: true,
                counterText: '',
              ),
            ),
          ),
        );
        return Container(
          key: const Key('assistant-composer'),
          margin: const EdgeInsets.only(top: 8),
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
          decoration: BoxDecoration(
            color: context.colors.raised,
            borderRadius: BorderRadius.circular(AppRadius.bubble + 4),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (widget.header case final Widget header)
                Align(alignment: Alignment.centerLeft, child: header),
              if (widget.pending.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: <Widget>[
                        for (var i = 0; i < widget.pending.length; i++)
                          AttachmentChip(
                            key: Key('pending-attachment-$i'),
                            name: widget.pending[i].name,
                            kind: widget.pending[i].kind,
                            size: widget.pending[i].size,
                            onRemove: widget.onRemovePending == null
                                ? null
                                : () => widget.onRemovePending!(i),
                          ),
                      ],
                    ),
                  ),
                ),
              // Что слышно сейчас: серым, пока говорят. В поле текст
              // попадает только после того, как нажат «стоп».
              if (showPartial)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      partial,
                      key: const Key('voice-partial'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: context.colors.muted,
                        fontStyle: FontStyle.italic,
                        fontSize: 16,
                      ),
                    ),
                  ),
                ),
              if (!showPartial && notice.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        notice,
                        key: const Key('voice-notice'),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: context.colors.text,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ),
                ),
              input,
              LayoutBuilder(
                builder: (BuildContext context, BoxConstraints c) {
                  // Подписи — если помещаются целиком: «+» и отправка по
                  // 44, зазоры, у каждого сегмента поля 12 + иконка 17 +
                  // зазор 6 + подпись по её реальной ширине + 12.
                  final labels = c.maxWidth >=
                      2 * 44 +
                          16 +
                          2 * (24 + 17 + 6) +
                          _ModeSwitch.labelsWidth(context);
                  return Row(
                    children: <Widget>[
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: widget.plus || voiceActive
                              ? left
                              : const SizedBox(height: AppSize.sendButton),
                        ),
                      ),
                      if (widget.modes)
                        _ModeSwitch(
                          mode: widget.mode,
                          onChanged: widget.onModeChanged,
                          labels: labels,
                        ),
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: send,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Микрофон (ADR-023), 44×44 — как кнопка отправки на его месте. На
/// всех платформах — нажатие: нажал — слушает (красный «стоп»), нажал
/// снова — итог в поле. Держать палец, пока говоришь, не нужно. Экранный
/// диктор нажимает двойным касанием — то же самое.
final class _VoiceButton extends StatelessWidget {
  const _VoiceButton({required this.mode, required this.onTap});

  final VoiceButtonMode mode;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final listening = mode == VoiceButtonMode.listening;
    final loading = mode == VoiceButtonMode.loading;
    final off = mode == VoiceButtonMode.off;
    final tooltip = switch (mode) {
      VoiceButtonMode.off => 'Голосовой ввод',
      VoiceButtonMode.listening => 'Говорите… нажмите, чтобы закончить',
      VoiceButtonMode.loading => 'Готовлю распознавание… нажмите, чтобы '
          'отменить',
      _ => 'Голосовой ввод: нажмите и говорите',
    };
    final Widget icon = loading
        ? SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: context.colors.onAccent,
            ),
          )
        : Icon(
            listening ? Icons.stop_rounded : Icons.mic_none,
            size: listening ? 22 : 22,
            color: off
                ? context.colors.icon
                : listening
                    ? context.colors.onPrimary
                    : context.colors.onAccent,
          );
    final circle = AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      width: 44,
      height: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: listening
            ? context.colors.danger
            : off
                ? context.colors.fieldOnRaised
                : context.colors.accent,
        boxShadow: off ? _controlShadow(context) : null,
      ),
      child: icon,
    );
    return Semantics(
      button: true,
      label: 'Голосовой ввод',
      value: listening
          ? 'слушаю'
          : loading
              ? 'готовлю'
              : null,
      hint: listening
          ? 'нажмите, чтобы закончить'
          : loading
              ? 'нажмите, чтобы отменить'
              : null,
      onTap: onTap,
      excludeSemantics: true,
      child: Tooltip(
        message: tooltip,
        excludeFromSemantics: true,
        // Подсказка — только наведением мыши. Долгое касание Tooltip
        // забрал бы себе, и удержание микрофона (старая привычка «нажал и
        // держи») не делало бы ничего; удержание здесь — то же нажатие.
        triggerMode: TooltipTriggerMode.manual,
        child: InkResponse(
          key: const Key('assistant-voice'),
          onTap: onTap,
          onLongPress: onTap,
          radius: 24,
          child: circle,
        ),
      ),
    );
  }
}

final class _RoundIcon extends StatelessWidget {
  const _RoundIcon({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    // Круг цвета выбранного сегмента «Диалог / Документ» (а не панели
    // поля — тогда он пропадает и остаётся один значок).
    return Container(
      width: AppSize.sendButton,
      height: AppSize.sendButton,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: context.colors.fieldOnRaised,
        boxShadow: _controlShadow(context),
      ),
      child: Icon(icon, size: 24, color: context.colors.icon),
    );
  }
}

/// Тонкая тень круглой кнопки на панели поля: в светлой теме белый круг на
/// светло-сером без неё почти не виден; в тёмной хватает заливки.
List<BoxShadow>? _controlShadow(BuildContext context) =>
    context.colors.brightness == Brightness.light
        ? <BoxShadow>[
            BoxShadow(
              color: context.colors.shadow,
              blurRadius: 2,
              offset: const Offset(0, .5),
            ),
          ]
        : null;

/// Компактный переключатель «Диалог / Документ»: капсула из двух иконок,
/// на широком поле — с подписями справа от иконок.
final class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({
    required this.mode,
    required this.onChanged,
    required this.labels,
  });

  final AssistantViewMode mode;
  final ValueChanged<AssistantViewMode> onChanged;
  final bool labels;

  /// Ширина обеих подписей при текущем шрифте и его масштабе.
  static double labelsWidth(BuildContext context) {
    var total = 0.0;
    for (final label in const <String>['Диалог', 'Документ']) {
      final painter = TextPainter(
        text: TextSpan(
          text: label,
          style: DefaultTextStyle.of(context).style.merge(
                const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
              ),
        ),
        textDirection: TextDirection.ltr,
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      total += painter.width;
      painter.dispose();
    }
    return total;
  }

  @override
  Widget build(BuildContext context) {
    // Видимая капсула — 44 (сегменты 40), а цель нажатия у каждого
    // сегмента — 48 (`AppSize.minTap`): дорожка рисуется позади.
    return Stack(
      alignment: Alignment.center,
      children: <Widget>[
        Positioned(
          left: 0,
          right: 0,
          child: Container(
            height: 44,
            // Сегменты заливкой, без рамок (ADR-027). Дорожка — внутри
            // панели поля: чуть темнее её, выбранный сегмент — светлее.
            decoration: BoxDecoration(
              color: context.colors.brightness == Brightness.dark
                  ? context.colors.workspace
                  : context.colors.bubble,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              _button(
                context,
                'Диалог',
                Icons.chat_bubble_outline,
                AssistantViewMode.dialogue,
                'mode-dialogue',
              ),
              _button(
                context,
                'Документ',
                Icons.edit_document,
                AssistantViewMode.document,
                'mode-document',
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _button(
    BuildContext context,
    String label,
    IconData icon,
    AssistantViewMode value,
    String key,
  ) {
    final active = mode == value;
    final color = active ? context.colors.textStrong : context.colors.muted;
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        selected: active,
        label: 'Режим: $label',
        onTap: () => onChanged(value),
        excludeSemantics: true,
        child: InkWell(
          key: Key(key),
          onTap: () => onChanged(value),
          borderRadius: BorderRadius.circular(999),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: AppSize.minTap,
              minWidth: AppSize.minTap,
            ),
            child: Center(
              widthFactor: 1,
              child: _segment(context, label, icon, active, color),
            ),
          ),
        ),
      ),
    );
  }

  Widget _segment(
    BuildContext context,
    String label,
    IconData icon,
    bool active,
    Color color,
  ) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      constraints: const BoxConstraints(minHeight: 40, minWidth: 44),
      alignment: Alignment.center,
      padding: EdgeInsets.symmetric(horizontal: labels ? 12 : 8),
      decoration: BoxDecoration(
        // Выбранный сегмент — «бегунок», как у вкладок «Мой Связной»: тот
        // же цвет и, в светлой теме, лёгкая тень (ADR-027).
        color: active ? context.colors.segmentSelected : Colors.transparent,
        borderRadius: BorderRadius.circular(999),
        boxShadow: active ? segmentThumbShadow(context) : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 17, color: color),
          if (labels) ...<Widget>[
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 14,
                fontWeight: active ? FontWeight.w500 : FontWeight.w400,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Лист «+» (ADR-019): у каждого из трёх пунктов свой раскрывающийся
/// список. Возвращает выбор: [CommandEntry], [_FindCommand], [PickKind],
/// [CloudDisk] или [CloudDiskConnect].
final class _PlusSheet extends StatefulWidget {
  const _PlusSheet({
    required this.cloudDisks,
    required this.canAttach,
    required this.templates,
    required this.canFind,
  });

  final List<CloudDisk> cloudDisks;
  final bool canAttach;
  final List<CommandEntry> templates;
  final bool canFind;

  @override
  State<_PlusSheet> createState() => _PlusSheetState();
}

enum _PlusGroup { cloud, attach, templates }

final class _PlusSheetState extends State<_PlusSheet> {
  _PlusGroup? _open;

  void _pick(Object value) => Navigator.of(context).pop(value);

  void _toggle(_PlusGroup group) =>
      setState(() => _open = _open == group ? null : group);

  @override
  Widget build(BuildContext context) {
    final cloud = CloudDiskMenu.entries(widget.cloudDisks);
    return SafeArea(
      child: SingleChildScrollView(
        key: const Key('composer-plus-sheet'),
        // Одна сгруппированная панель на фоне шторки (ADR-027).
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: _inset(
          context,
          <Widget>[
            // Один подключённый диск — пункт сразу открывает его, без
            // выбора диска.
            if (cloud case CloudDiskSingle(:final disk))
              _row(
                key: const Key('composer-cloud'),
                icon: Icons.cloud_outlined,
                label: 'Облачный диск',
                detail: disk.label,
                tile: context.colors.tileBlue,
                onTap: () => _pick(disk),
              )
            else
              ..._group(
                group: _PlusGroup.cloud,
                key: const Key('composer-cloud'),
                icon: Icons.cloud_outlined,
                label: 'Облачный диск',
                tile: context.colors.tileBlue,
                children: switch (cloud) {
                  CloudDiskChoice(:final disks) => <Widget>[
                      for (final disk in disks)
                        _row(
                          key: Key('cloud-${disk.name}'),
                          icon: Icons.folder_open_outlined,
                          label: disk.label,
                          onTap: () => _pick(disk),
                          nested: true,
                        ),
                    ],
                  _ => <Widget>[
                      _row(
                        key: const Key('cloud-connect'),
                        icon: Icons.add_link,
                        label: CloudDiskConnect.label,
                        detail: 'Яндекс Диск, Google Диск',
                        onTap: () => _pick(const CloudDiskConnect()),
                        nested: true,
                      ),
                    ],
                },
              ),
            if (widget.canAttach)
              ..._group(
                group: _PlusGroup.attach,
                key: const Key('composer-attach'),
                icon: Icons.attach_file,
                label: 'Прикрепить файл',
                tile: context.colors.tileGray,
                children: <Widget>[
                  for (final kind in PickKind.values)
                    _row(
                      key: Key('attach-${kind.name}'),
                      icon: kind.icon,
                      label: kind.label,
                      onTap: () => _pick(kind),
                      nested: true,
                    ),
                ],
              ),
            ..._group(
              group: _PlusGroup.templates,
              key: const Key('composer-templates'),
              icon: Icons.bolt,
              label: 'Шаблоны команд',
              tile: context.colors.tileViolet,
              children: <Widget>[
                for (final entry in widget.templates)
                  _row(
                    key: Key('command-top-${entry.id}'),
                    icon: commandIcon(entry.iconName),
                    label: entry.label,
                    onTap: () => _pick(entry),
                    nested: true,
                  ),
                if (widget.canFind)
                  _row(
                    key: const Key('command-find'),
                    icon: Icons.search,
                    label: 'Найти команду',
                    detail: 'Все команды по разделам',
                    onTap: () => _pick(const _FindCommand()),
                    nested: true,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// Строки на листе ячейкой со скруглением и разделителями «вставкой».
  Widget _inset(BuildContext context, List<Widget> rows) => ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Material(
          color: context.colors.workspace,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (var i = 0; i < rows.length; i++) ...<Widget>[
                if (i > 0)
                  Padding(
                    padding: const EdgeInsets.only(left: 56),
                    child: Divider(
                      height: .5,
                      thickness: .5,
                      color: context.colors.divider,
                    ),
                  ),
                rows[i],
              ],
            ],
          ),
        ),
      );

  List<Widget> _group({
    required _PlusGroup group,
    required Key key,
    required IconData icon,
    required String label,
    required List<Widget> children,
    Color? tile,
  }) {
    final open = _open == group;
    return <Widget>[
      _row(
        key: key,
        icon: icon,
        label: label,
        trailing: Icon(
          open ? Icons.expand_less : Icons.expand_more,
          color: context.colors.icon,
        ),
        expanded: open,
        tile: tile,
        onTap: () => _toggle(group),
      ),
      if (open) ...children,
    ];
  }

  Widget _row({
    required Key key,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    String? detail,
    Widget? trailing,
    bool nested = false,
    bool? expanded,
    Color? tile,
  }) {
    final colors = context.colors;
    // Пункт верхнего уровня — значком на цветной плитке, вложенный — просто
    // значком.
    final Widget leading = nested
        ? SizedBox(
            width: 28,
            child: Icon(icon, size: 22, color: colors.icon),
          )
        : Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: tile ?? colors.tileGray,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Icon(icon, size: 18, color: Colors.white),
          );
    return Semantics(
      expanded: expanded,
      child: ListTile(
        key: key,
        onTap: onTap,
        minTileHeight: AppSize.rowMin,
        horizontalTitleGap: 12,
        contentPadding: EdgeInsets.only(left: nested ? 32 : 16, right: 16),
        leading: leading,
        // Целыми словами: на 320 px со шрифтом 200 % простой Text рвал
        // «Прикрепит|ь файл».
        title: WholeWordText(
          label,
          style: TextStyle(fontSize: 16, color: colors.textStrong),
        ),
        subtitle: detail == null
            ? null
            : WholeWordText(
                detail,
                style: TextStyle(fontSize: 14, color: colors.muted),
              ),
        trailing: trailing,
      ),
    );
  }
}

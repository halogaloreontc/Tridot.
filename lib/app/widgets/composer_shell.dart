import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../assistant_theme.dart';
import '../layout.dart';
import 'whole_word_text.dart';

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

/// Середина нижней строки поля по её ширине [width] — например,
/// переключатель «Диалог / Документ», которому ширина нужна, чтобы решить,
/// показывать ли подписи.
typedef ComposerCenterBuilder = Widget Function(
  BuildContext context,
  double width,
);

/// Общий вид поля ввода: панель заливкой без рамок (ADR-027), поле во всю
/// ширину, снизу — [leading], [center] и отправка или микрофон. Без
/// файлов, дисков и шаблонов: их подставляет хозяин через слоты, поэтому
/// этот файл не тянет `dart:io` и выбор файлов и годится веб-виджету.
///
/// Не блокируется во время отправки, чтобы не терять фокус: повторную
/// отправку отсекает хозяин.
final class ComposerShell extends StatefulWidget {
  const ComposerShell({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.sending,
    required this.onSend,
    this.previousCommand,
    this.nextCommand,
    this.leading,
    this.center,
    this.above,
    this.hasAttachments = false,
    this.hintText = 'Сообщение',
    this.maxLength,
    this.voiceMode = VoiceButtonMode.hidden,
    this.onVoiceTap,
    this.onVoiceLongPress,
    this.onVoiceCancel,
    this.voicePartial,
    this.voiceNotice,
    this.inputKey = const Key('assistant-input'),
    this.sendKey = const Key('assistant-send'),
    this.voiceKey = const Key('assistant-voice'),
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool sending;
  final VoidCallback onSend;

  /// Прошлая и следующая команда из истории для ↑/↓; null — нет. Сами
  /// функции null — стрелки остаются полю.
  final String? Function()? previousCommand;
  final String? Function()? nextCommand;

  /// Левая кнопка нижней строки (в приложении — «+»); null — пусто. Пока
  /// слушает или готовится, на её месте всегда крестик отмены.
  final Widget? leading;

  /// Середина нижней строки; null — её нет.
  final ComposerCenterBuilder? center;

  /// Над полем: адресат в дуэте, чипы файлов.
  final Widget? above;

  /// Выбраны файлы: отправить можно и без текста, а долгое нажатие на
  /// поле — обычное выделение, не голос.
  final bool hasAttachments;

  /// Подсказка в пустом поле, пока не слушает.
  final String hintText;

  /// Предел длины текста; счётчик под полем не показываем.
  final int? maxLength;

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

  /// Крестик на месте [leading], пока слушает или готовится: прервать без
  /// итога.
  final VoidCallback? onVoiceCancel;

  /// Промежуточный распознанный текст: серой строкой над полем, пока
  /// слушает.
  final String? voicePartial;

  /// Подсказка голосового ввода («Нет доступа к микрофону…», «Микрофон
  /// выключен…»): строкой над полем, а не всплывающим уведомлением —
  /// уведомление закрыло бы сам микрофон.
  final String? voiceNotice;

  /// Ключи поля, отправки и микрофона: у веб-виджета свои.
  final Key inputKey;
  final Key sendKey;
  final Key voiceKey;

  @override
  State<ComposerShell> createState() => _ComposerShellState();
}

final class _ComposerShellState extends State<ComposerShell>
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
  void didUpdateWidget(covariant ComposerShell oldWidget) {
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
    final previous = widget.previousCommand;
    if (key == LogicalKeyboardKey.arrowUp && singleLine && previous != null) {
      return _recall(previous());
    }
    final next = widget.nextCommand;
    if (key == LogicalKeyboardKey.arrowDown && singleLine && next != null) {
      return _recall(next());
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

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (BuildContext context, _) {
        // Файлы можно отправить и без текста.
        final hasText =
            widget.controller.text.trim().isNotEmpty || widget.hasAttachments;
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
            !widget.hasAttachments &&
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
          _ => widget.hintText,
        };
        // Пока слушает или готовится, на месте [leading] — крестик:
        // прервать без итога.
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
                    child: const ComposerRoundIcon(icon: Icons.close),
                  ),
                ),
              )
            : widget.leading ?? const SizedBox.shrink();
        // Пустое поле — микрофон (если голос есть), с текстом — круг
        // акцента со стрелкой.
        final send = voice
            ? _VoiceButton(
                inkKey: widget.voiceKey,
                mode: voiceMode,
                onTap: widget.onVoiceTap,
              )
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
        // текст во всю ширину, снизу [leading], [center] ровно посередине
        // и отправка или микрофон. Текст во всю ширину не рвёт слова и при
        // крупном шрифте.
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
              focusNode: widget.focusNode,
              // Одна строка растёт до шести (ADR-027).
              minLines: 1,
              maxLines: 6,
              maxLength: widget.maxLength,
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
                // Предел длины — без счётчика под полем: панель не
                // растёт.
                counterText: widget.maxLength == null ? null : '',
                // Ни рамки, ни рамки фокуса: поле — заливкой.
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                errorBorder: InputBorder.none,
                focusedErrorBorder: InputBorder.none,
                filled: false,
                contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                isDense: true,
              ),
            ),
          ),
        );
        final center = widget.center;
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
              if (widget.above case final Widget above) above,
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
                  return Row(
                    children: <Widget>[
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: left,
                        ),
                      ),
                      if (center != null) center(context, c.maxWidth),
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
  const _VoiceButton({
    required this.inkKey,
    required this.mode,
    required this.onTap,
  });

  /// Ключ — у самой кнопки нажатия, как было до выноса: тесты нажимают
  /// по нему.
  final Key inkKey;
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
          key: inkKey,
          onTap: onTap,
          onLongPress: onTap,
          radius: 24,
          child: circle,
        ),
      ),
    );
  }
}

/// Круглая кнопка нижней строки поля («+», крестик отмены), 44×44.
final class ComposerRoundIcon extends StatelessWidget {
  const ComposerRoundIcon({super.key, required this.icon});

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

/// Отступы, скругления и размеры интерфейса (ADR-027, поправка «плотнее»):
/// всё кратно 4 и берётся отсюда, а не числами по месту.
library;

/// Отступы.
abstract final class AppSpace {
  static const double xxs = 4;
  static const double xs = 8;
  static const double s = 12;
  static const double m = 16;
  static const double l = 20;
  static const double xl = 24;
  static const double xxl = 32;

  /// Поля ленты чата и документа.
  static const double pageH = 16;

  /// От края экрана до сгруппированного списка.
  static const double insetH = 16;

  /// Внутренние отступы строки списка.
  static const double rowH = 16;
  static const double rowV = 12;

  /// Между группами.
  static const double sectionGap = 24;

  /// Отступ разделителя «вставкой»: 16 + плитка 28 + 12; без иконки — 16.
  static const double separatorInset = 56;

  // Ритм ленты чата.

  /// Ответ → пузырь пользователя.
  static const double toUser = 16;

  /// Пузырь → ответ, ответ → ответ того же автора.
  static const double toReply = 12;

  /// Имя автора → текст.
  static const double nameToText = 4;

  /// Абзац → абзац.
  static const double paragraph = 12;

  /// Текст → вложенная карточка.
  static const double textToCard = 12;

  /// Карточка → следующее сообщение.
  static const double afterCard = 16;

  /// Метка времени группы — сверху и снизу.
  static const double timeLabel = 12;

  /// Подпись группы → группа и группа → сноска.
  static const double groupLabel = 8;

  /// Поле заливки выбранной строки от краёв группы (ADR-027).
  static const double selectionInsetH = 4;
  static const double selectionInsetV = 4;
}

/// Скругления.
abstract final class AppRadius {
  static const double group = 12;
  static const double card = 12;
  static const double field = 12;
  static const double pill = 20;
  static const double bubble = 16;
  static const double sheet = 16;
  static const double dialog = 16;
  static const double tile = 8;
  static const double search = 12;
  static const double chip = 16;

  /// Поле и выпадающий список внутри карточки.
  static const double inner = 8;

  /// Заливка выбранной строки внутри группы: [group] минус поле
  /// [AppSpace.selectionInsetH] — скругления концентричны.
  static const double selection = 8;
}

/// Размеры.
abstract final class AppSize {
  /// Наименьшая цель нажатия.
  static const double minTap = 48;

  /// Видимая высота кнопки (цель нажатия добирает до [minTap] сама).
  static const double button = 44;
  static const double rowMin = 48;
  static const double iconTile = 28;
  static const double icon = 22;
  static const double navBar = 52;
  static const double composer = 44;
  static const double sendButton = 44;

  /// Наибольшая ширина колонки чтения: ≈ 70 знаков кириллицы при 16.
  static const double maxReading = 640;
  static const double maxSettings = 720;

  /// Пузырь пользователя — не шире этой доли колонки и не шире
  /// [maxBubble].
  static const double maxBubbleFactor = .78;
  static const double maxBubble = 460;
}

/// Окна подтверждения и разрешения (`AppDialog`, `AppSheet`).
abstract final class AppDialogMetrics {
  /// Ширина текста окна: с полями 20 окно — 352, на телефоне 390 —
  /// почти во всю ширину, и все окна одной ширины.
  static const double contentWidth = 312;

  /// Поля окна: сбоку и сверху.
  static const double padH = 20;
  static const double padTop = 20;

  /// Заголовок → текст.
  static const double titleGap = 8;

  /// Текст → кнопки; поля ряда кнопок.
  static const double actionsTop = 16;
  static const double actionsH = 12;
  static const double actionsBottom = 12;

  /// Между кнопками.
  static const double actionGap = 8;
}

import 'dart:async';

import 'package:flutter/foundation.dart';

/// Есть ли связь со складом — для капсулы над полем ввода (ADR-040).
///
/// [lost] — запрос не дошёл или браузер сказал «нет сети»: капсула «Нет
/// сети». [restored] — связь вернулась: на [backFor] «Сеть есть» (и
/// сколько отложенного ушло), потом капсула прячется. Без `dart:io` и
/// `package:web`: общая для приложения и веб-помощника.
final class NetworkStatus extends ChangeNotifier {
  NetworkStatus({this.backFor = const Duration(seconds: 2)});

  /// Сколько показывать «Сеть есть».
  final Duration backFor;

  /// Связи нет.
  bool offline = false;

  /// Сколько отложенных правок ушло, когда связь вернулась; `null` —
  /// «Сеть есть» не показывается.
  int? sent;

  Timer? _timer;
  bool _disposed = false;

  /// Капсула видна: нет сети или только что вернулась.
  bool get visible => offline || sent != null;

  /// Связи нет. Повтор — без перерисовки.
  void lost() {
    if (offline) return;
    _timer?.cancel();
    offline = true;
    sent = null;
    notifyListeners();
  }

  /// Связь вернулась; [sent] — сколько отложенного ушло. Была и так —
  /// ничего не показывается.
  void restored({int sent = 0}) {
    if (!offline) return;
    offline = false;
    this.sent = sent < 0 ? 0 : sent;
    _timer?.cancel();
    _timer = Timer(backFor, () {
      if (_disposed) return;
      this.sent = null;
      notifyListeners();
    });
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_assistant/app/downloads/download_keeper.dart';

final class _Service implements BackgroundDownloads {
  final List<String> calls = <String>[];

  @override
  Future<void> update(String title, int received, int total) async =>
      calls.add('$title $received/$total');

  @override
  Future<void> stop() async => calls.add('stop');
}

final class _Kit extends ChangeNotifier {
  bool active = false;
  int received = 0;

  void set({bool? active, int? received}) {
    this.active = active ?? this.active;
    this.received = received ?? this.received;
    notifyListeners();
  }
}

void main() {
  test('служба: старт, обновления не чаще секунды, остановка', () {
    var now = DateTime(2026, 11, 27, 12);
    final kit = _Kit();
    final service = _Service();
    final keeper = DownloadKeeper(
      <KeptDownload>[
        KeptDownload(
          listenable: kit,
          title: 'Модель',
          active: () => kit.active,
          received: () => kit.received,
          total: () => 100,
        ),
      ],
      service,
      now: () => now,
    );
    addTearDown(keeper.dispose);
    kit.set();
    expect(service.calls, isEmpty, reason: 'не качается — службы нет');
    kit.set(active: true);
    kit.set(received: 10);
    expect(service.calls, <String>['Модель 0/100']);
    now = now.add(const Duration(seconds: 2));
    kit.set(received: 50);
    expect(service.calls.last, 'Модель 50/100');
    kit.set(active: false);
    expect(service.calls.last, 'stop');
    kit.set();
    expect(service.calls.where((c) => c == 'stop'), hasLength(1));
  });

  test('две загрузки: служба показывает идущую', () {
    final a = _Kit();
    final b = _Kit();
    final service = _Service();
    DownloadKeeper(
      <KeptDownload>[
        for (final (kit, title) in <(_Kit, String)>[(a, 'А'), (b, 'Б')])
          KeptDownload(
            listenable: kit,
            title: title,
            active: () => kit.active,
            received: () => kit.received,
            total: () => 10,
          ),
      ],
      service,
    );
    b.set(active: true);
    expect(service.calls.single, 'Б 0/10');
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_memo/core/utils/date_tab_window.dart';

void main() {
  test('builds target-centered 30 tab window', () {
    final List<int> days = List<int>.generate(60, (int index) => index);

    final DateTabWindow<int> window = buildCenteredDateTabWindow<int>(
      items: days,
      targetIndex: 30,
    );

    expect(window.items.length, 30);
    expect(window.items.first, 16);
    expect(window.items.last, 45);
    expect(window.selectedIndex, 14);
    expect(window.items[window.selectedIndex], 30);
  });

  test('fills from newer side near oldest boundary', () {
    final List<int> days = List<int>.generate(40, (int index) => index);

    final DateTabWindow<int> window = buildCenteredDateTabWindow<int>(
      items: days,
      targetIndex: 38,
    );

    expect(window.items.length, 30);
    expect(window.items.first, 10);
    expect(window.items.last, 39);
    expect(window.items[window.selectedIndex], 38);
  });

  test('fills from older side near newest boundary', () {
    final List<int> days = List<int>.generate(40, (int index) => index);

    final DateTabWindow<int> window = buildCenteredDateTabWindow<int>(
      items: days,
      targetIndex: 2,
    );

    expect(window.items.length, 30);
    expect(window.items.first, 0);
    expect(window.items.last, 29);
    expect(window.items[window.selectedIndex], 2);
  });
}

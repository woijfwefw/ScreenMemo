import 'dart:math' as math;

class DateTabWindow<T> {
  const DateTabWindow({
    required this.items,
    required this.selectedIndex,
    required this.sourceStartIndex,
  });

  final List<T> items;
  final int selectedIndex;
  final int sourceStartIndex;

  int get sourceEndExclusive => sourceStartIndex + items.length;
}

/// 从倒序日期列表中截取以目标日期为中心的可见窗口。
DateTabWindow<T> buildCenteredDateTabWindow<T>({
  required List<T> items,
  required int targetIndex,
  int beforeCount = 14,
  int afterCount = 15,
}) {
  if (items.isEmpty || targetIndex < 0 || targetIndex >= items.length) {
    return DateTabWindow<T>(
      items: <T>[],
      selectedIndex: -1,
      sourceStartIndex: 0,
    );
  }

  final int safeBefore = math.max(0, beforeCount);
  final int safeAfter = math.max(0, afterCount);
  final int desiredLength = math.min(items.length, safeBefore + 1 + safeAfter);

  int start = targetIndex - safeBefore;
  int end = targetIndex + safeAfter + 1;

  if (start < 0) {
    end += -start;
    start = 0;
  }
  if (end > items.length) {
    start -= end - items.length;
    end = items.length;
  }
  start = math.max(0, start);

  if (end - start > desiredLength) {
    end = start + desiredLength;
  }

  return DateTabWindow<T>(
    items: items.sublist(start, end),
    selectedIndex: targetIndex - start,
    sourceStartIndex: start,
  );
}

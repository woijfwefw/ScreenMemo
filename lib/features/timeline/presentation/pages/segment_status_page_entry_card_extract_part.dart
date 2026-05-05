part of 'segment_status_page.dart';

// ========== 单条动态字段提取 ==========
extension _SegmentEntryCardExtractPart on _SegmentEntryCardState {
  Map<String, dynamic>? _tryParseJson(String? s) {
    if (s == null) return null;
    try {
      final obj = jsonDecode(s);
      if (obj is Map<String, dynamic>) return obj;
    } catch (_) {}
    return null;
  }

  String? _extractKeyActionDetail(Map<String, dynamic>? sj) {
    if (sj == null) return null;
    final ka = sj['key_actions'];
    if (ka is List && ka.isNotEmpty) {
      final first = ka.first;
      if (first is Map && first['detail'] is String)
        return (first['detail'] as String);
      if (first is String) return first;
    } else if (ka is Map && ka['detail'] is String) {
      return ka['detail'] as String;
    } else if (ka is String) {
      return ka;
    }
    return null;
  }

  List<String> _extractCategories(
    Map<String, dynamic>? result,
    Map<String, dynamic>? sj,
  ) {
    final List<String> out = <String>[];
    // 1) result.categories 可能是 JSON 或逗号分隔
    final raw = result?['categories'];
    if (raw is String && raw.trim().isNotEmpty) {
      try {
        final obj = jsonDecode(raw);
        if (obj is List) {
          out.addAll(obj.map((e) => e.toString()));
        } else {
          out.addAll(
            raw.split(RegExp(r'[,\s]+')).where((e) => e.trim().isNotEmpty),
          );
        }
      } catch (_) {
        out.addAll(
          raw.split(RegExp(r'[,\s]+')).where((e) => e.trim().isNotEmpty),
        );
      }
    }
    // 2) structured_json.categories
    final sc = sj?['categories'];
    if (sc is List) {
      out.addAll(sc.map((e) => e.toString()));
    } else if (sc is String && sc.trim().isNotEmpty) {
      out.addAll(sc.split(RegExp(r'[,\s]+')).where((e) => e.trim().isNotEmpty));
    }
    // 去重
    final set = <String>{};
    final res = <String>[];
    for (final c in out) {
      final v = c.trim();
      if (v.isEmpty) continue;
      if (set.add(v)) res.add(v);
    }
    return res;
  }

  String _extractOverallSummary(Map<String, dynamic>? sj) {
    final v = sj?['overall_summary'];
    if (v is String && v.trim().isNotEmpty) return v.trim();
    return '';
  }

  Map<String, dynamic>? _extractAiRetryMeta(Map<String, dynamic>? sj) {
    if (sj == null) return null;
    final dynamic raw = sj['_meta'];
    if (raw is Map<String, dynamic>) return raw;
    if (raw is Map) {
      try {
        return Map<String, dynamic>.from(raw);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  int _aiRetryCount(Map<String, dynamic>? sj) {
    final meta = _extractAiRetryMeta(sj);
    if (meta == null) return 0;
    final dynamic raw = meta['retry_count'];
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim()) ?? 0;
    return 0;
  }

  bool _aiNeedsManualRetry(Map<String, dynamic>? sj) {
    final meta = _extractAiRetryMeta(sj);
    if (meta == null) return false;
    final dynamic raw = meta['needs_manual_retry'];
    if (raw is bool) return raw;
    if (raw is num) return raw != 0;
    if (raw is String) {
      final v = raw.trim().toLowerCase();
      return v == 'true' || v == '1' || v == 'yes';
    }
    return false;
  }

  String _aiRetryMessage(BuildContext context, Map<String, dynamic>? sj) {
    final l10n = AppLocalizations.of(context);
    final meta = _extractAiRetryMeta(sj);
    if (meta == null) return '';
    final String raw = (meta['retry_message'] as String?)?.trim() ?? '';
    if (raw.isNotEmpty) return raw;
    if (_aiNeedsManualRetry(sj)) {
      return l10n.aiResultAutoRetryFailedHint;
    }
    if (_aiRetryCount(sj) > 0) {
      return l10n.aiResultAutoRetriedHint;
    }
    return '';
  }

  List<String> _uniquePackages(List<Map<String, dynamic>> samples) {
    final set = <String>{};
    for (final s in samples) {
      final p = (s['app_package_name'] as String?) ?? '';
      if (p.isNotEmpty) set.add(p);
    }
    return set.toList();
  }

  // （已移除）关键图片卡片相关 UI 代码
}

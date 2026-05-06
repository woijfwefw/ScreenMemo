import 'update_models.dart';

/// 版本比较工具，支持 v1.2.3 / 1.2.3 / 1.2.3-beta 等常见 tag。
class UpdateVersionComparator {
  UpdateVersionComparator._();

  static String normalize(String value) {
    final trimmed = value.trim();
    if (trimmed.startsWith('v') || trimmed.startsWith('V')) {
      return trimmed.substring(1);
    }
    return trimmed;
  }

  static int compare(String left, String right) {
    final a = _parse(normalize(left));
    final b = _parse(normalize(right));
    for (int i = 0; i < 3; i++) {
      final diff = a[i].compareTo(b[i]);
      if (diff != 0) return diff;
    }
    return 0;
  }

  static List<int> _parse(String value) {
    final match = RegExp(r'^(\d+)(?:\.(\d+))?(?:\.(\d+))?').firstMatch(value);
    if (match == null) return const <int>[0, 0, 0];
    return <int>[
      int.tryParse(match.group(1) ?? '') ?? 0,
      int.tryParse(match.group(2) ?? '') ?? 0,
      int.tryParse(match.group(3) ?? '') ?? 0,
    ];
  }
}

/// 按设备 ABI 从 Release 资产中选择最合适的 APK。
class UpdateAssetSelector {
  UpdateAssetSelector._();

  static UpdateReleaseAsset? select(
    List<UpdateReleaseAsset> assets,
    List<String> supportedAbis,
  ) {
    final apks = assets
        .where((asset) => asset.name.toLowerCase().endsWith('.apk'))
        .toList(growable: false);
    if (apks.isEmpty) return null;

    final normalizedAbis = supportedAbis
        .map((abi) => abi.trim().toLowerCase())
        .where((abi) => abi.isNotEmpty)
        .toList(growable: false);

    for (final abi in normalizedAbis) {
      final match = _findByAbi(apks, abi);
      if (match != null) return match;
    }

    // 部分构建可能提供 universal APK，优先使用通用包。
    for (final asset in apks) {
      final name = asset.name.toLowerCase();
      if (name.contains('universal') || !name.contains('release')) {
        return asset;
      }
    }

    // 兜底选择 arm64，兼容大多数现代设备；若不存在则选择第一个 APK。
    return _findByAbi(apks, 'arm64-v8a') ?? apks.first;
  }

  static UpdateReleaseAsset? _findByAbi(
    List<UpdateReleaseAsset> assets,
    String abi,
  ) {
    for (final asset in assets) {
      if (asset.name.toLowerCase().contains(abi)) return asset;
    }
    return null;
  }
}

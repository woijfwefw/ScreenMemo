/// 自动更新检查状态。
enum UpdateCheckStatus {
  updateAvailable,
  upToDate,
  skipped,
  incompatible,
  failed,
}

/// GitHub Release 中的 APK 资产。
class UpdateReleaseAsset {
  const UpdateReleaseAsset({
    required this.name,
    required this.downloadUrl,
    this.sizeBytes,
  });

  final String name;
  final String downloadUrl;
  final int? sizeBytes;
}

/// GitHub Release 版本信息。
class UpdateReleaseInfo {
  const UpdateReleaseInfo({
    required this.tagName,
    required this.version,
    required this.name,
    required this.htmlUrl,
    required this.assets,
    this.body,
    this.publishedAt,
  });

  final String tagName;
  final String version;
  final String name;
  final String htmlUrl;
  final String? body;
  final DateTime? publishedAt;
  final List<UpdateReleaseAsset> assets;
}

/// 可安装的更新候选。
class UpdateCandidate {
  const UpdateCandidate({
    required this.currentVersion,
    required this.currentBuildNumber,
    required this.release,
    required this.asset,
  });

  final String currentVersion;
  final String currentBuildNumber;
  final UpdateReleaseInfo release;
  final UpdateReleaseAsset asset;
}

/// 更新检查结果。
class UpdateCheckResult {
  const UpdateCheckResult({
    required this.status,
    this.candidate,
    this.errorMessage,
  });

  final UpdateCheckStatus status;
  final UpdateCandidate? candidate;
  final String? errorMessage;
}

/// 下载进度。
class UpdateDownloadProgress {
  const UpdateDownloadProgress({
    required this.receivedBytes,
    required this.totalBytes,
    required this.done,
  });

  const UpdateDownloadProgress.empty()
    : receivedBytes = 0,
      totalBytes = null,
      done = false;

  final int receivedBytes;
  final int? totalBytes;
  final bool done;
}

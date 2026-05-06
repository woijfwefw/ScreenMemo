import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:screen_memo/core/constants/user_settings_keys.dart';
import 'package:screen_memo/core/logging/flutter_logger.dart';
import 'package:screen_memo/features/updater/application/update_models.dart';
import 'package:screen_memo/features/updater/application/update_platform_service.dart';
import 'package:screen_memo/features/updater/application/update_version.dart';

/// ScreenMemo 的无服务器自动更新服务。
class UpdateService {
  UpdateService({
    http.Client? client,
    UpdatePlatformService? platform,
    DateTime Function()? now,
    Duration? autoCheckInterval,
  }) : _client = client ?? http.Client(),
       _platform = platform ?? UpdatePlatformService(),
       _now = now ?? DateTime.now,
       _autoCheckInterval = autoCheckInterval ?? const Duration(hours: 6);

  static final UpdateService instance = UpdateService();

  static const String _repoOwner = 'woijfwefw';
  static const String _repoName = 'ScreenMemo';
  static const String _apiLatestReleaseUrl =
      'https://api.github.com/repos/$_repoOwner/$_repoName/releases/latest';
  static const String _webLatestReleaseUrl =
      'https://github.com/$_repoOwner/$_repoName/releases/latest';
  static const String _webReleaseBaseUrl =
      'https://github.com/$_repoOwner/$_repoName/releases';
  static const Map<String, String> _headers = <String, String>{
    'Accept': 'application/vnd.github+json',
    'User-Agent': 'ScreenMemo-Updater',
    'X-GitHub-Api-Version': '2022-11-28',
  };

  final http.Client _client;
  final UpdatePlatformService _platform;
  final DateTime Function() _now;
  final Duration _autoCheckInterval;

  bool _checking = false;

  /// 检查是否有可安装新版本。
  Future<UpdateCheckResult> checkForUpdate({
    bool force = false,
    String reason = 'auto',
  }) async {
    if (!Platform.isAndroid) {
      return const UpdateCheckResult(status: UpdateCheckStatus.skipped);
    }
    if (_checking) {
      return const UpdateCheckResult(status: UpdateCheckStatus.skipped);
    }

    final prefs = await SharedPreferences.getInstance();
    if (!force) {
      final enabled = prefs.getBool(UserSettingKeys.autoUpdateEnabled) ?? true;
      if (!enabled) {
        return const UpdateCheckResult(status: UpdateCheckStatus.skipped);
      }
      final lastCheck =
          prefs.getInt(UserSettingKeys.autoUpdateLastCheckMs) ?? 0;
      final nowMs = _now().millisecondsSinceEpoch;
      if (lastCheck > 0 &&
          nowMs - lastCheck < _autoCheckInterval.inMilliseconds) {
        return const UpdateCheckResult(status: UpdateCheckStatus.skipped);
      }
      await prefs.setInt(UserSettingKeys.autoUpdateLastCheckMs, nowMs);
    }

    _checking = true;
    try {
      final PackageInfo packageInfo = await PackageInfo.fromPlatform();
      final UpdateReleaseInfo release = await fetchLatestRelease();
      final ignoredVersion =
          prefs.getString(UserSettingKeys.autoUpdateIgnoredVersion) ?? '';

      if (!force && ignoredVersion == release.version) {
        return const UpdateCheckResult(status: UpdateCheckStatus.skipped);
      }

      final int versionCompare = UpdateVersionComparator.compare(
        release.version,
        packageInfo.version,
      );
      if (versionCompare <= 0) {
        return const UpdateCheckResult(status: UpdateCheckStatus.upToDate);
      }

      final List<String> abis = await _safeSupportedAbis();
      final UpdateReleaseAsset? asset = UpdateAssetSelector.select(
        release.assets,
        abis,
      );
      if (asset == null) {
        return const UpdateCheckResult(status: UpdateCheckStatus.incompatible);
      }

      return UpdateCheckResult(
        status: UpdateCheckStatus.updateAvailable,
        candidate: UpdateCandidate(
          currentVersion: packageInfo.version,
          currentBuildNumber: packageInfo.buildNumber,
          release: release,
          asset: asset,
        ),
      );
    } catch (e, s) {
      unawaited(
        FlutterLogger.handle(e, s, tag: 'UpdateService.checkForUpdate.$reason'),
      );
      return UpdateCheckResult(
        status: UpdateCheckStatus.failed,
        errorMessage: e.toString(),
      );
    } finally {
      _checking = false;
    }
  }

  Future<void> ignoreVersion(String version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(UserSettingKeys.autoUpdateIgnoredVersion, version);
  }

  Future<UpdateReleaseInfo> fetchLatestRelease() async {
    try {
      return await _fetchLatestReleaseFromApi();
    } catch (e, s) {
      unawaited(FlutterLogger.handle(e, s, tag: 'UpdateService.githubApi'));
      return _fetchLatestReleaseFromWeb();
    }
  }

  Future<UpdateReleaseInfo> _fetchLatestReleaseFromApi() async {
    final response = await _client
        .get(Uri.parse(_apiLatestReleaseUrl), headers: _headers)
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('GitHub API returned ${response.statusCode}');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid GitHub release payload');
    }
    if (decoded['draft'] == true || decoded['prerelease'] == true) {
      throw const FormatException('Latest release is not a stable release');
    }

    final tag = (decoded['tag_name'] as String? ?? '').trim();
    if (tag.isEmpty) {
      throw const FormatException('Release tag is empty');
    }

    final List<UpdateReleaseAsset> assets = <UpdateReleaseAsset>[];
    final rawAssets = decoded['assets'];
    if (rawAssets is List) {
      for (final rawAsset in rawAssets) {
        if (rawAsset is! Map<String, dynamic>) continue;
        final name = (rawAsset['name'] as String? ?? '').trim();
        final downloadUrl = (rawAsset['browser_download_url'] as String? ?? '')
            .trim();
        if (name.isEmpty ||
            downloadUrl.isEmpty ||
            !name.toLowerCase().endsWith('.apk')) {
          continue;
        }
        assets.add(
          UpdateReleaseAsset(
            name: name,
            downloadUrl: downloadUrl,
            sizeBytes: _asInt(rawAsset['size']),
          ),
        );
      }
    }

    return UpdateReleaseInfo(
      tagName: tag,
      version: UpdateVersionComparator.normalize(tag),
      name: (decoded['name'] as String? ?? tag).trim(),
      htmlUrl:
          (decoded['html_url'] as String? ??
                  '$_webReleaseBaseUrl/tag/${Uri.encodeComponent(tag)}')
              .trim(),
      body: (decoded['body'] as String?)?.trim(),
      publishedAt: DateTime.tryParse(
        (decoded['published_at'] as String? ?? '').trim(),
      ),
      assets: assets,
    );
  }

  Future<UpdateReleaseInfo> _fetchLatestReleaseFromWeb() async {
    final latestResponse = await _client
        .get(
          Uri.parse(_webLatestReleaseUrl),
          headers: const <String, String>{
            'Accept': 'text/html',
            'User-Agent': 'ScreenMemo-Updater',
          },
        )
        .timeout(const Duration(seconds: 15));
    if (latestResponse.statusCode < 200 || latestResponse.statusCode >= 300) {
      throw HttpException(
        'GitHub release page returned ${latestResponse.statusCode}',
      );
    }

    final String finalUrl = latestResponse.request?.url.toString() ?? '';
    final String tag =
        _extractTagFromReleaseUrl(finalUrl) ??
        _extractTagFromReleaseUrl(latestResponse.body) ??
        '';
    if (tag.isEmpty) {
      throw const FormatException('Cannot resolve latest release tag');
    }

    final assetsResponse = await _client
        .get(
          Uri.parse('$_webReleaseBaseUrl/expanded_assets/$tag'),
          headers: const <String, String>{
            'Accept': 'text/html',
            'User-Agent': 'ScreenMemo-Updater',
          },
        )
        .timeout(const Duration(seconds: 15));
    if (assetsResponse.statusCode < 200 || assetsResponse.statusCode >= 300) {
      throw HttpException(
        'GitHub release assets returned ${assetsResponse.statusCode}',
      );
    }

    final Set<String> seen = <String>{};
    final List<UpdateReleaseAsset> assets = <UpdateReleaseAsset>[];
    final matches = RegExp(
      r'href="([^"]+\.apk)"',
      caseSensitive: false,
    ).allMatches(assetsResponse.body);
    for (final match in matches) {
      final href = (match.group(1) ?? '').trim();
      if (href.isEmpty || !seen.add(href)) continue;
      final uri = href.startsWith('http')
          ? Uri.parse(href)
          : Uri.parse('https://github.com$href');
      assets.add(
        UpdateReleaseAsset(
          name: p.basename(uri.path),
          downloadUrl: uri.toString(),
        ),
      );
    }

    return UpdateReleaseInfo(
      tagName: tag,
      version: UpdateVersionComparator.normalize(tag),
      name: tag,
      htmlUrl: '$_webReleaseBaseUrl/tag/${Uri.encodeComponent(tag)}',
      assets: assets,
    );
  }

  Future<List<String>> _safeSupportedAbis() async {
    try {
      return await _platform.getSupportedAbis();
    } catch (e, s) {
      unawaited(FlutterLogger.handle(e, s, tag: 'UpdateService.abis'));
      return const <String>['arm64-v8a', 'armeabi-v7a', 'x86_64'];
    }
  }

  String? _extractTagFromReleaseUrl(String value) {
    final match = RegExp(r'/releases/tag/([^/?#"\s<]+)').firstMatch(value);
    return match == null ? null : Uri.decodeComponent(match.group(1) ?? '');
  }

  int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}

/// APK 下载服务，负责流式写入临时目录。
class UpdateDownloadService {
  UpdateDownloadService({http.Client? client})
    : _client = client ?? http.Client();

  final http.Client _client;

  Future<String> downloadApk(
    UpdateReleaseAsset asset, {
    required void Function(UpdateDownloadProgress progress) onProgress,
  }) async {
    final Directory tempDir = await getTemporaryDirectory();
    final Directory updatesDir = Directory(
      p.join(tempDir.path, 'screen_memo_updates'),
    );
    await updatesDir.create(recursive: true);

    final String safeName = _safeFileName(asset.name);
    final File target = File(p.join(updatesDir.path, safeName));
    final File partial = File('${target.path}.part');
    if (await partial.exists()) {
      await partial.delete();
    }

    final request = http.Request('GET', Uri.parse(asset.downloadUrl));
    request.headers.addAll(const <String, String>{
      'User-Agent': 'ScreenMemo-Updater',
    });
    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException('Download returned ${response.statusCode}');
    }

    final int? total = response.contentLength ?? asset.sizeBytes;
    int received = 0;
    final IOSink sink = partial.openWrite();
    try {
      await for (final chunk in response.stream) {
        received += chunk.length;
        sink.add(chunk);
        onProgress(
          UpdateDownloadProgress(
            receivedBytes: received,
            totalBytes: total,
            done: false,
          ),
        );
      }
    } finally {
      await sink.close();
    }

    if (await target.exists()) {
      await target.delete();
    }
    await partial.rename(target.path);
    onProgress(
      UpdateDownloadProgress(
        receivedBytes: received,
        totalBytes: total,
        done: true,
      ),
    );
    return target.path;
  }

  String _safeFileName(String value) {
    final base = p.basename(value).replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return base.toLowerCase().endsWith('.apk') ? base : '$base.apk';
  }
}

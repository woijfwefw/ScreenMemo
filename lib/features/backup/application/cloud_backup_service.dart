import 'dart:io';

import 'package:flutter/services.dart';
import 'package:screen_memo/core/constants/user_settings_keys.dart';
import 'package:screen_memo/data/settings/user_settings_service.dart';

class CloudBackupSettings {
  const CloudBackupSettings({
    required this.enabled,
    required this.frequencyDays,
    required this.allowMobileData,
    required this.keepLatestCount,
    required this.appKey,
    required this.secretKey,
    required this.authorizationCode,
    required this.accessToken,
    required this.refreshToken,
    required this.tokenExpiresAt,
    required this.lastSuccessAt,
    required this.lastAttemptAt,
    required this.lastStatus,
    required this.deviceId,
  });

  final bool enabled;
  final int frequencyDays;
  final bool allowMobileData;
  final int keepLatestCount;
  final String appKey;
  final String secretKey;
  final String authorizationCode;
  final String accessToken;
  final String refreshToken;
  final int tokenExpiresAt;
  final int lastSuccessAt;
  final int lastAttemptAt;
  final String lastStatus;
  final String deviceId;

  bool get hasCredentials => appKey.isNotEmpty && secretKey.isNotEmpty;
  bool get isAuthorized => accessToken.isNotEmpty || refreshToken.isNotEmpty;
}

class CloudBackupProgress {
  const CloudBackupProgress({
    required this.stage,
    required this.percent,
    required this.detail,
    required this.updatedAt,
    required this.bytesDone,
    required this.bytesTotal,
    required this.active,
  });

  final String stage;
  final int percent;
  final String detail;
  final int updatedAt;
  final int bytesDone;
  final int bytesTotal;
  final bool active;

  bool get hasProgress => stage.isNotEmpty || percent > 0 || updatedAt > 0;
  double get value => (percent.clamp(0, 100)) / 100.0;

  factory CloudBackupProgress.empty() {
    return const CloudBackupProgress(
      stage: '',
      percent: 0,
      detail: '',
      updatedAt: 0,
      bytesDone: 0,
      bytesTotal: 0,
      active: false,
    );
  }

  factory CloudBackupProgress.fromMap(Map<String, dynamic> map) {
    return CloudBackupProgress(
      stage: map['stage']?.toString() ?? '',
      percent: _asInt(map['percent']).clamp(0, 100),
      detail: map['detail']?.toString() ?? '',
      updatedAt: _asInt(map['updatedAt']),
      bytesDone: _asInt(map['bytesDone']),
      bytesTotal: _asInt(map['bytesTotal']),
      active: _asBool(map['active']),
    );
  }
}

class CloudBackupStatus {
  const CloudBackupStatus({
    required this.lastAttemptAt,
    required this.lastSuccessAt,
    required this.lastStatus,
    required this.deviceId,
    required this.progress,
  });

  final int lastAttemptAt;
  final int lastSuccessAt;
  final String lastStatus;
  final String deviceId;
  final CloudBackupProgress progress;

  factory CloudBackupStatus.fromMap(Map<String, dynamic> map) {
    final Object? progressRaw = map['progress'];
    return CloudBackupStatus(
      lastAttemptAt: _asInt(map['lastAttemptAt']),
      lastSuccessAt: _asInt(map['lastSuccessAt']),
      lastStatus: map['lastStatus']?.toString() ?? '',
      deviceId: map['deviceId']?.toString() ?? '',
      progress: progressRaw is Map
          ? CloudBackupProgress.fromMap(
              progressRaw.map((Object? key, Object? value) {
                return MapEntry(key.toString(), value);
              }),
            )
          : CloudBackupProgress.empty(),
    );
  }
}

class CloudBackupService {
  CloudBackupService._();

  static final CloudBackupService instance = CloudBackupService._();

  static const int defaultFrequencyDays = 30;
  static const int defaultKeepLatestCount = 3;
  static const String baiduDeveloperDocsUrl =
      'https://pan.baidu.com/union/doc/fl0hhnulu';
  static const String baiduAuthorizeBaseUrl =
      'https://openapi.baidu.com/oauth/2.0/authorize';

  static const MethodChannel _channel = MethodChannel(
    'com.fqyw.screen_memo/accessibility',
  );

  final UserSettingsService _settings = UserSettingsService.instance;

  Future<CloudBackupSettings> loadSettings() async {
    final bool enabled = await _settings.getBool(
      UserSettingKeys.cloudBackupEnabled,
      defaultValue: false,
    );
    final int frequencyDays = (await _settings.getInt(
      UserSettingKeys.cloudBackupFrequencyDays,
      defaultValue: defaultFrequencyDays,
    )).clamp(1, 2147483647);
    final bool allowMobileData = await _settings.getBool(
      UserSettingKeys.cloudBackupAllowMobileData,
      defaultValue: false,
    );
    final int keepLatestCount = (await _settings.getInt(
      UserSettingKeys.cloudBackupKeepLatestCount,
      defaultValue: defaultKeepLatestCount,
    )).clamp(1, 2147483647);
    return CloudBackupSettings(
      enabled: enabled,
      frequencyDays: frequencyDays,
      allowMobileData: allowMobileData,
      keepLatestCount: keepLatestCount,
      appKey:
          await _settings.getString(
            UserSettingKeys.cloudBackupBaiduAppKey,
            defaultValue: '',
          ) ??
          '',
      secretKey:
          await _settings.getString(
            UserSettingKeys.cloudBackupBaiduSecretKey,
            defaultValue: '',
          ) ??
          '',
      authorizationCode:
          await _settings.getString(
            UserSettingKeys.cloudBackupBaiduAuthorizationCode,
            defaultValue: '',
          ) ??
          '',
      accessToken:
          await _settings.getString(
            UserSettingKeys.cloudBackupBaiduAccessToken,
            defaultValue: '',
          ) ??
          '',
      refreshToken:
          await _settings.getString(
            UserSettingKeys.cloudBackupBaiduRefreshToken,
            defaultValue: '',
          ) ??
          '',
      tokenExpiresAt: await _settings.getInt(
        UserSettingKeys.cloudBackupBaiduTokenExpiresAt,
        defaultValue: 0,
      ),
      lastSuccessAt: await _settings.getInt(
        UserSettingKeys.cloudBackupLastSuccessAt,
        defaultValue: 0,
      ),
      lastAttemptAt: await _settings.getInt(
        UserSettingKeys.cloudBackupLastAttemptAt,
        defaultValue: 0,
      ),
      lastStatus:
          await _settings.getString(
            UserSettingKeys.cloudBackupLastStatus,
            defaultValue: '',
          ) ??
          '',
      deviceId:
          await _settings.getString(
            UserSettingKeys.cloudBackupDeviceId,
            defaultValue: '',
          ) ??
          '',
    );
  }

  Future<void> saveSettings({
    required bool enabled,
    required int frequencyDays,
    required bool allowMobileData,
    required int keepLatestCount,
    required String appKey,
    required String secretKey,
    required String authorizationCode,
  }) async {
    final String nextAppKey = appKey.trim();
    final String nextSecretKey = secretKey.trim();
    final String nextAuthorizationCode = authorizationCode.trim();
    final String previousAppKey =
        await _settings.getString(
          UserSettingKeys.cloudBackupBaiduAppKey,
          defaultValue: '',
        ) ??
        '';
    final String previousSecretKey =
        await _settings.getString(
          UserSettingKeys.cloudBackupBaiduSecretKey,
          defaultValue: '',
        ) ??
        '';
    final bool credentialsChanged =
        previousAppKey != nextAppKey || previousSecretKey != nextSecretKey;

    await _settings.setBool(UserSettingKeys.cloudBackupEnabled, enabled);
    await _settings.setInt(
      UserSettingKeys.cloudBackupFrequencyDays,
      frequencyDays.clamp(1, 2147483647),
    );
    await _settings.setBool(
      UserSettingKeys.cloudBackupAllowMobileData,
      allowMobileData,
    );
    await _settings.setInt(
      UserSettingKeys.cloudBackupKeepLatestCount,
      keepLatestCount.clamp(1, 2147483647),
    );
    await _settings.setString(
      UserSettingKeys.cloudBackupBaiduAppKey,
      nextAppKey,
    );
    await _settings.setString(
      UserSettingKeys.cloudBackupBaiduSecretKey,
      nextSecretKey,
    );
    await _settings.setString(
      UserSettingKeys.cloudBackupBaiduAuthorizationCode,
      nextAuthorizationCode,
    );
    if (credentialsChanged) {
      await _settings.setString(
        UserSettingKeys.cloudBackupBaiduAccessToken,
        '',
      );
      await _settings.setString(
        UserSettingKeys.cloudBackupBaiduRefreshToken,
        '',
      );
      await _settings.setString(
        UserSettingKeys.cloudBackupBaiduTokenExpiresAt,
        '0',
      );
      await _settings.setString(
        UserSettingKeys.cloudBackupLastStatus,
        'authorization_required',
      );
    }
    await reschedule();
  }

  Uri buildAuthorizeUri(String appKey) {
    return Uri.parse(baiduAuthorizeBaseUrl).replace(
      queryParameters: <String, String>{
        'response_type': 'code',
        'client_id': appKey.trim(),
        'redirect_uri': 'oob',
        'scope': 'basic,netdisk',
      },
    );
  }

  Future<Map<String, dynamic>> exchangeCode(String code) async {
    return _invokeMap('baiduCloudBackupExchangeCode', <String, Object?>{
      'code': code.trim(),
    });
  }

  Future<Map<String, dynamic>> testConnection() async {
    return _invokeMap('baiduCloudBackupTestConnection');
  }

  Future<Map<String, dynamic>> runNow() async {
    return _invokeMap('baiduCloudBackupRunNow');
  }

  Future<Map<String, dynamic>> reschedule() async {
    if (!Platform.isAndroid) {
      return <String, dynamic>{'ok': true, 'platform': 'unsupported'};
    }
    return _invokeMap('baiduCloudBackupReschedule');
  }

  Future<Map<String, dynamic>> getStatus() async {
    return _invokeMap('baiduCloudBackupGetStatus');
  }

  Future<CloudBackupStatus> loadStatus() async {
    final Map<String, dynamic> map = await getStatus();
    if (map['ok'] == false) {
      throw StateError(map['error']?.toString() ?? 'Failed to read status.');
    }
    return CloudBackupStatus.fromMap(map);
  }

  Future<Map<String, dynamic>> _invokeMap(
    String method, [
    Map<String, Object?>? args,
  ]) async {
    if (!Platform.isAndroid) {
      return <String, dynamic>{'ok': false, 'error': 'Android only'};
    }
    final Object? raw = await _channel.invokeMethod<Object?>(method, args);
    if (raw is Map) {
      return raw.map((Object? key, Object? value) {
        return MapEntry(key.toString(), value);
      });
    }
    return <String, dynamic>{'ok': raw == true, 'value': raw};
  }
}

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

bool _asBool(Object? value) {
  if (value is bool) return value;
  final String raw = value?.toString().toLowerCase() ?? '';
  return raw == '1' || raw == 'true' || raw == 'yes' || raw == 'on';
}

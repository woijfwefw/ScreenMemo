import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_memo/core/theme/app_theme.dart';
import 'package:screen_memo/core/widgets/ui_components.dart';
import 'package:screen_memo/features/backup/application/cloud_backup_service.dart';
import 'package:screen_memo/l10n/app_localizations.dart';
import 'package:url_launcher/url_launcher.dart';

class CloudBackupSettingsPage extends StatefulWidget {
  const CloudBackupSettingsPage({super.key});

  @override
  State<CloudBackupSettingsPage> createState() =>
      _CloudBackupSettingsPageState();
}

class _CloudBackupSettingsPageState extends State<CloudBackupSettingsPage> {
  final CloudBackupService _service = CloudBackupService.instance;
  final TextEditingController _appKeyController = TextEditingController();
  final TextEditingController _secretKeyController = TextEditingController();
  final TextEditingController _codeController = TextEditingController();
  final TextEditingController _frequencyController = TextEditingController();
  final TextEditingController _keepLatestController = TextEditingController();

  bool _loading = true;
  bool _enabled = false;
  bool _allowMobileData = false;
  bool _busy = false;
  bool _backupActionLocked = false;
  CloudBackupSettings? _settings;
  CloudBackupProgress _progress = CloudBackupProgress.empty();
  Timer? _statusPollTimer;

  @override
  void initState() {
    super.initState();
    _appKeyController.addListener(_onFormChanged);
    _secretKeyController.addListener(_onFormChanged);
    _codeController.addListener(_onFormChanged);
    _load();
    _startStatusPolling();
  }

  @override
  void dispose() {
    _statusPollTimer?.cancel();
    _appKeyController.removeListener(_onFormChanged);
    _secretKeyController.removeListener(_onFormChanged);
    _codeController.removeListener(_onFormChanged);
    _appKeyController.dispose();
    _secretKeyController.dispose();
    _codeController.dispose();
    _frequencyController.dispose();
    _keepLatestController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final CloudBackupSettings settings = await _service.loadSettings();
    if (!mounted) return;
    _appKeyController.text = settings.appKey;
    _secretKeyController.text = settings.secretKey;
    _codeController.text = settings.authorizationCode;
    _frequencyController.text = settings.frequencyDays.toString();
    _keepLatestController.text = settings.keepLatestCount.toString();
    setState(() {
      _settings = settings;
      _enabled = settings.enabled;
      _allowMobileData = settings.allowMobileData;
      _loading = false;
    });
    await _refreshStatus();
  }

  void _onFormChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<bool> _save() async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final int? frequencyDays = int.tryParse(_frequencyController.text.trim());
    final int? keepLatest = int.tryParse(_keepLatestController.text.trim());
    if (frequencyDays == null || frequencyDays < 1) {
      UINotifier.error(context, l10n.cloudBackupFrequencyInvalid);
      return false;
    }
    if (keepLatest == null || keepLatest < 1) {
      UINotifier.error(context, l10n.cloudBackupKeepLatestInvalid);
      return false;
    }
    bool saved = false;
    await _runBusy(() async {
      await _service.saveSettings(
        enabled: _enabled,
        frequencyDays: frequencyDays,
        allowMobileData: _allowMobileData,
        keepLatestCount: keepLatest,
        appKey: _appKeyController.text,
        secretKey: _secretKeyController.text,
        authorizationCode: _codeController.text,
      );
      if (!mounted) return;
      UINotifier.success(context, l10n.cloudBackupSettingsSaved);
      await _load();
      saved = true;
    });
    return saved;
  }

  Future<void> _openAuthorizePage() async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final String appKey = _appKeyController.text.trim();
    if (appKey.isEmpty) {
      UINotifier.error(context, l10n.cloudBackupAppKeyRequired);
      return;
    }
    final bool saved = await _save();
    if (!saved || !mounted) return;
    final Uri uri = _service.buildAuthorizeUri(appKey);
    final bool opened = await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );
    if (!opened && mounted) {
      UINotifier.error(context, l10n.cloudBackupAuthPageOpenFailed);
    }
  }

  Future<void> _openDeveloperDocs() async {
    final Uri uri = Uri.parse(CloudBackupService.baiduDeveloperDocsUrl);
    final bool opened = await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );
    if (!opened && mounted) {
      UINotifier.error(
        context,
        AppLocalizations.of(context).cloudBackupDeveloperDocsOpenFailed,
      );
    }
  }

  Future<void> _exchangeCode() async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final String code = _codeController.text.trim();
    if (!_hasAppSecret) {
      UINotifier.error(context, l10n.cloudBackupAppSecretRequired);
      return;
    }
    if (code.isEmpty) {
      UINotifier.error(context, l10n.cloudBackupAuthCodeRequired);
      return;
    }
    final bool saved = await _save();
    if (!saved || !mounted) return;
    await _runBusy(() async {
      final Map<String, dynamic> result = await _service.exchangeCode(code);
      if (!mounted) return;
      if (result['ok'] == true) {
        UINotifier.success(context, l10n.cloudBackupAuthorizationComplete);
        await _load();
      } else {
        UINotifier.error(
          context,
          _formatResultError(
            result,
            fallback: l10n.cloudBackupAuthorizationFailed,
            withError: l10n.cloudBackupAuthorizationFailedWithError,
          ),
        );
      }
    });
  }

  Future<void> _testConnection() async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    if (!_canUseAuthorizedActions) {
      UINotifier.error(context, l10n.cloudBackupAuthorizationRequired);
      return;
    }
    final bool saved = await _save();
    if (!saved || !mounted) return;
    await _runBusy(() async {
      final Map<String, dynamic> result = await _service.testConnection();
      if (!mounted) return;
      if (result['ok'] == true) {
        UINotifier.success(context, l10n.cloudBackupConnectionSuccessful);
        await _load();
      } else {
        UINotifier.error(
          context,
          _formatResultError(
            result,
            fallback: l10n.cloudBackupConnectionFailed,
            withError: l10n.cloudBackupConnectionFailedWithError,
          ),
        );
      }
    });
  }

  Future<void> _runNow() async {
    final AppLocalizations l10n = AppLocalizations.of(context);
    if (!_canUseAuthorizedActions) {
      UINotifier.error(context, l10n.cloudBackupAuthorizationRequired);
      return;
    }
    final bool saved = await _save();
    if (!saved || !mounted) return;
    await _runBusy(() async {
      final Map<String, dynamic> result = await _service.runNow();
      if (!mounted) return;
      if (result['ok'] == true) {
        setState(() {
          _backupActionLocked = true;
          _progress = const CloudBackupProgress(
            stage: 'queued',
            percent: 0,
            detail: '',
            updatedAt: 0,
            bytesDone: 0,
            bytesTotal: 0,
            active: true,
          );
        });
        UINotifier.success(context, l10n.cloudBackupBackupStarted);
        await _refreshStatus();
      } else {
        UINotifier.error(
          context,
          _formatResultError(
            result,
            fallback: l10n.cloudBackupStartFailed,
            withError: l10n.cloudBackupStartFailedWithError,
          ),
        );
      }
    });
  }

  void _startStatusPolling() {
    _statusPollTimer?.cancel();
    _statusPollTimer = Timer.periodic(const Duration(milliseconds: 1500), (_) {
      _refreshStatus(silent: true);
    });
  }

  Future<void> _refreshStatus({bool silent = false}) async {
    try {
      final CloudBackupStatus status = await _service.loadStatus();
      if (!mounted) return;
      setState(() {
        _settings = CloudBackupSettings(
          enabled: _settings?.enabled ?? false,
          frequencyDays:
              _settings?.frequencyDays ??
              CloudBackupService.defaultFrequencyDays,
          allowMobileData: _settings?.allowMobileData ?? false,
          keepLatestCount:
              _settings?.keepLatestCount ??
              CloudBackupService.defaultKeepLatestCount,
          appKey: _settings?.appKey ?? '',
          secretKey: _settings?.secretKey ?? '',
          authorizationCode: _settings?.authorizationCode ?? '',
          accessToken: _settings?.accessToken ?? '',
          refreshToken: _settings?.refreshToken ?? '',
          tokenExpiresAt: _settings?.tokenExpiresAt ?? 0,
          lastSuccessAt: status.lastSuccessAt,
          lastAttemptAt: status.lastAttemptAt,
          lastStatus: status.lastStatus,
          deviceId: status.deviceId,
        );
        _progress = status.progress;
        _backupActionLocked =
            status.progress.active ||
            status.progress.stage == 'queued' ||
            status.lastStatus == 'running';
      });
    } catch (e) {
      if (!silent && mounted) {
        UINotifier.error(context, e.toString());
      }
    }
  }

  Future<void> _runBusy(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on PlatformException catch (e) {
      if (!mounted) return;
      UINotifier.error(context, e.message ?? e.code);
    } catch (e) {
      if (!mounted) return;
      UINotifier.error(context, e.toString());
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final AppLocalizations l10n = AppLocalizations.of(context);
    final bool backupRunning = _progress.active || _backupActionLocked;
    final bool canOpenAuth = !_busy && _appKeyController.text.trim().isNotEmpty;
    final bool canExchange =
        !_busy && _hasAppSecret && _codeController.text.trim().isNotEmpty;
    final bool canEditBottomActions = !_busy && !backupRunning;
    final bool canUseCloudActions =
        canEditBottomActions && _canUseAuthorizedActions;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.cloudBackupTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  AppTheme.spacing4,
                  AppTheme.spacing3,
                  AppTheme.spacing4,
                  AppTheme.spacing5,
                ),
                children: [
                  _buildTogglePanel(theme, l10n),
                  const SizedBox(height: AppTheme.spacing3),
                  _buildNumberGrid(theme, l10n),
                  const SizedBox(height: AppTheme.spacing3),
                  _buildPlatformPanel(
                    theme: theme,
                    l10n: l10n,
                    canOpenAuth: canOpenAuth,
                    canExchange: canExchange,
                    canUseCloudActions: canUseCloudActions,
                  ),
                  const SizedBox(height: AppTheme.spacing3),
                  _buildStatusPanel(
                    theme: theme,
                    l10n: l10n,
                    canUseCloudActions: canUseCloudActions,
                    canEditBottomActions: canEditBottomActions,
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildTogglePanel(ThemeData theme, AppLocalizations l10n) {
    return _panel(
      theme,
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          _toggleRow(
            theme: theme,
            icon: Icons.cloud_upload_outlined,
            title: l10n.cloudBackupEnableTitle,
            subtitle: l10n.cloudBackupEnableSubtitle,
            value: _enabled,
            onChanged: _busy
                ? null
                : (bool value) => setState(() => _enabled = value),
          ),
          _toggleRow(
            theme: theme,
            icon: Icons.wifi_tethering_outlined,
            title: l10n.cloudBackupAllowMobileDataTitle,
            subtitle: l10n.cloudBackupAllowMobileDataSubtitle,
            value: _allowMobileData,
            onChanged: _busy
                ? null
                : (bool value) => setState(() => _allowMobileData = value),
          ),
        ],
      ),
    );
  }

  Widget _toggleRow({
    required ThemeData theme,
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.spacing3,
        vertical: AppTheme.spacing2,
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: AppTheme.spacing3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppTheme.spacing2),
          Switch.adaptive(value: value, onChanged: onChanged),
        ],
      ),
    );
  }

  Widget _buildNumberGrid(ThemeData theme, AppLocalizations l10n) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool stacked = constraints.maxWidth < 340;
        final List<Widget> cards = <Widget>[
          _numberCard(
            theme: theme,
            controller: _frequencyController,
            icon: Icons.calendar_month_outlined,
            label: l10n.cloudBackupFrequencyLabel,
            helper: l10n.cloudBackupFrequencyHelper,
          ),
          _numberCard(
            theme: theme,
            controller: _keepLatestController,
            icon: Icons.inventory_2_outlined,
            label: l10n.cloudBackupKeepLatestLabel,
            helper: l10n.cloudBackupKeepLatestHelper,
          ),
        ];
        if (stacked) {
          return Column(
            children: [
              cards.first,
              const SizedBox(height: AppTheme.spacing2),
              cards.last,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: cards.first),
            const SizedBox(width: AppTheme.spacing2),
            Expanded(child: cards.last),
          ],
        );
      },
    );
  }

  Widget _numberCard({
    required ThemeData theme,
    required TextEditingController controller,
    required IconData icon,
    required String label,
    required String helper,
  }) {
    return _panel(
      theme,
      padding: const EdgeInsets.all(AppTheme.spacing2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: AppTheme.spacing1),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppTheme.spacing2),
          Row(
            children: [
              _stepButton(
                theme: theme,
                icon: Icons.remove,
                onPressed: _busy ? null : () => _changeNumber(controller, -1),
              ),
              const SizedBox(width: AppTheme.spacing1),
              Expanded(
                child: SizedBox(
                  height: 36,
                  child: TextField(
                    controller: controller,
                    textAlign: TextAlign.center,
                    keyboardType: TextInputType.number,
                    inputFormatters: <TextInputFormatter>[
                      FilteringTextInputFormatter.digitsOnly,
                    ],
                    decoration: _compactInputDecoration(theme),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: AppTheme.spacing1),
              _stepButton(
                theme: theme,
                icon: Icons.add,
                onPressed: _busy ? null : () => _changeNumber(controller, 1),
              ),
            ],
          ),
          const SizedBox(height: AppTheme.spacing1),
          Text(
            helper,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _stepButton({
    required ThemeData theme,
    required IconData icon,
    required VoidCallback? onPressed,
  }) {
    return SizedBox(
      width: 36,
      height: 36,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          padding: EdgeInsets.zero,
          backgroundColor: theme.colorScheme.surfaceContainerLowest,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          ),
          side: BorderSide.none,
        ),
        child: Icon(icon, size: 18),
      ),
    );
  }

  Widget _buildPlatformPanel({
    required ThemeData theme,
    required AppLocalizations l10n,
    required bool canOpenAuth,
    required bool canExchange,
    required bool canUseCloudActions,
  }) {
    return _panel(
      theme,
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppTheme.spacing3,
              vertical: AppTheme.spacing1,
            ),
            child: Row(
              children: [
                Icon(
                  Icons.cloud_queue_outlined,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: AppTheme.spacing2),
                Expanded(
                  child: Text(
                    l10n.cloudBackupBaiduPlatformSection,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: _busy ? null : _openDeveloperDocs,
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: Text(l10n.cloudBackupOpenDeveloperDocsShort),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.spacing3,
              AppTheme.spacing2,
              AppTheme.spacing3,
              AppTheme.spacing3,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  l10n.cloudBackupKeyGuide,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppTheme.spacing2),
                _compactTextField(
                  theme: theme,
                  controller: _appKeyController,
                  label: l10n.cloudBackupAppKeyLabel,
                ),
                const SizedBox(height: AppTheme.spacing2),
                _compactTextField(
                  theme: theme,
                  controller: _secretKeyController,
                  label: l10n.cloudBackupSecretKeyLabel,
                ),
                const SizedBox(height: AppTheme.spacing2),
                _compactTextField(
                  theme: theme,
                  controller: _codeController,
                  label: l10n.cloudBackupAuthorizationCodeLabel,
                  hint: l10n.cloudBackupAuthorizationCodeHelper,
                ),
                const SizedBox(height: AppTheme.spacing2),
                Row(
                  children: [
                    Expanded(
                      child: _actionButton(
                        theme: theme,
                        icon: Icons.open_in_new,
                        label: l10n.cloudBackupOpenAuthPage,
                        onPressed: canOpenAuth ? _openAuthorizePage : null,
                      ),
                    ),
                    const SizedBox(width: AppTheme.spacing1),
                    Expanded(
                      child: _actionButton(
                        theme: theme,
                        icon: Icons.key_outlined,
                        label: l10n.cloudBackupExchangeCode,
                        onPressed: canExchange ? _exchangeCode : null,
                      ),
                    ),
                    const SizedBox(width: AppTheme.spacing1),
                    Expanded(
                      child: _actionButton(
                        theme: theme,
                        icon: Icons.cloud_done_outlined,
                        label: l10n.cloudBackupTestConnection,
                        onPressed: canUseCloudActions ? _testConnection : null,
                        accent: true,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusPanel({
    required ThemeData theme,
    required AppLocalizations l10n,
    required bool canUseCloudActions,
    required bool canEditBottomActions,
  }) {
    final String rawStatus = _settings?.lastStatus ?? '';
    final bool hideStatusText = rawStatus == 'running';
    return _panel(
      theme,
      padding: const EdgeInsets.all(AppTheme.spacing3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_progress.hasProgress && _progress.active) ...[
            _progressPanel(_progress, l10n, theme),
            const SizedBox(height: AppTheme.spacing3),
          ],
          _statusLine(
            theme: theme,
            label: l10n.cloudBackupDeviceId,
            value: _settings?.deviceId,
            l10n: l10n,
          ),
          const SizedBox(height: AppTheme.spacing2),
          _statusLine(
            theme: theme,
            label: l10n.cloudBackupLastAttempt,
            value: _formatMillis(_settings?.lastAttemptAt ?? 0, l10n),
            l10n: l10n,
          ),
          const SizedBox(height: AppTheme.spacing2),
          _statusLine(
            theme: theme,
            label: l10n.cloudBackupLastSuccess,
            value: _formatMillis(_settings?.lastSuccessAt ?? 0, l10n),
            l10n: l10n,
          ),
          const SizedBox(height: AppTheme.spacing2),
          if (!hideStatusText) ...[
            _statusLine(
              theme: theme,
              value: _formatStatus(rawStatus, l10n),
              valueColor: _statusColor(theme, rawStatus),
              l10n: l10n,
              valueOnly: true,
            ),
            const SizedBox(height: AppTheme.spacing3),
          ] else
            const SizedBox(height: AppTheme.spacing1),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: canEditBottomActions ? _save : null,
                  icon: const Icon(Icons.save_outlined),
                  label: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(l10n.cloudBackupSave),
                  ),
                ),
              ),
              const SizedBox(width: AppTheme.spacing2),
              Expanded(
                child: FilledButton.icon(
                  onPressed: canUseCloudActions ? _runNow : null,
                  icon: const Icon(Icons.cloud_upload_outlined),
                  label: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(l10n.cloudBackupRunNow),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _panel(
    ThemeData theme, {
    required Widget child,
    EdgeInsetsGeometry padding = const EdgeInsets.all(AppTheme.spacing3),
    Color? color,
  }) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color ?? theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      ),
      child: Padding(padding: padding, child: child),
    );
  }

  Widget _compactTextField({
    required ThemeData theme,
    required TextEditingController controller,
    required String label,
    String? hint,
  }) {
    return SizedBox(
      height: 48,
      child: TextField(
        controller: controller,
        decoration: _compactInputDecoration(theme, label: label, hint: hint),
        maxLines: 1,
      ),
    );
  }

  Widget _actionButton({
    required ThemeData theme,
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
    bool accent = false,
  }) {
    final Color? foreground = accent ? theme.colorScheme.primary : null;
    return SizedBox(
      height: 40,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacing1),
          backgroundColor: theme.colorScheme.surfaceContainerLowest,
          foregroundColor: foreground,
          side: BorderSide.none,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16),
            const SizedBox(width: AppTheme.spacing1),
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  maxLines: 1,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusLine({
    required ThemeData theme,
    String? label,
    required String? value,
    required AppLocalizations l10n,
    Color? valueColor,
    bool valueOnly = false,
  }) {
    final String text = value == null || value.isEmpty
        ? l10n.cloudBackupNotAvailable
        : value;
    if (valueOnly) {
      return Text(
        text,
        softWrap: true,
        style: theme.textTheme.bodySmall?.copyWith(
          color: valueColor ?? theme.colorScheme.onSurface,
          fontSize: AppTheme.fontSizeXs,
          fontWeight: FontWeight.w700,
          height: 1.35,
        ),
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(width: AppTheme.spacing1),
        Expanded(
          child: Text(
            text,
            softWrap: true,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: valueColor ?? theme.colorScheme.onSurface,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }

  InputDecoration _compactInputDecoration(
    ThemeData theme, {
    String? label,
    String? hint,
  }) {
    final OutlineInputBorder border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      borderSide: BorderSide.none,
    );
    return InputDecoration(
      labelText: label,
      hintText: hint,
      filled: true,
      fillColor: theme.colorScheme.surfaceContainerLowest,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppTheme.spacing2,
        vertical: AppTheme.spacing2,
      ),
      border: border,
      enabledBorder: border,
      focusedBorder: border.copyWith(borderSide: BorderSide.none),
    );
  }

  void _changeNumber(TextEditingController controller, int delta) {
    final int current = int.tryParse(controller.text.trim()) ?? 1;
    final int next = (current + delta).clamp(1, 2147483647);
    controller.text = next.toString();
    controller.selection = TextSelection.collapsed(
      offset: controller.text.length,
    );
    setState(() {});
  }

  Color? _statusColor(ThemeData theme, String status) {
    if (status == 'authorization_required') {
      return const Color(0xFFA86B22);
    }
    if (status.startsWith('failed:')) return theme.colorScheme.error;
    if (status.startsWith('success:')) return AppTheme.success;
    if (status == 'running') return theme.colorScheme.primary;
    return null;
  }

  Widget _progressPanel(
    CloudBackupProgress progress,
    AppLocalizations l10n,
    ThemeData theme,
  ) {
    final String percentLabel = l10n.cloudBackupProgressPercent(
      progress.percent,
    );
    final String stageLabel = _formatProgressStage(progress.stage, l10n);
    final bool showBytes = progress.bytesTotal > 0;
    final String detail = showBytes
        ? l10n.cloudBackupProgressBytes(
            _formatBytes(progress.bytesDone),
            _formatBytes(progress.bytesTotal),
          )
        : progress.detail;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.cloudBackupProgressTitle,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              percentLabel,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppTheme.spacing2),
        LinearProgressIndicator(
          value: progress.value,
          minHeight: 6,
          borderRadius: BorderRadius.circular(999),
        ),
        const SizedBox(height: AppTheme.spacing2),
        Text(
          detail.isEmpty ? stageLabel : '$stageLabel · $detail',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  bool get _hasAppSecret =>
      _appKeyController.text.trim().isNotEmpty &&
      _secretKeyController.text.trim().isNotEmpty;

  bool get _canUseAuthorizedActions {
    final CloudBackupSettings? settings = _settings;
    return _hasAppSecret &&
        (settings?.isAuthorized ?? false) &&
        settings?.appKey == _appKeyController.text.trim() &&
        settings?.secretKey == _secretKeyController.text.trim();
  }

  String _formatMillis(int millis, AppLocalizations l10n) {
    if (millis <= 0) return l10n.cloudBackupNever;
    return DateTime.fromMillisecondsSinceEpoch(millis).toLocal().toString();
  }

  String _formatStatus(String status, AppLocalizations l10n) {
    if (status.isEmpty) return l10n.cloudBackupNotAvailable;
    if (status == 'running') return l10n.cloudBackupStatusRunning;
    if (status == 'skipped:not_due') {
      return l10n.cloudBackupStatusSkippedNotDue;
    }
    if (status == 'authorization_required') {
      return l10n.cloudBackupStatusAuthorizationRequired;
    }
    if (status.startsWith('success:')) {
      return l10n.cloudBackupStatusSuccess(status.substring('success:'.length));
    }
    if (status.startsWith('failed:')) {
      return l10n.cloudBackupStatusFailed(status.substring('failed:'.length));
    }
    return l10n.cloudBackupStatusUnknown(status);
  }

  String _formatProgressStage(String stage, AppLocalizations l10n) {
    return switch (stage) {
      'queued' => l10n.cloudBackupProgressQueued,
      'checking' => l10n.cloudBackupProgressChecking,
      'preparing' => l10n.cloudBackupProgressPreparing,
      'zipping' => l10n.cloudBackupProgressZipping,
      'remote_folder' => l10n.cloudBackupProgressRemoteFolder,
      'preparing_upload' => l10n.cloudBackupProgressPreparingUpload,
      'precreate' => l10n.cloudBackupProgressPrecreate,
      'uploading' => l10n.cloudBackupProgressUploading,
      'creating_remote_file' => l10n.cloudBackupProgressCreatingRemoteFile,
      'cleanup' => l10n.cloudBackupProgressCleanup,
      'finished' => l10n.cloudBackupProgressFinished,
      'failed' => l10n.cloudBackupProgressFailed,
      'skipped' => l10n.cloudBackupStatusSkippedNotDue,
      'disabled' => l10n.cloudBackupProgressDisabled,
      _ => stage.isEmpty ? l10n.cloudBackupNotAvailable : stage,
    };
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const List<String> units = <String>['B', 'KB', 'MB', 'GB', 'TB'];
    double value = bytes.toDouble();
    int unitIndex = 0;
    while (value >= 1024 && unitIndex < units.length - 1) {
      value /= 1024;
      unitIndex++;
    }
    final String text = value >= 10 || unitIndex == 0
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(1);
    return '$text ${units[unitIndex]}';
  }

  String _formatResultError(
    Map<String, dynamic> result, {
    required String fallback,
    required String Function(String error) withError,
  }) {
    final String? error = result['error']?.toString().trim();
    if (error == null || error.isEmpty) return fallback;
    return withError(error);
  }
}

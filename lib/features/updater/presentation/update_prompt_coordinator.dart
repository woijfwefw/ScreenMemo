import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:screen_memo/core/theme/app_theme.dart';
import 'package:screen_memo/core/widgets/ui_components.dart';
import 'package:screen_memo/core/widgets/ui_dialog.dart';
import 'package:screen_memo/features/updater/application/update_changelog.dart';
import 'package:screen_memo/features/updater/application/update_models.dart';
import 'package:screen_memo/features/updater/application/update_platform_service.dart';
import 'package:screen_memo/features/updater/application/update_service.dart';
import 'package:screen_memo/l10n/app_localizations.dart';

enum _UpdatePromptChoice { download, ignore, close }

/// 负责把更新检查结果转换成用户可见弹窗。
class UpdatePromptCoordinator {
  UpdatePromptCoordinator._();

  static final UpdatePromptCoordinator instance = UpdatePromptCoordinator._();

  final UpdateService _updateService = UpdateService.instance;
  final UpdateDownloadService _downloadService = UpdateDownloadService();
  final UpdatePlatformService _platform = UpdatePlatformService();

  bool _prompting = false;
  bool _downloading = false;

  Future<void> checkAndPrompt(
    BuildContext context, {
    bool force = false,
    String reason = 'auto',
  }) async {
    if (_prompting || !context.mounted) return;

    final l10n = AppLocalizations.of(context);
    if (force) {
      UINotifier.info(context, l10n.updateChecking);
    }

    final result = await _updateService.checkForUpdate(
      force: force,
      reason: reason,
    );
    if (!context.mounted) return;

    switch (result.status) {
      case UpdateCheckStatus.updateAvailable:
        final candidate = result.candidate;
        if (candidate == null) return;
        await _showUpdateDialog(context, candidate);
        break;
      case UpdateCheckStatus.upToDate:
        if (force) UINotifier.success(context, l10n.updateNoUpdate);
        break;
      case UpdateCheckStatus.incompatible:
        if (force) UINotifier.warning(context, l10n.updateNoCompatibleApk);
        break;
      case UpdateCheckStatus.failed:
        if (force) {
          UINotifier.error(
            context,
            l10n.updateCheckFailed(
              result.errorMessage ?? l10n.updateUnknownError,
            ),
          );
        }
        break;
      case UpdateCheckStatus.skipped:
        break;
    }
  }

  Future<void> _showUpdateDialog(
    BuildContext context,
    UpdateCandidate candidate,
  ) async {
    if (_prompting) return;
    _prompting = true;
    try {
      final l10n = AppLocalizations.of(context);
      final choice = await showUIDialog<_UpdatePromptChoice>(
        context: context,
        title: l10n.updateNewVersionTitle,
        content: _UpdateInfoContent(candidate: candidate),
        actions: <UIDialogAction<_UpdatePromptChoice>>[
          UIDialogAction<_UpdatePromptChoice>(
            text: l10n.updateDownloadAction,
            style: UIDialogActionStyle.primary,
            result: _UpdatePromptChoice.download,
          ),
          UIDialogAction<_UpdatePromptChoice>(
            text: l10n.updateIgnoreVersionAction,
            result: _UpdatePromptChoice.ignore,
          ),
          UIDialogAction<_UpdatePromptChoice>(
            text: l10n.updateCloseAction,
            result: _UpdatePromptChoice.close,
          ),
        ],
      );

      if (!context.mounted) return;
      switch (choice) {
        case _UpdatePromptChoice.download:
          await _downloadAndInstall(context, candidate);
          break;
        case _UpdatePromptChoice.ignore:
          await _updateService.ignoreVersion(candidate.release.version);
          if (context.mounted) {
            UINotifier.success(context, l10n.updateIgnoredToast);
          }
          break;
        case _UpdatePromptChoice.close:
        case null:
          break;
      }
    } finally {
      _prompting = false;
    }
  }

  Future<void> _downloadAndInstall(
    BuildContext context,
    UpdateCandidate candidate,
  ) async {
    if (_downloading) return;
    final l10n = AppLocalizations.of(context);

    if (!await _ensureInstallPermission(context)) {
      return;
    }
    if (!context.mounted) return;

    _downloading = true;
    final progress = ValueNotifier<UpdateDownloadProgress>(
      const UpdateDownloadProgress.empty(),
    );
    BuildContext? progressDialogContext;

    final dialogFuture = showUIDialog<void>(
      context: context,
      title: l10n.updateDownloadTitle,
      barrierDismissible: false,
      content: Builder(
        builder: (dialogContext) {
          progressDialogContext = dialogContext;
          return ValueListenableBuilder<UpdateDownloadProgress>(
            valueListenable: progress,
            builder: (context, value, _) {
              final double? indicatorValue =
                  value.totalBytes == null || value.totalBytes == 0
                  ? null
                  : (value.receivedBytes / value.totalBytes!).clamp(0.0, 1.0);
              final String label = value.totalBytes == null
                  ? l10n.updateDownloadProgressUnknown(
                      _formatBytes(value.receivedBytes),
                    )
                  : l10n.updateDownloadProgress(
                      _formatBytes(value.receivedBytes),
                      _formatBytes(value.totalBytes!),
                    );
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  LinearProgressIndicator(value: indicatorValue),
                  const SizedBox(height: AppTheme.spacing3),
                  Text(label, textAlign: TextAlign.center),
                ],
              );
            },
          );
        },
      ),
    );

    late final String apkPath;
    try {
      apkPath = await _downloadService.downloadApk(
        candidate.asset,
        onProgress: (value) => progress.value = value,
      );
    } catch (e) {
      if (context.mounted) {
        UINotifier.error(context, l10n.updateDownloadFailed(e.toString()));
      }
      return;
    } finally {
      _downloading = false;
      final dialogContext = progressDialogContext;
      if (dialogContext != null && dialogContext.mounted) {
        Navigator.of(dialogContext).pop();
      } else if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      try {
        await dialogFuture;
      } catch (_) {}
      progress.dispose();
    }

    if (!context.mounted) return;
    UINotifier.success(context, l10n.updateDownloadComplete);
    try {
      final opened = await _platform.installApk(apkPath);
      if (!context.mounted) return;
      if (opened) {
        UINotifier.info(context, l10n.updateInstalling);
      } else {
        UINotifier.error(
          context,
          l10n.updateInstallFailed(l10n.updateUnknownError),
        );
      }
    } catch (e) {
      if (context.mounted) {
        UINotifier.error(context, l10n.updateInstallFailed(e.toString()));
      }
    }
  }

  Future<bool> _ensureInstallPermission(BuildContext context) async {
    if (!Platform.isAndroid) return false;
    try {
      if (await _platform.canRequestPackageInstalls()) return true;
    } catch (_) {
      return true;
    }
    if (!context.mounted) return false;

    final l10n = AppLocalizations.of(context);
    final openSettings =
        await showUIDialog<bool>(
          context: context,
          title: l10n.updateInstallPermissionTitle,
          message: l10n.updateInstallPermissionMessage,
          actions: <UIDialogAction<bool>>[
            UIDialogAction<bool>(text: l10n.dialogCancel, result: false),
            UIDialogAction<bool>(
              text: l10n.updateOpenInstallSettingsAction,
              style: UIDialogActionStyle.primary,
              result: true,
            ),
          ],
        ) ??
        false;
    if (!openSettings) return false;
    try {
      await _platform.openInstallPermissionSettings();
    } catch (_) {}
    return false;
  }
}

class _UpdateInfoContent extends StatelessWidget {
  const _UpdateInfoContent({required this.candidate});

  final UpdateCandidate candidate;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final release = candidate.release;
    final noteItems = _buildNoteItems(release);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _InfoLine(
          label: l10n.updateCurrentVersionLabel,
          value: candidate.currentVersion,
        ),
        _InfoLine(label: l10n.updateLatestVersionLabel, value: release.version),
        if (release.publishedAt != null)
          _InfoLine(
            label: l10n.updatePublishedAtLabel,
            value: _formatDateTime(release.publishedAt!.toLocal()),
          ),
        _InfoLine(
          label: l10n.updateApkSizeLabel,
          value: candidate.asset.sizeBytes == null
              ? '—'
              : _formatBytes(candidate.asset.sizeBytes!),
        ),
        const SizedBox(height: AppTheme.spacing3),
        Text(
          l10n.updateReleaseNotesLabel,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: AppTheme.spacing1),
        _UpdateNotesList(items: noteItems),
      ],
    );
  }

  List<_DisplayUpdateNote> _buildNoteItems(UpdateReleaseInfo release) {
    final bodyItems = UpdateChangelogText.releaseBodyItems(release.body);
    if (bodyItems.isNotEmpty) {
      return bodyItems
          .map((text) => _DisplayUpdateNote(text: text))
          .toList(growable: false);
    }

    final fallback = release.name.trim().isEmpty
        ? release.version
        : release.name.trim();
    return <_DisplayUpdateNote>[_DisplayUpdateNote(text: fallback)];
  }

  String _formatDateTime(DateTime value) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${value.year}-${two(value.month)}-${two(value.day)} '
        '${two(value.hour)}:${two(value.minute)}';
  }
}

class _DisplayUpdateNote {
  const _DisplayUpdateNote({required this.text});

  final String text;
}

class _UpdateNotesList extends StatelessWidget {
  const _UpdateNotesList({required this.items});

  static const double _itemExtent = 56;
  static const double _maxHeight = 224;

  final List<_DisplayUpdateNote> items;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final height = (items.length * _itemExtent)
        .clamp(_itemExtent, _maxHeight)
        .toDouble();

    return ClipRRect(
      borderRadius: BorderRadius.circular(AppTheme.radiusSm),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.36,
          ),
          borderRadius: BorderRadius.circular(AppTheme.radiusSm),
          border: Border.all(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.8),
          ),
        ),
        child: SizedBox(
          height: height,
          child: ListView.builder(
            primary: false,
            padding: EdgeInsets.zero,
            itemExtent: _itemExtent,
            itemCount: items.length,
            itemBuilder: (context, index) {
              return _UpdateNoteTile(
                item: items[index],
                showDivider: index < items.length - 1,
              );
            },
          ),
        ),
      ),
    );
  }
}

class _UpdateNoteTile extends StatelessWidget {
  const _UpdateNoteTile({required this.item, required this.showDivider});

  final _DisplayUpdateNote item;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        border: showDivider
            ? Border(
                bottom: BorderSide(
                  color: theme.colorScheme.outlineVariant.withValues(
                    alpha: 0.72,
                  ),
                  width: 1,
                ),
              )
            : null,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.spacing3,
          vertical: AppTheme.spacing2,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '•',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: AppTheme.spacing2),
            Expanded(
              child: Text(
                item.text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.spacing1),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: AppTheme.spacing2),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = <String>['B', 'KB', 'MB', 'GB'];
  double value = bytes.toDouble();
  int unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex++;
  }
  final fixed = unitIndex == 0
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
  return '$fixed ${units[unitIndex]}';
}

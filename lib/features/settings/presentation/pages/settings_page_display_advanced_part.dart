part of 'settings_page.dart';

// ========== 显示与高级设置 ==========
extension _SettingsDisplayAdvancedPart on _SettingsPageState {
  Future<void> _loadLoggingEnabled() async {
    try {
      _loggingEnabled = FlutterLogger.enabled;
      _aiLoggingEnabled = await FlutterLogger.getCategoryEnabled('ai');
      _screenshotLoggingEnabled = await FlutterLogger.getCategoryEnabled(
        'screenshot',
      );
      if (mounted) _settingsSetState(() {});
    } catch (_) {}
  }

  Future<void> _updateLoggingEnabled(bool enabled) async {
    try {
      await FlutterLogger.setEnabled(enabled);
      if (mounted) _settingsSetState(() => _loggingEnabled = enabled);
    } catch (_) {}
  }

  Future<void> _updateAiLoggingEnabled(bool enabled) async {
    try {
      await FlutterLogger.setCategoryEnabled('ai', enabled);
      if (mounted) _settingsSetState(() => _aiLoggingEnabled = enabled);
    } catch (_) {}
  }

  Future<void> _updateScreenshotLoggingEnabled(bool enabled) async {
    try {
      await FlutterLogger.setCategoryEnabled('screenshot', enabled);
      if (mounted) _settingsSetState(() => _screenshotLoggingEnabled = enabled);
    } catch (_) {}
  }

  Future<void> _loadLogRetentionDays() async {
    try {
      final int days = await UserSettingsService.instance.getInt(
        UserSettingKeys.logRetentionDays,
        defaultValue: FlutterLogger.defaultLogRetentionDays,
      );
      if (mounted) {
        _settingsSetState(() => _logRetentionDays = math.max(1, days));
      }
    } catch (_) {}
  }

  Future<void> _updateLogRetentionDays(int days) async {
    final int value = math.max(1, days);
    _settingsSetState(() => _savingLogRetentionDays = true);
    try {
      await UserSettingsService.instance.setInt(
        UserSettingKeys.logRetentionDays,
        value,
      );
      await FlutterLogger.syncLogRetentionDaysToNative(value);
      if (mounted) {
        _settingsSetState(() => _logRetentionDays = value);
      }
    } finally {
      if (mounted) {
        _settingsSetState(() => _savingLogRetentionDays = false);
      }
    }
  }

  Future<void> _loadRenderImagesDuringStreaming() async {
    try {
      final v = await AISettingsService.instance
          .getRenderImagesDuringStreaming();
      if (mounted) _settingsSetState(() => _renderImagesDuringStreaming = v);
    } catch (_) {}
  }

  Future<void> _updateRenderImagesDuringStreaming(bool enabled) async {
    try {
      await AISettingsService.instance.setRenderImagesDuringStreaming(enabled);
      if (mounted) {
        _settingsSetState(() => _renderImagesDuringStreaming = enabled);
      }
    } catch (_) {}
  }

  Future<void> _loadAiChatPerfOverlayEnabled() async {
    try {
      final v = await AISettingsService.instance.getAiChatPerfOverlayEnabled();
      if (mounted) _settingsSetState(() => _aiChatPerfOverlayEnabled = v);
    } catch (_) {}
  }

  Future<void> _updateAiChatPerfOverlayEnabled(bool enabled) async {
    try {
      await AISettingsService.instance.setAiChatPerfOverlayEnabled(enabled);
      if (mounted) _settingsSetState(() => _aiChatPerfOverlayEnabled = enabled);
    } catch (_) {}
  }

  Future<void> _loadDynamicEntryLogIconEnabled() async {
    try {
      final bool enabled = await UserSettingsService.instance.getBool(
        UserSettingKeys.dynamicEntryLogIconEnabled,
        defaultValue: false,
      );
      if (mounted) {
        _settingsSetState(() => _dynamicEntryLogIconEnabled = enabled);
      }
    } catch (_) {}
  }

  Future<void> _updateDynamicEntryLogIconEnabled(bool enabled) async {
    try {
      await UserSettingsService.instance.setBool(
        UserSettingKeys.dynamicEntryLogIconEnabled,
        enabled,
      );
      if (mounted) {
        _settingsSetState(() => _dynamicEntryLogIconEnabled = enabled);
      }
    } catch (_) {}
  }

  String _themeModeLabel(BuildContext context, ThemeMode mode) {
    final AppLocalizations t = AppLocalizations.of(context);
    switch (mode) {
      case ThemeMode.system:
        return t.themeModeAuto;
      case ThemeMode.light:
        return t.themeModeLight;
      case ThemeMode.dark:
        return t.themeModeDark;
    }
  }

  Widget _buildThemeModeItem(BuildContext context) {
    final String currentMode = _themeModeLabel(
      context,
      widget.themeService.themeMode,
    );

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.spacing4,
        vertical: AppTheme.spacing3 - 2,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: _settingsDividerSide(context)),
      ),
      child: Row(
        children: [
          _buildSettingsLeadingIcon(context, Icons.brightness_6_outlined),
          const SizedBox(width: AppTheme.spacing3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppLocalizations.of(context).themeModeTitle,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 2),
                Text(
                  currentMode,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppTheme.spacing2),
          TextButton(
            onPressed: _showThemeModeSheet,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(
                horizontal: AppTheme.spacing3,
                vertical: AppTheme.spacing1 - 1,
              ),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              minimumSize: Size.zero,
              visualDensity: VisualDensity.compact,
            ),
            child: Text(currentMode),
          ),
        ],
      ),
    );
  }

  Widget _buildThemeColorsItem(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final AppThemeColors colors = widget.themeService.themeColors;
    final String status = colors.isDefault
        ? l10n.themeColorsDefaultBadge
        : l10n.themeColorsCustomBadge;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.spacing4,
        vertical: AppTheme.spacing3 - 2,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: _settingsDividerSide(context)),
      ),
      child: Row(
        children: [
          _buildSettingsLeadingIcon(context, Icons.palette_outlined),
          const SizedBox(width: AppTheme.spacing3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.themeColorTitle,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 2),
                Text(
                  '${l10n.themeColorDesc} · $status',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppTheme.spacing2),
                _buildThemeColorPreviewStrip(context, colors),
              ],
            ),
          ),
          const SizedBox(width: AppTheme.spacing2),
          TextButton(
            onPressed: _showThemeColorsSheet,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(
                horizontal: AppTheme.spacing3,
                vertical: AppTheme.spacing1 - 1,
              ),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              minimumSize: Size.zero,
              visualDensity: VisualDensity.compact,
            ),
            child: Text(l10n.actionEnter),
          ),
        ],
      ),
    );
  }

  Widget _buildThemeColorPreviewStrip(
    BuildContext context,
    AppThemeColors colors,
  ) {
    const List<String> previewKeys = <String>[
      AppThemeColors.primaryKey,
      AppThemeColors.secondaryKey,
      AppThemeColors.successKey,
      AppThemeColors.warningKey,
      AppThemeColors.destructiveKey,
      AppThemeColors.darkBackgroundKey,
    ];

    return Wrap(
      spacing: 5,
      runSpacing: 5,
      children: [
        for (final String key in previewKeys)
          _buildThemeColorSwatch(
            context,
            colors.colorFor(key),
            size: 18,
            tooltip: _themeColorLabel(context, key),
          ),
      ],
    );
  }

  Widget _buildThemeColorSwatch(
    BuildContext context,
    Color color, {
    double size = 28,
    String? tooltip,
  }) {
    final Widget swatch = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
      ),
    );
    if (tooltip == null) return swatch;
    return Tooltip(message: tooltip, child: swatch);
  }

  void _showThemeColorsSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            final AppLocalizations l10n = AppLocalizations.of(sheetContext);
            final ThemeData theme = Theme.of(sheetContext);
            final AppThemeColors colors = widget.themeService.themeColors;
            final double sheetHeight =
                MediaQuery.sizeOf(sheetContext).height * 0.86;

            return UISheetSurface(
              child: SizedBox(
                height: sheetHeight,
                child: Column(
                  children: [
                    const SizedBox(height: AppTheme.spacing3),
                    const UISheetHandle(),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        AppTheme.spacing4,
                        AppTheme.spacing3,
                        AppTheme.spacing3,
                        AppTheme.spacing2,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              l10n.themeColorsSheetTitle,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: l10n.themeColorsPasteTooltip,
                            onPressed: () => _pasteThemeColorsFromClipboard(
                              sheetContext,
                              setSheetState,
                            ),
                            icon: const Icon(Icons.content_paste, size: 20),
                          ),
                          IconButton(
                            tooltip: l10n.themeColorsCopyTooltip,
                            onPressed: () =>
                                _copyThemeColorsJsonToClipboard(sheetContext),
                            icon: const Icon(Icons.content_copy, size: 20),
                          ),
                          IconButton(
                            tooltip: l10n.actionResetToDefault,
                            onPressed: colors.isDefault
                                ? null
                                : () async {
                                    await widget.themeService
                                        .resetThemeColors();
                                    if (!mounted || !sheetContext.mounted) {
                                      return;
                                    }
                                    _settingsSetState(() {});
                                    setSheetState(() {});
                                    UINotifier.success(
                                      sheetContext,
                                      l10n.themeColorsResetSaved,
                                    );
                                  },
                            icon: const Icon(Icons.restart_alt, size: 20),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(
                          AppTheme.spacing4,
                          0,
                          AppTheme.spacing4,
                          AppTheme.spacing4,
                        ),
                        children: [
                          _buildThemePresetGroup(
                            sheetContext,
                            setSheetState: setSheetState,
                          ),
                          _buildThemeColorGroup(
                            sheetContext,
                            title: l10n.themeColorsLightBaseGroup,
                            keys: AppThemeColors.lightBaseKeys,
                            setSheetState: setSheetState,
                          ),
                          _buildThemeColorGroup(
                            sheetContext,
                            title: l10n.themeColorsStatusGroup,
                            keys: _themeColorVisibleStatusKeys,
                            setSheetState: setSheetState,
                          ),
                          _buildThemeColorGroup(
                            sheetContext,
                            title: l10n.themeColorsDarkBaseGroup,
                            keys: AppThemeColors.darkBaseKeys,
                            setSheetState: setSheetState,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildThemePresetGroup(
    BuildContext context, {
    required StateSetter setSheetState,
  }) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final ThemeData theme = Theme.of(context);
    final AppThemeColors current = widget.themeService.themeColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.spacing4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppTheme.spacing2),
            child: Text(
              l10n.themeColorsPresetGroup,
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: _buildThemePresetTile(
                  context,
                  title: l10n.themeColorsPresetDefault,
                  colors: AppThemeColors.defaults,
                  selected: _themeColorsEqual(current, AppThemeColors.defaults),
                  setSheetState: setSheetState,
                ),
              ),
              const SizedBox(width: AppTheme.spacing2),
              Expanded(
                child: _buildThemePresetTile(
                  context,
                  title: l10n.themeColorsPresetGreen,
                  colors: AppThemeColors.green,
                  selected: _themeColorsEqual(current, AppThemeColors.green),
                  setSheetState: setSheetState,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildThemePresetTile(
    BuildContext context, {
    required String title,
    required AppThemeColors colors,
    required bool selected,
    required StateSetter setSheetState,
  }) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    return Material(
      color: selected
          ? cs.primaryContainer.withValues(alpha: 0.58)
          : cs.surfaceContainer,
      borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        onTap: selected
            ? null
            : () async {
                await widget.themeService.setThemeColors(colors);
                if (!mounted) return;
                _settingsSetState(() {});
                setSheetState(() {});
                if (context.mounted) {
                  UINotifier.success(
                    context,
                    AppLocalizations.of(context).themeColorsPresetSaved(title),
                  );
                }
              },
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.spacing3),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: selected ? cs.primary : cs.onSurface,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (selected)
                    Icon(Icons.check_circle_rounded, color: cs.primary),
                ],
              ),
              const SizedBox(height: AppTheme.spacing2),
              _buildThemeColorPreviewStrip(context, colors),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pasteThemeColorsFromClipboard(
    BuildContext sheetContext,
    StateSetter setSheetState,
  ) async {
    final ClipboardData? clipboardData = await Clipboard.getData(
      Clipboard.kTextPlain,
    );
    if (!mounted || !sheetContext.mounted) return;
    final AppLocalizations l10n = AppLocalizations.of(sheetContext);
    final String? text = clipboardData?.text?.trim();
    if (text == null || text.isEmpty) {
      UINotifier.error(sheetContext, l10n.themeColorsPasteEmpty);
      return;
    }

    final Map<String, dynamic>? decoded = _decodeThemeColorsJson(text);
    if (decoded == null) {
      UINotifier.error(sheetContext, l10n.themeColorsPasteInvalid);
      return;
    }

    final Map<String, dynamic> validValues = _extractValidThemeColorValues(
      decoded,
    );
    if (validValues.isEmpty) {
      UINotifier.error(sheetContext, l10n.themeColorsPasteInvalid);
      return;
    }

    final AppThemeColors colors = AppThemeColors.fromJson(
      validValues,
      fallback: widget.themeService.themeColors,
    );
    await widget.themeService.setThemeColors(colors);
    if (!mounted || !sheetContext.mounted) return;
    _settingsSetState(() {});
    setSheetState(() {});
    UINotifier.success(sheetContext, l10n.themeColorsPasteSaved);
  }

  Future<void> _copyThemeColorsJsonToClipboard(
    BuildContext sheetContext,
  ) async {
    if (!mounted || !sheetContext.mounted) return;
    final AppLocalizations l10n = AppLocalizations.of(sheetContext);
    final AppThemeColors colors = widget.themeService.themeColors;
    final Map<String, String> themeColors = <String, String>{
      for (final String key in AppThemeColors.keys)
        key: _themeColorHex(colors.colorFor(key)),
    };
    final Map<String, dynamic> exportPayload = <String, dynamic>{
      'themeColors': <String, dynamic>{
        ...themeColors,
        AppThemeColors.dynamicTagPaletteKey: <String>[
          for (final Color color in colors.dynamicTagPalette)
            _themeColorHex(color),
        ],
      },
    };
    final String text = const JsonEncoder.withIndent(
      '  ',
    ).convert(exportPayload);

    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted || !sheetContext.mounted) return;
    UINotifier.success(sheetContext, l10n.themeColorsCopySaved);
  }

  Map<String, dynamic>? _decodeThemeColorsJson(String text) {
    try {
      Object? decoded = jsonDecode(text);
      if (decoded is Map) {
        final Object? nested =
            decoded['themeColors'] ?? decoded['colors'] ?? decoded['palette'];
        if (nested is Map) {
          decoded = nested;
        }
      }
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {}
    return null;
  }

  Map<String, dynamic> _extractValidThemeColorValues(
    Map<String, dynamic> source,
  ) {
    final Map<String, dynamic> values = <String, dynamic>{};
    for (final String key in AppThemeColors.keys) {
      final Object? value = source[key];
      if (value is int) {
        values[key] = value;
      } else if (value is String &&
          AppThemeColors.parseHexColor(value) != null) {
        values[key] = value;
      }
    }
    final Object? dynamicTagPalette =
        source[AppThemeColors.dynamicTagPaletteKey];
    if (dynamicTagPalette is List &&
        dynamicTagPalette.any(
          (Object? value) =>
              value is int ||
              (value is String && AppThemeColors.parseHexColor(value) != null),
        )) {
      values[AppThemeColors.dynamicTagPaletteKey] = dynamicTagPalette;
    }
    return values;
  }

  Widget _buildThemeColorGroup(
    BuildContext context, {
    required String title,
    required List<String> keys,
    required StateSetter setSheetState,
  }) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.spacing4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppTheme.spacing2),
            child: Text(
              title,
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Material(
            color: theme.colorScheme.surfaceContainer,
            borderRadius: BorderRadius.circular(AppTheme.radiusLg),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (int i = 0; i < keys.length; i++)
                  _buildThemeColorRow(
                    context,
                    key: keys[i],
                    showDivider: i < keys.length - 1,
                    setSheetState: setSheetState,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildThemeColorRow(
    BuildContext context, {
    required String key,
    required bool showDivider,
    required StateSetter setSheetState,
  }) {
    final ThemeData theme = Theme.of(context);
    final AppThemeColors colors = widget.themeService.themeColors;
    final Color color = colors.colorFor(key);
    final Color defaultColor = AppThemeColors.defaults.colorFor(key);
    final bool isCustom = color.toARGB32() != defaultColor.toARGB32();
    final BorderSide dividerSide = BorderSide(
      color: theme.colorScheme.outline.withValues(alpha: 0.42),
      width: 0.8,
    );

    return InkWell(
      onTap: () => _showThemeColorEditor(
        sheetContext: context,
        key: key,
        setSheetState: setSheetState,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.spacing3,
          vertical: AppTheme.spacing3,
        ),
        decoration: BoxDecoration(
          border: showDivider ? Border(bottom: dividerSide) : null,
        ),
        child: Row(
          children: [
            _buildThemeColorSwatch(context, color, size: 30),
            const SizedBox(width: AppTheme.spacing3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _themeColorLabel(context, key),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _themeColorHex(color),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _themeColorUsage(context, key),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant.withValues(
                        alpha: 0.86,
                      ),
                      height: 1.25,
                    ),
                  ),
                ],
              ),
            ),
            if (isCustom) ...[
              UIBadge(
                text: AppLocalizations.of(context).themeColorsCustomBadge,
                variant: UIBadgeVariant.primary,
              ),
              const SizedBox(width: AppTheme.spacing2),
            ],
            Icon(
              Icons.chevron_right,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  void _showThemeColorEditor({
    required BuildContext sheetContext,
    required String key,
    required StateSetter setSheetState,
  }) {
    final AppLocalizations l10n = AppLocalizations.of(sheetContext);
    final Color currentColor = widget.themeService.themeColors.colorFor(key);
    final TextEditingController controller = TextEditingController(
      text: _themeColorHex(currentColor),
    );

    showUIDialog<void>(
      context: sheetContext,
      title: _themeColorLabel(sheetContext, key),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: _buildThemeColorSwatch(sheetContext, currentColor, size: 48),
          ),
          const SizedBox(height: AppTheme.spacing3),
          TextField(
            controller: controller,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F#]')),
              LengthLimitingTextInputFormatter(9),
            ],
            decoration: InputDecoration(
              labelText: l10n.themeColorHexLabel,
              helperText: l10n.themeColorHexFormatHint,
              floatingLabelBehavior: FloatingLabelBehavior.always,
            ),
          ),
        ],
      ),
      actions: [
        UIDialogAction<void>(text: l10n.dialogCancel),
        UIDialogAction<void>(
          text: l10n.dialogOk,
          style: UIDialogActionStyle.primary,
          closeOnPress: false,
          onPressed: (dialogContext) async {
            final Color? parsed = AppThemeColors.parseHexColor(controller.text);
            if (parsed == null) {
              UINotifier.error(dialogContext, l10n.themeColorInvalidHex);
              return;
            }
            await widget.themeService.setThemeColor(key, parsed);
            if (!mounted) return;
            _settingsSetState(() {});
            setSheetState(() {});
            if (dialogContext.mounted) {
              Navigator.of(dialogContext).pop();
            }
            if (sheetContext.mounted) {
              UINotifier.success(sheetContext, l10n.themeColorSaved);
            }
          },
        ),
      ],
    );
  }

  String _themeColorHex(Color color) {
    final int value = color.toARGB32();
    final int alpha = (value >> 24) & 0xFF;
    if (alpha == 0xFF) {
      return '#${(value & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
    }
    return '#${value.toRadixString(16).padLeft(8, '0').toUpperCase()}';
  }

  String _themeColorLabel(BuildContext context, String key) {
    return AppLocalizations.of(context).themeColorSlotLabel(key);
  }

  String _themeColorUsage(BuildContext context, String key) {
    return AppLocalizations.of(context).themeColorUsageLabel(key);
  }

  bool _themeColorsEqual(AppThemeColors a, AppThemeColors b) {
    for (final String key in AppThemeColors.keys) {
      if (a.colorFor(key).toARGB32() != b.colorFor(key).toARGB32()) {
        return false;
      }
    }
    final List<Color> aPalette = a.dynamicTagPalette;
    final List<Color> bPalette = b.dynamicTagPalette;
    if (aPalette.length != bPalette.length) return false;
    for (int i = 0; i < aPalette.length; i += 1) {
      if (aPalette[i].toARGB32() != bPalette[i].toARGB32()) {
        return false;
      }
    }
    return true;
  }

  static const List<String> _themeColorVisibleStatusKeys = <String>[
    AppThemeColors.successKey,
    AppThemeColors.successForegroundKey,
    AppThemeColors.warningKey,
    AppThemeColors.warningForegroundKey,
    AppThemeColors.destructiveKey,
    AppThemeColors.destructiveForegroundKey,
    AppThemeColors.infoKey,
    AppThemeColors.infoForegroundKey,
  ];

  void _showThemeModeSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final ThemeData theme = Theme.of(sheetContext);
        final ThemeMode currentMode = widget.themeService.themeMode;
        final BorderSide dividerSide = BorderSide(
          color: theme.colorScheme.outline.withValues(alpha: 0.45),
          width: 0.8,
        );

        Widget buildOption({
          required ThemeMode mode,
          required IconData icon,
          required String label,
          required bool showDivider,
        }) {
          final bool selected = currentMode == mode;
          return InkWell(
            onTap: () async {
              await widget.themeService.setThemeMode(mode);
              if (mounted && sheetContext.mounted) {
                Navigator.of(sheetContext).pop();
                _settingsSetState(() {});
              }
            },
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppTheme.spacing4,
                vertical: AppTheme.spacing3,
              ),
              decoration: BoxDecoration(
                border: showDivider ? Border(bottom: dividerSide) : null,
                color: selected
                    ? theme.colorScheme.primaryContainer.withValues(alpha: 0.55)
                    : Colors.transparent,
              ),
              child: Row(
                children: [
                  Icon(
                    icon,
                    size: 20,
                    color: selected
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: AppTheme.spacing3),
                  Expanded(
                    child: Text(
                      label,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                        color: selected
                            ? theme.colorScheme.onSurface
                            : theme.colorScheme.onSurface,
                      ),
                    ),
                  ),
                  if (selected)
                    Icon(
                      Icons.check,
                      size: 18,
                      color: theme.colorScheme.primary,
                    ),
                ],
              ),
            ),
          );
        }

        return UISheetSurface(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: AppTheme.spacing3),
              const UISheetHandle(),
              Padding(
                padding: const EdgeInsets.all(AppTheme.spacing4),
                child: Text(
                  AppLocalizations.of(context).themeModeTitle,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              buildOption(
                mode: ThemeMode.system,
                icon: Icons.brightness_auto_outlined,
                label: _themeModeLabel(context, ThemeMode.system),
                showDivider: true,
              ),
              buildOption(
                mode: ThemeMode.light,
                icon: Icons.brightness_high_outlined,
                label: _themeModeLabel(context, ThemeMode.light),
                showDivider: true,
              ),
              buildOption(
                mode: ThemeMode.dark,
                icon: Icons.brightness_4_outlined,
                label: _themeModeLabel(context, ThemeMode.dark),
                showDivider: false,
              ),
              const SizedBox(height: AppTheme.spacing2),
            ],
          ),
        );
      },
    );
  }

  Widget _buildNsfwEntryItem(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.spacing4,
        vertical: AppTheme.spacing3 - 2,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: _settingsDividerSide(context)),
      ),
      child: Row(
        children: [
          _buildSettingsLeadingIcon(context, Icons.shield_outlined),
          const SizedBox(width: AppTheme.spacing3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppLocalizations.of(context).nsfwSettingsSectionTitle,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 2),
                Text(
                  AppLocalizations.of(context).blockedDomainListTitle,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppTheme.spacing2),
          TextButton(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const NsfwSettingsPage()),
              );
            },
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(
                horizontal: AppTheme.spacing3,
                vertical: AppTheme.spacing1 - 1,
              ),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              minimumSize: Size.zero,
              visualDensity: VisualDensity.compact,
            ),
            child: Text(AppLocalizations.of(context).actionEnter),
          ),
        ],
      ),
    );
  }

  Widget _buildPrivacyModeItem(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.spacing4,
        vertical: AppTheme.spacing3 - 2,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: _settingsDividerSide(context)),
      ),
      child: Row(
        children: [
          _buildSettingsLeadingIcon(context, Icons.privacy_tip_outlined),
          const SizedBox(width: AppTheme.spacing3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppLocalizations.of(context).privacyModeTitle,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 2),
                Text(
                  AppLocalizations.of(context).privacyModeDesc,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppTheme.spacing2),
          Transform.scale(
            scale: 0.9,
            child: Switch(
              value: _privacyMode,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              onChanged: (v) => _updatePrivacyMode(v),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoggingToggleItem(BuildContext context) {
    final AppLocalizations l10n = AppLocalizations.of(context);
    final String retentionTitle = l10n.logRetentionDaysTitle;
    final String retentionDesc = l10n.logRetentionDaysDesc(_logRetentionDays);
    final String retentionValueLabel = l10n.logRetentionDaysValue(
      _logRetentionDays,
    );

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.spacing4,
        vertical: AppTheme.spacing3 - 2,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            children: [
              Row(
                children: [
                  _buildSettingsLeadingIcon(context, Icons.event_note_outlined),
                  const SizedBox(width: AppTheme.spacing3),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(right: 72),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.loggingTitle,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(fontWeight: FontWeight.w500),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            l10n.loggingDesc,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              Positioned(
                top: -1,
                right: 0,
                child: Transform.scale(
                  scale: 0.9,
                  child: Switch(
                    value: _loggingEnabled,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    onChanged: (v) => _updateLoggingEnabled(v),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppTheme.spacing3),
          // 子列表整体：随主开关禁用并灰化
          IgnorePointer(
            ignoring: !_loggingEnabled,
            child: Opacity(
              opacity: _loggingEnabled ? 1.0 : 0.5,
              child: Column(
                children: [
                  // 子项：AI 日志
                  Container(
                    padding: const EdgeInsets.only(
                      left: AppTheme.spacing3,
                      top: AppTheme.spacing3,
                      bottom: AppTheme.spacing3,
                    ),
                    decoration: BoxDecoration(
                      border: Border(bottom: _settingsDividerSide(context)),
                    ),
                    child: Stack(
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildSettingsLeadingIcon(
                              context,
                              Icons.smart_toy_outlined,
                            ),
                            const SizedBox(width: AppTheme.spacing3),
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.only(right: 72),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      l10n.loggingAiTitle,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodyMedium,
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      l10n.loggingAiDesc,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.onSurfaceVariant,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                        Positioned(
                          top: -1,
                          right: 0,
                          child: Transform.scale(
                            scale: 0.9,
                            child: Switch(
                              value: _aiLoggingEnabled,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              onChanged: (v) => _updateAiLoggingEnabled(v),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // 子项：截图日志
                  Container(
                    padding: const EdgeInsets.only(
                      left: AppTheme.spacing3,
                      top: AppTheme.spacing3,
                      bottom: AppTheme.spacing3,
                    ),
                    decoration: BoxDecoration(
                      border: Border(bottom: _settingsDividerSide(context)),
                    ),
                    child: Stack(
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _buildSettingsLeadingIcon(
                              context,
                              Icons.image_search_outlined,
                            ),
                            const SizedBox(width: AppTheme.spacing3),
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.only(right: 72),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      l10n.loggingScreenshotTitle,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodyMedium,
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      l10n.loggingScreenshotDesc,
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(
                                            color: Theme.of(
                                              context,
                                            ).colorScheme.onSurfaceVariant,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                        Positioned(
                          top: -1,
                          right: 0,
                          child: Transform.scale(
                            scale: 0.9,
                            child: Switch(
                              value: _screenshotLoggingEnabled,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                              onChanged: (v) =>
                                  _updateScreenshotLoggingEnabled(v),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          _buildLogRetentionDaysItem(
            context,
            title: retentionTitle,
            desc: retentionDesc,
            valueLabel: retentionValueLabel,
          ),
        ],
      ),
    );
  }

  Widget _buildLogRetentionDaysItem(
    BuildContext context, {
    required String title,
    required String desc,
    required String valueLabel,
  }) {
    return Container(
      padding: const EdgeInsets.only(
        left: AppTheme.spacing3,
        top: AppTheme.spacing3,
        bottom: AppTheme.spacing3,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: _settingsDividerSide(context)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _buildSettingsLeadingIcon(context, Icons.auto_delete_outlined),
          const SizedBox(width: AppTheme.spacing3),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.bodyMedium),
                  const SizedBox(height: 2),
                  Text(
                    desc,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          TextButton(
            onPressed: _savingLogRetentionDays
                ? null
                : _showLogRetentionDaysDialog,
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(
                horizontal: AppTheme.spacing3,
                vertical: AppTheme.spacing1 - 1,
              ),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              minimumSize: Size.zero,
              visualDensity: VisualDensity.compact,
            ),
            child: Text(valueLabel),
          ),
        ],
      ),
    );
  }

  void _showLogRetentionDaysDialog() {
    final TextEditingController controller = TextEditingController(
      text: _logRetentionDays.toString(),
    );
    final AppLocalizations l10n = AppLocalizations.of(context);
    showUIDialog<void>(
      context: context,
      title: l10n.logRetentionDaysTitle,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.logRetentionDaysDialogMessage,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              height: 1.35,
            ),
          ),
          const SizedBox(height: AppTheme.spacing3),
          Container(
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            ),
            child: TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: InputDecoration(
                labelText: l10n.logRetentionDaysLabel,
                border: InputBorder.none,
                contentPadding: EdgeInsets.all(AppTheme.spacing3),
                floatingLabelBehavior: FloatingLabelBehavior.always,
              ),
            ),
          ),
        ],
      ),
      actions: [
        UIDialogAction(text: AppLocalizations.of(context).dialogCancel),
        UIDialogAction(
          text: l10n.dialogOk,
          style: UIDialogActionStyle.primary,
          closeOnPress: false,
          onPressed: (ctx) async {
            final int? parsed = int.tryParse(controller.text.trim());
            if (parsed == null || parsed < 1) {
              UINotifier.error(ctx, l10n.logRetentionDaysInvalid);
              return;
            }
            try {
              await _updateLogRetentionDays(parsed);
              if (ctx.mounted) {
                Navigator.of(ctx).pop();
                UINotifier.success(ctx, l10n.logRetentionDaysSaved);
              }
            } catch (e) {
              if (ctx.mounted) {
                UINotifier.error(ctx, e.toString());
              }
            }
          },
        ),
      ],
    );
  }

  Widget _buildStreamRenderImagesItem(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.spacing4,
        vertical: AppTheme.spacing3 - 2,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: _settingsDividerSide(context)),
      ),
      child: Stack(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _buildSettingsLeadingIcon(context, Icons.image_outlined),
              const SizedBox(width: AppTheme.spacing3),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: 72),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        AppLocalizations.of(context).streamRenderImagesTitle,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        AppLocalizations.of(context).streamRenderImagesDesc,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          Positioned(
            top: -1,
            right: 0,
            child: Transform.scale(
              scale: 0.9,
              child: Switch(
                value: _renderImagesDuringStreaming,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: (v) => _updateRenderImagesDuringStreaming(v),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAiChatPerfOverlayItem(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.spacing4,
        vertical: AppTheme.spacing3 - 2,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: _settingsDividerSide(context)),
      ),
      child: Stack(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _buildSettingsLeadingIcon(context, Icons.speed_outlined),
              const SizedBox(width: AppTheme.spacing3),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: 72),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        AppLocalizations.of(context).aiChatPerfOverlayTitle,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        AppLocalizations.of(context).aiChatPerfOverlayDesc,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          Positioned(
            top: -1,
            right: 0,
            child: Transform.scale(
              scale: 0.9,
              child: Switch(
                value: _aiChatPerfOverlayEnabled,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: (v) => _updateAiChatPerfOverlayEnabled(v),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDynamicEntryLogIconItem(BuildContext context) {
    final bool isZh = AppLocalizations.of(
      context,
    ).localeName.toLowerCase().startsWith('zh');
    final String title = isZh
        ? '动态页每日总结右侧日志图标'
        : 'Dynamic page summary-side log icon';
    final String desc = isZh
        ? '控制动态页中“每日总结”图标右侧日志入口是否显示，默认关闭。'
        : 'Show the log entry next to the daily summary icon on the dynamic page. Off by default.';

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.spacing4,
        vertical: AppTheme.spacing3 - 2,
      ),
      decoration: BoxDecoration(
        border: Border(bottom: _settingsDividerSide(context)),
      ),
      child: Stack(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _buildSettingsLeadingIcon(context, Icons.receipt_long_outlined),
              const SizedBox(width: AppTheme.spacing3),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: 72),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        desc,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          Positioned(
            top: -1,
            right: 0,
            child: Transform.scale(
              scale: 0.9,
              child: Switch(
                value: _dynamicEntryLogIconEnabled,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: (v) => _updateDynamicEntryLogIconEnabled(v),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

part of 'settings_page.dart';

extension _SettingsMcpPart on _SettingsPageState {
  Future<void> _loadMcpPageData() async {
    await Future.wait(<Future<void>>[
      _loadMcpStatus(),
      _loadExternalMcpServers(),
    ]);
  }

  Future<void> _loadMcpStatus() async {
    final l10n = AppLocalizations.of(context);
    if (_mcpLoading) return;
    _settingsSetState(() => _mcpLoading = true);
    try {
      final status = await McpService.getStatus();
      if (!mounted) return;
      _settingsSetState(() => _mcpStatus = status);
    } catch (e) {
      if (!mounted) return;
      _showMcpSnack(l10n.mcpLoadStatusFailed('$e'));
    } finally {
      if (mounted) _settingsSetState(() => _mcpLoading = false);
    }
  }

  Future<void> _loadExternalMcpServers({bool force = false}) async {
    if (_externalMcpLoading && !force) return;
    if (!_externalMcpLoading) {
      _settingsSetState(() => _externalMcpLoading = true);
    }
    try {
      final servers = await McpClientService.instance.listServers();
      if (!mounted) return;
      _settingsSetState(() => _externalMcpServers = servers);
    } catch (e) {
      if (!mounted) return;
      _showMcpSnack(
        AppLocalizations.of(context).externalMcpLoadServersFailed('$e'),
      );
    } finally {
      if (mounted) _settingsSetState(() => _externalMcpLoading = false);
    }
  }

  Future<void> _toggleMcpServer(bool enabled) async {
    final l10n = AppLocalizations.of(context);
    if (_mcpLoading) return;
    _settingsSetState(() => _mcpLoading = true);
    try {
      var status = enabled ? await McpService.start() : await McpService.stop();
      if (enabled) {
        await Future<void>.delayed(const Duration(milliseconds: 600));
        status = await McpService.getStatus();
      }
      if (!mounted) return;
      _settingsSetState(() => _mcpStatus = status);
      if (enabled && status.lastError != null) {
        _showMcpSnack(status.lastError!);
      }
    } catch (e) {
      if (!mounted) return;
      _showMcpSnack(
        enabled ? l10n.mcpStartFailed('$e') : l10n.mcpStopFailed('$e'),
      );
    } finally {
      if (mounted) _settingsSetState(() => _mcpLoading = false);
    }
  }

  Future<void> _resetMcpToken() async {
    final l10n = AppLocalizations.of(context);
    final bool ok = await UIDialogs.showConfirm(
      context,
      title: l10n.mcpResetTokenDialogTitle,
      message: l10n.mcpResetTokenDialogMessage,
      confirmText: l10n.mcpResetTokenConfirm,
      cancelText: l10n.dialogCancel,
      destructive: true,
    );
    if (!ok || _mcpLoading) return;
    _settingsSetState(() => _mcpLoading = true);
    try {
      final status = await McpService.resetToken();
      if (!mounted) return;
      _settingsSetState(() => _mcpStatus = status);
      _showMcpSnack(l10n.mcpTokenResetToast);
    } catch (e) {
      if (!mounted) return;
      _showMcpSnack(l10n.mcpResetTokenFailed('$e'));
    } finally {
      if (mounted) _settingsSetState(() => _mcpLoading = false);
    }
  }

  Future<void> _showExternalMcpServerDialog({McpClientServer? server}) async {
    final jsonController = TextEditingController(
      text: server == null
          ? _externalMcpExampleJson
          : _externalMcpServerJson(server),
    );
    try {
      final bool? saved = await showDialog<bool>(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            title: Text(
              server == null
                  ? AppLocalizations.of(context).externalMcpAddServerTitle
                  : AppLocalizations.of(context).externalMcpEditServerTitle,
            ),
            content: SizedBox(
              width: 560,
              child: TextField(
                controller: jsonController,
                minLines: 14,
                maxLines: 22,
                keyboardType: TextInputType.multiline,
                decoration: InputDecoration(
                  alignLabelWithHint: true,
                  labelText: AppLocalizations.of(
                    context,
                  ).externalMcpConfigJsonLabel,
                ),
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  height: 1.25,
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(AppLocalizations.of(context).dialogCancel),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(AppLocalizations.of(context).actionSave),
              ),
            ],
          );
        },
      );
      if (saved != true || !mounted) return;
      final String raw = jsonController.text.trim();
      _settingsSetState(() => _externalMcpLoading = true);
      final payload = await McpClientService.instance
          .executeManagementTool('configure_mcp_server', <String, dynamic>{
            'action': 'import_json',
            'confirm': true,
            'config_json': raw,
            if (server != null) 'replace_server_id': server.id,
          }, trustedLocal: true);
      if (!mounted) return;
      _showMcpSnack(
        payload['ok'] == true
            ? AppLocalizations.of(context).externalMcpServerSavedToast
            : AppLocalizations.of(
                context,
              ).externalMcpSaveFailed('${payload['error']}'),
      );
      await _loadExternalMcpServers(force: true);
    } catch (e) {
      if (!mounted) return;
      _showMcpSnack(
        AppLocalizations.of(context).externalMcpSaveServerFailed('$e'),
      );
    } finally {
      jsonController.dispose();
      if (mounted) _settingsSetState(() => _externalMcpLoading = false);
    }
  }

  String get _externalMcpExampleJson => const JsonEncoder.withIndent('  ')
      .convert(<String, dynamic>{
        'mcpServers': <String, dynamic>{
          'demo': <String, dynamic>{
            'type': 'streamable_http',
            'url': 'https://example.com/mcp',
            'headers': <String, String>{
              'Authorization': 'Bearer your-token',
            },
          },
        },
      });

  String _externalMcpServerJson(McpClientServer server) {
    return const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
      'mcpServers': <String, dynamic>{
        server.name: <String, dynamic>{
          'type': server.transport,
          'url': server.url,
          if (server.headers.isNotEmpty) 'headers': server.headers,
        },
      },
    });
  }

  Future<void> _setExternalMcpServerEnabled(
    McpClientServer server,
    bool enabled,
  ) async {
    if (_externalMcpServerBusyIds.contains(server.id)) return;
    _settingsSetState(() => _externalMcpServerBusyIds.add(server.id));
    try {
      final payload = await McpClientService.instance.executeManagementTool(
        'configure_mcp_server',
        <String, dynamic>{
          'action': enabled ? 'enable' : 'disable',
          'confirm': true,
          'id': server.id,
        },
        trustedLocal: true,
      );
      if (!mounted) return;
      if (payload['ok'] != true) {
        _showMcpSnack(
          AppLocalizations.of(
            context,
          ).externalMcpUpdateFailed('${payload['error']}'),
        );
      } else {
        _showMcpSnack(
          AppLocalizations.of(context).externalMcpServerUpdatedToast,
        );
      }
      await _loadExternalMcpServers(force: true);
    } catch (e) {
      if (!mounted) return;
      _showMcpSnack(
        AppLocalizations.of(context).externalMcpUpdateServerFailed('$e'),
      );
    } finally {
      if (mounted) {
        _settingsSetState(() => _externalMcpServerBusyIds.remove(server.id));
      }
    }
  }

  Future<void> _syncExternalMcpServer(McpClientServer server) async {
    if (_externalMcpSyncingIds.contains(server.id)) return;
    _settingsSetState(() => _externalMcpSyncingIds.add(server.id));
    try {
      final payload = await McpClientService.instance.syncServer(server.id);
      if (!mounted) return;
      _showMcpSnack(
        payload['ok'] == true
            ? AppLocalizations.of(
                context,
              ).externalMcpSyncedToast((payload['count'] as int?) ?? 0)
            : AppLocalizations.of(
                context,
              ).externalMcpSyncFailed('${payload['error']}'),
      );
      await _loadExternalMcpServers(force: true);
    } catch (e) {
      if (!mounted) return;
      _showMcpSnack(
        AppLocalizations.of(context).externalMcpSyncServerFailed('$e'),
      );
    } finally {
      if (mounted) {
        _settingsSetState(() => _externalMcpSyncingIds.remove(server.id));
      }
    }
  }

  Future<void> _deleteExternalMcpServer(McpClientServer server) async {
    if (_externalMcpServerBusyIds.contains(server.id)) return;
    final bool ok = await UIDialogs.showConfirm(
      context,
      title: AppLocalizations.of(context).externalMcpDeleteServerTitle,
      message: AppLocalizations.of(
        context,
      ).externalMcpDeleteServerMessage(server.name),
      confirmText: AppLocalizations.of(context).actionDelete,
      cancelText: AppLocalizations.of(context).dialogCancel,
      destructive: true,
    );
    if (!ok) return;
    _settingsSetState(() => _externalMcpServerBusyIds.add(server.id));
    try {
      final payload = await McpClientService.instance.executeManagementTool(
        'configure_mcp_server',
        <String, dynamic>{'action': 'remove', 'confirm': true, 'id': server.id},
        trustedLocal: true,
      );
      if (!mounted) return;
      if (payload['ok'] != true) {
        _showMcpSnack(
          AppLocalizations.of(
            context,
          ).externalMcpDeleteFailed('${payload['error']}'),
        );
      } else {
        _showMcpSnack(
          AppLocalizations.of(context).externalMcpServerDeletedToast,
        );
      }
      await _loadExternalMcpServers(force: true);
    } catch (e) {
      if (!mounted) return;
      _showMcpSnack(
        AppLocalizations.of(context).externalMcpDeleteServerFailed('$e'),
      );
    } finally {
      if (mounted) {
        _settingsSetState(() => _externalMcpServerBusyIds.remove(server.id));
      }
    }
  }

  Future<void> _setExternalMcpToolOption(
    McpClientTool tool, {
    bool? enabled,
  }) async {
    if (_externalMcpToolBusyNames.contains(tool.dynamicName)) return;
    _settingsSetState(() => _externalMcpToolBusyNames.add(tool.dynamicName));
    try {
      final payload = await McpClientService.instance
          .executeManagementTool('set_mcp_tool_options', <String, dynamic>{
            'dynamic_name': tool.dynamicName,
            if (enabled != null) 'enabled': enabled,
          }, trustedLocal: true);
      if (!mounted) return;
      if (payload['ok'] != true) {
        _showMcpSnack(
          AppLocalizations.of(
            context,
          ).externalMcpToolUpdateFailed('${payload['error']}'),
        );
      }
      await _loadExternalMcpServers(force: true);
    } catch (e) {
      if (!mounted) return;
      _showMcpSnack(
        AppLocalizations.of(context).externalMcpUpdateToolFailed('$e'),
      );
    } finally {
      if (mounted) {
        _settingsSetState(
          () => _externalMcpToolBusyNames.remove(tool.dynamicName),
        );
      }
    }
  }

  Future<void> _copyMcpText(String text, String label) async {
    final l10n = AppLocalizations.of(context);
    if (text.trim().isEmpty) {
      _showMcpSnack(l10n.mcpCopyValueEmpty(label));
      return;
    }
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (!mounted) return;
      _showMcpSnack(l10n.mcpCopiedToast(label));
    } catch (e) {
      if (!mounted) return;
      _showMcpSnack(l10n.mcpCopyFailed(label, '$e'));
    }
  }

  Widget _buildMcpServicePage(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final status = _mcpStatus;
    final running = status?.running == true;
    final endpoint = status?.endpoint ?? '';
    final token = status?.token ?? '';
    final lastError = status?.lastError;
    final aiInstallText = _buildMcpAiInstallText(
      context,
      endpoint: endpoint,
      token: token,
    );
    final bool canCopyConnection = endpoint.isNotEmpty && token.isNotEmpty;

    return ListView(
      padding: _settingsListPadding(),
      children: [
        _buildCard(
          context: context,
          children: [
            SwitchListTile.adaptive(
              value: running,
              onChanged: _mcpLoading ? null : _toggleMcpServer,
              secondary: _buildMcpLeadingIcon(
                context,
                color: running ? theme.colorScheme.primary : null,
              ),
              title: Text(l10n.mcpLanServerTitle),
              subtitle: Text(
                running ? l10n.mcpRunningOnPort(37621) : l10n.mcpStopped,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (_mcpLoading)
              const Padding(
                padding: EdgeInsets.fromLTRB(
                  AppTheme.spacing4,
                  0,
                  AppTheme.spacing4,
                  AppTheme.spacing3,
                ),
                child: LinearProgressIndicator(minHeight: 2),
              ),
          ],
        ),
        if (lastError != null) ...[
          const SizedBox(height: AppTheme.spacing3),
          _buildMcpInfoBlock(
            context: context,
            icon: Icons.error_outline,
            title: l10n.mcpLastErrorTitle,
            body: lastError,
            color: theme.colorScheme.error,
          ),
        ],
        const SizedBox(height: AppTheme.spacing2),
        _buildMcpInfoBlock(
          context: context,
          icon: Icons.auto_fix_high_outlined,
          title: l10n.mcpAiInstallTitle,
          body: aiInstallText,
          copyTooltip: l10n.mcpAiInstallCopyLabel,
          onCopy: canCopyConnection
              ? () => _copyMcpText(aiInstallText, l10n.mcpAiInstallCopyLabel)
              : null,
          trailingTooltip: l10n.mcpResetTokenTitle,
          trailingIcon: Icons.refresh_outlined,
          onTrailingPressed: _mcpLoading ? null : _resetMcpToken,
        ),
        const SizedBox(height: AppTheme.spacing2),
        _buildExternalMcpSection(context),
      ],
    );
  }

  Widget _buildExternalMcpSection(BuildContext context) {
    final theme = Theme.of(context);
    final servers = _externalMcpServers;
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.spacing4,
        AppTheme.spacing2,
        AppTheme.spacing4,
        AppTheme.spacing2,
      ),
      child: Row(
        children: [
          _buildSettingsLeadingIcon(
            context,
            Icons.hub_outlined,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: AppTheme.spacing3),
          Expanded(
            child: Text(
              AppLocalizations.of(context).externalMcpServersTitle,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          IconButton(
            tooltip: AppLocalizations.of(context).externalMcpAddServerTooltip,
            onPressed: _externalMcpLoading
                ? null
                : () => _showExternalMcpServerDialog(),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
    );
    if (servers.isEmpty) {
      return _buildCard(
        context: context,
        children: [
          header,
          if (_externalMcpLoading)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: AppTheme.spacing4),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          if (!_externalMcpLoading)
            _buildMcpCompactInfoRow(
              context: context,
              icon: Icons.info_outline,
              title: AppLocalizations.of(context).externalMcpEmptyTitle,
            ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildCard(context: context, children: [header]),
        for (final server in servers) ...[
          const SizedBox(height: AppTheme.spacing2),
          _buildExternalMcpServerCard(context, server),
        ],
      ],
    );
  }

  Widget _buildExternalMcpServerCard(
    BuildContext context,
    McpClientServer server,
  ) {
    final theme = Theme.of(context);
    final bool syncing = _externalMcpSyncingIds.contains(server.id);
    final bool busy = syncing || _externalMcpServerBusyIds.contains(server.id);
    return _buildCard(
      context: context,
      children: [
        SwitchListTile.adaptive(
          value: server.enabled,
          onChanged: busy
              ? null
              : (value) => _setExternalMcpServerEnabled(server, value),
          secondary: _buildSettingsLeadingIcon(
            context,
            server.enabled
                ? Icons.cloud_done_outlined
                : Icons.cloud_off_outlined,
            color: server.enabled ? theme.colorScheme.primary : null,
          ),
          title: Text(server.name),
          subtitle: Text(
            '${server.transport} · ${server.url}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppTheme.spacing4,
            0,
            AppTheme.spacing4,
            AppTheme.spacing2,
          ),
          child: Wrap(
            spacing: AppTheme.spacing2,
            runSpacing: AppTheme.spacing1,
            alignment: WrapAlignment.end,
            children: [
              TextButton.icon(
                onPressed: busy ? null : () => _syncExternalMcpServer(server),
                icon: syncing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync_outlined, size: 18),
                label: Text(AppLocalizations.of(context).externalMcpSyncAction),
              ),
              TextButton.icon(
                onPressed: busy
                    ? null
                    : () => _showExternalMcpServerDialog(server: server),
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: Text(AppLocalizations.of(context).actionEdit),
              ),
              TextButton.icon(
                onPressed: busy ? null : () => _deleteExternalMcpServer(server),
                icon: const Icon(Icons.delete_outline, size: 18),
                label: Text(AppLocalizations.of(context).actionDelete),
              ),
            ],
          ),
        ),
        if ((server.lastError ?? '').trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.spacing4,
              0,
              AppTheme.spacing4,
              AppTheme.spacing3,
            ),
            child: Text(
              server.lastError!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        if (server.tools.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.spacing4,
              0,
              AppTheme.spacing4,
              AppTheme.spacing4,
            ),
            child: Text(
              AppLocalizations.of(context).externalMcpNoToolsSynced,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          ...server.tools.map(
            (tool) => _buildExternalMcpToolRow(context, tool),
          ),
      ],
    );
  }

  Widget _buildExternalMcpToolRow(BuildContext context, McpClientTool tool) {
    final theme = Theme.of(context);
    final bool busy = _externalMcpToolBusyNames.contains(tool.dynamicName);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.spacing4,
        vertical: AppTheme.spacing2,
      ),
      decoration: BoxDecoration(
        border: Border(top: _settingsDividerSide(context)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Switch.adaptive(
            value: tool.enabled,
            onChanged: busy
                ? null
                : (value) => _setExternalMcpToolOption(tool, enabled: value),
          ),
          const SizedBox(width: AppTheme.spacing2),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tool.name,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  SelectableText(
                    tool.dynamicName,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  if (tool.description.trim().isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      tool.description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMcpInfoBlock({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String body,
    Color? color,
    String? copyTooltip,
    VoidCallback? onCopy,
    String? trailingTooltip,
    IconData? trailingIcon,
    VoidCallback? onTrailingPressed,
  }) {
    final theme = Theme.of(context);
    final fg = color ?? theme.colorScheme.onSurfaceVariant;
    return _buildCard(
      context: context,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppTheme.spacing4,
            AppTheme.spacing2,
            AppTheme.spacing4,
            AppTheme.spacing2,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _buildSettingsLeadingIcon(context, icon, color: fg),
                  const SizedBox(width: AppTheme.spacing3),
                  Expanded(
                    child: Text(
                      title,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: color,
                      ),
                    ),
                  ),
                  if (copyTooltip != null)
                    IconButton(
                      tooltip: copyTooltip,
                      onPressed: onCopy,
                      icon: const Icon(Icons.copy_outlined),
                    ),
                  if (trailingTooltip != null && trailingIcon != null)
                    IconButton(
                      tooltip: trailingTooltip,
                      onPressed: onTrailingPressed,
                      icon: Icon(trailingIcon),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Padding(
                padding: EdgeInsets.only(
                  left: AppTheme.spacing3 + 20,
                ),
                child: SelectableText(
                  body,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: color ?? theme.colorScheme.onSurfaceVariant,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMcpCompactInfoRow({
    required BuildContext context,
    required IconData icon,
    required String title,
  }) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        border: Border(top: _settingsDividerSide(context)),
      ),
      padding: const EdgeInsets.fromLTRB(
        AppTheme.spacing4,
        AppTheme.spacing2,
        AppTheme.spacing4,
        AppTheme.spacing2,
      ),
      child: Row(
        children: [
          _buildSettingsLeadingIcon(
            context,
            icon,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: AppTheme.spacing3),
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _buildMcpAiInstallText(
    BuildContext context, {
    required String endpoint,
    required String token,
  }) {
    final l10n = AppLocalizations.of(context);
    if (endpoint.isEmpty || token.isEmpty) {
      return l10n.mcpConnectionUnavailableHint;
    }
    return l10n.mcpAiInstallPrompt(endpoint, token);
  }

  void _showMcpSnack(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.clearSnackBars();
    messenger?.showSnackBar(SnackBar(content: Text(message)));
  }
}

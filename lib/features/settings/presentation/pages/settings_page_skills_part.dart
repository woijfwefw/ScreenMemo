part of 'settings_page.dart';

extension _SettingsSkillsPart on _SettingsPageState {
  Future<void> _loadSkills() async {
    final l10n = AppLocalizations.of(context);
    if (_skillsLoading) return;
    _settingsSetState(() => _skillsLoading = true);
    try {
      final skills = await SkillService.instance.listSkills();
      if (!mounted) return;
      _settingsSetState(() => _skills = skills);
    } catch (e) {
      if (!mounted) return;
      _showSkillsSnack(l10n.settingsSkillsLoadFailed(e.toString()));
    } finally {
      if (mounted) _settingsSetState(() => _skillsLoading = false);
    }
  }

  Future<void> _showAddSkillDialog() async {
    final controller = TextEditingController();
    try {
      final bool? saved = await showDialog<bool>(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            title: Text(AppLocalizations.of(context).settingsSkillsAddTitle),
            content: TextField(
              controller: controller,
              minLines: 10,
              maxLines: 18,
              decoration: InputDecoration(
                labelText: AppLocalizations.of(
                  context,
                ).settingsSkillsSkillMdLabel,
                hintText: AppLocalizations.of(
                  context,
                ).settingsSkillsSkillMdHint,
              ),
              style: const TextStyle(fontFamily: 'monospace'),
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
      _settingsSetState(() => _skillsLoading = true);
      final skill = await SkillService.instance.saveSkillFromContent(
        controller.text,
      );
      if (!mounted) return;
      _showSkillsSnack(
        AppLocalizations.of(context).settingsSkillsSavedToast(skill.name),
      );
      await _loadSkillsForce();
    } catch (e) {
      if (!mounted) return;
      _showSkillsSnack(
        AppLocalizations.of(context).settingsSkillsSaveFailed(e.toString()),
      );
    } finally {
      controller.dispose();
      if (mounted) _settingsSetState(() => _skillsLoading = false);
    }
  }

  Future<void> _deleteSkill(SkillMetadata skill) async {
    final bool ok = await UIDialogs.showConfirm(
      context,
      title: AppLocalizations.of(context).settingsSkillsDeleteTitle,
      message: AppLocalizations.of(
        context,
      ).settingsSkillsDeleteMessage(skill.name),
      confirmText: AppLocalizations.of(context).actionDelete,
      cancelText: AppLocalizations.of(context).dialogCancel,
      destructive: true,
    );
    if (!ok) return;
    try {
      _settingsSetState(() => _skillsLoading = true);
      final deleted = await SkillService.instance.deleteSkill(skill.name);
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      _showSkillsSnack(
        deleted
            ? l10n.settingsSkillsDeletedToast
            : l10n.settingsSkillsNotFoundToast,
      );
      await _loadSkillsForce();
    } catch (e) {
      if (!mounted) return;
      _showSkillsSnack(
        AppLocalizations.of(context).settingsSkillsDeleteFailed(e.toString()),
      );
    } finally {
      if (mounted) _settingsSetState(() => _skillsLoading = false);
    }
  }

  Future<void> _toggleSkillEnabled(SkillMetadata skill, bool enabled) async {
    try {
      final l10n = AppLocalizations.of(context);
      final String successMessage = enabled
          ? l10n.settingsSkillsEnabledToast
          : l10n.settingsSkillsDisabledToast;
      await SkillService.instance.setSkillEnabled(skill.name, enabled);
      if (!mounted) return;
      await _loadSkillsForce();
      _showSkillsSnack(successMessage);
    } catch (e) {
      if (!mounted) return;
      _showSkillsSnack(
        AppLocalizations.of(context).settingsSkillsUpdateFailed(e.toString()),
      );
    }
  }

  Future<void> _loadSkillsForce() async {
    final skills = await SkillService.instance.listSkills();
    if (!mounted) return;
    _settingsSetState(() => _skills = skills);
  }

  Widget _buildSkillsPage(BuildContext context) {
    final theme = Theme.of(context);
    final skills = _skills;
    return ListView(
      padding: _settingsListPadding(),
      children: [
        _buildCard(
          context: context,
          children: [
            Padding(
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
                    Icons.extension_outlined,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: AppTheme.spacing3),
                  Expanded(
                    child: Text(
                      AppLocalizations.of(context).settingsSkillsTitle,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: AppLocalizations.of(
                      context,
                    ).settingsSkillsAddTooltip,
                    onPressed: _skillsLoading ? null : _showAddSkillDialog,
                    icon: const Icon(Icons.add),
                  ),
                ],
              ),
            ),
            if (_skillsLoading)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: AppTheme.spacing4),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            if (skills.isEmpty && !_skillsLoading)
              _buildSkillsEmptyRow(context)
            else
              for (final skill in skills) _buildSkillRow(context, skill),
          ],
        ),
      ],
    );
  }

  Widget _buildSkillsEmptyRow(BuildContext context) {
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
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSettingsLeadingIcon(
            context,
            Icons.info_outline,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: AppTheme.spacing3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  AppLocalizations.of(context).settingsSkillsEmptyTitle,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSkillRow(BuildContext context, SkillMetadata skill) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: () async {
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => _SkillDetailDialog(
            skillName: skill.name,
            onChanged: () async {
              if (mounted) await _loadSkillsForce();
            },
          ),
        );
        if (mounted) await _loadSkillsForce();
      },
      child: Container(
        decoration: BoxDecoration(
          border: Border(top: _settingsDividerSide(context)),
        ),
        padding: const EdgeInsets.fromLTRB(
          AppTheme.spacing4,
          AppTheme.spacing3,
          AppTheme.spacing2,
          AppTheme.spacing3,
        ),
        child: Row(
          children: [
            _buildSettingsLeadingIcon(
              context,
              Icons.auto_awesome_outlined,
              color: skill.enabled
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outline,
            ),
            const SizedBox(width: AppTheme.spacing3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    skill.name,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: skill.enabled
                          ? theme.colorScheme.onSurface
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    skill.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if ((skill.compatibility ?? '').trim().isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      skill.compatibility!,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Switch(
              value: skill.enabled,
              onChanged: _skillsLoading
                  ? null
                  : (value) => _toggleSkillEnabled(skill, value),
            ),
            IconButton(
              tooltip: AppLocalizations.of(
                context,
              ).settingsSkillsDeleteFileTooltip,
              onPressed: _skillsLoading ? null : () => _deleteSkill(skill),
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      ),
    );
  }

  void _showSkillsSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }
}

class _SkillDetailDialog extends StatefulWidget {
  const _SkillDetailDialog({required this.skillName, required this.onChanged});

  final String skillName;
  final Future<void> Function() onChanged;

  @override
  State<_SkillDetailDialog> createState() => _SkillDetailDialogState();
}

class _SkillDetailDialogState extends State<_SkillDetailDialog> {
  bool _loading = true;
  SkillMetadata? _skill;
  List<SkillFileMetadata> _files = <SkillFileMetadata>[];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final skill = await SkillService.instance.getSkill(widget.skillName);
      final files = await SkillService.instance.listSkillFiles(
        widget.skillName,
      );
      if (!mounted) return;
      setState(() {
        _skill = skill;
        _files = files;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _editFile(String relativePath) async {
    final content = await SkillService.instance.readSkillFile(
      widget.skillName,
      relativePath,
    );
    if (!mounted || content == null) return;
    await _showFileEditor(relativePath: relativePath, initialContent: content);
  }

  Future<void> _addFile() async {
    await _showFileEditor(relativePath: '', initialContent: '');
  }

  Future<void> _showFileEditor({
    required String relativePath,
    required String initialContent,
  }) async {
    final pathController = TextEditingController(text: relativePath);
    final contentController = TextEditingController(text: initialContent);
    try {
      final bool isNew = relativePath.isEmpty;
      final bool? saved = await showDialog<bool>(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            title: Text(
              isNew
                  ? AppLocalizations.of(context).settingsSkillsNewFileTitle
                  : relativePath,
            ),
            content: SizedBox(
              width: 720,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: pathController,
                      enabled: isNew,
                      decoration: InputDecoration(
                        labelText: AppLocalizations.of(
                          context,
                        ).settingsSkillsRelativePathLabel,
                        hintText: AppLocalizations.of(
                          context,
                        ).settingsSkillsRelativePathHint,
                      ),
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                    const SizedBox(height: AppTheme.spacing3),
                    TextField(
                      controller: contentController,
                      minLines: 12,
                      maxLines: 20,
                      decoration: InputDecoration(
                        labelText: AppLocalizations.of(
                          context,
                        ).settingsSkillsContentLabel,
                      ),
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                  ],
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
      await SkillService.instance.saveSkillFile(
        widget.skillName,
        pathController.text,
        contentController.text,
      );
      await widget.onChanged();
      await _load();
      if (!mounted) return;
      _showSnack(AppLocalizations.of(context).settingsSkillsFileSavedToast);
    } catch (e) {
      if (!mounted) return;
      _showSnack(
        AppLocalizations.of(context).settingsSkillsFileSaveFailed(e.toString()),
      );
    } finally {
      pathController.dispose();
      contentController.dispose();
    }
  }

  Future<void> _deleteFile(String relativePath) async {
    final bool ok = await UIDialogs.showConfirm(
      context,
      title: AppLocalizations.of(context).settingsSkillsDeleteFileTitle,
      message: AppLocalizations.of(
        context,
      ).settingsSkillsDeleteFileMessage(relativePath, widget.skillName),
      confirmText: AppLocalizations.of(context).actionDelete,
      cancelText: AppLocalizations.of(context).dialogCancel,
      destructive: true,
    );
    if (!ok) return;
    try {
      await SkillService.instance.deleteSkillFile(
        widget.skillName,
        relativePath,
      );
      await widget.onChanged();
      await _load();
      if (!mounted) return;
      _showSnack(AppLocalizations.of(context).settingsSkillsFileDeletedToast);
    } catch (e) {
      if (!mounted) return;
      _showSnack(
        AppLocalizations.of(
          context,
        ).settingsSkillsFileDeleteFailed(e.toString()),
      );
    }
  }

  Future<void> _copyFile(String relativePath) async {
    final content = await SkillService.instance.readSkillFile(
      widget.skillName,
      relativePath,
    );
    if (content == null) return;
    await Clipboard.setData(ClipboardData(text: content));
    if (!mounted) return;
    _showSnack(AppLocalizations.of(context).settingsSkillsFileCopiedToast);
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final skill = _skill;
    return AlertDialog(
      title: Text(widget.skillName),
      content: SizedBox(
        width: 720,
        child: _loading
            ? const Padding(
                padding: EdgeInsets.all(AppTheme.spacing4),
                child: LinearProgressIndicator(minHeight: 2),
              )
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (skill != null) ...[
                      Text(
                        skill.description,
                        style: theme.textTheme.bodyMedium,
                      ),
                      const SizedBox(height: AppTheme.spacing2),
                      Row(
                        children: [
                          Text(
                            skill.enabled
                                ? AppLocalizations.of(
                                    context,
                                  ).externalMcpEnabledLabel
                                : AppLocalizations.of(context).mcpStopped,
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: skill.enabled
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const Spacer(),
                          Text(
                            AppLocalizations.of(
                              context,
                            ).settingsSkillsFileCount(_files.length),
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: AppTheme.spacing4),
                    ],
                    for (final file in _files) _buildFileRow(context, file),
                  ],
                ),
              ),
      ),
      actions: [
        TextButton.icon(
          onPressed: _loading ? null : _addFile,
          icon: const Icon(Icons.add),
          label: Text(AppLocalizations.of(context).settingsSkillsNewFileAction),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(AppLocalizations.of(context).actionClose),
        ),
      ],
    );
  }

  Widget _buildFileRow(BuildContext context, SkillFileMetadata file) {
    final theme = Theme.of(context);
    final String size = formatBytes(file.sizeBytes);
    final DateTime modified = DateTime.fromMillisecondsSinceEpoch(
      file.modifiedMillis,
    );
    return Container(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      padding: const EdgeInsets.symmetric(vertical: AppTheme.spacing2),
      child: Row(
        children: [
          Icon(
            file.relativePath == 'SKILL.md'
                ? Icons.description_outlined
                : Icons.insert_drive_file_outlined,
            size: 20,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: AppTheme.spacing2),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  file.relativePath,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$size · ${intl.DateFormat('yyyy-MM-dd HH:mm').format(modified)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: AppLocalizations.of(context).settingsSkillsCopyFileTooltip,
            onPressed: () => _copyFile(file.relativePath),
            icon: const Icon(Icons.copy_outlined),
          ),
          IconButton(
            tooltip: AppLocalizations.of(context).settingsSkillsEditFileTooltip,
            onPressed: () => _editFile(file.relativePath),
            icon: const Icon(Icons.edit_outlined),
          ),
          if (file.relativePath != 'SKILL.md')
            IconButton(
              tooltip: AppLocalizations.of(
                context,
              ).settingsSkillsDeleteFileTooltip,
              onPressed: () => _deleteFile(file.relativePath),
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
    );
  }
}

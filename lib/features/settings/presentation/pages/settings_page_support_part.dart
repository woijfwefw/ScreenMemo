part of 'settings_page.dart';

// ========== 赞赏页面 ==========
extension _SettingsSupportPart on _SettingsPageState {

  Widget _buildSupportPage(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return ListView(
      padding: _settingsListPadding(),
      children: [
        _buildSupportIntroCard(context),
        const SizedBox(height: AppTheme.spacing3),
        _buildAboutSectionTitle(context, l10n.supportWishListTitle),
        _buildCard(
          context: context,
          children: [
            _buildSupportWishItem(
              context: context,
              icon: Icons.devices_other_outlined,
              text: l10n.supportWishMorePlatforms,
              showBottomBorder: true,
            ),
            _buildSupportWishItem(
              context: context,
              icon: Icons.auto_stories_outlined,
              text: l10n.supportWishReviewViews,
              showBottomBorder: true,
            ),
            _buildSupportWishItem(
              context: context,
              icon: Icons.phonelink_setup_outlined,
              text: l10n.supportWishCompatibility,
              showBottomBorder: false,
            ),
          ],
        ),
        const SizedBox(height: AppTheme.spacing3),
        _buildSupportNoteCard(context),
      ],
    );
  }

  Widget _buildSupportIntroCard(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return _buildCard(
      context: context,
      children: [
        Padding(
          padding: const EdgeInsets.all(AppTheme.spacing5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.supportIntroTitle,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: AppTheme.spacing2),
              Text(
                l10n.supportIntroBody,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  height: 1.55,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSupportWishItem({
    required BuildContext context,
    required IconData icon,
    required String text,
    required bool showBottomBorder,
  }) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.spacing4,
        vertical: AppTheme.spacing3,
      ),
      decoration: BoxDecoration(
        border: Border(
          bottom: showBottomBorder
              ? _settingsDividerSide(context)
              : BorderSide.none,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSettingsLeadingIcon(context, icon),
          const SizedBox(width: AppTheme.spacing3),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSupportNoteCard(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);

    return _buildCard(
      context: context,
      children: [
        Padding(
          padding: const EdgeInsets.all(AppTheme.spacing4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildSettingsLeadingIcon(context, Icons.info_outline),
              const SizedBox(width: AppTheme.spacing3),
              Expanded(
                child: Text(
                  l10n.supportVoluntaryNote,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.45,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

}

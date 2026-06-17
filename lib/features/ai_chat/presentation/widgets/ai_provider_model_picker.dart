import 'package:flutter/material.dart';
import 'package:screen_memo/core/theme/app_theme.dart';
import 'package:screen_memo/core/widgets/model_logo.dart';
import 'package:screen_memo/core/widgets/search_styles.dart';
import 'package:screen_memo/core/widgets/ui_components.dart';
import 'package:screen_memo/features/ai/application/ai_providers_service.dart';
import 'package:screen_memo/l10n/app_localizations.dart';

typedef AIProviderDeleteCallback =
    Future<bool> Function(AIProvider provider, bool selected);

Future<void> showAIProviderPickerSheet({
  required BuildContext context,
  required List<AIProvider> providers,
  required int currentProviderId,
  required String queryText,
  required ValueChanged<String> onQueryChanged,
  required Future<void> Function(BuildContext sheetContext, AIProvider provider)
  onSelected,
  AIProviderDeleteCallback? onDelete,
  double initialChildSize = 0.85,
}) async {
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) {
      final TextEditingController queryCtrl = TextEditingController(
        text: queryText,
      );
      return StatefulBuilder(
        builder: (modalContext, setModalState) {
          return DraggableScrollableSheet(
            initialChildSize: initialChildSize,
            minChildSize: 0.5,
            maxChildSize: 0.95,
            expand: false,
            builder: (_, scrollCtrl) {
              final String query = queryCtrl.text.trim().toLowerCase();
              final List<AIProvider> filtered = providers.where((provider) {
                if (query.isEmpty) return true;
                final String name = provider.name.toLowerCase();
                final String type = provider.type.toLowerCase();
                final String baseUrl = (provider.baseUrl ?? '').toLowerCase();
                return name.contains(query) ||
                    type.contains(query) ||
                    baseUrl.contains(query);
              }).toList();
              _moveProviderToTop(filtered, currentProviderId);

              return _AISelectionSheetFrame(
                searchField: SearchTextField(
                  controller: queryCtrl,
                  hintText: AppLocalizations.of(
                    context,
                  ).searchProviderPlaceholder,
                  autofocus: true,
                  onChanged: (value) {
                    onQueryChanged(value);
                    setModalState(() {});
                  },
                ),
                child: ListView.separated(
                  controller: scrollCtrl,
                  itemCount: filtered.length,
                  separatorBuilder: (context, _) => const _AISelectionDivider(),
                  itemBuilder: (itemContext, index) {
                    final AIProvider provider = filtered[index];
                    final bool selected = provider.id == currentProviderId;
                    return _AIProviderTile(
                      provider: provider,
                      selected: selected,
                      onTap: () => onSelected(sheetContext, provider),
                      onDelete: onDelete == null
                          ? null
                          : () async {
                              final bool deleted = await onDelete(
                                provider,
                                selected,
                              );
                              if (deleted) {
                                providers.removeWhere(
                                  (item) => item.id == provider.id,
                                );
                                setModalState(() {});
                              }
                            },
                    );
                  },
                ),
              );
            },
          );
        },
      );
    },
  );
}

Future<void> showAIModelPickerSheet({
  required BuildContext context,
  required List<String> models,
  required String activeModel,
  required String queryText,
  required ValueChanged<String> onQueryChanged,
  required Future<void> Function(BuildContext sheetContext, String model)
  onSelected,
  double initialChildSize = 0.85,
}) async {
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) {
      final TextEditingController queryCtrl = TextEditingController(
        text: queryText,
      );
      return StatefulBuilder(
        builder: (modalContext, setModalState) {
          return DraggableScrollableSheet(
            initialChildSize: initialChildSize,
            minChildSize: 0.5,
            maxChildSize: 0.95,
            expand: false,
            builder: (_, scrollCtrl) {
              final String query = queryCtrl.text.trim().toLowerCase();
              final List<String> filtered = models.where((model) {
                if (query.isEmpty) return true;
                return model.toLowerCase().contains(query);
              }).toList();
              _moveModelToTop(filtered, activeModel);

              return _AISelectionSheetFrame(
                searchField: SearchTextField(
                  controller: queryCtrl,
                  hintText: AppLocalizations.of(context).searchModelPlaceholder,
                  autofocus: true,
                  onChanged: (value) {
                    onQueryChanged(value);
                    setModalState(() {});
                  },
                ),
                child: ListView.separated(
                  controller: scrollCtrl,
                  itemCount: filtered.length,
                  separatorBuilder: (context, _) => const _AISelectionDivider(),
                  itemBuilder: (itemContext, index) {
                    final String model = filtered[index];
                    final bool selected = model == activeModel;
                    return _AIModelTile(
                      model: model,
                      selected: selected,
                      onTap: () => onSelected(sheetContext, model),
                    );
                  },
                ),
              );
            },
          );
        },
      );
    },
  );
}

String resolveModelForProvider(AIProvider provider, String? currentModel) {
  String model = (currentModel ?? '').trim();
  final List<String> available = provider.models;
  if (model.isEmpty || (available.isNotEmpty && !available.contains(model))) {
    model = (provider.extra['active_model'] as String? ?? provider.defaultModel)
        .toString()
        .trim();
  }
  if (model.isEmpty && available.isNotEmpty) {
    model = available.first;
  }
  return model;
}

void _moveProviderToTop(List<AIProvider> providers, int currentProviderId) {
  final int selectedIndex = providers.indexWhere(
    (provider) => provider.id == currentProviderId,
  );
  if (selectedIndex <= 0) return;
  final AIProvider selected = providers.removeAt(selectedIndex);
  providers.insert(0, selected);
}

void _moveModelToTop(List<String> models, String activeModel) {
  final String active = activeModel.trim();
  if (active.isEmpty) return;
  final int selectedIndex = models.indexOf(active);
  if (selectedIndex <= 0) return;
  final String selected = models.removeAt(selectedIndex);
  models.insert(0, selected);
}

class _AISelectionSheetFrame extends StatelessWidget {
  const _AISelectionSheetFrame({
    required this.searchField,
    required this.child,
  });

  final Widget searchField;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return UISheetSurface(
      child: Column(
        children: [
          const SizedBox(height: AppTheme.spacing3),
          const UISheetHandle(),
          const SizedBox(height: AppTheme.spacing3),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.spacing4,
              AppTheme.spacing2,
              AppTheme.spacing4,
              AppTheme.spacing2,
            ),
            child: searchField,
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _AISelectionDivider extends StatelessWidget {
  const _AISelectionDivider();

  @override
  Widget build(BuildContext context) {
    return Divider(
      height: 1,
      thickness: 0.8,
      color: Theme.of(context).colorScheme.outlineVariant,
    );
  }
}

class _AIProviderTile extends StatelessWidget {
  const _AIProviderTile({
    required this.provider,
    required this.selected,
    required this.onTap,
    this.onDelete,
  });

  final AIProvider provider;
  final bool selected;
  final VoidCallback onTap;
  final Future<void> Function()? onDelete;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colorScheme = theme.colorScheme;
    final Color selectedBackground = colorScheme.primaryContainer.withValues(
      alpha: theme.brightness == Brightness.dark ? 0.38 : 0.58,
    );

    return Material(
      color: selected ? selectedBackground : Colors.transparent,
      child: ListTile(
        leading: ProviderLogo(
          providerType: provider.type,
          providerName: provider.name,
          baseUrl: provider.baseUrl,
          size: 20,
        ),
        title: Text(
          provider.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? colorScheme.primary : colorScheme.onSurface,
          ),
        ),
        subtitle: (provider.baseUrl ?? '').trim().isEmpty
            ? null
            : Text(
                provider.baseUrl ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selected)
              Icon(Icons.check_circle_rounded, color: colorScheme.primary),
            if (onDelete != null) ...[
              const SizedBox(width: AppTheme.spacing1),
              IconButton(
                tooltip: AppLocalizations.of(context).actionDelete,
                icon: Icon(
                  Icons.delete_outline_rounded,
                  color: colorScheme.error,
                ),
                onPressed: onDelete == null ? null : () => onDelete!(),
              ),
            ],
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}

class _AIModelTile extends StatelessWidget {
  const _AIModelTile({
    required this.model,
    required this.selected,
    required this.onTap,
  });

  final String model;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colorScheme = theme.colorScheme;
    final Color selectedBackground = colorScheme.primaryContainer.withValues(
      alpha: theme.brightness == Brightness.dark ? 0.38 : 0.58,
    );

    return Material(
      color: selected ? selectedBackground : Colors.transparent,
      child: ListTile(
        leading: ModelLogo(modelId: model, size: 20),
        title: Text(
          model,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? colorScheme.primary : colorScheme.onSurface,
          ),
        ),
        trailing: selected
            ? Icon(Icons.check_circle_rounded, color: colorScheme.primary)
            : null,
        onTap: onTap,
      ),
    );
  }
}

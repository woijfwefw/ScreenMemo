import 'package:flutter/material.dart';

@immutable
class AppThemeColors {
  const AppThemeColors._(this._values, this._dynamicTagPalette);

  static const String primaryKey = 'primary';
  static const String primaryForegroundKey = 'primaryForeground';
  static const String secondaryKey = 'secondary';
  static const String secondaryForegroundKey = 'secondaryForeground';
  static const String mutedKey = 'muted';
  static const String mutedForegroundKey = 'mutedForeground';
  static const String accentKey = 'accent';
  static const String accentForegroundKey = 'accentForeground';
  static const String destructiveKey = 'destructive';
  static const String destructiveForegroundKey = 'destructiveForeground';
  static const String borderKey = 'border';
  static const String inputKey = 'input';
  static const String ringKey = 'ring';
  static const String backgroundKey = 'background';
  static const String foregroundKey = 'foreground';
  static const String cardKey = 'card';
  static const String cardForegroundKey = 'cardForeground';
  static const String popoverKey = 'popover';
  static const String popoverForegroundKey = 'popoverForeground';
  static const String successKey = 'success';
  static const String successForegroundKey = 'successForeground';
  static const String warningKey = 'warning';
  static const String warningForegroundKey = 'warningForeground';
  static const String infoKey = 'info';
  static const String infoForegroundKey = 'infoForeground';
  static const String mergedEventAccentKey = 'mergedEventAccent';
  static const String dynamicTagPaletteKey = 'dynamicTagPalette';
  static const String lightPrimaryContainerKey = 'lightPrimaryContainer';
  static const String lightSecondaryContainerKey = 'lightSecondaryContainer';
  static const String lightTertiaryContainerKey = 'lightTertiaryContainer';
  static const String lightErrorContainerKey = 'lightErrorContainer';
  static const String lightOutlineVariantKey = 'lightOutlineVariant';
  static const String lightSurfaceHighKey = 'lightSurfaceHigh';
  static const String lightSurfaceHighestKey = 'lightSurfaceHighest';
  static const String lightInversePrimaryKey = 'lightInversePrimary';
  static const String darkPrimaryKey = 'darkPrimary';
  static const String darkPrimaryForegroundKey = 'darkPrimaryForeground';
  static const String darkSecondaryKey = 'darkSecondary';
  static const String darkSecondaryForegroundKey = 'darkSecondaryForeground';
  static const String darkMutedKey = 'darkMuted';
  static const String darkMutedForegroundKey = 'darkMutedForeground';
  static const String darkAccentKey = 'darkAccent';
  static const String darkAccentForegroundKey = 'darkAccentForeground';
  static const String darkDestructiveKey = 'darkDestructive';
  static const String darkDestructiveForegroundKey =
      'darkDestructiveForeground';
  static const String darkBorderKey = 'darkBorder';
  static const String darkInputKey = 'darkInput';
  static const String darkRingKey = 'darkRing';
  static const String darkBackgroundKey = 'darkBackground';
  static const String darkForegroundKey = 'darkForeground';
  static const String darkCardKey = 'darkCard';
  static const String darkCardForegroundKey = 'darkCardForeground';
  static const String darkPopoverKey = 'darkPopover';
  static const String darkPopoverForegroundKey = 'darkPopoverForeground';
  static const String darkSelectedAccentKey = 'darkSelectedAccent';
  static const String darkPrimaryContainerKey = 'darkPrimaryContainer';
  static const String darkSecondaryContainerKey = 'darkSecondaryContainer';
  static const String darkTertiaryContainerKey = 'darkTertiaryContainer';
  static const String darkErrorContainerKey = 'darkErrorContainer';
  static const String darkOutlineVariantKey = 'darkOutlineVariant';
  static const String darkSurfaceHighKey = 'darkSurfaceHigh';
  static const String darkSurfaceHighestKey = 'darkSurfaceHighest';
  static const String darkSurfaceContainerLowestKey =
      'darkSurfaceContainerLowest';

  static const List<String> lightBaseKeys = <String>[
    primaryKey,
    primaryForegroundKey,
    secondaryKey,
    secondaryForegroundKey,
    mutedKey,
    mutedForegroundKey,
    accentKey,
    accentForegroundKey,
    borderKey,
    inputKey,
    ringKey,
    backgroundKey,
    foregroundKey,
    cardKey,
    cardForegroundKey,
    popoverKey,
    popoverForegroundKey,
  ];

  static const List<String> statusKeys = <String>[
    successKey,
    successForegroundKey,
    warningKey,
    warningForegroundKey,
    destructiveKey,
    destructiveForegroundKey,
    infoKey,
    infoForegroundKey,
    mergedEventAccentKey,
  ];

  static const List<String> lightSurfaceKeys = <String>[
    lightPrimaryContainerKey,
    lightSecondaryContainerKey,
    lightTertiaryContainerKey,
    lightErrorContainerKey,
    lightOutlineVariantKey,
    lightSurfaceHighKey,
    lightSurfaceHighestKey,
    lightInversePrimaryKey,
  ];

  static const List<String> darkBaseKeys = <String>[
    darkPrimaryKey,
    darkPrimaryForegroundKey,
    darkSecondaryKey,
    darkSecondaryForegroundKey,
    darkMutedKey,
    darkMutedForegroundKey,
    darkAccentKey,
    darkAccentForegroundKey,
    darkDestructiveKey,
    darkDestructiveForegroundKey,
    darkBorderKey,
    darkInputKey,
    darkRingKey,
    darkBackgroundKey,
    darkForegroundKey,
    darkCardKey,
    darkCardForegroundKey,
    darkPopoverKey,
    darkPopoverForegroundKey,
    darkSelectedAccentKey,
  ];

  static const List<String> darkSurfaceKeys = <String>[
    darkPrimaryContainerKey,
    darkSecondaryContainerKey,
    darkTertiaryContainerKey,
    darkErrorContainerKey,
    darkOutlineVariantKey,
    darkSurfaceHighKey,
    darkSurfaceHighestKey,
    darkSurfaceContainerLowestKey,
  ];

  static const List<String> keys = <String>[
    ...lightBaseKeys,
    ...statusKeys,
    ...lightSurfaceKeys,
    ...darkBaseKeys,
    ...darkSurfaceKeys,
  ];

  static const List<Color> defaultDynamicTagPalette = <Color>[
    Color(0xFF6A9BCC),
    Color(0xFF788C5D),
    Color(0xFFD97757),
    Color(0xFF4E9A8A),
    Color(0xFFB56A7A),
    Color(0xFF7E77B8),
    Color(0xFF5B8A72),
  ];

  static const AppThemeColors defaults = AppThemeColors._(<String, Color>{
    primaryKey: Color(0xFFD97757),
    primaryForegroundKey: Color(0xFFFFFFFF),
    secondaryKey: Color(0xFF6A9BCC),
    secondaryForegroundKey: Color(0xFFFAF9F5),
    mutedKey: Color(0xFFE8E6DC),
    mutedForegroundKey: Color(0xFF828179),
    accentKey: Color(0xFFD97757),
    accentForegroundKey: Color(0xFF141413),
    destructiveKey: Color(0xFFD32F2F),
    destructiveForegroundKey: Color(0xFFFAF9F5),
    borderKey: Color(0xFFD8D4C9),
    inputKey: Color(0xFFF0EFEA),
    ringKey: Color(0xFFD97757),
    backgroundKey: Color(0xFFFAF9F5),
    foregroundKey: Color(0xFF141413),
    cardKey: Color(0xFFE8E6DC),
    cardForegroundKey: Color(0xFF141413),
    popoverKey: Color(0xFFF0EFEA),
    popoverForegroundKey: Color(0xFF141413),
    successKey: Color(0xFF788C5D),
    successForegroundKey: Color(0xFFFAF9F5),
    warningKey: Color(0xFFD32F2F),
    warningForegroundKey: Color(0xFFFAF9F5),
    infoKey: Color(0xFF6A9BCC),
    infoForegroundKey: Color(0xFFFAF9F5),
    mergedEventAccentKey: Color(0xFF9B7656),
    lightPrimaryContainerKey: Color(0xFFF2E0D7),
    lightSecondaryContainerKey: Color(0xFFDCE7F1),
    lightTertiaryContainerKey: Color(0xFFE2E8D9),
    lightErrorContainerKey: Color(0xFFFFEBEE),
    lightOutlineVariantKey: Color(0xFFE3DED2),
    lightSurfaceHighKey: Color(0xFFE3DFD4),
    lightSurfaceHighestKey: Color(0xFFDFDBCF),
    lightInversePrimaryKey: Color(0xFFE6A48A),
    darkPrimaryKey: Color(0xFFD97757),
    darkPrimaryForegroundKey: Color(0xFFFFFFFF),
    darkSecondaryKey: Color(0xFF86ADD3),
    darkSecondaryForegroundKey: Color(0xFF141413),
    darkMutedKey: Color(0xFF2A2926),
    darkMutedForegroundKey: Color(0xFFD8D1C4),
    darkAccentKey: Color(0xFFD97757),
    darkAccentForegroundKey: Color(0xFF141413),
    darkDestructiveKey: Color(0xFFD32F2F),
    darkDestructiveForegroundKey: Color(0xFFFAF9F5),
    darkBorderKey: Color(0xFF3D3D3A),
    darkInputKey: Color(0xFF1F1E1B),
    darkRingKey: Color(0xFFD97757),
    darkBackgroundKey: Color(0xFF141413),
    darkForegroundKey: Color(0xFFFAF9F5),
    darkCardKey: Color(0xFF2A2926),
    darkCardForegroundKey: Color(0xFFFAF9F5),
    darkPopoverKey: Color(0xFF1F1E1B),
    darkPopoverForegroundKey: Color(0xFFFAF9F5),
    darkSelectedAccentKey: Color(0xFF86ADD3),
    darkPrimaryContainerKey: Color(0xFF5D372D),
    darkSecondaryContainerKey: Color(0xFF243747),
    darkTertiaryContainerKey: Color(0xFF323D28),
    darkErrorContainerKey: Color(0xFF8C1D18),
    darkOutlineVariantKey: Color(0xFF4A4844),
    darkSurfaceHighKey: Color(0xFF2F2E2B),
    darkSurfaceHighestKey: Color(0xFF353431),
    darkSurfaceContainerLowestKey: Color(0xFF0E0E0D),
  }, defaultDynamicTagPalette);

  static const AppThemeColors green = AppThemeColors._(<String, Color>{
    primaryKey: Color(0xFF27BD51),
    primaryForegroundKey: Color(0xFFFFFFFF),
    secondaryKey: Color(0xFF166534),
    secondaryForegroundKey: Color(0xFFF7FAF6),
    mutedKey: Color(0xFFEAF2EC),
    mutedForegroundKey: Color(0xFF647067),
    accentKey: Color(0xFFD8FFE3),
    accentForegroundKey: Color(0xFF063814),
    destructiveKey: Color(0xFFEF4444),
    destructiveForegroundKey: Color(0xFFFFFFFF),
    borderKey: Color(0xFFDDE7E0),
    inputKey: Color(0xFFFFFFFF),
    ringKey: Color(0xFF22E66A),
    backgroundKey: Color(0xFFF4F4F4),
    foregroundKey: Color(0xFF101914),
    cardKey: Color(0xFFFFFFFF),
    cardForegroundKey: Color(0xFF101914),
    popoverKey: Color(0xFFFFFFFF),
    popoverForegroundKey: Color(0xFF101914),
    successKey: Color(0xFF22E66A),
    successForegroundKey: Color(0xFF06100B),
    warningKey: Color(0xFFF59E0B),
    warningForegroundKey: Color(0xFF1F1603),
    infoKey: Color(0xFF8AC3FB),
    infoForegroundKey: Color(0xFFFFFFFF),
    mergedEventAccentKey: Color(0xFF98BF71),
    lightPrimaryContainerKey: Color(0xFFC9FFD9),
    lightSecondaryContainerKey: Color(0xFFDDF4E5),
    lightTertiaryContainerKey: Color(0xFFEAF2FF),
    lightErrorContainerKey: Color(0xFFFEE2E2),
    lightOutlineVariantKey: Color(0xFFE6EEE8),
    lightSurfaceHighKey: Color(0xFFDFF1E4),
    lightSurfaceHighestKey: Color(0xFFDFF1E4),
    lightInversePrimaryKey: Color(0xFF39F17A),
    darkPrimaryKey: Color(0xFF27BD51),
    darkPrimaryForegroundKey: Color(0xFF06100B),
    darkSecondaryKey: Color(0xFF8BE6A7),
    darkSecondaryForegroundKey: Color(0xFF06100B),
    darkMutedKey: Color(0xFF14221A),
    darkMutedForegroundKey: Color(0xFFA8B8AD),
    darkAccentKey: Color(0xFF39F17A),
    darkAccentForegroundKey: Color(0xFF06100B),
    darkDestructiveKey: Color(0xFFF87171),
    darkDestructiveForegroundKey: Color(0xFF160606),
    darkBorderKey: Color(0xFF284233),
    darkInputKey: Color(0xFF102018),
    darkRingKey: Color(0xFF22E66A),
    darkBackgroundKey: Color(0xFF080807),
    darkForegroundKey: Color(0xFFF4FFF7),
    darkCardKey: Color(0xFF0B1711),
    darkCardForegroundKey: Color(0xFFF4FFF7),
    darkPopoverKey: Color(0xFF171716),
    darkPopoverForegroundKey: Color(0xFFF4FFF7),
    darkSelectedAccentKey: Color(0xFF8AC3FB),
    darkPrimaryContainerKey: Color(0xFF0E4D24),
    darkSecondaryContainerKey: Color(0xFF123D25),
    darkTertiaryContainerKey: Color(0xFF102A3F),
    darkErrorContainerKey: Color(0xFF5F1515),
    darkOutlineVariantKey: Color(0xFF20382A),
    darkSurfaceHighKey: Color(0xFF080807),
    darkSurfaceHighestKey: Color(0xFF0D1F13),
    darkSurfaceContainerLowestKey: Color(0xFF020604),
  }, defaultDynamicTagPalette);

  final Map<String, Color> _values;
  final List<Color> _dynamicTagPalette;

  Color colorFor(String key) {
    return _values[key] ?? defaults._values[key] ?? defaults.primary;
  }

  AppThemeColors copyWithColor(String key, Color color) {
    if (!keys.contains(key)) return this;
    return AppThemeColors._(<String, Color>{
      ...toColorMap(),
      key: color,
    }, dynamicTagPalette);
  }

  AppThemeColors copyWithDynamicTagPalette(List<Color> palette) {
    final List<Color> nextPalette = palette.isEmpty
        ? defaultDynamicTagPalette
        : List<Color>.unmodifiable(palette);
    return AppThemeColors._(toColorMap(), nextPalette);
  }

  AppThemeColors copyWithDynamicTagPaletteColor(int index, Color color) {
    final List<Color> palette = List<Color>.of(dynamicTagPalette);
    if (index < 0 || index >= palette.length) return this;
    palette[index] = color;
    return copyWithDynamicTagPalette(palette);
  }

  Map<String, Color> toColorMap() {
    return <String, Color>{for (final String key in keys) key: colorFor(key)};
  }

  Map<String, int> toJson() {
    return <String, int>{
      for (final String key in keys) key: colorFor(key).toARGB32(),
    };
  }

  Map<String, dynamic> toJsonMap() {
    return <String, dynamic>{
      for (final String key in keys) key: colorFor(key).toARGB32(),
      dynamicTagPaletteKey: <int>[
        for (final Color color in dynamicTagPalette) color.toARGB32(),
      ],
    };
  }

  static AppThemeColors fromJson(
    Map<String, dynamic> json, {
    AppThemeColors fallback = defaults,
  }) {
    final Map<String, Color> values = fallback.toColorMap();
    for (final String key in keys) {
      final Color? parsed = _parseColorValue(json[key]);
      if (parsed != null) values[key] = parsed;
    }
    final List<Color> dynamicTagPalette =
        _parseColorList(json[dynamicTagPaletteKey]) ??
        fallback.dynamicTagPalette;
    return AppThemeColors._(values, dynamicTagPalette);
  }

  static Color? _parseColorValue(Object? value) {
    if (value is int) return Color(value);
    if (value is String) {
      return parseHexColor(value);
    }
    return null;
  }

  static List<Color>? _parseColorList(Object? value) {
    if (value is! List) return null;
    final List<Color> colors = <Color>[];
    for (final Object? item in value) {
      final Color? parsed = _parseColorValue(item);
      if (parsed != null) colors.add(parsed);
    }
    return colors.isEmpty ? null : List<Color>.unmodifiable(colors);
  }

  static Color? parseHexColor(String value) {
    final String normalized = value.trim().replaceFirst('#', '');
    final int? parsed = int.tryParse(normalized, radix: 16);
    if (parsed == null) return null;
    if (normalized.length == 6) return Color(0xFF000000 | parsed);
    if (normalized.length == 8) return Color(parsed);
    return null;
  }

  bool get isDefault {
    for (final String key in keys) {
      if (colorFor(key).toARGB32() != defaults.colorFor(key).toARGB32()) {
        return false;
      }
    }
    if (dynamicTagPalette.length != defaults.dynamicTagPalette.length) {
      return false;
    }
    for (int i = 0; i < dynamicTagPalette.length; i += 1) {
      if (dynamicTagPalette[i].toARGB32() !=
          defaults.dynamicTagPalette[i].toARGB32()) {
        return false;
      }
    }
    return true;
  }

  List<Color> get dynamicTagPalette => List<Color>.unmodifiable(
    _dynamicTagPalette.isEmpty ? defaultDynamicTagPalette : _dynamicTagPalette,
  );

  Color get primary => colorFor(primaryKey);
  Color get primaryForeground => colorFor(primaryForegroundKey);
  Color get secondary => colorFor(secondaryKey);
  Color get secondaryForeground => colorFor(secondaryForegroundKey);
  Color get muted => colorFor(mutedKey);
  Color get mutedForeground => colorFor(mutedForegroundKey);
  Color get accent => colorFor(accentKey);
  Color get accentForeground => colorFor(accentForegroundKey);
  Color get destructive => colorFor(destructiveKey);
  Color get destructiveForeground => colorFor(destructiveForegroundKey);
  Color get border => colorFor(borderKey);
  Color get input => colorFor(inputKey);
  Color get ring => colorFor(ringKey);
  Color get background => colorFor(backgroundKey);
  Color get foreground => colorFor(foregroundKey);
  Color get card => colorFor(cardKey);
  Color get cardForeground => colorFor(cardForegroundKey);
  Color get popover => colorFor(popoverKey);
  Color get popoverForeground => colorFor(popoverForegroundKey);
  Color get success => colorFor(successKey);
  Color get successForeground => colorFor(successForegroundKey);
  Color get warning => colorFor(warningKey);
  Color get warningForeground => colorFor(warningForegroundKey);
  Color get info => colorFor(infoKey);
  Color get infoForeground => colorFor(infoForegroundKey);
  Color get mergedEventAccent => colorFor(mergedEventAccentKey);
  Color get lightPrimaryContainer => colorFor(lightPrimaryContainerKey);
  Color get lightSecondaryContainer => colorFor(lightSecondaryContainerKey);
  Color get lightTertiaryContainer => colorFor(lightTertiaryContainerKey);
  Color get lightErrorContainer => colorFor(lightErrorContainerKey);
  Color get lightOutlineVariant => colorFor(lightOutlineVariantKey);
  Color get lightSurfaceHigh => colorFor(lightSurfaceHighKey);
  Color get lightSurfaceHighest => colorFor(lightSurfaceHighestKey);
  Color get lightInversePrimary => colorFor(lightInversePrimaryKey);
  Color get darkPrimary => colorFor(darkPrimaryKey);
  Color get darkPrimaryForeground => colorFor(darkPrimaryForegroundKey);
  Color get darkSecondary => colorFor(darkSecondaryKey);
  Color get darkSecondaryForeground => colorFor(darkSecondaryForegroundKey);
  Color get darkMuted => colorFor(darkMutedKey);
  Color get darkMutedForeground => colorFor(darkMutedForegroundKey);
  Color get darkAccent => colorFor(darkAccentKey);
  Color get darkAccentForeground => colorFor(darkAccentForegroundKey);
  Color get darkDestructive => colorFor(darkDestructiveKey);
  Color get darkDestructiveForeground => colorFor(darkDestructiveForegroundKey);
  Color get darkBorder => colorFor(darkBorderKey);
  Color get darkInput => colorFor(darkInputKey);
  Color get darkRing => colorFor(darkRingKey);
  Color get darkBackground => colorFor(darkBackgroundKey);
  Color get darkForeground => colorFor(darkForegroundKey);
  Color get darkCard => colorFor(darkCardKey);
  Color get darkCardForeground => colorFor(darkCardForegroundKey);
  Color get darkPopover => colorFor(darkPopoverKey);
  Color get darkPopoverForeground => colorFor(darkPopoverForegroundKey);
  Color get darkSelectedAccent => colorFor(darkSelectedAccentKey);
  Color get darkPrimaryContainer => colorFor(darkPrimaryContainerKey);
  Color get darkSecondaryContainer => colorFor(darkSecondaryContainerKey);
  Color get darkTertiaryContainer => colorFor(darkTertiaryContainerKey);
  Color get darkErrorContainer => colorFor(darkErrorContainerKey);
  Color get darkOutlineVariant => colorFor(darkOutlineVariantKey);
  Color get darkSurfaceHigh => colorFor(darkSurfaceHighKey);
  Color get darkSurfaceHighest => colorFor(darkSurfaceHighestKey);
  Color get darkSurfaceContainerLowest =>
      colorFor(darkSurfaceContainerLowestKey);
}

class AppTheme {
  static AppThemeColors _colors = AppThemeColors.defaults;

  static AppThemeColors get colors => _colors;

  static void setColors(AppThemeColors colors) {
    _colors = colors;
  }

  static Color get primary => _colors.primary;
  static Color get primaryForeground => _colors.primaryForeground;
  static Color get secondary => _colors.secondary;
  static Color get secondaryForeground => _colors.secondaryForeground;
  static Color get muted => _colors.muted;
  static Color get mutedForeground => _colors.mutedForeground;
  static Color get accent => _colors.accent;
  static Color get accentForeground => _colors.accentForeground;
  static Color get destructive => _colors.destructive;
  static Color get destructiveForeground => _colors.destructiveForeground;
  static Color get border => _colors.border;
  static Color get input => _colors.input;
  static Color get ring => _colors.ring;
  static Color get background => _colors.background;
  static Color get pageBackgroundLight => background;
  static Color get foreground => _colors.foreground;
  static Color get card => _colors.card;
  static Color get cardForeground => _colors.cardForeground;
  static Color get popover => _colors.popover;
  static Color get popoverForeground => _colors.popoverForeground;

  static Color get success => _colors.success;
  static Color get successForeground => _colors.successForeground;
  static Color get warning => _colors.warning;
  static Color get warningForeground => _colors.warningForeground;
  static Color get info => _colors.info;
  static Color get infoForeground => _colors.infoForeground;
  static Color get mergedEventAccent => _colors.mergedEventAccent;
  static List<Color> get dynamicTagPalette => _colors.dynamicTagPalette;

  static const double radiusXs = 2.0;
  static const double radiusSm = 4.0;
  static const double radiusMd = 6.0;
  static const double radiusLg = 8.0;
  static const double radiusXl = 12.0;

  static const double spacing1 = 4.0;
  static const double spacing2 = 8.0;
  static const double spacing3 = 12.0;
  static const double spacing4 = 16.0;
  static const double spacing5 = 20.0;
  static const double spacing6 = 24.0;
  static const double spacing8 = 32.0;
  static const double spacing10 = 40.0;
  static const double spacing12 = 48.0;
  static const double spacing16 = 64.0;
  static const double spacing20 = 80.0;

  static const double fontSizeXs = 12.0;
  static const double fontSizeSm = 14.0;
  static const double fontSizeBase = 16.0;
  static const double fontSizeLg = 18.0;
  static const double fontSizeXl = 20.0;
  static const double fontSize2xl = 24.0;
  static const double fontSize3xl = 30.0;
  static const double fontSize4xl = 36.0;

  static const List<BoxShadow> shadowNone = [];

  static Color get darkPrimary => _colors.darkPrimary;
  static Color get darkPrimaryForeground => _colors.darkPrimaryForeground;
  static Color get darkSecondary => _colors.darkSecondary;
  static Color get darkSecondaryForeground => _colors.darkSecondaryForeground;
  static Color get darkMuted => _colors.darkMuted;
  static Color get darkMutedForeground => _colors.darkMutedForeground;
  static Color get darkAccent => _colors.darkAccent;
  static Color get darkAccentForeground => _colors.darkAccentForeground;
  static Color get darkDestructive => _colors.darkDestructive;
  static Color get darkDestructiveForeground =>
      _colors.darkDestructiveForeground;
  static Color get darkBorder => _colors.darkBorder;
  static Color get darkInput => _colors.darkInput;
  static Color get darkRing => _colors.darkRing;
  static Color get darkBackground => _colors.darkBackground;
  static Color get darkForeground => _colors.darkForeground;
  static Color get darkCard => _colors.darkCard;
  static Color get darkCardForeground => _colors.darkCardForeground;
  static Color get darkPopover => _colors.darkPopover;
  static Color get darkPopoverForeground => _colors.darkPopoverForeground;
  static Color get darkSelectedAccent => _colors.darkSelectedAccent;

  static Color get _lightSubtle => input;
  static Color get _lightCard => card;
  static Color get _lightPrimaryContainer => _colors.lightPrimaryContainer;
  static Color get _lightSecondaryContainer => _colors.lightSecondaryContainer;
  static Color get _lightTertiaryContainer => _colors.lightTertiaryContainer;
  static Color get _lightErrorContainer => _colors.lightErrorContainer;
  static Color get _lightOutlineVariant => _colors.lightOutlineVariant;
  static Color get _lightSurfaceHigh => _colors.lightSurfaceHigh;
  static Color get _lightSurfaceHighest => _colors.lightSurfaceHighest;
  static Color get _lightInversePrimary => _colors.lightInversePrimary;

  static Color get _darkSubtle => darkPopover;
  static Color get _darkCard => darkCard;
  static Color get _darkPrimaryContainer => _colors.darkPrimaryContainer;
  static Color get _darkSecondaryContainer => _colors.darkSecondaryContainer;
  static Color get _darkTertiaryContainer => _colors.darkTertiaryContainer;
  static Color get _darkErrorContainer => _colors.darkErrorContainer;
  static Color get _darkOutlineVariant => _colors.darkOutlineVariant;
  static Color get _darkSurfaceHigh => _colors.darkSurfaceHigh;
  static Color get _darkSurfaceHighest => _colors.darkSurfaceHighest;
  static Color get _darkSurfaceContainerLowest =>
      _colors.darkSurfaceContainerLowest;

  static ColorScheme get _lightColorScheme => ColorScheme(
    brightness: Brightness.light,
    primary: primary,
    onPrimary: primaryForeground,
    primaryContainer: _lightPrimaryContainer,
    onPrimaryContainer: foreground,
    secondary: secondary,
    onSecondary: secondaryForeground,
    secondaryContainer: _lightSecondaryContainer,
    onSecondaryContainer: foreground,
    tertiary: success,
    onTertiary: successForeground,
    tertiaryContainer: _lightTertiaryContainer,
    onTertiaryContainer: foreground,
    error: destructive,
    onError: destructiveForeground,
    errorContainer: _lightErrorContainer,
    onErrorContainer: foreground,
    surface: _lightSubtle,
    onSurface: foreground,
    surfaceDim: _lightSubtle,
    surfaceBright: const Color(0xFFFCFBF7),
    surfaceContainerLowest: background,
    surfaceContainerLow: _lightSubtle,
    surfaceContainer: _lightCard,
    surfaceContainerHigh: _lightSurfaceHigh,
    surfaceContainerHighest: _lightSurfaceHighest,
    onSurfaceVariant: mutedForeground,
    outline: border,
    outlineVariant: _lightOutlineVariant,
    shadow: Colors.black,
    scrim: Colors.black,
    inverseSurface: darkBackground,
    onInverseSurface: darkForeground,
    inversePrimary: _lightInversePrimary,
    surfaceTint: Colors.transparent,
  );

  static ColorScheme get _darkColorScheme => ColorScheme(
    brightness: Brightness.dark,
    primary: darkPrimary,
    onPrimary: darkPrimaryForeground,
    primaryContainer: _darkPrimaryContainer,
    onPrimaryContainer: darkForeground,
    secondary: darkSecondary,
    onSecondary: darkSecondaryForeground,
    secondaryContainer: _darkSecondaryContainer,
    onSecondaryContainer: darkForeground,
    tertiary: const Color(0xFF8EA076),
    onTertiary: foreground,
    tertiaryContainer: _darkTertiaryContainer,
    onTertiaryContainer: darkForeground,
    error: darkDestructive,
    onError: darkDestructiveForeground,
    errorContainer: _darkErrorContainer,
    onErrorContainer: darkForeground,
    surface: _darkSubtle,
    onSurface: darkForeground,
    surfaceDim: darkBackground,
    surfaceBright: _darkCard,
    surfaceContainerLowest: _darkSurfaceContainerLowest,
    surfaceContainerLow: _darkSubtle,
    surfaceContainer: _darkCard,
    surfaceContainerHigh: _darkSurfaceHigh,
    surfaceContainerHighest: _darkSurfaceHighest,
    onSurfaceVariant: darkMutedForeground,
    outline: darkBorder,
    outlineVariant: _darkOutlineVariant,
    shadow: Colors.black,
    scrim: Colors.black,
    inverseSurface: background,
    onInverseSurface: foreground,
    inversePrimary: primary,
    surfaceTint: Colors.transparent,
  );

  static ThemeData get lightTheme => _buildThemeData(
    colorScheme: _lightColorScheme,
    scaffoldBackgroundColor: background,
    appBarBackgroundColor: background,
    cardColor: card,
    inputFillColor: _lightSubtle,
    primaryButtonBackgroundColor: primary,
    primaryButtonForegroundColor: primaryForeground,
    secondaryButtonBackgroundColor: _lightCard,
    secondaryButtonForegroundColor: foreground,
  );

  static ThemeData get darkTheme => _buildThemeData(
    colorScheme: _darkColorScheme,
    scaffoldBackgroundColor: darkBackground,
    appBarBackgroundColor: darkBackground,
    cardColor: darkCard,
    inputFillColor: _darkSubtle,
    primaryButtonBackgroundColor: darkPrimary,
    primaryButtonForegroundColor: darkPrimaryForeground,
    secondaryButtonBackgroundColor: _darkCard,
    secondaryButtonForegroundColor: darkForeground,
  );

  static ThemeData _buildThemeData({
    required ColorScheme colorScheme,
    required Color scaffoldBackgroundColor,
    required Color appBarBackgroundColor,
    required Color cardColor,
    required Color inputFillColor,
    required Color primaryButtonBackgroundColor,
    required Color primaryButtonForegroundColor,
    required Color secondaryButtonBackgroundColor,
    required Color secondaryButtonForegroundColor,
  }) {
    final bool isDark = colorScheme.brightness == Brightness.dark;

    final TextTheme textTheme = TextTheme(
      displayLarge: TextStyle(
        fontSize: fontSize4xl,
        fontWeight: FontWeight.bold,
        color: colorScheme.onSurface,
      ),
      displayMedium: TextStyle(
        fontSize: fontSize3xl,
        fontWeight: FontWeight.bold,
        color: colorScheme.onSurface,
      ),
      displaySmall: TextStyle(
        fontSize: fontSize2xl,
        fontWeight: FontWeight.bold,
        color: colorScheme.onSurface,
      ),
      headlineLarge: TextStyle(
        fontSize: fontSize2xl,
        fontWeight: FontWeight.w600,
        color: colorScheme.onSurface,
      ),
      headlineMedium: TextStyle(
        fontSize: fontSizeXl,
        fontWeight: FontWeight.w600,
        color: colorScheme.onSurface,
      ),
      headlineSmall: TextStyle(
        fontSize: fontSizeLg,
        fontWeight: FontWeight.w600,
        color: colorScheme.onSurface,
      ),
      titleLarge: TextStyle(
        fontSize: fontSizeBase,
        fontWeight: FontWeight.w600,
        color: colorScheme.onSurface,
      ),
      titleMedium: TextStyle(
        fontSize: fontSizeSm,
        fontWeight: FontWeight.w500,
        color: colorScheme.onSurface,
      ),
      titleSmall: TextStyle(
        fontSize: fontSizeXs,
        fontWeight: FontWeight.w500,
        color: colorScheme.onSurface,
      ),
      bodyLarge: TextStyle(
        fontSize: fontSizeBase,
        color: colorScheme.onSurface,
      ),
      bodyMedium: TextStyle(fontSize: fontSizeSm, color: colorScheme.onSurface),
      bodySmall: TextStyle(
        fontSize: fontSizeXs,
        color: colorScheme.onSurfaceVariant,
      ),
      labelLarge: TextStyle(
        fontSize: fontSizeSm,
        fontWeight: FontWeight.w500,
        color: colorScheme.onSurface,
      ),
      labelMedium: TextStyle(
        fontSize: fontSizeXs,
        fontWeight: FontWeight.w500,
        color: colorScheme.onSurface,
      ),
      labelSmall: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w500,
        color: colorScheme.onSurfaceVariant,
      ),
    );

    final RoundedRectangleBorder mediumShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radiusMd),
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: scaffoldBackgroundColor,
      dividerColor: colorScheme.outline,
      iconTheme: IconThemeData(color: colorScheme.onSurface),
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: appBarBackgroundColor,
        foregroundColor: colorScheme.onSurface,
        iconTheme: IconThemeData(color: colorScheme.onSurface),
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        toolbarHeight: 48,
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: colorScheme.surfaceContainerLow,
        selectedItemColor: colorScheme.primary,
        unselectedItemColor: colorScheme.onSurfaceVariant,
        type: BottomNavigationBarType.fixed,
        selectedIconTheme: IconThemeData(color: colorScheme.primary, size: 20),
        unselectedIconTheme: IconThemeData(
          color: colorScheme.onSurfaceVariant,
          size: 18,
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colorScheme.surface,
        modalBackgroundColor: colorScheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        modalElevation: 0,
        dragHandleColor: colorScheme.onSurfaceVariant.withValues(alpha: 0.45),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(radiusLg)),
        ),
        clipBehavior: Clip.hardEdge,
      ),
      cardTheme: CardThemeData(
        color: cardColor,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(radiusLg)),
          side: BorderSide(color: colorScheme.outline, width: 1),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: colorScheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusLg),
          side: BorderSide(color: colorScheme.outline, width: 1),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: isDark
            ? const Color(0xE01F1E1B)
            : const Color(0xE0141413),
        contentTextStyle: textTheme.bodyMedium?.copyWith(
          color: background,
          fontWeight: FontWeight.w600,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMd),
        ),
        behavior: SnackBarBehavior.floating,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: colorScheme.primary,
      ),
      chipTheme: ChipThemeData(
        backgroundColor: colorScheme.surfaceContainer,
        selectedColor: colorScheme.primaryContainer,
        secondarySelectedColor: colorScheme.primaryContainer,
        disabledColor: colorScheme.surfaceContainerLow,
        labelStyle: textTheme.bodySmall?.copyWith(color: colorScheme.onSurface),
        secondaryLabelStyle: textTheme.bodySmall?.copyWith(
          color: colorScheme.onPrimaryContainer,
        ),
        padding: const EdgeInsets.symmetric(horizontal: spacing2, vertical: 2),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          side: BorderSide(color: colorScheme.outline, width: 1),
        ),
        side: BorderSide(color: colorScheme.outline, width: 1),
        showCheckmark: false,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return colorScheme.onSurface.withValues(alpha: 0.38);
          }
          if (states.contains(WidgetState.selected)) {
            return Colors.white;
          }
          return colorScheme.surface;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return colorScheme.onSurface.withValues(alpha: 0.12);
          }
          if (states.contains(WidgetState.selected)) {
            return colorScheme.primary;
          }
          return colorScheme.surfaceContainerHigh;
        }),
        trackOutlineColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return Colors.transparent;
          }
          return colorScheme.outline;
        }),
        overlayColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.pressed) ||
              states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.focused)) {
            return colorScheme.primary.withValues(alpha: 0.10);
          }
          return Colors.transparent;
        }),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primaryButtonBackgroundColor,
          foregroundColor: primaryButtonForegroundColor,
          surfaceTintColor: Colors.transparent,
          shape: mediumShape,
          padding: const EdgeInsets.symmetric(
            horizontal: spacing4,
            vertical: spacing2,
          ),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryButtonBackgroundColor,
          foregroundColor: primaryButtonForegroundColor,
          elevation: 0,
          shadowColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          shape: mediumShape,
          padding: const EdgeInsets.symmetric(
            horizontal: spacing4,
            vertical: spacing2,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          backgroundColor: Colors.transparent,
          foregroundColor: colorScheme.onSurface,
          side: BorderSide(color: colorScheme.outline, width: 1),
          shape: mediumShape,
          padding: const EdgeInsets.symmetric(
            horizontal: spacing4,
            vertical: spacing2,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: colorScheme.primary,
          shape: mediumShape,
          padding: const EdgeInsets.symmetric(
            horizontal: spacing4,
            vertical: spacing2,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: inputFillColor,
        hintStyle: textTheme.bodyMedium?.copyWith(
          color: colorScheme.onSurfaceVariant,
        ),
        labelStyle: textTheme.bodyMedium?.copyWith(
          color: colorScheme.onSurfaceVariant,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: BorderSide(color: colorScheme.outline, width: 1),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: BorderSide(color: colorScheme.outline, width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: BorderSide(color: colorScheme.primary, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: BorderSide(color: colorScheme.error, width: 1),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMd),
          borderSide: BorderSide(color: colorScheme.error, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: spacing3,
          vertical: spacing2,
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: colorScheme.onSurfaceVariant,
        textColor: colorScheme.onSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMd),
        ),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: colorScheme.primary,
        selectionColor: colorScheme.primary.withValues(alpha: 0.22),
        selectionHandleColor: colorScheme.primary,
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: colorScheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.only(
            topRight: Radius.circular(radiusLg),
            bottomRight: Radius.circular(radiusLg),
          ),
        ),
      ),
    );
  }
}

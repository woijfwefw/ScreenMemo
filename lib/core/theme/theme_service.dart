import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:screen_memo/core/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeService extends ChangeNotifier {
  static const String _themeKey = 'theme_mode';
  static const String _themeColorsKey = 'theme_colors_v1';
  static const String _legacySeedKey = 'theme_seed_color';
  static const String _legacyLightPageBackgroundKey =
      'light_page_background_color';

  ThemeMode _themeMode = ThemeMode.system;
  AppThemeColors _themeColors = AppThemeColors.defaults;

  ThemeMode get themeMode => _themeMode;
  AppThemeColors get themeColors => _themeColors;
  ThemeData get lightTheme => AppTheme.lightTheme;
  ThemeData get darkTheme => AppTheme.darkTheme;

  ThemeService() {
    _loadTheme();
  }

  Future<void> _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    final int savedThemeMode =
        prefs.getInt(_themeKey) ?? ThemeMode.system.index;
    _themeMode = ThemeMode.values[savedThemeMode];
    _themeColors = _loadSavedThemeColors(prefs);
    AppTheme.setColors(_themeColors);

    await prefs.remove(_legacySeedKey);
    await prefs.remove(_legacyLightPageBackgroundKey);

    notifyListeners();
  }

  AppThemeColors _loadSavedThemeColors(SharedPreferences prefs) {
    final String? savedColors = prefs.getString(_themeColorsKey);
    if (savedColors == null || savedColors.trim().isEmpty) {
      return AppThemeColors.defaults;
    }
    try {
      final Object? decoded = jsonDecode(savedColors);
      if (decoded is Map<String, dynamic>) {
        return AppThemeColors.fromJson(decoded);
      }
      if (decoded is Map) {
        return AppThemeColors.fromJson(Map<String, dynamic>.from(decoded));
      }
    } catch (_) {}
    return AppThemeColors.defaults;
  }

  Future<void> setThemeColor(String key, Color color) async {
    if (!AppThemeColors.keys.contains(key)) return;
    await setThemeColors(_themeColors.copyWithColor(key, color));
  }

  Future<void> setDynamicTagPaletteColor(int index, Color color) async {
    await setThemeColors(
      _themeColors.copyWithDynamicTagPaletteColor(index, color),
    );
  }

  Future<void> setThemeColors(AppThemeColors colors) async {
    _themeColors = colors;
    AppTheme.setColors(_themeColors);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _themeColorsKey,
      jsonEncode(_themeColors.toJsonMap()),
    );
    notifyListeners();
  }

  Future<void> resetThemeColors() async {
    _themeColors = AppThemeColors.defaults;
    AppTheme.setColors(_themeColors);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_themeColorsKey);
    notifyListeners();
  }

  Future<void> toggleTheme() async {
    switch (_themeMode) {
      case ThemeMode.system:
        _themeMode = ThemeMode.light;
        break;
      case ThemeMode.light:
        _themeMode = ThemeMode.dark;
        break;
      case ThemeMode.dark:
        _themeMode = ThemeMode.system;
        break;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_themeKey, _themeMode.index);
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (_themeMode == mode) return;

    _themeMode = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_themeKey, _themeMode.index);
    notifyListeners();
  }

  IconData get themeModeIcon {
    switch (_themeMode) {
      case ThemeMode.system:
        return Icons.brightness_auto_outlined;
      case ThemeMode.light:
        return Icons.brightness_high_outlined;
      case ThemeMode.dark:
        return Icons.brightness_4_outlined;
    }
  }
}

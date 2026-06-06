import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'non-generated source files stay under the maintainability line limit',
    () {
      const int maxLines = 3500;
      final List<_SourceRoot> roots = <_SourceRoot>[
        _SourceRoot(
          directory: Directory('lib'),
          extensions: <String>{'.dart'},
          isGenerated: _isGeneratedDartFile,
        ),
        _SourceRoot(
          directory: Directory('android/app/src/main/kotlin'),
          extensions: <String>{'.kt'},
          isGenerated: _isGeneratedKotlinFile,
        ),
      ];

      for (final _SourceRoot root in roots) {
        expect(root.directory.existsSync(), isTrue);
      }

      final List<String> oversized = roots
          .expand(_listSourceFiles)
          .where((File file) => file.readAsLinesSync().length > maxLines)
          .map(
            (File file) =>
                '${file.path} (${file.readAsLinesSync().length} lines)',
          )
          .toList(growable: false);

      expect(
        oversized,
        isEmpty,
        reason:
            'Split non-generated source files before they exceed 3500 lines.',
      );
    },
  );
}

Iterable<File> _listSourceFiles(_SourceRoot root) {
  return root.directory
      .listSync(recursive: true)
      .whereType<File>()
      .where(
        (File file) =>
            root.extensions.any((String ext) => file.path.endsWith(ext)),
      )
      .where((File file) => !root.isGenerated(file.path));
}

bool _isGeneratedDartFile(String path) {
  final String normalized = path.replaceAll('\\', '/');
  if (normalized == 'lib/l10n/app_localizations.dart') return true;
  if (normalized.startsWith('lib/l10n/app_localizations_')) return true;
  if (normalized.endsWith('.g.dart')) return true;
  if (normalized.endsWith('.freezed.dart')) return true;
  if (normalized.endsWith('.gr.dart')) return true;
  return false;
}

bool _isGeneratedKotlinFile(String path) {
  final String normalized = path.replaceAll('\\', '/');
  if (normalized.contains('/build/')) return true;
  if (normalized.contains('/.gradle/')) return true;
  return false;
}

class _SourceRoot {
  const _SourceRoot({
    required this.directory,
    required this.extensions,
    required this.isGenerated,
  });

  final Directory directory;
  final Set<String> extensions;
  final bool Function(String path) isGenerated;
}

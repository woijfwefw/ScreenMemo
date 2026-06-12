import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class SkillService {
  SkillService._();

  static final SkillService instance = SkillService._();
  static const String _stateFileName = '.screenmemo_skills_state.json';
  static const int _maxGitHubFiles = 80;
  static const int _maxGitHubDepth = 8;
  static const int _maxSkillFileBytes = 512 * 1024;
  static const int _maxSkillTotalBytes = 3 * 1024 * 1024;
  static const Set<String> _blockedFileNames = <String>{
    '.env',
    'id_rsa',
    'id_dsa',
    'id_ecdsa',
    'id_ed25519',
    'credentials',
    'credentials.json',
    'secrets.json',
  };
  static const Set<String> _allowedTextExtensions = <String>{
    '',
    '.md',
    '.markdown',
    '.txt',
    '.json',
    '.yaml',
    '.yml',
    '.toml',
    '.csv',
    '.tsv',
    '.xml',
    '.html',
    '.css',
    '.js',
    '.ts',
    '.dart',
    '.kt',
    '.java',
    '.py',
    '.sh',
    '.ps1',
  };

  Directory? _baseDirForTesting;
  http.Client? _httpClientForTesting;

  void setBaseDirForTesting(Directory? directory) {
    _baseDirForTesting = directory;
  }

  void setHttpClientForTesting(http.Client? client) {
    _httpClientForTesting = client;
  }

  Future<Directory> skillsRoot() async {
    final Directory root =
        _baseDirForTesting ??
        Directory(
          p.join((await getApplicationSupportDirectory()).path, 'skills'),
        );
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
    return root;
  }

  Future<List<SkillMetadata>> listSkills() async {
    final Directory root = await skillsRoot();
    final List<SkillMetadata> out = <SkillMetadata>[];
    final Set<String> disabled = await _readDisabledSkillNames(root);
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final File skillFile = File(p.join(entity.path, 'SKILL.md'));
      if (!await skillFile.exists()) continue;
      final SkillMetadata? metadata = await _parseSkillFile(skillFile, entity);
      if (metadata != null) {
        out.add(metadata.copyWith(enabled: !disabled.contains(metadata.name)));
      }
    }
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  Future<SkillMetadata?> getSkill(String name) async {
    final Directory? dir = await resolveSkillDir(name, mustExist: true);
    if (dir == null) return null;
    final File skillFile = File(p.join(dir.path, 'SKILL.md'));
    if (!await skillFile.exists()) return null;
    final SkillMetadata? metadata = await _parseSkillFile(skillFile, dir);
    if (metadata == null) return null;
    final Set<String> disabled = await _readDisabledSkillNames(
      await skillsRoot(),
    );
    return metadata.copyWith(enabled: !disabled.contains(metadata.name));
  }

  Future<List<SkillMetadata>> listEnabledSkills() async {
    return (await listSkills())
        .where((SkillMetadata skill) => skill.enabled)
        .toList(growable: false);
  }

  Future<void> setSkillEnabled(String name, bool enabled) async {
    final Directory? dir = await resolveSkillDir(name, mustExist: true);
    if (dir == null) {
      throw ArgumentError('Skill not found.');
    }
    final Directory root = await skillsRoot();
    final Set<String> disabled = await _readDisabledSkillNames(root);
    if (enabled) {
      disabled.remove(name);
    } else {
      disabled.add(name);
    }
    await _writeDisabledSkillNames(root, disabled);
  }

  Future<String?> readSkillBody(String name) async {
    final String? content = await readSkillFile(name, 'SKILL.md');
    return content == null ? null : SkillFrontmatterParser.extractBody(content);
  }

  Future<String?> readSkillFile(String name, String relativePath) async {
    final File? file = await resolveSkillFile(name, relativePath);
    if (file == null || !await file.exists()) return null;
    final FileStat stat = await file.stat();
    if (stat.type != FileSystemEntityType.file ||
        stat.size > _maxSkillFileBytes) {
      return null;
    }
    return file.readAsString();
  }

  Future<List<SkillFileMetadata>> listSkillFiles(String name) async {
    final Directory? dir = await resolveSkillDir(name, mustExist: true);
    if (dir == null) return <SkillFileMetadata>[];
    final List<SkillFileMetadata> files = <SkillFileMetadata>[];
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final String relativePath = p
          .relative(entity.path, from: dir.path)
          .replaceAll(r'\', '/');
      if (!_isSafeSkillRelativePath(relativePath)) continue;
      final FileStat stat = await entity.stat();
      if (stat.type != FileSystemEntityType.file ||
          stat.size > _maxSkillFileBytes) {
        continue;
      }
      files.add(
        SkillFileMetadata(
          relativePath: relativePath,
          sizeBytes: stat.size,
          modifiedMillis: stat.modified.millisecondsSinceEpoch,
        ),
      );
    }
    files.sort((a, b) {
      if (a.relativePath == 'SKILL.md') return -1;
      if (b.relativePath == 'SKILL.md') return 1;
      return a.relativePath.toLowerCase().compareTo(
        b.relativePath.toLowerCase(),
      );
    });
    return files;
  }

  Future<SkillMetadata> saveSkillFromContent(String content) async {
    final Map<String, String> frontmatter = SkillFrontmatterParser.parse(
      content,
    );
    final String name = (frontmatter['name'] ?? '').trim();
    if (name.isEmpty) {
      throw const FormatException('SKILL.md must include a name field.');
    }
    if ((frontmatter['description'] ?? '').trim().isEmpty) {
      throw const FormatException('SKILL.md must include a description field.');
    }
    return saveSkillFiles(name, <String, String>{'SKILL.md': content});
  }

  Future<SkillMetadata> saveSkillFiles(
    String name,
    Map<String, String> files,
  ) async {
    final Directory root = await skillsRoot();
    final Directory? targetDir = await resolveSkillDir(name);
    if (targetDir == null) {
      throw ArgumentError('Invalid skill name.');
    }
    final Directory staging = await _createTempSkillDir(root, name, 'staging');
    Directory? backup;
    try {
      int totalBytes = 0;
      for (final entry in files.entries) {
        _ensureSafeSkillFileContent(entry.key, entry.value);
        totalBytes += utf8.encode(entry.value).length;
        if (totalBytes > _maxSkillTotalBytes) {
          throw const FormatException('Skill import is too large.');
        }
        final File? target = await _resolveFileInside(
          staging,
          entry.key,
          mustExist: false,
        );
        if (target == null) {
          throw ArgumentError('Invalid skill file path: ${entry.key}');
        }
        await target.parent.create(recursive: true);
        await target.writeAsString(entry.value);
      }
      final File stagedSkillFile = File(p.join(staging.path, 'SKILL.md'));
      if (!await stagedSkillFile.exists()) {
        throw const FormatException('Skill import must include SKILL.md.');
      }
      final SkillMetadata? metadata = await _parseSkillFile(
        stagedSkillFile,
        staging,
      );
      if (metadata == null) {
        throw const FormatException('Invalid SKILL.md frontmatter.');
      }
      if (metadata.name != name) {
        throw const FormatException(
          'SKILL.md name does not match target name.',
        );
      }
      if (await targetDir.exists()) {
        backup = await _createTempSkillDir(root, name, 'backup');
        await targetDir.rename(backup.path);
      }
      await staging.rename(targetDir.path);
      if (backup != null && await backup.exists()) {
        await backup.delete(recursive: true);
      }
      final SkillMetadata? saved = await getSkill(name);
      if (saved == null) {
        throw StateError('Skill saved but could not be read.');
      }
      return saved;
    } catch (_) {
      if (backup != null &&
          await backup.exists() &&
          !await targetDir.exists()) {
        await backup.rename(targetDir.path);
      }
      rethrow;
    } finally {
      if (await staging.exists()) {
        await staging.delete(recursive: true);
      }
      if (backup != null && await backup.exists() && await targetDir.exists()) {
        await backup.delete(recursive: true);
      }
    }
  }

  Future<SkillMetadata> importSkillFromGitHub(String repoUrl) async {
    final _GitHubRepoInfo info = _parseGitHubUrl(repoUrl);
    final List<_GitHubFileEntry> entries = <_GitHubFileEntry>[];
    await _listGitHubFiles(
      info: info,
      currentPath: info.path,
      basePath: info.path,
      out: entries,
      depth: 0,
    );
    final _GitHubFileEntry skillEntry = entries.firstWhere(
      (entry) => entry.relativePath == 'SKILL.md',
      orElse: () =>
          throw const FormatException('GitHub path must contain SKILL.md.'),
    );
    final String skillContent = await _downloadText(skillEntry.downloadUrl);
    final Map<String, String> frontmatter = SkillFrontmatterParser.parse(
      skillContent,
    );
    final String name = (frontmatter['name'] ?? '').trim();
    if (name.isEmpty) {
      throw const FormatException('SKILL.md must include a name field.');
    }
    int totalBytes = utf8.encode(skillContent).length;
    final Map<String, String> files = <String, String>{};
    for (final entry in entries) {
      final String content = entry.relativePath == 'SKILL.md'
          ? skillContent
          : await _downloadText(entry.downloadUrl);
      final int size = utf8.encode(content).length;
      if (size > _maxSkillFileBytes) {
        throw FormatException('Skill file is too large: ${entry.relativePath}');
      }
      totalBytes += entry.relativePath == 'SKILL.md' ? 0 : size;
      if (totalBytes > _maxSkillTotalBytes) {
        throw const FormatException('Skill import is too large.');
      }
      files[entry.relativePath] = content;
    }
    return saveSkillFiles(name, files);
  }

  Future<bool> deleteSkill(String name) async {
    final Directory? dir = await resolveSkillDir(name, mustExist: true);
    if (dir == null) return false;
    await dir.delete(recursive: true);
    final Directory root = await skillsRoot();
    final Set<String> disabled = await _readDisabledSkillNames(root);
    if (disabled.remove(name)) {
      await _writeDisabledSkillNames(root, disabled);
    }
    return true;
  }

  Future<SkillMetadata> saveSkillFile(
    String name,
    String relativePath,
    String content,
  ) async {
    final String pathValue = relativePath.trim();
    if (pathValue.isEmpty) {
      throw ArgumentError('Invalid skill file path.');
    }
    _ensureSafeSkillFileContent(pathValue, content);
    final File? file = await resolveSkillFile(
      name,
      pathValue,
      mustExist: false,
    );
    if (file == null) {
      throw ArgumentError('Invalid skill file path.');
    }
    if (pathValue == 'SKILL.md') {
      final Map<String, String> frontmatter = SkillFrontmatterParser.parse(
        content,
      );
      if ((frontmatter['name'] ?? '').trim() != name) {
        throw const FormatException('SKILL.md name cannot be changed.');
      }
      if ((frontmatter['description'] ?? '').trim().isEmpty) {
        throw const FormatException(
          'SKILL.md must include a description field.',
        );
      }
    }
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
    final SkillMetadata? metadata = await getSkill(name);
    if (metadata == null) {
      throw StateError('Skill saved but could not be read.');
    }
    return metadata;
  }

  Future<bool> deleteSkillFile(String name, String relativePath) async {
    final String pathValue = relativePath.trim();
    if (pathValue == 'SKILL.md') {
      throw ArgumentError('SKILL.md cannot be deleted.');
    }
    final File? file = await resolveSkillFile(name, pathValue);
    if (file == null || !await file.exists()) return false;
    await file.delete();
    return true;
  }

  Future<File?> resolveSkillFile(
    String name,
    String relativePath, {
    bool mustExist = true,
  }) async {
    final Directory? dir = await resolveSkillDir(name, mustExist: true);
    if (dir == null) return null;
    return _resolveFileInside(dir, relativePath, mustExist: mustExist);
  }

  Future<Directory?> resolveSkillDir(
    String name, {
    bool mustExist = false,
  }) async {
    final String value = name.trim();
    if (!_isValidSkillName(value)) return null;
    final Directory root = await skillsRoot();
    final Directory dir = Directory(p.join(root.path, value));
    if (!_isSameOrInside(root, dir)) return null;
    if (mustExist && !await dir.exists()) return null;
    return dir;
  }

  Future<SkillMetadata?> _parseSkillFile(
    File skillFile,
    Directory skillDir,
  ) async {
    try {
      final String content = await skillFile.readAsString();
      final Map<String, String> frontmatter = SkillFrontmatterParser.parse(
        content,
      );
      final String name = (frontmatter['name'] ?? '').trim();
      final String description = (frontmatter['description'] ?? '').trim();
      if (name.isEmpty || description.isEmpty) return null;
      return SkillMetadata(
        name: name,
        description: description,
        compatibility: frontmatter['compatibility'],
        allowedTools: (frontmatter['allowed-tools'] ?? '')
            .split(RegExp(r'\s+'))
            .where((value) => value.trim().isNotEmpty)
            .toList(growable: false),
        directoryPath: skillDir.path,
      );
    } catch (_) {
      return null;
    }
  }

  Future<Directory> _createTempSkillDir(
    Directory root,
    String skillName,
    String suffix,
  ) async {
    for (int i = 0; i < 100; i += 1) {
      final Directory candidate = Directory(
        p.join(root.path, '.$skillName.$suffix.$i.tmp'),
      );
      if (!await candidate.exists()) {
        await candidate.create(recursive: true);
        return candidate;
      }
    }
    throw StateError('Unable to create temporary skill directory.');
  }

  Future<File?> _resolveFileInside(
    Directory root,
    String relativePath, {
    bool mustExist = true,
  }) async {
    final String value = relativePath.trim();
    if (value.isEmpty || p.isAbsolute(value)) return null;
    if (!_isSafeSkillRelativePath(value)) return null;
    final File file = File(p.join(root.path, value));
    if (!_isSameOrInside(root, file)) return null;
    final Directory parent = file.parent;
    if (await parent.exists() && !await _isRealSameOrInside(root, parent)) {
      return null;
    }
    if (await file.exists() && !await _isRealSameOrInside(root, file)) {
      return null;
    }
    if (mustExist && !await file.exists()) return null;
    return file;
  }

  void _ensureSafeSkillFileContent(String relativePath, String content) {
    if (!_isSafeSkillRelativePath(relativePath)) {
      throw ArgumentError('Invalid skill file path: $relativePath');
    }
    final int size = utf8.encode(content).length;
    if (size > _maxSkillFileBytes) {
      throw FormatException('Skill file is too large: $relativePath');
    }
  }

  bool _isSafeSkillRelativePath(String relativePath) {
    final String normalized = relativePath.trim().replaceAll(r'\', '/');
    if (normalized.isEmpty || normalized.startsWith('/')) return false;
    final List<String> segments = normalized
        .split('/')
        .where((String segment) => segment.isNotEmpty)
        .toList(growable: false);
    if (segments.isEmpty) return false;
    for (final String segment in segments) {
      if (segment == '.' || segment == '..') return false;
      if (segment.startsWith('.')) return false;
    }
    final String fileName = segments.last.toLowerCase();
    if (_blockedFileNames.contains(fileName)) return false;
    final String extension = p.extension(fileName).toLowerCase();
    return _allowedTextExtensions.contains(extension);
  }

  bool _isValidSkillName(String name) {
    if (name.isEmpty || name == '.' || name == '..') return false;
    if (name.contains('/') || name.contains(r'\')) return false;
    return RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$').hasMatch(name);
  }

  bool _isSameOrInside(Directory root, FileSystemEntity entity) {
    final String rootPath = p.canonicalize(root.absolute.path);
    final String entityPath = p.canonicalize(entity.absolute.path);
    return entityPath == rootPath || p.isWithin(rootPath, entityPath);
  }

  Future<bool> _isRealSameOrInside(
    Directory root,
    FileSystemEntity entity,
  ) async {
    try {
      final String rootPath = await root.resolveSymbolicLinks();
      final String entityPath = await entity.resolveSymbolicLinks();
      return entityPath == rootPath || p.isWithin(rootPath, entityPath);
    } catch (_) {
      return false;
    }
  }

  _GitHubRepoInfo _parseGitHubUrl(String url) {
    final Uri? uri = Uri.tryParse(url.trim());
    if (uri == null || uri.scheme != 'https' || uri.host != 'github.com') {
      throw const FormatException('Invalid GitHub repository URL.');
    }
    final List<String> segments = uri.pathSegments
        .where((segment) => segment.trim().isNotEmpty)
        .toList(growable: false);
    if (segments.length < 2) {
      throw const FormatException('Invalid GitHub repository URL.');
    }
    final String owner = segments[0];
    final String repo = segments[1];
    String branch = 'HEAD';
    String path = '';
    if (segments.length >= 4 && segments[2] == 'tree') {
      branch = segments[3];
      if (segments.length > 4) {
        path = segments.sublist(4).join('/');
      }
    }
    return _GitHubRepoInfo(
      owner: owner,
      repo: repo,
      branch: branch,
      path: path,
    );
  }

  Future<void> _listGitHubFiles({
    required _GitHubRepoInfo info,
    required String currentPath,
    required String basePath,
    required List<_GitHubFileEntry> out,
    required int depth,
  }) async {
    if (depth > _maxGitHubDepth) {
      throw const FormatException('GitHub skill directory is too deep.');
    }
    final Uri uri = Uri.https(
      'api.github.com',
      '/repos/${info.owner}/${info.repo}/contents/$currentPath',
      <String, String>{'ref': info.branch},
    );
    final String jsonText = await _downloadText(uri.toString());
    final dynamic decoded = jsonDecode(jsonText);
    final List<dynamic> items = decoded is List ? decoded : <dynamic>[decoded];
    for (final item in items) {
      if (item is! Map) continue;
      final String type = (item['type'] ?? '').toString();
      final String path = (item['path'] ?? '').toString();
      final String relativePath = _relativeGitHubPath(path, basePath);
      if (type == 'file') {
        if (!_isSafeSkillRelativePath(relativePath)) {
          throw FormatException('Unsupported skill file path: $relativePath');
        }
        final String downloadUrl = (item['download_url'] ?? '').toString();
        if (downloadUrl.isEmpty) {
          throw FormatException('Missing download URL for $relativePath.');
        }
        out.add(_GitHubFileEntry(relativePath, downloadUrl));
        if (out.length > _maxGitHubFiles) {
          throw const FormatException(
            'GitHub skill directory has too many files.',
          );
        }
      } else if (type == 'dir') {
        await _listGitHubFiles(
          info: info,
          currentPath: path,
          basePath: basePath,
          out: out,
          depth: depth + 1,
        );
      }
    }
  }

  String _relativeGitHubPath(String path, String basePath) {
    final String normalizedBase = basePath.trim().replaceAll(r'\', '/');
    final String normalizedPath = path.trim().replaceAll(r'\', '/');
    if (normalizedBase.isEmpty) return normalizedPath;
    return normalizedPath
        .replaceFirst(RegExp('^${RegExp.escape(normalizedBase)}/?'), '')
        .trim();
  }

  Future<String> _downloadText(String url) async {
    final http.Client client = _httpClientForTesting ?? http.Client();
    try {
      final response = await client
          .get(
            Uri.parse(url),
            headers: const <String, String>{
              'Accept': 'application/vnd.github+json, text/plain',
              'User-Agent': 'ScreenMemo Skill Importer',
            },
          )
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}: ${response.body}');
      }
      return response.body;
    } finally {
      if (_httpClientForTesting == null) client.close();
    }
  }

  Future<Set<String>> _readDisabledSkillNames(Directory root) async {
    final File stateFile = File(p.join(root.path, _stateFileName));
    if (!await stateFile.exists()) return <String>{};
    try {
      final dynamic decoded = jsonDecode(await stateFile.readAsString());
      final dynamic rawDisabled = decoded is Map ? decoded['disabled'] : null;
      if (rawDisabled is! List) return <String>{};
      return rawDisabled
          .map((dynamic value) => value.toString().trim())
          .where(_isValidSkillName)
          .toSet();
    } catch (_) {
      return <String>{};
    }
  }

  Future<void> _writeDisabledSkillNames(
    Directory root,
    Set<String> disabled,
  ) async {
    final File stateFile = File(p.join(root.path, _stateFileName));
    final File tempFile = File('${stateFile.path}.tmp');
    final List<String> normalized =
        disabled.where(_isValidSkillName).toSet().toList(growable: false)
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    await tempFile.writeAsString(
      jsonEncode(<String, Object>{'disabled': normalized}),
    );
    if (await stateFile.exists()) {
      await stateFile.delete();
    }
    await tempFile.rename(stateFile.path);
  }
}

class SkillMetadata {
  const SkillMetadata({
    required this.name,
    required this.description,
    required this.directoryPath,
    this.compatibility,
    this.allowedTools = const <String>[],
    this.enabled = true,
  });

  final String name;
  final String description;
  final String directoryPath;
  final String? compatibility;
  final List<String> allowedTools;
  final bool enabled;

  SkillMetadata copyWith({
    String? name,
    String? description,
    String? directoryPath,
    String? compatibility,
    List<String>? allowedTools,
    bool? enabled,
  }) {
    return SkillMetadata(
      name: name ?? this.name,
      description: description ?? this.description,
      directoryPath: directoryPath ?? this.directoryPath,
      compatibility: compatibility ?? this.compatibility,
      allowedTools: allowedTools ?? this.allowedTools,
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'name': name,
      'description': description,
      'directory_path': directoryPath,
      'compatibility': compatibility,
      'allowed_tools': allowedTools,
      'enabled': enabled,
    };
  }
}

class SkillFileMetadata {
  const SkillFileMetadata({
    required this.relativePath,
    required this.sizeBytes,
    required this.modifiedMillis,
  });

  final String relativePath;
  final int sizeBytes;
  final int modifiedMillis;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'relative_path': relativePath,
      'size_bytes': sizeBytes,
      'modified_millis': modifiedMillis,
    };
  }
}

class SkillFrontmatterParser {
  static final RegExp _frontmatterEndRegex = RegExp(r'\r?\n---(?:\r?\n|$)');

  static Map<String, String> parse(String content) {
    final Map<String, String> out = <String, String>{};
    if (!content.startsWith('---')) return out;
    final Match? match = _frontmatterEndRegex.firstMatch(content.substring(3));
    if (match == null) return out;
    final int end = 3 + match.start;
    final String yaml = content.substring(3, end).trim();
    for (final String line in const LineSplitter().convert(yaml)) {
      final int index = line.indexOf(':');
      if (index <= 0) continue;
      final String key = line.substring(0, index).trim();
      final String value = line
          .substring(index + 1)
          .trim()
          .replaceAll(RegExp("^['\"]|['\"]\$"), '');
      if (key.isNotEmpty && value.isNotEmpty) out[key] = value;
    }
    return out;
  }

  static String extractBody(String content) {
    if (!content.startsWith('---')) return content;
    final Match? match = _frontmatterEndRegex.firstMatch(content.substring(3));
    if (match == null) return content;
    final int end = 3 + match.end;
    return content.substring(end).trimLeft();
  }
}

class _GitHubRepoInfo {
  const _GitHubRepoInfo({
    required this.owner,
    required this.repo,
    required this.branch,
    required this.path,
  });

  final String owner;
  final String repo;
  final String branch;
  final String path;
}

class _GitHubFileEntry {
  const _GitHubFileEntry(this.relativePath, this.downloadUrl);

  final String relativePath;
  final String downloadUrl;
}

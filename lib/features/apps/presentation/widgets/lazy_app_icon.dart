import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:screen_memo/features/apps/application/app_icon_service.dart';

class LazyAppIcon extends StatefulWidget {
  const LazyAppIcon({
    super.key,
    required this.packageName,
    this.initialIcon,
    required this.size,
    required this.fallback,
    this.fit = BoxFit.contain,
  });

  final String packageName;
  final Uint8List? initialIcon;
  final double size;
  final Widget fallback;
  final BoxFit fit;

  @override
  State<LazyAppIcon> createState() => _LazyAppIconState();
}

class _LazyAppIconState extends State<LazyAppIcon> {
  Uint8List? _bytes;
  Object? _loadToken;

  @override
  void initState() {
    super.initState();
    _bytes =
        _validBytes(widget.initialIcon) ??
        AppIconService.instance.getCached(widget.packageName, sizePx: _sizePx);
    if (_bytes == null) {
      _load();
    }
  }

  @override
  void didUpdateWidget(covariant LazyAppIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.packageName == widget.packageName &&
        oldWidget.size == widget.size &&
        identical(oldWidget.initialIcon, widget.initialIcon)) {
      return;
    }

    _bytes =
        _validBytes(widget.initialIcon) ??
        AppIconService.instance.getCached(widget.packageName, sizePx: _sizePx);
    if (_bytes == null) {
      _load();
    } else {
      _loadToken = null;
    }
  }

  int get _sizePx => (widget.size * 2).round().clamp(32, 192);

  void _load() {
    final packageName = widget.packageName.trim();
    if (packageName.isEmpty) return;

    final token = Object();
    _loadToken = token;
    AppIconService.instance.loadIcon(packageName, sizePx: _sizePx).then((
      bytes,
    ) {
      if (!mounted || !identical(_loadToken, token)) return;
      if (bytes == null || bytes.isEmpty) return;
      setState(() {
        _bytes = bytes;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: bytes != null && bytes.isNotEmpty
          ? Image.memory(
              bytes,
              width: widget.size,
              height: widget.size,
              fit: widget.fit,
              gaplessPlayback: true,
            )
          : widget.fallback,
    );
  }

  Uint8List? _validBytes(Uint8List? bytes) {
    if (bytes == null || bytes.isEmpty) return null;
    return bytes;
  }
}

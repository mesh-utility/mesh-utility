import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';

/// How long map work must stay busy before [MapLoadingPill] appears.
const Duration mapLoadingPillDelay = Duration(milliseconds: 300);

/// Small "Loading map…" chip. Shown only after [busy] stays true for
/// [mapLoadingPillDelay], and hidden on the next false. Ignores pointers
/// so it never blocks map taps or pans.
class MapLoadingPill extends StatefulWidget {
  const MapLoadingPill({super.key, required this.busy});

  /// OR-ed together. Any true value counts as busy.
  final List<ValueListenable<bool>> busy;

  @override
  State<MapLoadingPill> createState() => _MapLoadingPillState();
}

class _MapLoadingPillState extends State<MapLoadingPill> {
  Timer? _timer;
  final ValueNotifier<bool> _visible = ValueNotifier(false);
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    for (final source in widget.busy) {
      source.addListener(_sync);
    }
    _sync();
  }

  @override
  void didUpdateWidget(covariant MapLoadingPill oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_sameSources(oldWidget.busy, widget.busy)) return;
    for (final source in oldWidget.busy) {
      source.removeListener(_sync);
    }
    for (final source in widget.busy) {
      source.addListener(_sync);
    }
    _sync();
  }

  bool _sameSources(
    List<ValueListenable<bool>> a,
    List<ValueListenable<bool>> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return false;
    }
    return true;
  }

  void _sync() {
    final busy = widget.busy.any((source) => source.value);
    if (busy == _busy) return;
    _busy = busy;
    if (busy) {
      if (_visible.value || _timer != null) return;
      _timer = Timer(mapLoadingPillDelay, () {
        _timer = null;
        if (!mounted || !_busy) return;
        _visible.value = true;
      });
      return;
    }
    _timer?.cancel();
    _timer = null;
    _visible.value = false;
  }

  @override
  void dispose() {
    _timer?.cancel();
    for (final source in widget.busy) {
      source.removeListener(_sync);
    }
    _visible.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: _visible,
      builder: (context, visible, _) {
        if (!visible) return const SizedBox.shrink();
        return const Align(
          alignment: Alignment.topCenter,
          child: IgnorePointer(child: _MapLoadingChip()),
        );
      },
    );
  }
}

class _MapLoadingChip extends StatelessWidget {
  const _MapLoadingChip();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xB81C1C1E),
        borderRadius: BorderRadius.circular(20),
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            ),
            SizedBox(width: 8),
            Text(
              'Loading map…',
              style: TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

import 'dart:convert';

import 'package:mesh_utility/src/models/coverage_zone.dart';

/// Inclusive slider / custom-range limits for the coverage-map SNR filter.
const double kSnrFilterMinDb = -20;
const double kSnrFilterMaxDb = 15;

/// Preset bands match [signalLevelForValues] SNR tiers in `signal_class.dart`:
/// Strong = avgSnr > 0 (Good/Excellent), OK = -7 < avgSnr <= 0 (Fair),
/// Weak = avgSnr <= -7 (Marginal/Poor).
enum SnrFilterPreset { all, weak, ok, strong, custom }

class SnrFilter {
  const SnrFilter({required this.preset, this.min, this.max});

  static const all = SnrFilter(preset: SnrFilterPreset.all);
  static const weak = SnrFilter(preset: SnrFilterPreset.weak);
  static const ok = SnrFilter(preset: SnrFilterPreset.ok);
  static const strong = SnrFilter(preset: SnrFilterPreset.strong);

  factory SnrFilter.custom({double? min, double? max}) {
    var lo = clampSnrFilterBound(min);
    var hi = clampSnrFilterBound(max);
    if (lo != null && hi != null && lo > hi) {
      final swap = lo;
      lo = hi;
      hi = swap;
    }
    return SnrFilter(preset: SnrFilterPreset.custom, min: lo, max: hi);
  }

  final SnrFilterPreset preset;
  final double? min;
  final double? max;

  bool get active => preset != SnrFilterPreset.all;

  /// True when [z] should stay visible. Inactive (All) keeps every zone,
  /// including dead zones. An active filter hides dead zones and null SNR.
  bool matches(CoverageZone z) {
    if (!active) return true;
    if (z.isDeadZone) return false;
    final snr = z.avgSnr;
    if (snr == null) return false;
    switch (preset) {
      case SnrFilterPreset.all:
        return true;
      case SnrFilterPreset.weak:
        return snr <= -7;
      case SnrFilterPreset.ok:
        return snr > -7 && snr <= 0;
      case SnrFilterPreset.strong:
        return snr > 0;
      case SnrFilterPreset.custom:
        if (min != null && snr < min!) return false;
        if (max != null && snr > max!) return false;
        return true;
    }
  }

  String get label {
    switch (preset) {
      case SnrFilterPreset.all:
        return 'SNR: All';
      case SnrFilterPreset.weak:
        return 'SNR: Weak';
      case SnrFilterPreset.ok:
        return 'SNR: OK';
      case SnrFilterPreset.strong:
        return 'SNR: Strong';
      case SnrFilterPreset.custom:
        final hasMin = min != null;
        final hasMax = max != null;
        if (hasMin && hasMax) {
          return 'SNR: ${_formatBound(min!)} to ${_formatBound(max!)} dB';
        }
        if (hasMin) return 'SNR: ≥ ${_formatBound(min!)} dB';
        if (hasMax) return 'SNR: ≤ ${_formatBound(max!)} dB';
        return 'SNR: Custom';
    }
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'preset': preset.name,
      if (preset == SnrFilterPreset.custom) 'min': min,
      if (preset == SnrFilterPreset.custom) 'max': max,
    };
  }

  factory SnrFilter.fromJson(Map<String, dynamic> json) {
    final raw = json['preset']?.toString();
    final preset = _presetByName(raw);
    if (preset != SnrFilterPreset.custom) {
      return SnrFilter(preset: preset);
    }
    return SnrFilter.custom(
      min: (json['min'] as num?)?.toDouble(),
      max: (json['max'] as num?)?.toDouble(),
    );
  }

  /// Compact settings string: `all` / `weak` / `ok` / `strong` /
  /// `custom:<min>:<max>` (either bound may be empty). Also accepts JSON.
  String encode() {
    switch (preset) {
      case SnrFilterPreset.all:
        return 'all';
      case SnrFilterPreset.weak:
        return 'weak';
      case SnrFilterPreset.ok:
        return 'ok';
      case SnrFilterPreset.strong:
        return 'strong';
      case SnrFilterPreset.custom:
        return 'custom:${_encodeBound(min)}:${_encodeBound(max)}';
    }
  }

  static SnrFilter decode(String? raw) {
    if (raw == null) return all;
    final text = raw.trim();
    if (text.isEmpty) return all;
    switch (text.toLowerCase()) {
      case 'all':
        return all;
      case 'weak':
        return weak;
      case 'ok':
        return ok;
      case 'strong':
        return strong;
      case 'custom':
        return SnrFilter.custom();
    }
    if (text.startsWith('{')) {
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map<String, dynamic>) {
          return SnrFilter.fromJson(decoded);
        }
        if (decoded is Map) {
          return SnrFilter.fromJson(Map<String, dynamic>.from(decoded));
        }
      } catch (_) {
        return all;
      }
      return all;
    }
    final lower = text.toLowerCase();
    if (lower.startsWith('custom')) {
      final parts = text.split(':');
      double? partAt(int i) {
        if (parts.length <= i) return null;
        final piece = parts[i].trim();
        if (piece.isEmpty) return null;
        return double.tryParse(piece);
      }

      return SnrFilter.custom(min: partAt(1), max: partAt(2));
    }
    return all;
  }

  @override
  bool operator ==(Object other) {
    return other is SnrFilter &&
        other.preset == preset &&
        other.min == min &&
        other.max == max;
  }

  @override
  int get hashCode => Object.hash(preset, min, max);
}

/// Clamp a custom bound into `-20..+15`. Null and NaN stay null.
double? clampSnrFilterBound(double? value) {
  if (value == null || value.isNaN) return null;
  if (value < kSnrFilterMinDb) return kSnrFilterMinDb;
  if (value > kSnrFilterMaxDb) return kSnrFilterMaxDb;
  return value;
}

/// One O(n) pass. Inactive filters return [zones] unchanged (same instance).
List<CoverageZone> applySnrFilter(SnrFilter filter, List<CoverageZone> zones) {
  if (!filter.active) return zones;
  return zones.where(filter.matches).toList(growable: false);
}

SnrFilterPreset _presetByName(String? raw) {
  switch ((raw ?? '').trim().toLowerCase()) {
    case 'weak':
      return SnrFilterPreset.weak;
    case 'ok':
      return SnrFilterPreset.ok;
    case 'strong':
      return SnrFilterPreset.strong;
    case 'custom':
      return SnrFilterPreset.custom;
    default:
      return SnrFilterPreset.all;
  }
}

String _formatBound(double value) {
  if (value == value.roundToDouble()) return value.toInt().toString();
  return value.toString();
}

String _encodeBound(double? value) {
  if (value == null) return '';
  return _formatBound(value);
}

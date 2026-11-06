import 'package:flutter/material.dart';

class SignalClass {
  const SignalClass(this.label, this.color, this.level);

  final String label;
  final Color color;
  final int level;
}

/// Purple used by the map legend for Noisy (good RSSI, bad SNR).
const Color kNoisySignalColor = Color(0xFFA855F7);

/// Combined RSSI/SNR quality level.
///
/// Returns `0` only when there is **no response at all** (both [rssi] and
/// [snr] are null). Any hearing of a repeater floors at `1` (Poor) — weak
/// readings must never be classified as a dead zone.
int signalLevelForValues({
  required double? rssi,
  required double? snr,
  int nullRssiLevel = 3,
  int nullSnrLevel = 3,
}) {
  if (rssi == null && snr == null) return 0;

  int rssiLevel() {
    if (rssi == null) return nullRssiLevel;
    if (rssi > -90) return 5;
    if (rssi > -100) return 4;
    if (rssi > -110) return 3;
    if (rssi > -115) return 2;
    // Response heard, even if very weak (e.g. -123 dBm).
    return 1;
  }

  int snrLevel() {
    if (snr == null) return nullSnrLevel;
    if (snr > 10) return 5;
    if (snr > 0) return 4;
    if (snr > -7) return 3;
    if (snr > -13) return 2;
    // Response heard with very poor SNR — still not a dead zone.
    return 1;
  }

  final rssiScore = rssiLevel();
  final snrScore = snrLevel();
  return rssiScore < snrScore ? rssiScore : snrScore;
}

/// True when power looks usable but clarity is bad (legend: Noisy).
bool isNoisySignal({required double? rssi, required double? snr}) {
  if (rssi == null || snr == null) return false;
  // "Good signal, bad SNR": RSSI in the Good-or-better band, SNR at/below
  // the Marginal floor.
  return rssi > -100 && snr <= -13;
}

SignalClass signalClassForValues({
  required double? rssi,
  required double? snr,
  bool includeDeadZone = true,
}) {
  if (rssi == null && snr == null) {
    if (!includeDeadZone) {
      return const SignalClass('Poor', Color(0xFFEF4444), 1);
    }
    return const SignalClass('Dead Zone', Color(0xFF991B1B), 0);
  }

  if (isNoisySignal(rssi: rssi, snr: snr)) {
    return const SignalClass('Noisy', kNoisySignalColor, 1);
  }

  var level = signalLevelForValues(rssi: rssi, snr: snr);
  // Belt-and-suspenders: never emit Dead Zone when any metric is present.
  if (level < 1) level = 1;
  if (!includeDeadZone && level < 1) {
    level = 1;
  }
  switch (level) {
    case 5:
      return const SignalClass('Excellent', Color(0xFF22C55E), 5);
    case 4:
      return const SignalClass('Good', Color(0xFF4ADE80), 4);
    case 3:
      return const SignalClass('Fair', Color(0xFFFACC15), 3);
    case 2:
      return const SignalClass('Marginal', Color(0xFFF97316), 2);
    case 1:
    default:
      return const SignalClass('Poor', Color(0xFFEF4444), 1);
  }
}

Color signalColorForValues({
  required double? rssi,
  required double? snr,
  bool includeDeadZone = true,
}) => signalClassForValues(
  rssi: rssi,
  snr: snr,
  includeDeadZone: includeDeadZone,
).color;

/// Recompute [isDeadZone] from metrics so stored/API rows that had a real
/// response are never treated as dead on read.
bool deadZoneFromMetrics({
  required double? avgRssi,
  required double? avgSnr,
  bool? storedFlag,
}) {
  final heardResponse = avgRssi != null || avgSnr != null;
  if (heardResponse) return false;
  // No metrics: trust a stored true flag, otherwise treat as dead when both
  // averages are missing (no response aggregated).
  if (storedFlag != null) return storedFlag;
  return true;
}

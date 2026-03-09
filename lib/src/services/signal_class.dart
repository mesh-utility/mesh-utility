import 'package:flutter/material.dart';

class SignalClass {
  const SignalClass(this.label, this.color, this.level);

  final String label;
  final Color color;
  final int level;
}

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
    if (rssi > -120) return 1;
    return 0;
  }

  int snrLevel() {
    if (snr == null) return nullSnrLevel;
    if (snr > 10) return 5;
    if (snr > 0) return 4;
    if (snr > -7) return 3;
    if (snr > -13) return 2;
    return 0;
  }

  final rssiScore = rssiLevel();
  final snrScore = snrLevel();
  return rssiScore < snrScore ? rssiScore : snrScore;
}

SignalClass signalClassForValues({
  required double? rssi,
  required double? snr,
  bool includeDeadZone = true,
}) {
  var level = signalLevelForValues(rssi: rssi, snr: snr);
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
      return const SignalClass('Poor', Color(0xFFEF4444), 1);
    default:
      return const SignalClass('Dead Zone', Color(0xFF991B1B), 0);
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

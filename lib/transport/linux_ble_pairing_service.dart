import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mesh_utility/transport/linux_ble_pairing_service_base.dart';

class LinuxBlePairingService implements LinuxBlePairingServiceBase {
  @override
  Future<bool> isPairedAndTrusted(String remoteId) async {
    final result = await Process.run('bluetoothctl', <String>['info', remoteId]);
    if (result.exitCode != 0) {
      return false;
    }
    final output = (result.stdout as String).toLowerCase();
    return output.contains('paired: yes') && output.contains('trusted: yes');
  }

  @override
  Future<void> removeDevice(
    String remoteId, {
    void Function(String message)? onLog,
  }) async {
    await _removeDevice(remoteId, onLog: onLog);
  }

  @override
  Future<bool> pairAndTrust({
    required String remoteId,
    Duration timeout = const Duration(seconds: 45),
    void Function(String message)? onLog,
    Future<String?> Function()? onRequestPin,
    bool proactivePinRetryUsed = false,
    bool removeRetryUsed = false,
  }) async {
    onLog?.call('Starting bluetoothctl pairing flow for $remoteId');
    final process = await Process.start('bluetoothctl', <String>[]);
    final output = StringBuffer();
    var pinSent = false;
    var pairSucceeded = false;
    var pairFailed = false;

    void writeCmd(String cmd) {
      process.stdin.writeln(cmd);
    }

    void handleChunk(String chunk) {
      output.write(chunk);
      final lower = chunk.toLowerCase();

      if (!pinSent &&
          (lower.contains('enter pin code') ||
              lower.contains('requestpin') ||
              lower.contains('input pin code') ||
              lower.contains('request passkey') ||
              lower.contains('requestpasskey') ||
              lower.contains('enter passkey'))) {
        pinSent = true;
        onLog?.call('Pairing agent is ready for PIN/passkey input');
        unawaited(
          Future<void>(() async {
            final pin = await onRequestPin?.call();
            if (pin == null || pin.trim().isEmpty) {
              onLog?.call('No PIN/passkey provided; cancelling pairing');
              pairFailed = true;
              writeCmd('cancel');
              return;
            }
            onLog?.call('Submitting PIN/passkey to pairing agent');
            writeCmd(pin.trim());
          }),
        );
      }

      if (lower.contains('confirm passkey') ||
          lower.contains('requestconfirmation') ||
          lower.contains('[agent] confirm')) {
        onLog?.call('Pairing agent requested passkey confirmation; answering yes');
        writeCmd('yes');
      }

      if (lower.contains('pairing successful') || lower.contains('already paired')) {
        onLog?.call('Pairing reported success');
        pairSucceeded = true;
      }

      if (lower.contains('failed to pair') ||
          lower.contains('authenticationfailed') ||
          lower.contains('authentication failed')) {
        onLog?.call('Pairing reported authentication failure');
        pairFailed = true;
      }
    }

    final stdoutSub = process.stdout.transform(utf8.decoder).listen(handleChunk);
    final stderrSub = process.stderr.transform(utf8.decoder).listen(handleChunk);

    writeCmd('power on');
    writeCmd('agent KeyboardDisplay');
    writeCmd('default-agent');
    onLog?.call('Waiting for pairing challenge from bluetoothctl agent');
    writeCmd('pair $remoteId');

    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline) && !pairSucceeded && !pairFailed) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }

    if (!pairFailed && pairSucceeded) {
      onLog?.call('Pair succeeded; trusting and connecting device');
      writeCmd('trust $remoteId');
      writeCmd('connect $remoteId');
    }
    writeCmd('quit');

    try {
      await process.exitCode.timeout(const Duration(seconds: 5));
    } catch (_) {
      process.kill();
    }
    await stdoutSub.cancel();
    await stderrSub.cancel();

    if (pairFailed) {
      if (!removeRetryUsed) {
        onLog?.call('Pairing failed before completion; removing cached bond and retrying once');
        await _removeDevice(remoteId, onLog: onLog);
        return pairAndTrust(
          remoteId: remoteId,
          timeout: timeout,
          onLog: onLog,
          onRequestPin: onRequestPin,
          proactivePinRetryUsed: proactivePinRetryUsed,
          removeRetryUsed: true,
        );
      }
      if (!pinSent && !proactivePinRetryUsed && onRequestPin != null) {
        onLog?.call('Pairing failed before PIN challenge; requesting PIN for proactive retry');
        final pin = await onRequestPin();
        if (pin == null || pin.trim().isEmpty) {
          onLog?.call('No PIN provided for proactive retry');
          return false;
        }
        return pairAndTrust(
          remoteId: remoteId,
          timeout: timeout,
          onLog: onLog,
          onRequestPin: () async => pin.trim(),
          proactivePinRetryUsed: true,
          removeRetryUsed: removeRetryUsed,
        );
      }
      return false;
    }

    if (pairSucceeded) {
      return true;
    }

    onLog?.call('Pairing did not complete before timeout');
    if (!pinSent && !proactivePinRetryUsed && onRequestPin != null) {
      onLog?.call('No PIN challenge observed before timeout; requesting PIN for proactive retry');
      final pin = await onRequestPin();
      if (pin == null || pin.trim().isEmpty) {
        onLog?.call('No PIN provided for proactive retry after timeout');
        return false;
      }
      return pairAndTrust(
        remoteId: remoteId,
        timeout: timeout,
        onLog: onLog,
        onRequestPin: () async => pin.trim(),
        proactivePinRetryUsed: true,
        removeRetryUsed: removeRetryUsed,
      );
    }

    final allOutput = output.toString().toLowerCase();
    return allOutput.contains('pairing successful') || allOutput.contains('already paired');
  }

  Future<void> _removeDevice(
    String remoteId, {
    void Function(String message)? onLog,
  }) async {
    final process = await Process.start('bluetoothctl', <String>[]);
    process.stdin.writeln('remove $remoteId');
    process.stdin.writeln('quit');
    try {
      await process.exitCode.timeout(const Duration(seconds: 6));
    } catch (_) {
      process.kill();
    }
    onLog?.call('Issued bluetoothctl remove for $remoteId');
  }
}

LinuxBlePairingServiceBase createLinuxBlePairingService() {
  return LinuxBlePairingService();
}

import 'dart:math';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';

/// Plays short alert tones. The tones are generated in code, so the app needs
/// no sound files.
class Alerts {
  Alerts._();

  static final _player = AudioPlayer();
  static final _newOrder = _tone([880, 0, 880, 0, 1175], 0.13);
  static final _ready = _tone([1046, 1318, 1568], 0.18);

  /// Kitchen: a new ticket arrived.
  static Future<void> newOrder() => _play(_newOrder);

  /// Waiter: an order is ready to pick up.
  static Future<void> ready() => _play(_ready);

  static Future<void> _play(Uint8List wav) async {
    HapticFeedback.heavyImpact();
    try {
      await _player.stop();
      await _player.play(BytesSource(wav, mimeType: 'audio/wav'), volume: 1);
    } catch (_) {
      SystemSound.play(SystemSoundType.alert);
    }
  }

  /// Builds a 16-bit mono WAV of consecutive notes (0 = silence).
  static Uint8List _tone(List<double> freqs, double noteSeconds) {
    const rate = 22050;
    final perNote = (rate * noteSeconds).round();
    final samples = Int16List(perNote * freqs.length);
    for (var n = 0; n < freqs.length; n++) {
      final f = freqs[n];
      if (f == 0) continue;
      for (var i = 0; i < perNote; i++) {
        final t = i / rate;
        final fade = min(1.0, min(i / 200, (perNote - i) / 600));
        samples[n * perNote + i] = (sin(2 * pi * f * t) * 0.6 * fade * 32767).round();
      }
    }
    final data = samples.buffer.asUint8List();
    final header = ByteData(44)
      ..setUint32(0, 0x52494646) // RIFF
      ..setUint32(4, 36 + data.length, Endian.little)
      ..setUint32(8, 0x57415645) // WAVE
      ..setUint32(12, 0x666d7420) // fmt
      ..setUint32(16, 16, Endian.little)
      ..setUint16(20, 1, Endian.little)
      ..setUint16(22, 1, Endian.little)
      ..setUint32(24, rate, Endian.little)
      ..setUint32(28, rate * 2, Endian.little)
      ..setUint16(32, 2, Endian.little)
      ..setUint16(34, 16, Endian.little)
      ..setUint32(36, 0x64617461) // data
      ..setUint32(40, data.length, Endian.little);
    return Uint8List.fromList([...header.buffer.asUint8List(), ...data]);
  }
}

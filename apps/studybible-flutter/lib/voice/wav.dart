/// Кодировка PCM float32 [-1..1] в WAV (16-бит, моно) — для
/// воспроизведения синтеза нейробэкенда через audioplayers.
library;

import 'dart:typed_data';

/// Один WAV-файл целиком в памяти: 44-байтный заголовок RIFF +
/// данные PCM16. Стих — секунды звука, память копеечная.
Uint8List wavFromPcm(Float32List samples, int sampleRate) {
  final n = samples.length;
  final dataLen = n * 2;
  final out = ByteData(44 + dataLen);
  void str(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      out.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  str(0, 'RIFF');
  out.setUint32(4, 36 + dataLen, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  out.setUint32(16, 16, Endian.little); // PCM-чанк
  out.setUint16(20, 1, Endian.little); // PCM
  out.setUint16(22, 1, Endian.little); // моно
  out.setUint32(24, sampleRate, Endian.little);
  out.setUint32(28, sampleRate * 2, Endian.little); // байт/с
  out.setUint16(32, 2, Endian.little); // выравнивание блока
  out.setUint16(34, 16, Endian.little); // бит/сэмпл
  str(36, 'data');
  out.setUint32(40, dataLen, Endian.little);
  for (var i = 0; i < n; i++) {
    final s = samples[i].clamp(-1.0, 1.0);
    out.setInt16(44 + i * 2, (s * 32767).round(), Endian.little);
  }
  return out.buffer.asUint8List();
}

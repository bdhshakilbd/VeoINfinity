import 'dart:io';
import 'dart:typed_data';

/// specific utilities for handling Lyria audio output.
class LyriaAudioUtils {
  
  /// Fixes the WAV header of a file after recording is complete.
  /// 
  /// [file] is the generic file handle.
  /// [dataSize] is the total number of bytes of PCM data written after the 44-byte header.
  /// [sampleRate] defaults to 48000 (Lyria standard).
  static Future<void> fixWavHeader(File file, int dataSize, {int sampleRate = 48000, int channels = 2}) async {
    final raf = await file.open(mode: FileMode.append); // Opens for random access (read/write/seek)
    
    final header = ByteData(44);
    final bitsPerSample = 16;
    final byteRate = sampleRate * channels * (bitsPerSample ~/ 8);
    final blockAlign = channels * (bitsPerSample ~/ 8);

    // RIFF chunk
    _writeString(header, 0, 'RIFF');
    header.setInt32(4, 36 + dataSize, Endian.little); // File size - 8
    _writeString(header, 8, 'WAVE');

    // fmt chunk
    _writeString(header, 12, 'fmt ');
    header.setInt32(16, 16, Endian.little); // Subchunk1Size (16 for PCM)
    header.setInt16(20, 1, Endian.little); // AudioFormat (1 = PCM)
    header.setInt16(22, channels, Endian.little);
    header.setInt32(24, sampleRate, Endian.little);
    header.setInt32(28, byteRate, Endian.little);
    header.setInt16(32, blockAlign, Endian.little); // BlockAlign
    header.setInt16(34, bitsPerSample, Endian.little); 

    // data chunk
    _writeString(header, 36, 'data');
    header.setInt32(40, dataSize, Endian.little);
    
    await raf.setPosition(0);
    await raf.writeFrom(header.buffer.asUint8List());
    await raf.close();
  }

  static void _writeString(ByteData data, int offset, String value) {
    for (int i = 0; i < value.length; i++) {
        data.setUint8(offset + i, value.codeUnitAt(i));
    }
  }
}

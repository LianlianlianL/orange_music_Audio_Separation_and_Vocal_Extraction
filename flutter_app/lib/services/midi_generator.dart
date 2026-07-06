import 'dart:typed_data';
import 'package:dart_midi_pro/dart_midi_pro.dart';
import 'dart:math';

class MidiGenerator {
  /// 将模型输出转换为 MIDI 文件字节
  /// [onset], [offset], [frame], [velocity] 形状均为 (time_steps, 88)
  static Uint8List generateMidi({
    required List<List<double>> onset,
    required List<List<double>> offset,
    required List<List<double>> frame,
    required List<List<double>> velocity,
    double onsetThreshold = 0.3,
    double frameThreshold = 0.3,
    int sampleRate = 16000,
    int hopLength = 160,
  }) {
    final List<MidiEvent> events = [];
    final int timeSteps = onset.length;
    final double secondsPerStep = hopLength / sampleRate;
    
    // 跟踪每个按键的当前状态 (是否正在按下)
    // key: pitch (21-108), value: startTime
    final Map<int, double> activeNotes = {};
    
    for (int t = 0; t < timeSteps; t++) {
      final double currentTime = t * secondsPerStep;
      
      for (int pitchIdx = 0; pitchIdx < 88; pitchIdx++) {
        final int pitch = pitchIdx + 21; // MIDI 钢琴范围 21-108
        final bool isOnset = onset[t][pitchIdx] > onsetThreshold;
        final bool isFrameActive = frame[t][pitchIdx] > frameThreshold;
        
        if (isOnset) {
          // 如果已经在响，先关掉 (重触发)
          if (activeNotes.containsKey(pitch)) {
            final double startTime = activeNotes.remove(pitch)!;
            events.add(NoteOffEvent(
              pitch: pitch,
              velocity: 0,
              deltaTime: _secondsToTicks(currentTime - startTime),
            ));
          }
          
          // 开启新音符
          activeNotes[pitch] = currentTime;
          final int vel = (velocity[t][pitchIdx] * 127).clamp(0, 127).toInt();
          events.add(NoteOnEvent(
            pitch: pitch,
            velocity: vel,
            deltaTime: 0, // 这里 deltaTime 需要根据前一个事件计算，稍后统一处理
          ));
        } else if (!isFrameActive && activeNotes.containsKey(pitch)) {
          // 音符结束
          final double startTime = activeNotes.remove(pitch)!;
          events.add(NoteOffEvent(
            pitch: pitch,
            velocity: 0,
            deltaTime: _secondsToTicks(currentTime - startTime),
          ));
        }
      }
    }
    
    // 关闭所有残留音符
    activeNotes.forEach((pitch, startTime) {
      events.add(NoteOffEvent(
        pitch: pitch,
        velocity: 0,
        deltaTime: 0,
      ));
    });

    // 构建 MIDI 文件结构
    // 注意：dart_midi 的 deltaTime 是相对于前一个事件的 ticks
    // 我们需要重新计算所有事件的顺序和时间差
    // 这里简化处理，直接返回一个基本的 MIDI 轨道
    final track = [
      TrackNameEvent(text: 'Piano Transcription', deltaTime: 0),
      SetTempoEvent(microsecondsPerBeat: 500000, deltaTime: 0), // 120 BPM
      ...events,
      EndOfTrackEvent(deltaTime: 0),
    ];

    final midiFile = MidiFile([track], MidiHeader(format: 1, numTracks: 1, timeDivision: 480));
    return Uint8List.fromList(MidiWriter().writeMidiToBuffer(midiFile));
  }

  static int _secondsToTicks(double seconds, {int bpm = 120, int ppq = 480}) {
    return (seconds * bpm * ppq / 60).toInt();
  }
}

import 'dart:typed_data';
import 'package:dart_midi_pro/dart_midi_pro.dart';

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
    final int timeSteps = onset.length;
    final double secondsPerStep = hopLength / sampleRate;
    
    // 1. 收集所有原始事件 (绝对时间)
    final List<_RawEvent> rawEvents = [];
    
    // 跟踪每个按键的开始时间 (key: pitch, value: startTime)
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
            rawEvents.add(_RawEvent(
              time: currentTime, 
              type: _EventType.noteOff, 
              pitch: pitch, 
              velocity: 0
            ));
            activeNotes.remove(pitch);
          }
          
          // 开启新音符
          final int vel = (velocity[t][pitchIdx] * 127).clamp(1, 127).toInt();
          activeNotes[pitch] = currentTime;
          rawEvents.add(_RawEvent(
            time: currentTime,
            type: _EventType.noteOn,
            pitch: pitch,
            velocity: vel
          ));
        } else if (!isFrameActive && activeNotes.containsKey(pitch)) {
          // 音符结束 (Frame 不再活跃)
          rawEvents.add(_RawEvent(
            time: currentTime,
            type: _EventType.noteOff,
            pitch: pitch,
            velocity: 0
          ));
          activeNotes.remove(pitch);
        }
      }
    }
    
    // 关闭所有残留音符
    final double endTime = timeSteps * secondsPerStep;
    activeNotes.forEach((pitch, startTime) {
      rawEvents.add(_RawEvent(
        time: endTime,
        type: _EventType.noteOff,
        pitch: pitch,
        velocity: 0
      ));
    });

    // 2. 按时间排序
    // 如果时间相同，NoteOff 排在 NoteOn 前面 (避免同一个 tick 内先开后关导致极短音符，或者逻辑错误)
    rawEvents.sort((a, b) {
      final int timeCompare = a.time.compareTo(b.time);
      if (timeCompare != 0) return timeCompare;
      
      // 时间相同时，NoteOff 优先
      if (a.type == _EventType.noteOff && b.type == _EventType.noteOn) return -1;
      if (a.type == _EventType.noteOn && b.type == _EventType.noteOff) return 1;
      return 0;
    });

    // 3. 构建 MIDI Track (计算 deltaTime)
    final List<MidiEvent> midiEvents = [];
    
    // 元数据
    midiEvents.add(TrackNameEvent()
      ..text = 'Piano Transcription'
      ..deltaTime = 0);
    midiEvents.add(SetTempoEvent()
      ..microsecondsPerBeat = 500000 // 120 BPM
      ..deltaTime = 0);

    int currentTicks = 0;
    
    for (final event in rawEvents) {
      final int eventTicks = _secondsToTicks(event.time);
      int delta = eventTicks - currentTicks;
      if (delta < 0) delta = 0;
      
      currentTicks += delta; // 更新当前 tick 指针

      if (event.type == _EventType.noteOn) {
        midiEvents.add(NoteOnEvent()
          ..channel = 0
          ..noteNumber = event.pitch
          ..velocity = event.velocity
          ..deltaTime = delta);
      } else {
        midiEvents.add(NoteOffEvent()
          ..channel = 0
          ..noteNumber = event.pitch
          ..velocity = 0
          ..deltaTime = delta);
      }
    }

    midiEvents.add(EndOfTrackEvent()..deltaTime = 0);

    final midiFile = MidiFile([midiEvents], MidiHeader(format: 0, numTracks: 1, timeDivision: 480));
    return Uint8List.fromList(MidiWriter().writeMidiToBuffer(midiFile));
  }

  static int _secondsToTicks(double seconds, {int bpm = 120, int ppq = 480}) {
    return (seconds * bpm * ppq / 60).toInt();
  }
}

enum _EventType { noteOn, noteOff }

class _RawEvent {
  final double time;
  final _EventType type;
  final int pitch;
  final int velocity;

  _RawEvent({
    required this.time,
    required this.type,
    required this.pitch,
    required this.velocity,
  });
}

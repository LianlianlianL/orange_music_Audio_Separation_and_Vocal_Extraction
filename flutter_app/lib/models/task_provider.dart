import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:uuid/uuid.dart';
import 'task_model.dart';
import '../services/audio_service.dart';

class TaskProvider extends ChangeNotifier {
  final List<ProcessingTask> _tasks = [];
  final AudioService _audioService = AudioService();
  final _uuid = const Uuid();

  List<ProcessingTask> get tasks => _tasks;

  Future<void> pickAndAddFiles(ProcessingMode mode, ModelType modelType) async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp3', 'wav', 'flac', 'm4a'],
      allowMultiple: true,
    );

    if (result != null) {
      for (var file in result.files) {
        if (file.path != null) {
          final task = ProcessingTask(
            id: _uuid.v4(),
            inputPath: file.path!,
            mode: mode,
            modelType: modelType,
          );
          _tasks.add(task);
        }
      }
      notifyListeners();
    }
  }

  Future<void> startProcessing() async {
    for (var task in _tasks) {
      if (task.statusMessage == '等待中...') {
        await _processTask(task);
      }
    }
  }

  bool _isInitialized = false;

  TaskProvider() {
    _init();
  }

  Future<void> _init() async {
    await _audioService.initModels();
    _isInitialized = true;
  }

  String? _soundFontPath;
  String? get soundFontPath => _soundFontPath;

  Future<void> pickSoundFont() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['sf2'],
    );
    if (result != null && result.files.single.path != null) {
      _soundFontPath = result.files.single.path;
      notifyListeners();
    }
  }

  Future<void> _processTask(ProcessingTask task) async {
    if (!_isInitialized) {
      task.statusMessage = '正在初始化模型...';
      notifyListeners();
      await _init();
    }

    task.statusMessage = '正在准备音频...';
    task.progress = 0.1;
    notifyListeners();

    try {
      final tempDir = await _audioService.getAppTempDir();
      final outputMidiPath = '${tempDir}/${task.id}.mid';
      
      // 执行转录
      task.statusMessage = '正在转录为 MIDI...';
      task.progress = 0.3;
      notifyListeners();
      
      await _audioService.transcribeToMidi(task.inputPath, outputMidiPath);
      
      if (_soundFontPath != null) {
        task.statusMessage = '正在使用 SoundFont 渲染...';
        notifyListeners();
        await _audioService.renderMidiToAudio(outputMidiPath, _soundFontPath!);
      }
      
      task.progress = 1.0;
      task.statusMessage = '处理完成';
      notifyListeners();
    } catch (e) {
      task.statusMessage = '错误: $e';
      notifyListeners();
    }
  }

  void removeTask(String id) {
    _tasks.removeWhere((t) => t.id == id);
    notifyListeners();
  }

  void clearCompleted() {
    _tasks.removeWhere((t) => t.statusMessage == '处理完成');
    notifyListeners();
  }
}

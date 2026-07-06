import 'dart:io';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:file_picker/file_picker.dart';
import 'package:uuid/uuid.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'task_model.dart';
import '../services/audio_service.dart';

class TaskProvider extends ChangeNotifier {
  final List<ProcessingTask> _tasks = [];
  final AudioService _audioService = AudioService();
  final _uuid = const Uuid();
  
  String? _customSaveDirectory;
  String? get customSaveDirectory => _customSaveDirectory;

  void setCustomSaveDirectory(String? path) {
    _customSaveDirectory = path;
    notifyListeners();
  }

  List<ProcessingTask> get tasks => _tasks;

  Future<void> pickAndAddFiles(ProcessingMode mode, ModelType modelType) async {
    // 强制先进行一次权限请求
    if (Platform.isAndroid) {
      // Android 13+ (SDK 33) 使用细分媒体权限
      // 这里的逻辑稍微宽泛一点，确保兼容性
      Map<Permission, PermissionStatus> statuses = await [
        Permission.storage,
        Permission.audio,
      ].request();
      
      // 只要有一个权限被授予，我们就尝试打开文件选择器
      // 因为在不同 Android 版本上需要的权限不同
    }

    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['mp3', 'wav', 'flac', 'm4a'],
        allowMultiple: true,
        lockParentWindow: Platform.isWindows,
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
            
            // Calculate estimated time
            _audioService.estimateProcessingTime(file.path!).then((time) {
              task.statusMessage = '等待中... (预计 $time)';
              notifyListeners();
            });
            
            _tasks.add(task);
          }
        }
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Error picking files: $e');
      // 可以考虑添加一个错误状态通知 UI
    }
  }

  Future<void> startProcessing() async {
    // 启用屏幕常亮，防止后台杀进程
    await WakelockPlus.enable();
    
    try {
      for (var task in _tasks) {
        if (task.statusMessage.startsWith('等待中')) {
          await _processTask(task);
        }
      }
    } finally {
      await WakelockPlus.disable();
    }
  }

  bool _isInitialized = false;
  List<String> _availableModels = [];
  String? _selectedModelPath;

  List<String> get availableModels => _availableModels;
  String? get selectedModelPath => _selectedModelPath;

  void selectModel(String? path) {
    _selectedModelPath = path;
    notifyListeners();
  }

  TaskProvider() {
    _init();
  }

  Future<void> _init() async {
    await _audioService.initModels();
    _availableModels = await _audioService.getAvailableModels();
    if (_availableModels.isNotEmpty) {
      // 默认选择第一个（通常是 demucs.onnx 或者列表里的第一个）
      _selectedModelPath = _availableModels.first;
    }
    _isInitialized = true;
    notifyListeners();
  }

  String? _soundFontPath;
  String? get soundFontPath => _soundFontPath;

  Future<void> pickSoundFont() async {
    // 权限请求
    if (Platform.isAndroid) {
      if (!await Permission.storage.isGranted) await Permission.storage.request();
      if (!await Permission.manageExternalStorage.isGranted) await Permission.manageExternalStorage.request();
    }

    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['sf2'],
        lockParentWindow: Platform.isWindows,
      );
      if (result != null && result.files.single.path != null) {
        _soundFontPath = result.files.single.path;
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Error picking SoundFont: $e');
    }
  }

  void removeTask(String id) {
    _tasks.removeWhere((t) => t.id == id);
    notifyListeners();
  }

  Future<void> _processTask(ProcessingTask task) async {
    if (!_isInitialized) {
      task.statusMessage = '正在初始化模型...';
      notifyListeners();
      await _init();
    }

    if (!await File(task.inputPath).exists()) {
       task.statusMessage = '错误: 输入文件已丢失';
       task.progress = 0.0;
       notifyListeners();
       return;
    }

    task.statusMessage = '正在准备音频...';
    task.progress = 0.1;
    notifyListeners();

    try {
      final tempDir = await _audioService.getAppTempDir();
      
      if (task.mode == ProcessingMode.separate || task.mode == ProcessingMode.accompaniment) {
        // 人声分离模式
        task.statusMessage = '正在进行人声分离 (Demucs)...';
        task.progress = 0.3;
        notifyListeners();

        try {
          final stems = await _audioService.separateAudio(
            task.inputPath, 
            outputDirectory: _customSaveDirectory,
            modelPath: _selectedModelPath
          );
          task.stems = stems;
          task.statusMessage = '分离完成';
          task.progress = 1.0;
          notifyListeners();
        } catch (e) {
          task.statusMessage = '分离失败: $e';
          task.progress = 0.0;
          debugPrint(e.toString());
          // 可以在这里添加重试逻辑或更详细的错误提示
        }

      } else if (task.mode == ProcessingMode.enhancedPiano) {
        // 增强纯钢琴模式: 先分离 -> 提取伴奏 -> 转录 MIDI
        task.statusMessage = '步骤 1/3: 正在进行人声分离...';
        task.progress = 0.2;
        notifyListeners();

        try {
          // 1. 分离音频
          final stems = await _audioService.separateAudio(
            task.inputPath,
            outputDirectory: _customSaveDirectory, // 这里的中间产物也保存一份？或者仅临时？
            // 实际上增强模式的中间产物（stems）通常不需要保存到用户目录，除非用户想看
            // 但为了调试方便，或者用户可能也想要 stems，我们还是传进去吧
            // 只要 outputDirectory 不为空，它就会保存。
            modelPath: _selectedModelPath
          );
          task.stems = stems;
          
          task.statusMessage = '步骤 2/3: 正在混合伴奏...';
          task.progress = 0.5;
          notifyListeners();
          
          // 混合 drums, bass, other 成为无声源
          final accompanimentPath = '$tempDir/${task.id}_accompaniment.wav';
          final stemsToMix = [
             stems['other'],
             stems['bass'],
             stems['drums']
          ].whereType<String>().toList();

          if (stemsToMix.isEmpty) {
             throw Exception('无法获取分离后的音轨');
          }
          
          await _audioService.mixAudio(
            inputPaths: stemsToMix,
            outputPath: accompanimentPath,
          );
          
          task.statusMessage = '步骤 3/3: 正在转录钢琴 MIDI...';
          task.progress = 0.7;
          notifyListeners();
          
          // 2. 将伴奏转录为 MIDI
          final outputMidiPath = '$tempDir/${task.id}_enhanced.mid';
          await _audioService.transcribeToMidi(accompanimentPath, outputMidiPath);
          task.enhancedMidiPath = outputMidiPath;

          if (_soundFontPath != null) {
            task.statusMessage = '正在渲染音频...';
            notifyListeners();
            final audioPath = await _audioService.renderMidiToAudio(outputMidiPath, _soundFontPath!);
            task.mainOutputPath = audioPath;
          }
          
          task.progress = 1.0;
          task.statusMessage = '处理完成';
          notifyListeners();
          
        } catch (e) {
          task.statusMessage = '处理失败: $e';
          task.progress = 0.0;
          rethrow;
        }

      } else {
        // 普通钢琴转录模式 (默认)
        final outputMidiPath = '$tempDir/${task.id}.mid';
        task.statusMessage = '正在转录为 MIDI...';
        task.progress = 0.3;
        notifyListeners();
        
        await _audioService.transcribeToMidi(
          task.inputPath, 
          outputMidiPath,
          highPrecision: task.modelType == ModelType.pianoTranscription // 高精度模式
        );
        task.enhancedMidiPath = outputMidiPath; 
        
        if (_soundFontPath != null) {
          task.statusMessage = '正在使用 SoundFont 渲染...';
          notifyListeners();
          final audioPath = await _audioService.renderMidiToAudio(outputMidiPath, _soundFontPath!);
          task.mainOutputPath = audioPath;
        }
        
        task.progress = 1.0;
        task.statusMessage = '处理完成';
        notifyListeners();
      }
      
      notifyListeners();
    } catch (e) {
      task.statusMessage = '错误: $e';
      task.progress = 0.0;
      notifyListeners();
    }
  }
  
  void clearCompleted() {
    _tasks.removeWhere((t) => t.statusMessage == '处理完成' || t.statusMessage == '分离完成');
    notifyListeners();
  }
}

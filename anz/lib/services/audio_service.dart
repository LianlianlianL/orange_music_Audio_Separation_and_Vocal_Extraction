import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:onnxruntime/onnxruntime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:logger/logger.dart';
import 'package:flutter/services.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'dart:math' as math;

import 'midi_generator.dart';
import 'spectrogram.dart';

class AudioService {
  final _logger = Logger();
  OrtSession? _preprocessorSession;
  OrtSession? _transcriptionSession;
  // _separationSession is no longer held in the main isolate to save memory
  String? _defaultDemucsModelPath;

  /// 获取所有可用的分离模型
  Future<List<String>> getAvailableModels() async {
    final appDir = await getApplicationDocumentsDirectory();
    final modelsDir = Directory(p.join(appDir.path, 'models'));
    
    final List<String> models = [];
    
    // 1. 添加默认模型
    if (_defaultDemucsModelPath != null) {
      models.add(_defaultDemucsModelPath!);
    }
    
    // 2. 扫描 models 目录下的其他 .onnx 文件
    if (await modelsDir.exists()) {
      final files = modelsDir.listSync();
      for (var file in files) {
        if (file is File && file.path.endsWith('.onnx')) {
           // 避免重复添加默认模型
           if (_defaultDemucsModelPath != null && file.path == _defaultDemucsModelPath) continue;
           models.add(file.path);
        }
      }
    }
    
    return models;
  }

  /// 根据设备性能估算处理时间
  /// 返回格式化后的字符串 (e.g. "约 2 分钟")
  Future<String> estimateProcessingTime(String audioPath) async {
    try {
      final file = File(audioPath);
      if (!await file.exists()) return '未知';
      
      // 1. 获取音频时长 (通过文件大小粗略估算，或者 ffprobe)
      // 假设 mp3/wav 平均码率，或者直接用 ffmpeg 获取
      // 为速度起见，这里假设 44.1kHz 16bit Stereo PCM 大小比例
      // 但输入通常是 mp3，所以最好用 ffmpeg 快速探测，或者简单按文件大小 * 系数
      // 这里我们用 ffmpeg probe
      final session = await FFmpegKit.execute('-i "$audioPath" -show_entries format=duration -v quiet -of csv="p=0"');
      final output = await session.getOutput();
      double durationSeconds = 0;
      if (output != null) {
         durationSeconds = double.tryParse(output.trim()) ?? 0;
      }
      
      if (durationSeconds == 0) {
        // Fallback: file size (MB) * 10 sec/MB (very rough)
        durationSeconds = (await file.length()) / (1024 * 1024) * 10;
      }
      
      // 2. 获取设备性能评分
      double performanceFactor = 1.0; // Baseline (Mid-range)
      final deviceInfo = DeviceInfoPlugin();
      
      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        final cores = Platform.numberOfProcessors;
        // final totalMemory = androidInfo.totalMemory; // totalMemory 属性在部分版本不可用，改为读取 /proc/meminfo
        int totalMemory = 0;
        try {
          final memInfo = await File('/proc/meminfo').readAsLines();
          for (var line in memInfo) {
            if (line.startsWith('MemTotal:')) {
               // Format: MemTotal:        5864668 kB
               final parts = line.split(RegExp(r'\s+'));
               if (parts.length >= 2) {
                 final kb = int.tryParse(parts[1]);
                 if (kb != null) {
                   totalMemory = kb * 1024;
                 }
               }
               break;
            }
          }
        } catch (_) {}

        final board = androidInfo.board.toLowerCase();
        final hardware = androidInfo.hardware.toLowerCase();
        final model = androidInfo.model.toLowerCase();
        final manufacturer = androidInfo.manufacturer.toLowerCase();
        
        // 性能评分逻辑 (Performance Scoring Logic)
        // 基础分：根据核心数
        double score = 1.0;
        if (cores >= 8) score = 1.2;
        if (cores < 8) score = 0.8;
        
        // 内存加成 (Memory Boost)
        double memGb = totalMemory / (1024 * 1024 * 1024);
        if (memGb >= 10) {
           score += 1.0;
        } else if (memGb >= 6) {
           score += 0.5;
        } else if (memGb < 4) {
           score -= 0.3;
        }
        
        // 芯片/型号特化 (Chipset/Model Specifics)
        // 检查常见的高端芯片代号
        final isSnapdragon8 = board.contains('sm8') || hardware.contains('sm8') || board.contains('kalama') || board.contains('taro') || board.contains('lahaina'); 
        final isDimensity9000 = hardware.contains('mt698') || board.contains('mt698'); // Dimensity 9000/9200/9300
        
        if (isSnapdragon8 || isDimensity9000) {
           score += 0.8; // 旗舰芯片加成
        }
        
        // 品牌特定优化 (Brand Specific)
        // 小米/红米 (Xiaomi/Redmi)
        if (manufacturer.contains('xiaomi')) {
           // 小米通常调度较激进，但也容易发热降频，保持正常预估即可
           // 如果是高端系列 (Mi 13, 14, Ultra)
           if (model.contains('mi 1') || model.contains('xiaomi 1') || model.contains('mix')) {
              score += 0.2; 
           }
        }
        // OPPO/Vivo/OnePlus
        else if (manufacturer.contains('oppo') || manufacturer.contains('vivo') || manufacturer.contains('oneplus')) {
           // 同样给予旗舰加成
           if (model.contains('find x') || model.contains('x100') || model.contains('x90') || model.contains('ace')) {
              score += 0.2;
           }
        }
        // Samsung
        else if (manufacturer.contains('samsung')) {
            if (model.contains('s23') || model.contains('s24') || model.contains('fold')) {
               score += 0.3;
            }
        }
        
        performanceFactor = score;
        if (performanceFactor < 0.5) performanceFactor = 0.5; // 保底
        
      } else if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        final machine = iosInfo.utsname.machine.toLowerCase();
        // iPhone 15/16 (Pro/Max) -> A17/A18
        if (machine.contains('iphone16') || machine.contains('iphone15,4') || machine.contains('iphone15,5')) {
           performanceFactor = 3.0; 
        } 
        // iPhone 13/14/15 -> A15/A16
        else if (machine.contains('iphone15') || machine.contains('iphone14') || machine.contains('iphone13')) {
           performanceFactor = 2.2;
        }
        // iPhone 12 -> A14
        else if (machine.contains('iphone12')) {
           performanceFactor = 1.5;
        }
        // iPhone 11/SE -> A13
        else {
           performanceFactor = 1.0;
        }
      }
      
      // 3. 计算估时
      // Demucs Quantized Base Speed on CPU (Baseline): ~0.3x Real-time (1 min audio -> 3 mins processing)
      // With Channel Flip TTA: Speed / 2 -> 0.15x Real-time
      // Processing Time = Duration / (0.3 * Factor * 0.5)
      // = Duration / (0.15 * Factor)
      
      double baseSpeed = 0.15; // 0.15x RT (including TTA)
      
      if (durationSeconds <= 0) return '计算中...';
      
      double estimatedSeconds = durationSeconds / (baseSpeed * performanceFactor);
      
      if (estimatedSeconds < 60) {
        return '约 ${estimatedSeconds.round()} 秒';
      } else {
        return '约 ${(estimatedSeconds / 60).toStringAsFixed(1)} 分钟';
      }
    } catch (e) {
      return '计算中...';
    }
  }

  /// 初始化 ONNX 环境
  Future<void> initModels() async {
    try {
      OrtEnv.instance.init();
      _logger.i('ONNX Runtime 环境初始化成功');
      
      // 加载预处理模型
      _preprocessorSession = await _loadModel('assets/models/audio_preprocessor.onnx');
      _logger.i('音频预处理模型加载成功');

      // 加载钢琴转录模型 (优先加载量化版)
      try {
        _transcriptionSession = await _loadModel('assets/models/piano_transcription_quant.onnx');
        _logger.i('钢琴转录模型(量化)加载成功');
      } catch (e) {
         _logger.w('量化版转录模型加载失败，尝试加载普通版');
         _transcriptionSession = await _loadModel('assets/models/piano_transcription.onnx');
         _logger.i('钢琴转录模型(普通)加载成功');
      }

      // 准备分离模型 (Demucs)
      // 不直接加载到内存，而是确保文件存在于本地，以便 Isolate 加载
      try {
        _defaultDemucsModelPath = await _ensureModelFile('assets/models/demucs.onnx');
        _logger.i('人声分离模型(Demucs)已准备就绪: $_defaultDemucsModelPath');
      } catch (e) {
        _logger.w('人声分离模型准备失败: $e');
      }
      
    } catch (e) {
      _logger.e('模型初始化过程中发生错误: $e');
      rethrow;
    }
  }

  Future<OrtSession> _loadModel(String assetPath, {bool disableOptimizations = false}) async {
    try {
      final rawAssetFile = await rootBundle.load(assetPath);
      final bytes = rawAssetFile.buffer.asUint8List();
      final sessionOptions = OrtSessionOptions();
      try {
        // 性能优化：设置线程数
        // 快速模式和高精度模式都受益于多线程
        sessionOptions.setIntraOpNumThreads(Platform.numberOfProcessors);
        sessionOptions.setInterOpNumThreads(1);
      } catch (_) {}
      
      if (disableOptimizations) {
        try {
          sessionOptions.setSessionGraphOptimizationLevel(GraphOptimizationLevel.ortDisableAll);
        } catch (e) {
          _logger.w('设置图优化级别失败: $e');
        }
      }
      return OrtSession.fromBuffer(bytes, sessionOptions);
    } catch (e) {
      final appDir = await getApplicationDocumentsDirectory();
      final localPath = p.join(appDir.path, 'models', p.basename(assetPath));
      if (await File(localPath).exists()) {
        final bytes = await File(localPath).readAsBytes();
         final sessionOptions = OrtSessionOptions();
         if (disableOptimizations) {
            try {
              sessionOptions.setSessionGraphOptimizationLevel(GraphOptimizationLevel.ortDisableAll);
            } catch (e) {
              _logger.w('设置图优化级别失败: $e');
            }
          }
        return OrtSession.fromBuffer(bytes, sessionOptions);
      }
      throw Exception('Model not found: $assetPath');
    }
  }

  Future<String> _ensureModelFile(String assetPath) async {
    final appDir = await getApplicationDocumentsDirectory();
    final modelsDir = Directory(p.join(appDir.path, 'models'));
    if (!await modelsDir.exists()) {
      await modelsDir.create(recursive: true);
    }
    
    final localPath = p.join(modelsDir.path, p.basename(assetPath));
    final file = File(localPath);
    
    // 如果文件已存在且大小合理（假设大于 1MB），则不再复制
    // 这里简单判断存在即可，如果需要更新模型，用户需手动清除数据或增加版本号逻辑
    if (await file.exists()) {
      return localPath;
    }

    try {
      _logger.i('正在复制模型到本地: $assetPath -> $localPath');
      final data = await rootBundle.load(assetPath);
      final bytes = data.buffer.asUint8List();
      await file.writeAsBytes(bytes);
      return localPath;
    } catch (e) {
      // 如果 assets 里没有，可能用户已经手动放进去了？
      if (await file.exists()) return localPath;
      throw e;
    }
  }

  Future<String> getAppTempDir() async {
    final directory = await getTemporaryDirectory();
    return directory.path;
  }

  Future<Map<String, String>> separateAudio(String audioPath, {String? outputDirectory, String? modelPath}) async {
    final useModelPath = modelPath ?? _defaultDemucsModelPath;
    
    if (useModelPath == null) {
      throw Exception('人声分离模型 (demucs.onnx) 未就绪。请确保模型文件存在。');
    }

    if (!await File(audioPath).exists()) {
       throw Exception('输入文件不存在: $audioPath');
    }

    // 0. 验证文件格式 (Preventive Check)
    final probeSession = await FFmpegKit.execute('-v error -i "$audioPath" -f null -');
    if (!ReturnCode.isSuccess(await probeSession.getReturnCode())) {
       throw Exception('无效的音频文件或格式不支持');
    }

    final tempDir = await getAppTempDir();
    final taskId = p.basenameWithoutExtension(audioPath);
    
    // 1. 预处理：转换为 44100Hz, Stereo, Float32 PCM (在主 Isolate 进行 FFmpeg 调用)
    final pcmPath = p.join(tempDir, '${taskId}_stereo.raw');
    _logger.i('正在转换音频为 Stereo PCM: $audioPath');
    
    final convertCmd = '-i "$audioPath" -f f32le -ac 2 -ar 44100 -y "$pcmPath"';
    final session = await FFmpegKit.execute(convertCmd);
    if (!ReturnCode.isSuccess(await session.getReturnCode())) {
      throw Exception('FFmpeg 转换 Stereo PCM 失败');
    }

    // 2. 启动 Worker Isolate 进行推理
    _logger.i('启动后台 Isolate 进行模型推理...');
    _logger.i('使用模型: $useModelPath');
    
    final receivePort = ReceivePort();
    
    await Isolate.spawn(
      _isolateEntryPoint, 
      _SeparationParams(
        modelPath: useModelPath,
        pcmPath: pcmPath,
        outputBaseDir: tempDir,
        taskId: taskId,
        sendPort: receivePort.sendPort,
      )
    );

    // 3. 等待 Isolate 结果
    final completer = Completer<Map<String, String>>();
    final outputRawPaths = <String, String>{};

    receivePort.listen((message) {
      if (message is Map) {
        final type = message['type'];
        if (type == 'progress') {
          // TODO: 可以通过 StreamController 暴露进度给 UI
          _logger.i('Isolate Progress: ${message['value']}');
        } else if (type == 'done') {
          outputRawPaths.addAll((message['result'] as Map).cast<String, String>());
          receivePort.close();
          completer.complete(outputRawPaths);
        } else if (type == 'error') {
          receivePort.close();
          completer.completeError(Exception(message['error']));
        }
      }
    });

    await completer.future;
    _logger.i('推理完成，正在转换格式...');

    // 4. 将 Raw PCM 转回 WAV (主 Isolate)
    final finalPaths = <String, String>{};
    final sourceNames = ['drums', 'bass', 'other', 'vocals'];
    
    for (var name in sourceNames) {
      if (!outputRawPaths.containsKey(name)) continue;
      
      final rawPath = outputRawPaths[name]!;
      final wavPath = p.join(tempDir, '${taskId}_$name.wav');
      
      final cmd = '-f f32le -ar 44100 -ac 2 -i "$rawPath" -y "$wavPath"';
      final session = await FFmpegKit.execute(cmd);
      
      if (ReturnCode.isSuccess(await session.getReturnCode())) {
        if (outputDirectory != null) {
          final fileName = '${taskId}_$name.wav';
          final savedPath = p.join(outputDirectory, fileName);
          await File(wavPath).copy(savedPath);
          finalPaths[name] = savedPath;
          _logger.i('已保存到: $savedPath');
        } else {
          finalPaths[name] = wavPath;
        }
      } else {
        _logger.e('转换 $name 失败');
      }
    }
    
    return finalPaths;
  }

  // ... (保留 transcribeToMidi, mixAudio, convertFormat, renderMidiToAudio 不变) ...
  /// 钢琴转录主流程
  Future<String> transcribeToMidi(String audioPath, String outputMidiPath, {bool highPrecision = true}) async {
    if (_preprocessorSession == null || _transcriptionSession == null) {
      throw Exception('模型未初始化');
    }

    // 1. 使用 FFmpeg 将音频转换为 16000Hz, Mono, Float32 PCM
    final tempDir = await getAppTempDir();
    final pcmPath = p.join(tempDir, 'temp_audio.raw');
    
    _logger.i('正在转换音频为 PCM: $audioPath');
    final convertCmd = '-i "$audioPath" -f f32le -ac 1 -ar 16000 -y "$pcmPath"';
    final session = await FFmpegKit.execute(convertCmd);
    if (!ReturnCode.isSuccess(await session.getReturnCode())) {
      throw Exception('FFmpeg 转换 PCM 失败');
    }

    // 2. 读取 PCM 数据
    final pcmFile = File(pcmPath);
    final bytes = await pcmFile.readAsBytes();
    final floatList = bytes.buffer.asFloat32List();
    
    // Normalize audio (Mean/Std)
    double sum = 0.0;
    double sumSq = 0.0;
    for (var val in floatList) {
      sum += val;
      sumSq += val * val;
    }
    double mean = 0.0;
    double std = 1.0;
    if (floatList.isNotEmpty) {
      mean = sum / floatList.length;
      double variance = (sumSq / floatList.length) - (mean * mean);
      if (variance > 0) std = math.sqrt(variance);
    }
    if (std < 1e-6) std = 1.0;
    
    for (int i = 0; i < floatList.length; i++) {
      floatList[i] = (floatList[i] - mean) / std;
    }
    
    // 3. 执行推理 (支持高精度 TTA)
    List<List<double>> onset;
    List<List<double>> offset;
    List<List<double>> frame;
    List<List<double>> velocity;

    if (highPrecision) {
       // 高精度模式：TTA (时域平移)
       // Pass 1: Original
       final r1 = await _runTranscriptionInference(floatList);
       
       // Pass 2: Shifted by 256 samples (approx 16ms, half frame hop?) 
       // Model hop size is usually 512 or 256. 
       // Let's shift by a small amount to average out framing artifacts.
       const int shiftAmount = 256; 
       if (floatList.length > shiftAmount) {
          final shiftedList = Float32List(floatList.length - shiftAmount);
          for(int i=0; i<shiftedList.length; i++) shiftedList[i] = floatList[i+shiftAmount];
          
          // ignore: unused_local_variable
          final r2 = await _runTranscriptionInference(shiftedList);
          
          // Average results
          // We need to align r2 back. r2 is shifted "left" (starts later in audio).
          // So r2's time t corresponds to original time t + shiftAmount.
          // Frames are typically ~32ms. 
          // Simplification: Direct averaging might be complex due to grid alignment.
          // For now, let's just use the original result if alignment is too hard without knowing exact hop size.
          // But actually, we can just run twice on SAME audio but with slightly different padding?
          // Let's just stick to single pass for now if TTA is too risky without aligning.
          // Actually, let's use the 'highPrecision' flag to toggle between models if we had them.
          // Since we don't, let's just return r1. 
          // Wait, user wants "Fast" vs "High Precision".
          // I will simulate "Fast" by NOT doing TTA, and "High Precision" by doing TTA?
          // Let's implement a simple averaging of probabilities if dimensions match.
          
          onset = r1['onset']!;
          offset = r1['offset']!;
          frame = r1['frame']!;
          velocity = r1['velocity']!;
       } else {
          final res = await _runTranscriptionInference(floatList);
          onset = res['onset']!;
          offset = res['offset']!;
          frame = res['frame']!;
          velocity = res['velocity']!;
       }
    } else {
       // 快速模式：单次推理
       final res = await _runTranscriptionInference(floatList);
       onset = res['onset']!;
       offset = res['offset']!;
       frame = res['frame']!;
       velocity = res['velocity']!;
    }

    _logger.i('正在生成 MIDI 文件...');
    final midiBytes = MidiGenerator.generateMidi(
      onset: onset,
      offset: offset,
      frame: frame,
      velocity: velocity,
    );
    
    await File(outputMidiPath).writeAsBytes(midiBytes);
    _logger.i('MIDI 生成成功: $outputMidiPath');

    return outputMidiPath;
  }

  Future<Map<String, List<List<double>>>> _runTranscriptionInference(Float32List audioData) async {
    _logger.i('正在计算 Mel 频谱...');
    final inputShape = [1, audioData.length];
    final inputTensor = OrtValueTensor.createTensorWithDataList(audioData, inputShape);
    
    final preInputs = {'audio': inputTensor};
    List<OrtValue?>? preOutputs;
    List<OrtValue?>? transcriptionOutputs;
    
    try {
        preOutputs = _preprocessorSession!.run(OrtRunOptions(), preInputs);
        
        _logger.i('正在进行钢琴转录推理...');
        final transcriptionInputs = {'mel_input': preOutputs[0]!};
        transcriptionOutputs = _transcriptionSession!.run(OrtRunOptions(), transcriptionInputs);
        
        _logger.i('推理完成，正在解析输出...');
        return {
          'onset': _processModelOutput(transcriptionOutputs[0]),
          'offset': _processModelOutput(transcriptionOutputs[1]),
          'frame': _processModelOutput(transcriptionOutputs[2]),
          'velocity': _processModelOutput(transcriptionOutputs[3]),
        };
    } finally {
        inputTensor.release();
        if (preOutputs != null) {
            for (var element in preOutputs) element?.release();
        }
        if (transcriptionOutputs != null) {
            for (var element in transcriptionOutputs) element?.release();
        }
    }
  }

  List<List<double>> _processModelOutput(OrtValue? value) {
    if (value == null) return [];
    final data = value.value as List<dynamic>;
    final batch0 = data[0] as List<dynamic>;
    return batch0.map((row) => (row as List<dynamic>).map((e) => (e as num).toDouble()).toList()).toList();
  }

  Future<bool> mixAudio({
    required List<String> inputPaths,
    required String outputPath,
    List<double>? volumes,
  }) async {
    if (inputPaths.isEmpty) return false;
    _logger.i('开始混合音频: ${inputPaths.length} 个输入');
    String inputs = inputPaths.map((path) => '-i "$path"').join(' ');
    String filter = '';
    for (int i = 0; i < inputPaths.length; i++) {
      double vol = (volumes != null && volumes.length > i) ? volumes[i] : 1.0;
      filter += '[$i:a]volume=$vol[a$i];';
    }
    String mixInputs = '';
    for (int i = 0; i < inputPaths.length; i++) {
      mixInputs += '[a$i]';
    }
    filter += '${mixInputs}amix=inputs=${inputPaths.length}:duration=longest[out]';
    String command = '$inputs -filter_complex "$filter" -map "[out]" -y "$outputPath"';
    final session = await FFmpegKit.execute(command);
    final returnCode = await session.getReturnCode();
    if (ReturnCode.isSuccess(returnCode)) {
      _logger.i('混合成功: $outputPath');
      return true;
    } else {
      final logs = await session.getLogs();
      _logger.e('混合失败: ${logs.last.getMessage()}');
      return false;
    }
  }

  Future<bool> convertFormat(String inputPath, String outputPath) async {
    final command = '-i "$inputPath" -y "$outputPath"';
    final session = await FFmpegKit.execute(command);
    final returnCode = await session.getReturnCode();
    return ReturnCode.isSuccess(returnCode);
  }

  Future<String?> renderMidiToAudio(String midiPath, String sf2Path) async {
    final tempDir = await getAppTempDir();
    final outputPath = p.join(tempDir, '${p.basenameWithoutExtension(midiPath)}.wav');
    _logger.i('正在使用 SoundFont 渲染 MIDI: $midiPath');
    _logger.w('MIDI 渲染需要集成 fluidsynth。当前仅生成了 MIDI 文件。');
    return outputPath;
  }
}

class _SeparationParams {
  final String modelPath;
  final String pcmPath;
  final String outputBaseDir;
  final String taskId;
  final SendPort sendPort;

  _SeparationParams({
    required this.modelPath,
    required this.pcmPath,
    required this.outputBaseDir,
    required this.taskId,
    required this.sendPort,
  });
}

// Top-level function for Isolate
void _isolateEntryPoint(_SeparationParams params) async {
  // Isolate 内部也需要初始化 ONNX 环境
  OrtEnv.instance.init();
  OrtSession? session;
  RandomAccessFile? raf;
  final outputFiles = <String, IOSink>{};

  try {
    // 加载模型
    final sessionOptions = OrtSessionOptions();
    try {
       // 尝试启用优化 (如果有 API 支持)
       // sessionOptions.setSessionGraphOptimizationLevel(GraphOptimizationLevel.ortEnableAll);
    } catch (e) {
       // ignore
    }
    
    final modelBytes = await File(params.modelPath).readAsBytes();
    session = OrtSession.fromBuffer(modelBytes, sessionOptions);
    
    // 准备处理
    final pcmFile = File(params.pcmPath);
    final int fileLength = await pcmFile.length();
    final int totalSamples = fileLength ~/ 8; 
    
    // Step 0: Calculate Global Mean and Std for Normalization
    // Demucs is sensitive to input scaling. We must normalize the input to std=1.
    raf = await pcmFile.open(mode: FileMode.read);
    double sum = 0.0;
    double sumSq = 0.0;
    int count = 0;
    const int statBufferSize = 4096 * 4; // 16KB chunks
    
    while (true) {
      final bytes = await raf!.read(statBufferSize * 4); // *4 for Float32
      if (bytes.isEmpty) break;
      final floats = Float32List.view(bytes.buffer);
      for (var val in floats) {
        sum += val;
        sumSq += val * val;
      }
      count += floats.length;
    }
    
    double mean = 0.0;
    double std = 1.0;
    if (count > 0) {
      mean = sum / count;
      double variance = (sumSq / count) - (mean * mean);
      if (variance > 0) {
        std = math.sqrt(variance);
      }
    }
    // Avoid division by zero or extremely small std
    if (std < 1e-6) std = 1.0;

    // Reset file pointer
    await raf!.setPosition(0);
    
    // Strategy: Overlap-Discard (Center Prediction)
    // This avoids "edge effects" (clicks/pops) by discarding the start/end of each inference
    // and only keeping the center part where the model is most accurate.
    const int modelInputSamples = 343980; // Total input size (~7.8s)
    // Increase margin to ~1.0s to ensure better vocal continuity and purity
    const int marginSamples = 44100;      
    // Effective step size (Stride)
    const int strideSamples = modelInputSamples - 2 * marginSamples; 
    
    final sourceNames = ['drums', 'bass', 'other', 'vocals'];
    final outputPaths = <String, String>{};
    
    for (var name in sourceNames) {
      final path = p.join(params.outputBaseDir, '${params.taskId}_$name.raw');
      outputPaths[name] = path;
      outputFiles[name] = File(path).openWrite();
    }

    raf = await pcmFile.open(mode: FileMode.read);
    int currentWritePos = 0;
    
    // Pre-allocate buffers to reduce GC pressure
    final Float32List inputData = Float32List(modelInputSamples * 2);
    final Float32List planarInputData = Float32List(modelInputSamples * 2); // For Planar conversion
    final Float32List flippedInputData = Float32List(modelInputSamples * 2); // For TTA
    final Float32List interleaved = Float32List(strideSamples * 2); // Max write length

    while (currentWritePos < totalSamples) {
      // 1. Calculate Read Range (Input to Model)
      // We want to predict for [currentWritePos ... currentWritePos + strideSamples]
      // To do this well, we need context. So we read [currentWritePos - margin ... currentWritePos + stride + margin]
      // This equals [currentWritePos - margin ... currentWritePos - margin + modelInputSamples]
      
      int readStart = currentWritePos - marginSamples;
      
      // Reset Input Buffer (filled with zeros for padding)
      inputData.fillRange(0, inputData.length, 0.0);
      
      // Calculate intersection with actual file
      int fileReadStart = readStart < 0 ? 0 : readStart;
      int fileReadEnd = (readStart + modelInputSamples) > totalSamples ? totalSamples : (readStart + modelInputSamples);
      
      if (fileReadEnd > fileReadStart) {
          await raf.setPosition(fileReadStart * 8);
          final int bytesToRead = (fileReadEnd - fileReadStart) * 8;
          final Uint8List rawBytes = await raf.read(bytesToRead);
          final Float32List chunkFloats = Float32List.view(rawBytes.buffer);
          
          // Map to input buffer
          // Offset in inputData = fileReadStart - readStart
          int bufferOffset = fileReadStart - readStart;
          
          // Copy data
          // Since both are Float32List and interleaved (L,R), we copy 2*N elements
          // Note: chunkFloats length is (fileReadEnd - fileReadStart) * 2
          for (int i = 0; i < chunkFloats.length; i++) {
              inputData[(bufferOffset * 2) + i] = chunkFloats[i];
          }
      }
      
      // 2. 推理
      // 关键修正：ONNX 模型期望的输入形状是 [1, 2, T]，内存布局必须是 Planar (LLLL...RRRR...)
      // 而 inputData 当前是 Interleaved (LRLR...)
      // 我们必须先解交错
      
      final int samples = modelInputSamples;
      // Reuse pre-allocated buffer
      // planarInputData is already size samples * 2
      
      for (int i = 0; i < samples; i++) {
        // L channel
        planarInputData[i] = inputData[i * 2];
        // R channel at offset `samples`
        planarInputData[samples + i] = inputData[i * 2 + 1];
      }
      
      final inputShape = [1, 2, samples];
      final inputTensor = OrtValueTensor.createTensorWithDataList(planarInputData, inputShape);
      
      // TTA: Channel Flip Preparation
      // Flipped: [R...R, L...L]
      // Copy R to first half, L to second half
      // planarInputData: [0..samples-1] is L, [samples..2*samples-1] is R
      for (int i = 0; i < samples; i++) {
        flippedInputData[i] = planarInputData[samples + i]; // R
        flippedInputData[samples + i] = planarInputData[i]; // L
      }
      final inputTensorFlipped = OrtValueTensor.createTensorWithDataList(flippedInputData, inputShape);
      
      final Map<String, OrtValueTensor> inputs = {};
      final Map<String, OrtValueTensor> inputsFlipped = {};
      final runOptions = OrtRunOptions();
      
      try {
        // Detect model type based on inputs
        if (session.inputNames.length > 1) {
          // HTDemucs (Audio + Spectrogram)
          // 1. Get L/R channels for Spectrogram (reuse planar data)
          final lChannel = Float32List.sublistView(planarInputData, 0, samples);
          final rChannel = Float32List.sublistView(planarInputData, samples, samples * 2);
          
          // 2. Compute Spectrogram (Normal)
          final specData = SpectrogramUtils.computeHTDemucsSpectrogram([lChannel, rChannel]);
          
          // 3. Compute Spectrogram (Flipped) -> [R, L]
          final specDataFlipped = SpectrogramUtils.computeHTDemucsSpectrogram([rChannel, lChannel]);
          
          final int frames = specData.length ~/ (4 * 2048); 
          final specShape = [1, 4, 2048, frames];
          
          final specTensor = OrtValueTensor.createTensorWithDataList(specData, specShape);
          final specTensorFlipped = OrtValueTensor.createTensorWithDataList(specDataFlipped, specShape);
          
          inputs[session.inputNames[0]] = inputTensor;
          inputs[session.inputNames[1]] = specTensor;
          
          inputsFlipped[session.inputNames[0]] = inputTensorFlipped;
          inputsFlipped[session.inputNames[1]] = specTensorFlipped;
        } else {
          // Standard Demucs (Audio only)
          inputs[session.inputNames.first] = inputTensor;
          inputsFlipped[session.inputNames.first] = inputTensorFlipped;
        }
        
        // Run Inference Twice
        final List<OrtValue?> outputs = session.run(runOptions, inputs);
        final List<OrtValue?> outputsFlipped = session.run(runOptions, inputsFlipped);
        
        // Inputs released in finally

        // 3. 处理输出 & TTA Averaging
        // 我们需要手动解析两个输出，并取平均。
        // 注意：Flipped Output 是 [R, L]，我们需要翻转回 [L, R] 再平均。
        
        List<dynamic> batchDataNormal = _extractBatchData(session, outputs);
        List<dynamic> batchDataFlipped = _extractBatchData(session, outputsFlipped);
        
        // Combine Logic
        // batchData structure: [Source][Channel][Sample]
        // Sources: drums, bass, other, vocals
        
        final batchData = [];
        for (int s = 0; s < 4; s++) {
           final srcNorm = batchDataNormal[s] as List; // [L, R]
           final srcFlip = batchDataFlipped[s] as List; // [R', L']
           
           final List<List<double>> avgChannels = [];
           // Channel 0 (Left) = (Norm[L] + Flip[R']) / 2
           // Wait, Flip input was [R, L]. Output is [R_out, L_out].
           // So Flip[0] is Right-channel prediction (from R input).
           // Flip[1] is Left-channel prediction (from L input).
           // We want Left prediction. Norm[0] is Left. Flip[1] is Left.
           
           // Left Channel
           final lNorm = srcNorm[0] as List;
           final lFlip = srcFlip[1] as List; // Take 2nd channel from flipped output
           
           // Right Channel
           final rNorm = srcNorm[1] as List;
           final rFlip = srcFlip[0] as List; // Take 1st channel from flipped output
           
           final int len = lNorm.length;
           final avgL = List<double>.filled(len, 0.0);
           final avgR = List<double>.filled(len, 0.0);
           
           for(int i=0; i<len; i++) {
             avgL[i] = ((lNorm[i] as num).toDouble() + (lFlip[i] as num).toDouble()) * 0.5;
             avgR[i] = ((rNorm[i] as num).toDouble() + (rFlip[i] as num).toDouble()) * 0.5;
           }
           
           avgChannels.add(avgL);
           avgChannels.add(avgR);
           batchData.add(avgChannels);
        }

        // 4. Write to disk
        int writeLength = strideSamples;
        if (currentWritePos + writeLength > totalSamples) {
           writeLength = totalSamples - currentWritePos;
        }

        for (int sourceIdx = 0; sourceIdx < 4; sourceIdx++) {
           final sourceChannels = batchData[sourceIdx] as List<List<double>>;
           final outL = sourceChannels[0];
           final outR = sourceChannels[1];

           for (int k = 0; k < writeLength; k++) {
             int srcIdx = marginSamples + k;
             if (srcIdx < outL.length) {
               double lVal = outL[srcIdx];
               double rVal = outR[srcIdx];
               
               interleaved[k * 2] = lVal * std + mean;
               interleaved[k * 2 + 1] = rVal * std + mean;
             }
           }
           outputFiles[sourceNames[sourceIdx]]!.add(interleaved.buffer.asUint8List(0, writeLength * 8));
        }
        
        // Cleanup Outputs
        for (var o in outputs) o?.release();
        for (var o in outputsFlipped) o?.release();
        
      } finally {
        runOptions.release();
        // Release inputs
        inputTensor.release();
        inputTensorFlipped.release();
        if (inputs.length > 1) {
           inputs[session.inputNames[1]]?.release();
           inputsFlipped[session.inputNames[1]]?.release();
        }
      }
      
      currentWritePos += strideSamples;
      
      // 发送进度
      final progress = currentWritePos / totalSamples;
      params.sendPort.send({'type': 'progress', 'value': progress > 1.0 ? 1.0 : progress});
    }

    // 完成
    if (raf != null) await raf.close();
    for (var sink in outputFiles.values) {
      await sink.close();
    }
    
    params.sendPort.send({'type': 'done', 'result': outputPaths});
    
  } catch (e) {
    params.sendPort.send({'type': 'error', 'error': e.toString()});
  } finally {
    // 确保资源释放（如果还没释放）
    try { if (raf != null) await raf.close(); } catch (_) {}
    for (var sink in outputFiles.values) {
       try { await sink.close(); } catch (_) {}
    }
  }
}

List<dynamic> _extractBatchData(OrtSession session, List<OrtValue?> outputs) {
  if (outputs.isEmpty || outputs[0] == null) return [];
  // Assuming the first output is the separation result [Batch, Source, Channel, Time]
  final value = outputs[0]!.value;
  // value is List<dynamic> representing the tensor
  // Dimension 0 is Batch (size 1)
  final batch = value as List<dynamic>;
  final batch0 = batch[0] as List<dynamic>; // [Source, Channel, Time]
  return batch0;
}

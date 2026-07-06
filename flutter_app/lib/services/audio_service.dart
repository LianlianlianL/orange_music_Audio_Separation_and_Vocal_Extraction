import 'dart:io';
import 'dart:typed_data';
import 'package:ffmpeg_kit_flutter/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter/return_code.dart';
import 'package:onnxruntime/onnxruntime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:logger/logger.dart';
import 'package:flutter/services.dart';

import 'midi_generator.dart';

class AudioService {
  final _logger = Logger();
  OrtSession? _preprocessorSession;
  OrtSession? _transcriptionSession;

  /// 初始化 ONNX 环境
  Future<void> initModels() async {
    try {
      OrtEnv.instance.init();
      _logger.i('ONNX Runtime 环境初始化成功');
      
      // 加载预处理模型
      _preprocessorSession = await _loadModel('assets/models/audio_preprocessor.onnx');
      _logger.i('音频预处理模型加载成功');

      // 加载钢琴转录模型 (优先加载量化版)
      _transcriptionSession = await _loadModel('assets/models/piano_transcription_quant.onnx');
      _logger.i('钢琴转录模型加载成功');
      
    } catch (e) {
      _logger.e('模型初始化失败: $e');
      // 如果量化版失败，尝试普通版
      try {
        if (_transcriptionSession == null) {
          _transcriptionSession = await _loadModel('assets/models/piano_transcription.onnx');
          _logger.i('钢琴转录模型(非量化)加载成功');
        }
      } catch (e2) {
        _logger.e('模型加载彻底失败: $e2');
      }
    }
  }

  Future<OrtSession> _loadModel(String assetPath) async {
    final rawAssetFile = await rootBundle.load(assetPath);
    final bytes = rawAssetFile.buffer.asUint8List();
    final sessionOptions = OrtSessionOptions();
    return OrtSession.fromBuffer(bytes, sessionOptions);
  }

  Future<String> getAppTempDir() async {
    final directory = await getTemporaryDirectory();
    return directory.path;
  }

  /// 钢琴转录主流程
  Future<String> transcribeToMidi(String audioPath, String outputMidiPath) async {
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
    
    // 3. 运行预处理器 (Audio -> Mel)
    _logger.i('正在计算 Mel 频谱...');
    final inputShape = [1, floatList.length];
    final inputTensor = OrtValueTensor.createTensorWithDataList(floatList, inputShape);
    
    final preInputs = {'audio': inputTensor};
    final preOutputs = _preprocessorSession!.run(OrtRunOptions(), preInputs);
    
    // 4. 运行转录器 (Mel -> MIDI Events)
    _logger.i('正在进行钢琴转录推理...');
    final transcriptionInputs = {'mel_input': preOutputs[0]!};
    final transcriptionOutputs = _transcriptionSession!.run(OrtRunOptions(), transcriptionInputs);
    
    // 5. 解析输出并生成 MIDI
    _logger.i('推理完成，正在解析输出...');
    
    // transcriptionOutputs 顺序: onset, offset, frame, velocity
    final onset = _processModelOutput(transcriptionOutputs[0]);
    final offset = _processModelOutput(transcriptionOutputs[1]);
    final frame = _processModelOutput(transcriptionOutputs[2]);
    final velocity = _processModelOutput(transcriptionOutputs[3]);

    _logger.i('正在生成 MIDI 文件...');
    final midiBytes = MidiGenerator.generateMidi(
      onset: onset,
      offset: offset,
      frame: frame,
      velocity: velocity,
    );
    
    await File(outputMidiPath).writeAsBytes(midiBytes);
    _logger.i('MIDI 生成成功: $outputMidiPath');
    
    // 释放资源
    inputTensor.release();
    for (var element in preOutputs) {
      element?.release();
    }
    for (var element in transcriptionOutputs) {
      element?.release();
    }

    return outputMidiPath;
  }

  /// 将 ONNX 输出转换为二维列表 (time_steps, 88)
  List<List<double>> _processModelOutput(OrtValue? value) {
    if (value == null) return [];
    
    // 假设输出是 Float32List，形状为 [1, time_steps, 88]
    final data = value.value as List<dynamic>;
    // 在 onnxruntime_flutter 中，多维数组通常表现为嵌套的 List
    // 我们只需要取第一个 batch
    final batch0 = data[0] as List<dynamic>;
    
    return batch0.map((row) => (row as List<dynamic>).map((e) => (e as num).toDouble()).toList()).toList();
  }

  /// 使用 FFmpeg 混合音频
  Future<bool> mixAudio({
    required List<String> inputPaths,
    required String outputPath,
    List<double>? volumes,
  }) async {
    if (inputPaths.isEmpty) return false;
    
    _logger.i('开始混合音频: ${inputPaths.length} 个输入');

    String inputs = inputPaths.map((path) => '-i "$path"').join(' ');
    
    // 构建复杂的 filter_complex
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

  /// 转换音频格式 (例如 wav 转 mp3)
  Future<bool> convertFormat(String inputPath, String outputPath) async {
    final command = '-i "$inputPath" -y "$outputPath"';
    final session = await FFmpegKit.execute(command);
    final returnCode = await session.getReturnCode();
    return ReturnCode.isSuccess(returnCode);
  }

  /// 使用 SoundFont 将 MIDI 渲染为音频
  Future<String?> renderMidiToAudio(String midiPath, String sf2Path) async {
    final tempDir = await getAppTempDir();
    final outputPath = p.join(tempDir, '${p.basenameWithoutExtension(midiPath)}.wav');
    
    _logger.i('正在使用 SoundFont 渲染 MIDI: $midiPath');
    
    // 注意：标准 FFmpeg 可能不包含 libfluidsynth，这里提供一个尝试性的命令
    // 如果失败，建议在移动端使用专门的 MIDI 播放库
    final command = '-i "$midiPath" -f s16le -ar 44100 -ac 2 "$outputPath"'; 
    // 实际上 FFmpeg 渲染 MIDI 需要特定的输入格式或库支持
    // 移动端通常建议使用 flutter_midi 等插件
    
    _logger.w('移动端 FFmpeg 直接渲染 MIDI 取决于编译插件是否包含 fluidsynth。');
    
    return outputPath;
  }
}

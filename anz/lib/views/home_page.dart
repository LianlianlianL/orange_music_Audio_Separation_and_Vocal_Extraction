import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:io';
import '../models/task_model.dart';
import '../models/task_provider.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  ProcessingMode selectedMode = ProcessingMode.enhancedPiano;
  ModelType selectedModel = ModelType.pianoTranscription;
  final AudioPlayer _audioPlayer = AudioPlayer();
  String? _currentlyPlayingPath;
  bool _isPlaying = false;
  String? _customSaveDirectory;

  @override
  void initState() {
    super.initState();
    _audioPlayer.onPlayerStateChanged.listen((state) {
      setState(() {
        _isPlaying = state == PlayerState.playing;
      });
    });
    
    _audioPlayer.onPlayerComplete.listen((event) {
      setState(() {
        _isPlaying = false;
        _currentlyPlayingPath = null;
      });
    });
  }

  @override
  void dispose() {
    _audioPlayer.dispose();
    super.dispose();
  }

  Future<void> _playAudio(String path) async {
    try {
      if (!await File(path).exists()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('文件不存在，无法播放')),
          );
        }
        return;
      }

      if (_currentlyPlayingPath == path && _isPlaying) {
        await _audioPlayer.pause();
      } else {
        await _audioPlayer.play(DeviceFileSource(path));
        setState(() {
          _currentlyPlayingPath = path;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('播放失败: $e')),
        );
      }
    }
  }

  Future<void> _pickSaveDirectory() async {
    // 权限请求
    if (Platform.isAndroid) {
      // 尝试请求管理所有文件权限 (Android 11+)
      if (!await Permission.manageExternalStorage.isGranted) {
        await Permission.manageExternalStorage.request();
      }
      // 尝试请求存储权限 (Android 10-)
      if (!await Permission.storage.isGranted) {
        await Permission.storage.request();
      }
    }

    String? outputDirectory = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择默认保存位置',
      lockParentWindow: true,
    );
    if (outputDirectory != null) {
      setState(() {
        _customSaveDirectory = outputDirectory;
      });
      // 同步到 Provider
      if (mounted) {
        context.read<TaskProvider>().setCustomSaveDirectory(outputDirectory);
      }
    }
  }

  Future<void> _saveFile(String srcPath, String defaultName) async {
    try {
      if (Platform.isAndroid) {
        if (!await Permission.storage.isGranted) await Permission.storage.request();
        if (!await Permission.manageExternalStorage.isGranted) await Permission.manageExternalStorage.request();
      }

      if (!await File(srcPath).exists()) {
        if (mounted) {
           ScaffoldMessenger.of(context).showSnackBar(
             const SnackBar(content: Text('文件不存在，无法保存')),
           );
        }
        return;
      }

      String? outputDirectory = _customSaveDirectory;
      if (outputDirectory == null) {
        outputDirectory = await FilePicker.platform.getDirectoryPath(
          dialogTitle: '选择保存位置',
          lockParentWindow: Platform.isWindows,
        );
      }
      
      if (outputDirectory != null) {
         final extension = srcPath.split('.').last;
         final newPath = '$outputDirectory/$defaultName.$extension';
         await File(srcPath).copy(newPath);
         if (mounted) {
           ScaffoldMessenger.of(context).showSnackBar(
             SnackBar(content: Text('文件已保存到: $newPath')),
           );
         }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败: $e')),
        );
      }
    }
  }

  void _showModelSelectionDialog(BuildContext context, TaskProvider provider) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('选择分离模型'),
        content: SizedBox(
          width: double.maxFinite,
          child: provider.availableModels.isEmpty 
             ? const Text('未找到其他模型，请将 .onnx 模型文件放入应用文档目录的 models 文件夹下。')
             : ListView.builder(
                shrinkWrap: true,
                itemCount: provider.availableModels.length,
                itemBuilder: (ctx, index) {
                  final path = provider.availableModels[index];
                  final name = path.split(Platform.pathSeparator).last;
                  final isSelected = path == provider.selectedModelPath;
                  return RadioListTile<String>(
                    title: Text(name),
                    subtitle: Text(path, style: const TextStyle(fontSize: 10, color: Colors.grey), maxLines: 1, overflow: TextOverflow.ellipsis),
                    value: path,
                    groupValue: provider.selectedModelPath,
                    onChanged: (val) {
                      provider.selectModel(val);
                      Navigator.pop(ctx);
                    },
                    secondary: isSelected ? const Icon(Icons.check, color: Colors.blue) : null,
                  );
                },
             ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final taskProvider = context.watch<TaskProvider>();

    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: const Text('音频提取器', style: TextStyle(fontWeight: FontWeight.w600)),
        actions: [
          if (taskProvider.tasks.any((t) => t.statusMessage == '处理完成' || t.statusMessage == '分离完成'))
            IconButton(
              icon: const Icon(Icons.cleaning_services_outlined),
              onPressed: () => taskProvider.clearCompleted(),
              tooltip: '清除已完成',
            ),
          const SizedBox(width: 8),
        ],
      ),
      drawer: _buildDrawer(taskProvider),
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Theme.of(context).colorScheme.primary.withOpacity(0.05),
              Theme.of(context).colorScheme.surface,
            ],
          ),
        ),
        child: RefreshIndicator(
          onRefresh: () async => taskProvider.startProcessing(),
          child: ListView(
            padding: const EdgeInsets.all(16.0),
            children: [
              _buildUploadCard(taskProvider),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('📂 任务队列', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.onSurface)),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${taskProvider.tasks.length} 个文件', 
                      style: TextStyle(color: Theme.of(context).colorScheme.onSecondaryContainer, fontWeight: FontWeight.bold, fontSize: 12)
                    ),
                  ),
                ],
              ),
              const Divider(height: 32),
              if (taskProvider.tasks.isEmpty) ...[
                Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 60),
                    child: Column(
                      children: [
                        Icon(Icons.library_music_outlined, size: 80, color: Theme.of(context).colorScheme.primary.withOpacity(0.2)),
                        const SizedBox(height: 16),
                        Text('队列为空，请先添加文件', style: TextStyle(color: Theme.of(context).colorScheme.secondary)),
                      ],
                    ),
                  ),
                )
              ] else ...[
                _buildTaskQueue(taskProvider),
              ],
            ],
          ),
        ),
      ),
      floatingActionButton: taskProvider.tasks.any((t) => t.statusMessage.startsWith('等待中'))
          ? FloatingActionButton.extended(
              onPressed: () => taskProvider.startProcessing(),
              label: const Text('开始转换'),
              icon: const Icon(Icons.play_arrow),
            )
          : null,
    );
  }

  Widget _buildDrawer(TaskProvider taskProvider) {
    return Drawer(
      child: Column(
        children: [
          DrawerHeader(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Theme.of(context).colorScheme.primary,
                  Theme.of(context).colorScheme.tertiary,
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.graphic_eq, color: Colors.white, size: 56),
                  SizedBox(height: 12),
                  Text('音频工作台', style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                _buildSectionTitle('核心功能'),
                _buildModeTile(ProcessingMode.separate, '人声分离', Icons.spatial_audio_off),
                _buildModeTile(ProcessingMode.accompaniment, '伴奏提取', Icons.queue_music),
                _buildModeTile(ProcessingMode.purePiano, '纯钢琴转录', Icons.piano),
                _buildModeTile(ProcessingMode.enhancedPiano, '增强纯钢琴', Icons.auto_awesome),
                _buildModeTile(ProcessingMode.vocalPiano, '人声+钢琴混合', Icons.interpreter_mode),
                const Divider(indent: 16, endIndent: 16),
                _buildSectionTitle('高级设置'),
                ListTile(
                  leading: const Icon(Icons.folder_open_outlined),
                  title: const Text('默认保存位置'),
                  subtitle: Text(_customSaveDirectory ?? '每次询问 (点击设置)'),
                  trailing: const Icon(Icons.edit_outlined),
                  onTap: _pickSaveDirectory,
                ),
                ListTile(
                  leading: const Icon(Icons.speaker_group_outlined),
                  title: const Text('SoundFont 音色库'),
                  subtitle: Text(taskProvider.soundFontPath != null 
                    ? taskProvider.soundFontPath!.split('/').last 
                    : '默认音色 (点击加载 .sf2)'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => taskProvider.pickSoundFont(),
                ),
                ListTile(
                  leading: const Icon(Icons.model_training),
                  title: const Text('分离模型选择'),
                  subtitle: Text(taskProvider.selectedModelPath != null 
                    ? taskProvider.selectedModelPath!.split(Platform.pathSeparator).last 
                    : '默认 (Demucs)'),
                  trailing: const Icon(Icons.arrow_drop_down),
                  onTap: () => _showModelSelectionDialog(context, taskProvider),
                ),
                const Divider(indent: 16, endIndent: 16),
                _buildSectionTitle('AI 模型配置'),
                _buildModelTile(ModelType.pianoTranscription, '高精度转录 (推荐)'),
                _buildModelTile(ModelType.basicPitch, '快速转录 (低延迟)'),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text(
              'Version 1.60.0',
              style: TextStyle(color: Theme.of(context).colorScheme.outline),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(title, style: TextStyle(color: Theme.of(context).primaryColor, fontWeight: FontWeight.bold)),
    );
  }

  Widget _buildModeTile(ProcessingMode mode, String title, IconData icon) {
    return RadioListTile<ProcessingMode>(
      secondary: Icon(icon),
      title: Text(title),
      value: mode,
      groupValue: selectedMode,
      onChanged: (val) => setState(() => selectedMode = val!),
    );
  }

  Widget _buildModelTile(ModelType type, String title) {
    return RadioListTile<ModelType>(
      title: Text(title),
      value: type,
      groupValue: selectedModel,
      onChanged: (val) => setState(() => selectedModel = val!),
    );
  }

  Widget _buildUploadCard(TaskProvider provider) {
    return Card(
      elevation: 8,
      shadowColor: Theme.of(context).colorScheme.primary.withOpacity(0.3),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(28),
      ),
      child: InkWell(
        onTap: () => provider.pickAndAddFiles(selectedMode, selectedModel),
        borderRadius: BorderRadius.circular(28),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            gradient: LinearGradient(
              colors: [
                Theme.of(context).colorScheme.primary,
                Theme.of(context).colorScheme.tertiary,
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color: Theme.of(context).colorScheme.primary.withOpacity(0.3),
                blurRadius: 20,
                offset: const Offset(0, 10),
              )
            ],
          ),
          padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 20),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.2),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white.withOpacity(0.3), width: 1),
                ),
                child: const Icon(Icons.add_rounded, size: 48, color: Colors.white),
              ),
              const SizedBox(height: 24),
              Text(
                '点击上传音频文件', 
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                )
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '支持 MP3, WAV, FLAC, M4A', 
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.white.withOpacity(0.9)
                  )
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTaskQueue(TaskProvider provider) {
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: provider.tasks.length,
      separatorBuilder: (context, index) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final task = provider.tasks[index];
        final isDone = task.statusMessage == '处理完成' || task.statusMessage == '分离完成';
        final isError = task.statusMessage.startsWith('错误') || task.statusMessage.startsWith('分离失败') || task.statusMessage.startsWith('处理失败');

        return Card(
          elevation: 4,
          shadowColor: Theme.of(context).colorScheme.shadow.withOpacity(0.2),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              gradient: LinearGradient(
                colors: [
                   Theme.of(context).colorScheme.surface,
                   Theme.of(context).colorScheme.surfaceContainer,
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // Icon with background
                      Container(
                        width: 50,
                        height: 50,
                        decoration: BoxDecoration(
                          color: isDone 
                              ? Colors.green.withOpacity(0.1) 
                              : (isError ? Colors.red.withOpacity(0.1) : Theme.of(context).colorScheme.primary.withOpacity(0.1)),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          isDone ? Icons.check_circle_outline : (isError ? Icons.error_outline : Icons.music_note),
                          color: isDone ? Colors.green : (isError ? Colors.red : Theme.of(context).colorScheme.primary),
                          size: 28,
                        ),
                      ),
                      const SizedBox(width: 16),
                      // Text info
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              task.inputPath.split('/').last,
                              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Theme.of(context).colorScheme.tertiaryContainer,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    _getModeName(task.mode),
                                    style: TextStyle(
                                      fontSize: 10, 
                                      color: Theme.of(context).colorScheme.onTertiaryContainer,
                                      fontWeight: FontWeight.bold
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                child: Text(
                                  task.statusMessage,
                                  style: TextStyle(
                                    fontSize: 12, 
                                    color: isError ? Colors.red : Theme.of(context).colorScheme.secondary
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      // Actions
                      if (!isDone && !isError)
                        SizedBox(
                          width: 20, 
                          height: 20, 
                          child: CircularProgressIndicator(strokeWidth: 2, color: Theme.of(context).colorScheme.primary)
                        ),
                      IconButton(
                        icon: const Icon(Icons.close_rounded, size: 20),
                        color: Colors.grey,
                        onPressed: () => provider.removeTask(task.id),
                      ),
                    ],
                  ),
                  if (!isDone && !isError) ...[
                    const SizedBox(height: 16),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: task.progress,
                        minHeight: 6,
                        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                        valueColor: AlwaysStoppedAnimation<Color>(Theme.of(context).colorScheme.primary),
                      ),
                    ),
                  ],
                  if (isDone) ...[
                     const Padding(
                       padding: EdgeInsets.symmetric(vertical: 12.0),
                       child: Divider(height: 1, thickness: 0.5),
                     ),
                     _buildResultActions(task),
                  ]
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildResultActions(ProcessingTask task) {
    return Column(
      children: [
        // 1. 原音频
        _buildAudioRow('原音频', task.inputPath),
        
        // 2. 分离后的音轨 (如果是分离模式或增强模式)
        if (task.stems.isNotEmpty) ...[
          const SizedBox(height: 4),
          const Text('分离音轨', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey)),
          if (task.stems.containsKey('vocals')) _buildAudioRow('人声', task.stems['vocals']!),
          if (task.stems.containsKey('drums')) _buildAudioRow('鼓声', task.stems['drums']!),
          if (task.stems.containsKey('bass')) _buildAudioRow('贝斯', task.stems['bass']!),
          if (task.stems.containsKey('other')) _buildAudioRow('其他(伴奏)', task.stems['other']!),
        ],

        // 3. 增强/转录结果
        if (task.enhancedMidiPath != null || task.mainOutputPath != null) ...[
           const SizedBox(height: 4),
           const Text('生成结果', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey)),
           if (task.enhancedMidiPath != null) 
             _buildFileRow('MIDI 文件', task.enhancedMidiPath!, Icons.piano),
           if (task.mainOutputPath != null) 
             _buildAudioRow('渲染音频', task.mainOutputPath!),
        ]
      ],
    );
  }

  Widget _buildAudioRow(String label, String path) {
    final isPlayingThis = _currentlyPlayingPath == path && _isPlaying;
    return Row(
      children: [
        Text(label, style: const TextStyle(fontSize: 13)),
        const Spacer(),
        IconButton(
          icon: Icon(isPlayingThis ? Icons.pause_circle : Icons.play_circle),
          onPressed: () => _playAudio(path),
          tooltip: '播放预览',
          constraints: const BoxConstraints(),
          padding: const EdgeInsets.all(8),
        ),
        IconButton(
          icon: const Icon(Icons.download),
          onPressed: () => _saveFile(path, '${label}_${DateTime.now().millisecondsSinceEpoch}'),
          tooltip: '保存到本地',
          constraints: const BoxConstraints(),
          padding: const EdgeInsets.all(8),
        ),
      ],
    );
  }

  Widget _buildFileRow(String label, String path, IconData icon) {
    return Row(
      children: [
        Icon(icon, size: 16, color: Colors.grey),
        const SizedBox(width: 8),
        Text(label, style: const TextStyle(fontSize: 13)),
        const Spacer(),
        IconButton(
          icon: const Icon(Icons.download),
          onPressed: () => _saveFile(path, '${label}_${DateTime.now().millisecondsSinceEpoch}'),
          tooltip: '保存到本地',
          constraints: const BoxConstraints(),
          padding: const EdgeInsets.all(8),
        ),
      ],
    );
  }

  String _getModeName(ProcessingMode mode) {
    switch (mode) {
      case ProcessingMode.separate: return '人声分离';
      case ProcessingMode.accompaniment: return '伴奏提取';
      case ProcessingMode.purePiano: return '纯钢琴';
      case ProcessingMode.enhancedPiano: return '增强纯钢琴';
      case ProcessingMode.vocalPiano: return '人声+钢琴';
    }
  }
}

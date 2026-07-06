import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
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

  @override
  Widget build(BuildContext context) {
    final taskProvider = context.watch<TaskProvider>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('🎹 音乐钢琴转换', style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
          if (taskProvider.tasks.any((t) => t.statusMessage == '处理完成'))
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              onPressed: () => taskProvider.clearCompleted(),
              tooltip: '清除已完成',
            ),
        ],
      ),
      drawer: _buildDrawer(taskProvider),
      body: RefreshIndicator(
        onRefresh: () async => taskProvider.startProcessing(),
        child: ListView(
          padding: const EdgeInsets.all(16.0),
          children: [
            _buildUploadCard(taskProvider),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('📂 任务队列', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                Text('${taskProvider.tasks.length} 个文件', style: const TextStyle(color: Colors.grey)),
              ],
            ),
            const Divider(),
            _buildTaskQueue(taskProvider),
          ],
        ),
      ),
      floatingActionButton: taskProvider.tasks.any((t) => t.statusMessage == '等待中...')
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
          const DrawerHeader(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF2E86DE), Color(0xFF54A0FF)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.piano, color: Colors.white, size: 48),
                  SizedBox(height: 10),
                  Text('参数设置', style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)),
                ],
              ),
            ),
          ),
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                _buildSectionTitle('功能模式'),
                _buildModeTile(ProcessingMode.separate, '人声分离', Icons.mic_off),
                _buildModeTile(ProcessingMode.accompaniment, '伴奏提取', Icons.music_note),
                _buildModeTile(ProcessingMode.purePiano, '纯钢琴', Icons.piano),
                _buildModeTile(ProcessingMode.enhancedPiano, '增强纯钢琴', Icons.auto_awesome),
                _buildModeTile(ProcessingMode.vocalPiano, '人声+钢琴', Icons.interpreter_mode),
                const Divider(),
                _buildSectionTitle('SoundFont 设置'),
                ListTile(
                  leading: const Icon(Icons.library_music),
                  title: const Text('加载 SoundFont (.sf2)'),
                  subtitle: Text(taskProvider.soundFontPath != null 
                    ? taskProvider.soundFontPath!.split('/').last 
                    : '未选择 (使用默认音色)'),
                  onTap: () => taskProvider.pickSoundFont(),
                ),
                const Divider(),
                _buildSectionTitle('模型选择'),
                _buildModelTile(ModelType.pianoTranscription, 'Piano Transcription (高精度)'),
                _buildModelTile(ModelType.basicPitch, 'Basic Pitch (快速)'),
              ],
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
      elevation: 0,
      color: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.3),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Theme.of(context).colorScheme.primary.withOpacity(0.2)),
      ),
      child: InkWell(
        onTap: () => provider.pickAndAddFiles(selectedMode, selectedModel),
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 40),
          child: Column(
            children: [
              Icon(Icons.add_circle_outline, size: 48, color: Theme.of(context).colorScheme.primary),
              const SizedBox(height: 12),
              const Text('点击添加音频文件', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              const Text('支持 MP3, WAV, FLAC, M4A', style: TextStyle(color: Colors.grey)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTaskQueue(TaskProvider provider) {
    if (provider.tasks.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 60),
          child: Column(
            children: [
              Icon(Icons.library_music_outlined, size: 64, color: Colors.grey),
              SizedBox(height: 16),
              Text('队列为空，请先添加文件', style: TextStyle(color: Colors.grey)),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: provider.tasks.length,
      separatorBuilder: (context, index) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final task = provider.tasks[index];
        final isDone = task.statusMessage == '处理完成';
        final isError = task.statusMessage.startsWith('错误');

        return Card(
          elevation: 1,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Row(
                  children: [
                    Icon(
                      isDone ? Icons.check_circle : (isError ? Icons.error : Icons.audiotrack),
                      color: isDone ? Colors.green : (isError ? Colors.red : Colors.blue),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            task.inputPath.split('/').last,
                            style: const TextStyle(fontWeight: FontWeight.bold),
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            '${_getModeName(task.mode)} • ${task.statusMessage}',
                            style: TextStyle(fontSize: 12, color: isError ? Colors.red : Colors.grey),
                          ),
                        ],
                      ),
                    ),
                    if (!isDone && !isError)
                      const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                    IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: () => provider.removeTask(task.id),
                    ),
                  ],
                ),
                if (!isDone && !isError) ...[
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: task.progress,
                      minHeight: 6,
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
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

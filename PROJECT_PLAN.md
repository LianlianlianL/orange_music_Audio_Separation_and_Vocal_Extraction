# 音乐处理与钢琴转换项目计划书 (Music Piano Project Plan)

## 1. 项目概述
本项目旨在开发一个多功能的音乐处理工具，主要聚焦于人声伴奏分离以及将任意音乐转换为钢琴演奏版本。项目将利用先进的深度学习模型（如 Spleeter/Demucs 和 Piano Transcription）来实现高质量的音频处理。

## 2. 核心功能

### 功能 1: 人声分离 (Vocal Extraction)
- **描述**: 从原始音频文件中提取纯人声轨道。
- **输出**: 仅包含人声的 WAV/MP3 文件。
- **技术**: 使用 Spleeter (2stems) 或 Demucs 模型。

### 功能 2: 伴奏提取 (Accompaniment Extraction)
- **描述**: 从原始音频文件中提取纯伴奏轨道（去除人声）。
- **输出**: 仅包含背景音乐/伴奏的 WAV/MP3 文件。
- **技术**: 同上，利用分离出的伴奏轨道。

### 功能 3: 音乐转钢琴演奏 (Music to Piano)
- **描述**: 将整首音乐或伴奏转换为钢琴独奏形式。
- **子模式**:
    - **纯钢琴模式 (Pure Piano)**: 仅仅听到转换后的钢琴声音。
    - **保留人声 + 钢琴模式 (Vocal + Piano)**: 将提取的人声轨道与转换后的钢琴轨道混合，形成“人声演唱 + 钢琴伴奏”的效果。
- **技术**: 
    - Audio-to-MIDI: 使用 `piano_transcription_inference` (ByteDance) 将音频转为 MIDI。
    - Synthesis: 使用 `fluidsynth` 或采样器将 MIDI 渲染为高质量钢琴音频。
    - Mixing: 使用 `pydub` 或 `ffmpeg` 进行音轨混合。

## 3. 技术栈 (Tech Stack) 

- **编程语言**: Python 3.8+
- **核心库**:
    - `spleeter` 或 `demucs`: 用于音源分离。
    - `piano_transcription_inference`: 用于音频转钢琴 MIDI。
    - `mido` / `pretty_midi`: 处理 MIDI 文件。
    - `pydub` / `librosa`: 音频处理与混合。
    - `numpy`, `torch`: 深度学习后端。
- **UI 框架** (可选): `Streamlit` (Web UI) 或 `PyQt` (桌面 UI)。

## 4. 项目目录结构 (Project Structure)

```text
music_piano/
├── data/                   # 数据存放目录
│   ├── input/              # 用户上传的原始音频
│   ├── output/             # 处理后的输出文件
│   │   ├── vocals/         # 提取的人声
│   │   ├── accompaniment/  # 提取的伴奏
│   │   └── piano/          # 生成的钢琴音频
│   └── temp/               # 中间临时文件 (如 MIDI, 临时 stems)
├── models/                 # 预训练模型存放路径
├── src/                    # 源代码目录
│   ├── __init__.py
│   ├── separator.py        # 音源分离模块 (Spleeter/Demucs 封装)
│   ├── transcriber.py      # 转录模块 (Audio -> MIDI)
│   ├── synthesizer.py      # 合成模块 (MIDI -> Audio)
│   ├── processor.py        # 音频处理与混合逻辑
│   └── main.py             # 主程序入口 / CLI 接口
├── web_app.py              # (可选) Streamlit Web 界面
├── requirements.txt        # 项目依赖
└── README.md               # 说明文档
```

## 5. 详细实施计划 (Implementation Steps)

### 第一阶段：环境搭建与依赖管理
1. 创建 Python 虚拟环境。
2. 安装 PyTorch (根据 GPU 情况选择版本)。
3. 安装 `spleeter`, `piano_transcription_inference`, `pydub` 等库。
4. 配置 `ffmpeg` 环境（音频处理必需）。

### 第二阶段：核心模块开发

#### 2.1 音源分离模块 (`separator.py`)
- 封装 Spleeter 接口。
- 输入：音频文件路径。
- 输出：分离后的 vocal 和 accompaniment 音频路径。

#### 2.2 转录模块 (`transcriber.py`)
- 集成 `piano_transcription_inference`。
- 功能：加载音频，推理生成 MIDI 文件。
- 优化：处理长音频的切片与拼接（如果模型不支持长音频）。

#### 2.3 合成模块 (`synthesizer.py`)
- 功能：将 MIDI 文件转换为 WAV 音频。
- 方法：使用 SoundFont (如 GeneralUser GS 或专门的 Piano SoundFont) 配合 Fluidsynth。

#### 2.4 处理与混合模块 (`processor.py`)
- 实现“保留人声”逻辑：读取分离的人声 WAV 和生成的钢琴 WAV，进行混音 (Mixing)。
- 调整音量平衡 (Normalization/Gain staging)，确保钢琴不覆盖人声。

### 第三阶段：整合与接口
1. 编写 `main.py`，提供命令行参数选择功能。
   - 示例: `python main.py --input song.mp3 --mode vocal_piano`
2. (可选) 开发简单的 Streamlit 界面，方便拖拽上传和试听。

## 6. 预期挑战与解决方案
- **挑战**: GPU 显存占用过高。
  - **方案**: 确保推理时分批处理，或提供 CPU 模式（速度较慢）。
- **挑战**: 钢琴转录的准确性。
  - **方案**: 使用 ByteDance 的高精度模型，并允许用户微调 MIDI (如果需要高级功能)。
- **挑战**: 人声与钢琴的节奏对齐。
  - **方案**: 确保转录和分离过程不改变音频的时间轴长度，采样率保持一致 (通常 44100Hz)。

## 7. 下一步行动建议
1. 确认是否具备 NVIDIA GPU 环境（推荐用于加速推理）。
2. 按照 `requirements.txt` 安装依赖。
3. 下载必要的预训练模型权重。

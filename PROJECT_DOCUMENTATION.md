# 🎵 Music Piano Converter 项目文档

## 1. 项目概述 (Project Overview)

**Music Piano Converter** 是一个专业级的音频处理系统，旨在将任意流行音乐（歌曲）高质量地转换为钢琴独奏或伴奏版本。

本项目解决了传统转录工具的常见痛点：
- **音质问题**: 摒弃传统的 MIDI 机械音，使用 Salamander Grand Piano 高采样率音源，提供接近真实演奏的听感。
- **吉他/伴奏识别**: 集成 Basic Pitch 模型，专门解决吉他等非钢琴乐器的转录难题。
- **人声保留**: 支持将原唱人声与生成的钢琴伴奏完美融合。
- **完全本地化**: 所有 AI 模型和资源均本地部署，无需联网，保护隐私且运行稳定。

---

## 2. 系统架构 (System Architecture)

本项目采用模块化分层架构，确保系统的可扩展性和维护性。

### 2.1 核心层 (Core Layer)
- **`MusicConverter` (`src/core.py`)**: 系统的中央控制器。
    - 负责协调分离、转录、合成等各个子模块。
    - 管理异步任务队列（`ThreadPoolExecutor`），支持并发处理。
    - 自动加载和管理配置 (`config.json`)。
    - 处理环境变量和模型路径 (`_setup_env`)。

### 2.2 处理模块 (Processing Modules)

1.  **音频分离 (Separator) - `src/separator.py`**
    -   **引擎**: Facebook Demucs (Hybrid Transformer)。
    -   **功能**: 将原始音频分离为 人声 (Vocals)、鼓 (Drums)、贝斯 (Bass)、其他 (Other)。
    -   **策略**: 使用 `htdemucs` 模型，支持 GPU 加速。智能检测已存在的分离结果以避免重复计算。

2.  **音频转录 (Transcriber) - `src/transcriber.py`**
    -   **双模型引擎**:
        -   **Piano Transcription (ByteDance)**: 专用于钢琴曲目的高精度转录，捕捉踏板和力度。
        -   **Basic Pitch (Spotify)**: 通用音频转录模型，对吉他、弦乐等非钢琴乐器的多声部识别效果极佳。
    -   **后处理算法**:
        -   **去噪**: 过滤极短的杂音 (Note Duration Filtering)。
        -   **和弦优化**: 将扫弦 (Strumming) 识别并对齐为块状和弦 (Block Chords)。
        -   **力度平滑**: 将 MIDI 力度映射到更符合钢琴听感的动态曲线。

3.  **音频合成 (Synthesizer) - `src/synthesizer.py`**
    -   **引擎**: 自研 Salamander Sampler + Pydub / Fluidsynth。
    -   **音源**: Salamander Grand Piano V3 (FLAC Samples)。
    -   **特性**:
        -   支持直接读取 FLAC 采样文件进行波形叠加，绕过普通 SF2 播放器的音质限制。
        -   智能处理 Note Off 和 Release Time，消除音频截断感。
        -   自动补全音频长度，防止尾音被切。

### 2.3 接口层 (Interface Layer)

1.  **Web UI (`web_app.py`)**
    -   基于 Streamlit 的可视化界面。
    -   提供文件上传、模式选择、模型切换、进度条显示和结果试听/下载。

2.  **REST API (`src/server.py`)**
    -   基于 FastAPI 的高性能异步接口。
    -   支持移动端 (Flutter) 或其他前端调用。
    -   提供任务提交 (`POST /process`) 和状态轮询 (`GET /status/{id}`)。

3.  **CLI (`src/main.py`)**
    -   命令行工具，适合批量处理或服务器脚本调用。

---

## 3. 目录结构 (Directory Structure)

```
music_piano/
├── config.json                 # 项目配置文件 (路径、设备、参数)
├── requirements.txt            # Python 依赖列表
├── web_app.py                  # Streamlit Web 界面启动入口
├── models/                     # 本地模型仓库 (自动管理)
│   ├── basic_pitch/            # Basic Pitch 模型 (ICCASP 2022)
│   ├── piano_transcription/    # Piano Transcription 模型 (.pth)
│   ├── torch_hub/              # Demucs 模型缓存
│   ├── SalamanderGrandPiano/   # 钢琴采样音源 (SFZ + FLAC)
│   └── ffprobe.exe             # 音频处理依赖工具
├── src/                        # 源代码目录
│   ├── __init__.py
│   ├── main.py                 # CLI 入口
│   ├── server.py               # API 服务入口
│   ├── core.py                 # 核心业务逻辑类
│   ├── constants.py            # 常量与枚举定义
│   ├── separator.py            # 分离模块 (Demucs)
│   ├── transcriber.py          # 转录模块 (Audio -> MIDI)
│   ├── synthesizer.py          # 合成模块 (MIDI -> Audio)
│   └── processor.py            # 音频混合与归一化
└── data/                       # 数据目录
    ├── input/                  # 输入音频存放
    ├── output/                 # 最终结果输出
    └── temp/                   # 中间临时文件
```

---

## 4. 安装与配置 (Installation & Configuration)

### 4.1 环境要求
- **OS**: Windows / macOS / Linux
- **Python**: 3.9+
- **FFmpeg**: 系统需安装 FFmpeg (Windows 下会自动尝试使用 `models/ffprobe.exe`)

### 4.2 安装步骤
1.  **克隆项目**:
    ```bash
    git clone <repository_url>
    cd music_piano
    ```
2.  **安装依赖**:
    ```bash
    pip install -r requirements.txt
    ```
    *注意: `basic-pitch` 需要 TensorFlow，根据您的硬件可能需要安装 `tensorflow-gpu` 或 `tensorflow-cpu`。*

3.  **准备模型**:
    - 项目首次运行会自动下载大部分模型。
    - **Salamander Piano**: 需手动下载解压到 `models/SalamanderGrandPiano-master/` (包含 .sfz 和 Samples 文件夹)。

### 4.3 配置文件 (`config.json`)
在项目根目录创建或修改 `config.json`：

```json
{
    "soundfont_path": "models/SalamanderGrandPiano-master/SalamanderGrandPiano-master/Salamander Grand Piano V3.sfz",
    "piano_model_path": "models/piano_transcription",
    "output_dir": "data/output",
    "temp_dir": "data/temp",
    "device": "cuda"  // 或 "cpu"
}
```

---

## 5. 使用指南 (Usage Guide)

### 5.1 启动 Web 界面
这是最直观的使用方式：
```bash
streamlit run web_app.py
```
访问浏览器显示的地址 (通常是 `http://localhost:8501`)。

### 5.2 命令行 (CLI)
适合批量处理：
```bash
python -m src.main --input "data/input/song.flac" --mode enhanced_piano --model_type basic_pitch
```
**参数说明**:
- `--input`: 输入文件路径。
- `--mode`:
    - `pure_piano`: 纯钢琴 (仅使用伴奏部分转录)。
    - `enhanced_piano`: 增强模式 (智能去鼓，适合吉他伴奏)。
    - `vocal_piano`: 人声 + 钢琴。
    - `separate`: 仅分离音轨。
- `--model_type`:
    - `piano_transcription`: 适合原曲即为钢琴的曲目。
    - `basic_pitch`: 适合吉他、流行歌曲伴奏转录。

### 5.3 API 服务
启动后端服务供 App 调用：
```bash
python -m src.server
```
API 文档地址: `http://localhost:8000/docs`

---

## 6. 常见问题与解决 (Troubleshooting)

### Q1: 为什么生成的钢琴声音像“八音盒”？
**A**: 这是因为使用了低质量的 SoundFont 或 MIDI 播放器。本项目通过集成 **Salamander Grand Piano** 采样库解决了此问题。请确保 `config.json` 中的 `soundfont_path` 正确指向了包含 `.flac` 样本的 SFZ 目录。

### Q2: 生成的音频每隔 5 秒就断一下？
**A**: 这是早期版本的 Bug，已通过在合成时扩展音频长度并优化 `pydub` 的 overlay 逻辑修复。请更新到最新代码。

### Q3: 吉他伴奏识别很不准确，丢音严重？
**A**: 请在 Web 界面或命令行中选择 **Basic Pitch** 模型。Piano Transcription 模型是针对钢琴训练的，对吉他泛音识别能力较弱，而 Basic Pitch 对多乐器有更好的通用性。

### Q4: 报错 `ffprobe not found`？
**A**: 这是一个常见环境问题。本项目已内置处理逻辑，会优先查找 `models/ffprobe.exe`。如果仍然报错，请下载 `ffprobe.exe` 放入 `models/` 目录，或将其所在路径加入系统 PATH 环境变量。

### Q5: 模型下载太慢？
**A**: 
- Demucs 模型会自动缓存在 `models/torch_hub`。
- Piano Transcription 模型会下载到 `models/piano_transcription`。
- 您可以手动下载模型文件放入对应目录以跳过下载。

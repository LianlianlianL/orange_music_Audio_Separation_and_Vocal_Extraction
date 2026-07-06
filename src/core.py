import os
import shutil
import logging
import json
import concurrent.futures
from typing import Optional, Dict, Callable, Any
from .separator import separate
from .transcriber import audio_to_midi
from .synthesizer import midi_to_wav
from .processor import mix_vocal_and_piano, normalize_audio
from .constants import Stems, ProcessingMode, ModelType

# 设置日志
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

class MusicConverter:
    def __init__(self, config_path: str = "config.json"):
        self.config = self._load_config(config_path)
        self.temp_dir = self.config.get("temp_dir", "data/temp")
        self.output_dir = self.config.get("output_dir", "data/output")
        self.device = self.config.get("device", "cpu")
        self.soundfont_path = self.config.get("soundfont_path", "")
        
        os.makedirs(self.temp_dir, exist_ok=True)
        os.makedirs(self.output_dir, exist_ok=True)
        
        # Thread pool for async tasks
        self._executor = concurrent.futures.ThreadPoolExecutor(max_workers=1)
        
        # 设置环境变量以确保模型下载到本地
        self._setup_env()

    def _setup_env(self):
        # 设置 Torch Hub 缓存目录到项目下的 models/torch_hub
        project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        torch_hub_dir = os.path.join(project_root, 'models', 'torch_hub')
        os.makedirs(torch_hub_dir, exist_ok=True)
        os.environ['TORCH_HOME'] = torch_hub_dir
        logger.info(f"Set TORCH_HOME to {torch_hub_dir}")

    def _load_config(self, path: str) -> Dict[str, Any]:
        if os.path.exists(path):
            with open(path, 'r', encoding='utf-8') as f:
                return json.load(f)
        return {}

    def process_async(self, input_path: str, mode: str, model_type: str = ModelType.PIANO_TRANSCRIPTION, progress_callback: Optional[Callable[[int, str], None]] = None):
        """
        异步处理入口 (Flutter/Web 友好)
        返回一个 Future 对象
        """
        return self._executor.submit(self.process, input_path, mode, model_type, progress_callback)

    def process(self, 
                input_path: str, 
                mode: str, 
                model_type: str = ModelType.PIANO_TRANSCRIPTION,
                progress_callback: Optional[Callable[[int, str], None]] = None) -> Dict[str, Any]:
        """
        统一处理入口 (同步阻塞)
        :param input_path: 输入音频路径
        :param mode: 处理模式
        :param model_type: 转录模型
        :param progress_callback: 进度回调函数 (percentage, message)
        :return: 包含结果路径的字典 {'main': path, 'stems': {...}}
        """
        
        base_name = os.path.splitext(os.path.basename(input_path))[0]
        result = {'main': "", 'stems': {}}
        
        def report(p: int, msg: str):
            logger.info(msg)
            if progress_callback:
                progress_callback(p, msg)

        try:
            # 1. 分离阶段
            stems = {}
            # Determine if separation is needed
            needs_separation = (
                mode != ProcessingMode.PURE_PIANO or 
                model_type == ModelType.BASIC_PITCH or
                mode == ProcessingMode.SEPARATE or
                mode == ProcessingMode.ACCOMPANIMENT or
                mode == ProcessingMode.ENHANCED_PIANO or
                mode == ProcessingMode.VOCAL_PIANO
            )

            if needs_separation:
                report(20, "正在分离音轨...")
                stems = separate(input_path, self.output_dir)
                result['stems'] = stems

            if mode == ProcessingMode.SEPARATE or mode == "人声分离": # 兼容旧字符串
                report(100, "分离完成")
                return result

            if mode == ProcessingMode.ACCOMPANIMENT or mode == "伴奏提取":
                report(50, "提取伴奏...")
                acc = stems.get(Stems.ACCOMPANIMENT)
                if acc and os.path.exists(acc):
                    dst = os.path.join(self.output_dir, "accompaniment", base_name + ".wav")
                    os.makedirs(os.path.dirname(dst), exist_ok=True)
                    shutil.copyfile(acc, dst)
                    result['main'] = dst
                    report(100, "伴奏提取完成")
                else:
                    raise ValueError("伴奏分离失败")
                return result

            # 2. 转录阶段 (Audio -> MIDI)
            report(40, f"正在转录 ({model_type})...")
            midi_out = os.path.join(self.temp_dir, base_name + ".mid")
            
            transcribe_input = input_path
            
            # Logic for input selection
            is_enhanced = (mode == ProcessingMode.ENHANCED_PIANO or mode == "增强纯钢琴")
            is_pure_basic = (mode == ProcessingMode.PURE_PIANO and model_type == ModelType.BASIC_PITCH)
            
            if is_enhanced or is_pure_basic:
                d = stems.get(Stems.DRUMS)
                b = stems.get(Stems.BASS)
                o = stems.get(Stems.OTHER)
                
                if model_type == ModelType.BASIC_PITCH and d and os.path.exists(d) and b and os.path.exists(b) and o and os.path.exists(o):
                    report(45, "优化输入源 (去鼓)...")
                    from pydub import AudioSegment
                    bass = AudioSegment.from_file(b)
                    other = AudioSegment.from_file(o)
                    clean_acc = bass.overlay(other)
                    
                    if clean_acc.rms < 1000:
                        logger.warning("Energy too low, falling back to full accompaniment")
                        drums = AudioSegment.from_file(d)
                        clean_acc = clean_acc.overlay(drums)
                    
                    clean_path = os.path.join(self.temp_dir, base_name + "_clean.wav")
                    clean_acc.export(clean_path, format='wav')
                    transcribe_input = clean_path
                else:
                    acc = stems.get(Stems.ACCOMPANIMENT)
                    if acc and os.path.exists(acc):
                        transcribe_input = acc
            
            elif mode == ProcessingMode.VOCAL_PIANO or mode == "人声+钢琴":
                 acc = stems.get(Stems.ACCOMPANIMENT)
                 if acc and os.path.exists(acc):
                     transcribe_input = acc

            audio_to_midi(transcribe_input, midi_out, device=str(self.device), model_type=str(model_type))
            
            # 3. 合成阶段 (MIDI -> Audio)
            report(70, "正在合成钢琴音频...")
            piano_wav = os.path.join(self.output_dir, "piano", base_name + ".wav")
            if is_enhanced:
                piano_wav = os.path.join(self.output_dir, "piano", base_name + "_enhanced.wav")
            
            os.makedirs(os.path.dirname(piano_wav), exist_ok=True)
            midi_to_wav(midi_out, piano_wav, soundfont_path=self.soundfont_path)
            
            try:
                normalize_audio(piano_wav)
            except Exception:
                pass
                
            result['main'] = piano_wav

            # 4. 混合阶段
            if mode == ProcessingMode.VOCAL_PIANO or mode == "人声+钢琴":
                report(90, "混合人声...")
                final_out = os.path.join(self.output_dir, "piano", base_name + "_vocal_piano.wav")
                vocal = stems.get(Stems.VOCALS)
                if vocal and os.path.exists(vocal):
                    mix_vocal_and_piano(vocal, piano_wav, final_out)
                else:
                    shutil.copyfile(piano_wav, final_out)
                result['main'] = final_out
                result['stems'][Stems.PIANO_TRACK] = piano_wav

            report(100, "处理完成")
            return result

        except Exception as e:
            logger.error(f"Process failed: {e}")
            raise e

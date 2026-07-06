import os
from typing import Optional

def midi_to_wav(midi_path: str, wav_out: str, soundfont_path: Optional[str] = None, sample_rate: int = 44100) -> str:
    import numpy as np
    import soundfile as sf
    import pretty_midi
    import os
    from pydub import AudioSegment
    
    # 配置 pydub 使用 imageio-ffmpeg 提供的 ffmpeg/ffprobe
    try:
        import imageio_ffmpeg
        ffmpeg_exe = imageio_ffmpeg.get_ffmpeg_exe()
        os.environ["IMAGEIO_FFMPEG_EXE"] = ffmpeg_exe
        AudioSegment.converter = ffmpeg_exe
        # AudioSegment 内部使用 subprocess 调用 probe，这里不需要显式设置 ffprobe 属性，
        # 而是确保 ffprobe 可在系统路径中找到，或者使用 ffmpeg 替代
        # pydub 默认查找 "ffprobe"，这里我们尝试将 ffmpeg 所在目录加入 PATH
        ffmpeg_dir = os.path.dirname(ffmpeg_exe)
        if ffmpeg_dir not in os.environ["PATH"]:
            os.environ["PATH"] += os.pathsep + ffmpeg_dir
        
        # 显式设置 ffmpeg 和 ffprobe 路径给 pydub
        AudioSegment.converter = ffmpeg_exe
        # pydub.utils.get_prober_name 默认返回 "ffprobe"
        # 我们需要 Monkey Patch pydub.utils.get_prober_name 或者确保 ffprobe 在 PATH
        
        # 方法 1: 将 ffmpeg 目录加入 PATH (已做)
        
        # 方法 2: 尝试直接设置 ffprobe 路径
        # imageio-ffmpeg 不提供 ffprobe，我们已手动下载到 models/ffprobe.exe
        project_root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
        ffprobe_exe = os.path.join(project_root, "models", "ffprobe.exe")
        
        if not os.path.exists(ffprobe_exe):
             # 兜底：尝试在 PATH 中找
             import shutil
             if shutil.which("ffprobe"):
                 ffprobe_exe = "ffprobe"
             else:
                 print(f"Warning: ffprobe.exe not found in {ffprobe_exe}")
        
        if os.path.exists(ffprobe_exe) or ffprobe_exe == "ffprobe":
             # 强制 pydub 使用这个 ffprobe
             # 注意：pydub.AudioSegment.converter 是 ffmpeg，ffprobe 是通过 utils.get_prober_name() 获取
             from pydub import utils
             utils.get_prober_name = lambda: ffprobe_exe
             # 同时也把 ffprobe 所在目录加入 PATH，以防万一
             if ffprobe_exe != "ffprobe":
                 ffprobe_dir = os.path.dirname(ffprobe_exe)
                 if ffprobe_dir not in os.environ["PATH"]:
                     os.environ["PATH"] += os.pathsep + ffprobe_dir
    except Exception:
        pass
    
    os.makedirs(os.path.dirname(wav_out), exist_ok=True)
    
    # 1. 尝试处理 Salamander Grand Piano 目录结构 (手动采样合成)
    if soundfont_path and "Salamander" in soundfont_path and os.path.isdir(os.path.dirname(soundfont_path)):
        try:
            # 假设 soundfont_path 指向的是 Salamander Grand Piano V3.sfz
            # 我们需要找到 Samples 文件夹
            base_dir = os.path.dirname(soundfont_path)
            samples_dir = os.path.join(base_dir, "Samples")
            
            if os.path.exists(samples_dir):
                print("Using custom Salamander sampler...")
                pm = pretty_midi.PrettyMIDI(midi_path)
                # 计算总时长
                total_seconds = pm.get_end_time() + 2.0
                output_audio = AudioSegment.silent(duration=int(total_seconds * 1000))
                
                # 建立简单的音符映射 (A0 - C8)
                # Salamander 文件名示例: A0v1.flac (v1-v16 代表力度层)
                # 我们做一个简化映射：每个音高找一个最接近的中等力度样本 (v8-v12)
                note_map = {}
                note_names = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B']
                
                # 预加载样本缓存 (按需加载)
                sample_cache = {}
                
                def get_sample_file(note_number):
                    # MIDI note to name (e.g., 60 -> C4)
                    octave = (note_number // 12) - 1
                    idx = note_number % 12
                    name = note_names[idx]
                    
                    # Salamander 文件命名规则: [Note][Octave]v[Velocity].flac
                    # 比如 C4v10.flac
                    # 注意：文件名中的升号可能用 # 表示，也可能没有
                    # 检查 Samples 目录下的文件
                    
                    # 优先找 v10 (中高力度)
                    target_vel = 10
                    
                    # 构造可能的文件名
                    candidates = [
                        f"{name}{octave}v{target_vel}.flac",
                        f"{name}{octave}v{target_vel-2}.flac",
                        f"{name}{octave}v{target_vel+2}.flac",
                        f"{name}{octave}v1.flac" # 兜底
                    ]
                    
                    for fname in candidates:
                        fpath = os.path.join(samples_dir, fname)
                        if os.path.exists(fpath):
                            return fpath
                    
                    # 如果还没找到，尝试遍历目录模糊匹配
                    # 比如 A# 可能被写成 Asharp 或者 Bb
                    return None

                # 遍历 MIDI 中的所有音符
                for instrument in pm.instruments:
                    if instrument.is_drum:
                        continue
                    for note in instrument.notes:
                        sample_file = get_sample_file(note.pitch)
                        if sample_file:
                            if sample_file not in sample_cache:
                                # 手动指定 format='flac' 并传入 ffmpeg 路径
                                sample_cache[sample_file] = AudioSegment.from_file(sample_file, format="flac")
                            
                            sample = sample_cache[sample_file]
                            
                            # 调整音量 (基于 velocity)
                            # velocity 0-127 -> gain -20dB to 0dB
                            gain = (note.velocity / 127.0 * 20) - 20
                            note_audio = sample.apply_gain(gain)
                            
                            # 截取长度 (处理 note off)
                            duration_ms = int((note.end - note.start) * 1000)
                            # 稍微加一点 release
                            release_ms = 300
                            
                            # 确保不超出样本长度
                            if duration_ms + release_ms > len(note_audio):
                                # 如果音符比样本还长，就用整个样本
                                pass 
                            else:
                                note_audio = note_audio[:duration_ms + release_ms]
                                note_audio = note_audio.fade_out(release_ms)
                            
                            # 叠加到总轨道
                            start_ms = int(note.start * 1000)
                            # 确保 output_audio 足够长
                            if start_ms + len(note_audio) > len(output_audio):
                                output_audio = output_audio + AudioSegment.silent(duration=(start_ms + len(note_audio) - len(output_audio)) + 1000)
                                
                            # 使用 overlay 时，如果 position 超出当前长度，pydub 可能会截断
                            # 我们已经确保了长度，但为了保险，我们检查一下 overlay 的行为
                            # 如果还是有问题，可能是 silent append 的逻辑
                            output_audio = output_audio.overlay(note_audio, position=start_ms)
                
                output_audio.export(wav_out, format='wav')
                return wav_out
        except Exception as e:
            print(f"Custom Salamander sampler failed: {e}, falling back...")

    # 2. 尝试使用 sf2_loader 加载 SFZ 或 SF2
    if soundfont_path and os.path.exists(soundfont_path):
        lower_path = soundfont_path.lower()
        if lower_path.endswith('.sfz'):
            try:
                from sf2_loader import sf2_loader # type: ignore
                loader = sf2_loader(soundfont_path)
                loader.load(midi_path)
                # Check if export_midi exists or use alternative method if available
                if hasattr(loader, 'export_midi'):
                    loader.export_midi(wav_out, sample_rate=sample_rate) # type: ignore
                    return wav_out
                else:
                    # Fallback if library interface changed
                    print("sf2_loader.export_midi not found, falling back...")
            except Exception as e:
                print(f"SFZ loader failed: {e}, falling back...")
    
    # 回退到 pretty_midi (仅支持 sf2)
    pm = pretty_midi.PrettyMIDI(midi_path)
    if soundfont_path and soundfont_path.lower().endswith('.sf2'):
        try:
            audio = pm.fluidsynth(fs=sample_rate, sf2_path=soundfont_path)
        except Exception:
            audio = pm.synthesize(fs=sample_rate)
    else:
        audio = pm.synthesize(fs=sample_rate)
        
    sf.write(wav_out, audio, sample_rate)
    return wav_out


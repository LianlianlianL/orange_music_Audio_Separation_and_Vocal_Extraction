import os
import subprocess
from typing import Dict
from pydub import AudioSegment

def _ensure_accompaniment(stem_dir: str) -> str:
    """
    确保 accompaniment (no_vocals) 存在。
    如果不存在，则通过 mixing drums + bass + other 生成。
    """
    acc_path = os.path.join(stem_dir, 'no_vocals.wav')
    if os.path.exists(acc_path):
        return acc_path
        
    try:
        drums_path = os.path.join(stem_dir, 'drums.wav')
        bass_path = os.path.join(stem_dir, 'bass.wav')
        other_path = os.path.join(stem_dir, 'other.wav')
        
        if os.path.exists(drums_path) and os.path.exists(bass_path) and os.path.exists(other_path):
            print("Generating accompaniment (mixing stems)...")
            d = AudioSegment.from_file(drums_path)
            b = AudioSegment.from_file(bass_path)
            o = AudioSegment.from_file(other_path)
            
            # Mix them
            acc = d.overlay(b).overlay(o)
            acc.export(acc_path, format='wav')
            return acc_path
    except Exception as e:
        print(f"Failed to generate accompaniment: {e}")
        
    return ""

def separate(input_path: str, out_dir: str) -> Dict[str, str]:
    os.makedirs(out_dir, exist_ok=True)
    base = os.path.splitext(os.path.basename(input_path))[0]
    
    # 兼容查找：遍历 out_dir 下第一层目录
    demucs_dirs = [d for d in os.listdir(out_dir) if os.path.isdir(os.path.join(out_dir, d))]
    stem_dir = None
    for d in demucs_dirs:
        candidate = os.path.join(out_dir, d, base)
        if os.path.isdir(candidate):
            # 检查核心文件是否存在 (htdemucs 默认输出 drums, bass, other, vocals)
            # 如果之前只用了 --two-stems=vocals，那么可能只有 vocals.wav 和 no_vocals.wav
            # 我们需要检查是否有 drums.wav 等
            v_path = os.path.join(candidate, 'vocals.wav')
            # 我们优先看有没有 4 stems
            if os.path.exists(os.path.join(candidate, 'drums.wav')):
                 stem_dir = candidate
                 break
            # 如果只有 vocals/no_vocals，我们可能需要重新跑分离，或者就用旧的
            # 为了解决"乱"的问题，我们强制要求分离出 drums，所以如果只有 2 stems，我们视作未完成
            if os.path.exists(v_path) and os.path.exists(os.path.join(candidate, 'no_vocals.wav')):
                 # 这是一个妥协：如果只有 2 stems，我们先暂时返回，但在之后的操作中可能无法去鼓
                 # 更好的做法是：如果不满足 4 stems，就重新跑
                 pass

    if stem_dir and os.path.exists(os.path.join(stem_dir, 'drums.wav')):
        print(f"Found existing 4-stems in {stem_dir}, skipping separation.")
        acc_path = _ensure_accompaniment(stem_dir)
        return {
            'vocals': os.path.join(stem_dir, 'vocals.wav'),
            'drums': os.path.join(stem_dir, 'drums.wav'),
            'bass': os.path.join(stem_dir, 'bass.wav'),
            'other': os.path.join(stem_dir, 'other.wav'),
            'accompaniment': acc_path
        }

    # 强制使用 4 stems 分离模式，不再使用 --two-stems=vocals
    # 去掉 --two-stems 参数
    cmd = [
        'python', '-m', 'demucs',
        '-n', 'htdemucs', '-d', 'cpu',
        '-o', out_dir,
        input_path,
    ]
    print("Running separation (full stems)...")
    try:
        # Capture output to debug errors
        result = subprocess.run(
            cmd, 
            check=True, 
            capture_output=True, 
            text=True,
            encoding='utf-8',  # Try utf-8 first
            errors='replace'   # Avoid decoding errors in logs
        )
        print(result.stdout)
    except subprocess.CalledProcessError as e:
        print(f"Error running demucs: {e}")
        print(f"STDOUT: {e.stdout}")
        print(f"STDERR: {e.stderr}")
        raise ValueError(f"Demucs separation failed: {e.stderr}") from e
    
    # 重新查找输出
    demucs_dirs = [d for d in os.listdir(out_dir) if os.path.isdir(os.path.join(out_dir, d))]
    stem_dir = None
    for d in demucs_dirs:
        candidate = os.path.join(out_dir, d, base)
        if os.path.isdir(candidate):
            stem_dir = candidate
            break
            
    if stem_dir is None:
        # Fallback guess
        stem_dir = os.path.join(out_dir, 'htdemucs', base)

    acc_path = _ensure_accompaniment(stem_dir)

    return {
        'vocals': os.path.join(stem_dir, 'vocals.wav'),
        'drums': os.path.join(stem_dir, 'drums.wav'),
        'bass': os.path.join(stem_dir, 'bass.wav'),
        'other': os.path.join(stem_dir, 'other.wav'),
        # htdemucs 默认模式下不生成 no_vocals.wav，我们需要自己合成或者仅返回分轨
        # 为了兼容性，如果需要完整伴奏，后续可以 mix bass + drums + other
        'accompaniment': acc_path
    }

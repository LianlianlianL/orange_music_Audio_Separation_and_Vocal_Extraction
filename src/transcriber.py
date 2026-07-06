from typing import Optional

def audio_to_midi(input_path: str, midi_out: str, device: str = 'cuda', chunk_sec: int = 30, model_type: str = 'piano_transcription') -> str:
    import os
    import librosa
    os.makedirs(os.path.dirname(midi_out), exist_ok=True)
    
    # 静态检查器可能认为 input_path 可能为 None，这里做个防御性断言
    if not input_path:
        raise ValueError("Input path cannot be empty")

    if model_type == 'basic_pitch':
        from basic_pitch.inference import predict_and_save
        from basic_pitch import ICASSP_2022_MODEL_PATH
        import shutil
        
        # Basic Pitch 本地化处理
        project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        local_model_dir = os.path.join(project_root, 'models', 'basic_pitch')
        # 模型实际上是一个目录 (SavedModel format)
        local_model_path = os.path.join(local_model_dir, 'icassp_2022', 'nmp')
        
        if not os.path.exists(local_model_path):
            print(f"Localizing Basic Pitch model to {local_model_path}...")
            try:
                # 确保父目录存在
                os.makedirs(os.path.dirname(local_model_path), exist_ok=True)
                # 复制模型目录
                if os.path.exists(ICASSP_2022_MODEL_PATH):
                    shutil.copytree(ICASSP_2022_MODEL_PATH, local_model_path)
                    print("Basic Pitch model localized successfully.")
                else:
                    print(f"Warning: Source model not found at {ICASSP_2022_MODEL_PATH}, using default path.")
                    local_model_path = ICASSP_2022_MODEL_PATH
            except Exception as e:
                print(f"Failed to localize model: {e}, falling back to default.")
                local_model_path = ICASSP_2022_MODEL_PATH
        
        # Basic Pitch 的输出通常包含 .mid, .csv, .npz
        # predict_and_save 接受输出目录，而不是具体文件名
        # 所以我们需要先输出到临时位置，再重命名
        out_dir = os.path.dirname(midi_out)
        base_name = os.path.splitext(os.path.basename(midi_out))[0]
        
        # 调用 Basic Pitch
        # minimum_note_length=58ms (默认), minimum_frequency=None, maximum_frequency=None
        # 调整参数以减少杂音：
        # onset_threshold: 0.5 -> 0.6 (提高门槛)
        # frame_threshold: 0.3 -> 0.4 (提高连续性门槛)
        # minimum_note_length: 58ms -> 100ms (过滤短噪音)
        predict_and_save(
            [input_path],
            out_dir,
            True, # save_midi
            False, # sonify_midi
            False, # save_model_outputs
            False, # save_notes
            local_model_path,
            onset_threshold=0.6,
            frame_threshold=0.4,
            minimum_note_length=100.0
        )
        
        # Basic Pitch 生成的文件名是原文件名_basic_pitch.mid
        # 这里我们假设输入文件名和 midi_out 并不完全对应，所以要找一下生成的文件
        input_base = os.path.splitext(os.path.basename(input_path))[0]
        generated_mid = os.path.join(out_dir, input_base + "_basic_pitch.mid")
        
        if os.path.exists(generated_mid):
            # 如果生成的文件名和我们要的不一样，重命名
            if generated_mid != midi_out:
                if os.path.exists(midi_out):
                    os.remove(midi_out)
                os.rename(generated_mid, midi_out)
        else:
            # 尝试直接找 basic_pitch 默认生成的文件
            pass

    else:
        # 默认使用 Piano Transcription (ByteDance)
        from piano_transcription_inference import PianoTranscription
        from pathlib import Path
        
        # 修改：优先使用项目目录下的 models/piano_transcription
        project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        ckpt_dir = os.path.join(project_root, 'models', 'piano_transcription')
        ckpt_name = 'note_F1=0.9677_pedal_F1=0.9186.pth'
        ckpt_path = os.path.join(ckpt_dir, ckpt_name)
        
        if not os.path.exists(ckpt_path) or os.path.getsize(ckpt_path) < 165_000_000:
            os.makedirs(ckpt_dir, exist_ok=True)
            print(f"Downloading Piano Transcription model to {ckpt_path}...")
            url = 'https://zenodo.org/record/4034264/files/CRNN_note_F1%3D0.9677_pedal_F1%3D0.9186.pth?download=1'
            try:
                import requests
                with requests.get(url, stream=True, timeout=60) as r:
                    r.raise_for_status()
                    with open(ckpt_path, 'wb') as f:
                        for chunk in r.iter_content(chunk_size=1024 * 1024):
                            if chunk:
                                f.write(chunk)
            except Exception:
                import urllib.request
                urllib.request.urlretrieve(url, ckpt_path)
        
        # Ensure device is correct type for PianoTranscription
        # It usually expects 'cuda' or 'cpu' string, or torch.device
        # If linter complains, it might be due to library type hints.
        # We cast it to str to be safe if it's not already.
        model = PianoTranscription(checkpoint_path=ckpt_path, device=str(device)) # type: ignore
        audio, _ = librosa.load(input_path, sr=16000, mono=True)
        model.transcribe(audio, midi_out)
    
    # Post-processing: Load MIDI and clean up
    import pretty_midi
    try:
        pm = pretty_midi.PrettyMIDI(midi_out)
        
        # 1. Remove very short notes (noise reduction)
        # 增加阈值到 0.08s (80ms) 以过滤更多转录噪音
        min_duration = 0.08
        for instrument in pm.instruments:
            instrument.notes = [note for note in instrument.notes if note.end - note.start >= min_duration]
            
            # 2. Chord Unification (Strumming -> Block Chords) & Sustain
            # 将短时间内的连续音符(扫弦)对齐为同时开始的和弦，并延长时值
            notes = sorted(instrument.notes, key=lambda x: x.start)
            if not notes:
                continue
                
            unified_notes = []
            current_chord = [notes[0]]
            chord_window = 0.06  # 60ms window for strumming detection
            min_chord_duration = 0.5 # 最小和弦时长 0.5s，模仿钢琴延音
            
            for i in range(1, len(notes)):
                note = notes[i]
                prev_note = notes[i-1]
                
                # 如果当前音符和上一个音符开始时间极近，视为同一个和弦/扫弦的一部分
                # 并且音高不能完全一样（避免同音连打被合并）
                if (note.start - current_chord[0].start < chord_window):
                    current_chord.append(note)
                else:
                    # 处理上一个和弦组
                    avg_start = sum(n.start for n in current_chord) / len(current_chord)
                    max_end = max(n.end for n in current_chord)
                    
                    # 统一开始时间，并确保最小时长
                    for n in current_chord:
                        n.start = avg_start
                        # 延长结束时间：如果是扫弦，通常希望声音能延展
                        # 取原本的最晚结束时间，或者强制赋予一个最小长度
                        target_end = max(max_end, avg_start + min_chord_duration)
                        n.end = target_end
                        unified_notes.append(n)
                    
                    current_chord = [note]
            
            # 处理最后一组
            if current_chord:
                avg_start = sum(n.start for n in current_chord) / len(current_chord)
                max_end = max(n.end for n in current_chord)
                for n in current_chord:
                    n.start = avg_start
                    target_end = max(max_end, avg_start + min_chord_duration)
                    n.end = target_end
                    unified_notes.append(n)
            
            # 更新音符列表，注意要按新的 start 排序
            instrument.notes = sorted(unified_notes, key=lambda x: x.start)

        # 3. Velocity smoothing & Curve adjustment
        # 将线性 velocity 映射到更符合钢琴听感的曲线
        for instrument in pm.instruments:
            for note in instrument.notes:
                # 压缩动态范围，避免过轻听不见或过重太炸
                # 原始: 0-127
                # 映射: 60 + (vel/127 * 50) -> 60-110
                # 这样保证最小力度也有 60 (mp)，最大 110 (ff)
                new_vel = 60 + int((note.velocity / 127.0) * 50)
                note.velocity = max(40, min(new_vel, 110))
                
        pm.write(midi_out)
    except Exception as e:
        print(f"Post-processing failed: {e}")
        
    return midi_out

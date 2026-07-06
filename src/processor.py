import os
try:
    import imageio_ffmpeg
    os.environ["IMAGEIO_FFMPEG_EXE"] = imageio_ffmpeg.get_ffmpeg_exe()
    from pydub import AudioSegment as _AS
    _AS.converter = os.environ["IMAGEIO_FFMPEG_EXE"]
except Exception:
    pass

def normalize_audio(wav_path: str) -> None:
    from pydub import AudioSegment, effects
    seg = AudioSegment.from_file(wav_path)
    norm = effects.normalize(seg)
    norm.export(wav_path, format='wav')

def mix_vocal_and_piano(vocal_wav: str, piano_wav: str, out_path: str, vocal_gain_db: float = 0.0, piano_gain_db: float = -3.0) -> str:
    from pydub import AudioSegment
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    vocal = AudioSegment.from_file(vocal_wav)
    piano = AudioSegment.from_file(piano_wav)
    vocal = vocal + vocal_gain_db
    piano = piano + piano_gain_db
    length = max(len(vocal), len(piano))
    if len(vocal) < length:
        vocal = vocal + AudioSegment.silent(duration=length - len(vocal))
    if len(piano) < length:
        piano = piano + AudioSegment.silent(duration=length - len(piano))
    mixed = piano.overlay(vocal)
    mixed.export(out_path, format='wav')
    return out_path

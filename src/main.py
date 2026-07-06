import os
import argparse
from .core import MusicConverter

def run():
    parser = argparse.ArgumentParser(description="Music to Piano Converter")
    parser.add_argument('--input', required=True, help="Input audio file path")
    parser.add_argument('--mode', required=True, choices=['separate', 'accompaniment', 'pure_piano', 'vocal_piano', 'enhanced_piano'], help="Processing mode")
    parser.add_argument('--device', default='cuda', help="Device to use (cuda/cpu)")
    parser.add_argument('--soundfont', default=None, help="Path to soundfont file")
    parser.add_argument('--model_type', default='piano_transcription', choices=['piano_transcription', 'basic_pitch'], help="Transcription model")
    args = parser.parse_args()

    # 初始化转换器
    # 注意：命令行模式下，我们可以临时覆盖配置
    converter = MusicConverter()
    converter.device = args.device
    if args.soundfont:
        converter.soundfont_path = args.soundfont

    def progress_callback(p, msg):
        print(f"[{p}%] {msg}")

    try:
        result = converter.process(
            input_path=args.input,
            mode=args.mode,
            model_type=args.model_type,
            progress_callback=progress_callback
        )
        print(f"Success! Main output: {result['main']}")
        if result['stems']:
            print("Stems created:")
            for k, v in result['stems'].items():
                if v: print(f"  - {k}: {v}")
                
    except Exception as e:
        print(f"Error: {e}")

if __name__ == '__main__':
    run()

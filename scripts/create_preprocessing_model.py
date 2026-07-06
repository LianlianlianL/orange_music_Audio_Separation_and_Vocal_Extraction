import torch
import torch.nn as nn
import os
import sys

# 导入 piano_transcription_inference 的组件
# 我们需要其 Mel 频谱计算逻辑
try:
    from piano_transcription_inference.models import Spectrogram, LogmelFilterBank
except ImportError:
    print("请确保安装了 piano_transcription_inference")
    sys.exit(1)

class AudioPreprocessingModel(nn.Module):
    def __init__(self):
        super().__init__()
        # 这里的参数必须与 piano_transcription_inference 一致
        sample_rate = 16000
        n_fft = 2048
        hop_length = 160
        win_length = 2048
        window = 'hann'
        center = True
        pad_mode = 'reflect'
        n_mels = 229
        fmin = 30
        fmax = 8000

        self.spectrogram_extractor = Spectrogram(
            n_fft=n_fft, 
            hop_length=hop_length, 
            win_length=win_length, 
            window=window, 
            center=center, 
            pad_mode=pad_mode, 
            freeze_parameters=True
        )

        self.logmel_extractor = LogmelFilterBank(
            sr=sample_rate, 
            n_fft=n_fft, 
            n_mels=n_mels, 
            fmin=fmin, 
            fmax=fmax, 
            is_log=True, 
            freeze_parameters=True
        )

    def forward(self, input):
        # input: (batch, length)
        # 1. 计算频谱
        x = self.spectrogram_extractor(input)   # (batch, 1, time_steps, freq_bins)
        # 2. 计算 Log-Mel
        x = self.logmel_extractor(x)    # (batch, 1, time_steps, mel_bins)
        return x

def export_preprocessing():
    model = AudioPreprocessingModel()
    model.eval()

    # 10秒音频，16000Hz
    dummy_input = torch.randn(1, 16000 * 10)

    project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    onnx_path = os.path.join(project_root, 'flutter_app', 'assets', 'models', 'audio_preprocessor.onnx')
    
    print(f"正在导出预处理模型: {onnx_path}")
    
    # 注意：这里我们依然会遇到 STFT 导出问题。
    # 如果 STFT 导出失败，我们可能需要手动实现 Mel 滤波器组。
    try:
        torch.onnx.export(
            model,
            dummy_input,
            onnx_path,
            export_params=True,
            opset_version=17, # STFT 需要 opset 17
            do_constant_folding=True,
            input_names=['audio'],
            output_names=['mel'],
            dynamic_axes={
                'audio': {1: 'length'},
                'mel': {2: 'time'}
            }
        )
        print("✅ 预处理模型导出成功！")
    except Exception as e:
        print(f"❌ 预处理模型导出失败: {e}")

if __name__ == "__main__":
    export_preprocessing()

import torch
import torch.onnx
import os
import sys

# 将项目根目录添加到路径
project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.append(project_root)

def export_piano_transcription():
    """
    专门导出 Piano Transcription 模型
    """
    try:
        from piano_transcription_inference.models import Note_pedal
        print("正在加载 Piano Transcription 模型 (Note_pedal)...")
        
        checkpoint_path = os.path.join(project_root, 'models', 'piano_transcription', 'note_F1=0.9677_pedal_F1=0.9186.pth')
        if not os.path.exists(checkpoint_path):
            print(f"错误: 找不到模型权重 {checkpoint_path}")
            return

        model = Note_pedal(frames_per_second=100, classes_num=88)
        checkpoint = torch.load(checkpoint_path, map_location='cpu')
        model.load_state_dict(checkpoint['model'])
        model.eval()

        onnx_path = os.path.join(project_root, 'flutter_app', 'assets', 'models', 'piano_transcription.onnx')
        os.makedirs(os.path.dirname(onnx_path), exist_ok=True)

        # 尝试将 mode 改为 'reflect' 绕过 ONNX 的 constant padding 限制
        # 这通常对音频转录效果影响极小
        import torch.nn as nn
        import torch.nn.functional as F
        original_pad = F.pad
        
        # 定义一个移动端友好的包装类，直接接受 Mel 频谱作为输入
        # 这样可以绕过 STFT 导出问题，并在 Flutter 端用更高效的方式实现频谱计算
        class PianoTranscriptionMobile(torch.nn.Module):
            def __init__(self, original_model):
                super().__init__()
                self.note_model = original_model.note_model
                self.pedal_model = original_model.pedal_model
            
            def process_crnn(self, model, mel):
                # 模拟 Regress_onset_offset_frame_velocity_CRNN 的 forward 中频谱提取后的部分
                x = mel.transpose(1, 3)
                x = model.bn0(x)
                x = x.transpose(1, 3)
                
                frame_output = model.frame_model(x)
                reg_onset_output = model.reg_onset_model(x)
                reg_offset_output = model.reg_offset_model(x)
                velocity_output = model.velocity_model(x)
                
                # Onset GRU
                x_onset = torch.cat((reg_onset_output, (reg_onset_output ** 0.5) * velocity_output.detach()), dim=2)
                (x_onset, _) = model.reg_onset_gru(x_onset)
                reg_onset_output = torch.sigmoid(model.reg_onset_fc(x_onset))
                
                # Frame GRU
                x_frame = torch.cat((frame_output, reg_onset_output.detach(), reg_offset_output.detach()), dim=2)
                (x_frame, _) = model.frame_gru(x_frame)
                frame_output = torch.sigmoid(model.frame_fc(x_frame))
                
                return reg_onset_output, reg_offset_output, frame_output, velocity_output

            def forward(self, mel):
                # mel shape: (batch_size, 1, time_steps, mel_bins)
                # 分别处理 note 和 pedal
                n_onset, n_offset, n_frame, n_velocity = self.process_crnn(self.note_model, mel)
                
                # Pedal model 结构略有不同，需要根据实际类结构调整
                # 这里简化处理，先只导出 note 部分作为测试，或者尝试通用处理
                return n_onset, n_offset, n_frame, n_velocity

        mobile_model = PianoTranscriptionMobile(model)
        mobile_model.eval()

        # Mel 频谱输入：(1, 1, 1000, 229)
        dummy_mel = torch.randn(1, 1, 1000, 229)

        print(f"开始导出移动端优化版 ONNX (Mel Input): {onnx_path}")
        torch.onnx.export(
            mobile_model,
            dummy_mel,
            onnx_path,
            export_params=True,
            opset_version=11,
            do_constant_folding=True,
            input_names=['mel_input'],
            output_names=['onset', 'offset', 'frame', 'velocity'],
            dynamic_axes={
                'mel_input': {2: 'time'},
                'onset': {1: 'time'},
                'offset': {1: 'time'},
                'frame': {1: 'time'},
                'velocity': {1: 'time'}
            }
        )
        print("✅ Piano Transcription 导出成功！")
        
        # 尝试量化
        quant_path = onnx_path.replace('.onnx', '_quant.onnx')
        quantize_onnx_model(onnx_path, quant_path)

    except Exception as e:
        print(f"❌ 导出失败: {e}")
        import traceback
        traceback.print_exc()

def quantize_onnx_model(onnx_path, quantized_path):
    try:
        from onnxruntime.quantization import quantize_dynamic, QuantType
        import onnx
        
        print(f"正在量化: {os.path.basename(onnx_path)}...")
        
        # 尝试直接量化，不进行显式的形状推断文件写入，或者使用临时目录
        import tempfile
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp_model_path = os.path.join(tmpdir, "model.onnx")
            tmp_quant_path = os.path.join(tmpdir, "quant.onnx")
            
            # 复制到临时目录以避免路径编码问题
            import shutil
            shutil.copy2(onnx_path, tmp_model_path)
            
            quantize_dynamic(
                tmp_model_path,
                tmp_quant_path,
                weight_type=QuantType.QUInt8
            )
            
            # 复制回来
            shutil.copy2(tmp_quant_path, quantized_path)
            
        print(f"✅ 量化完成: {os.path.basename(quantized_path)}")
            
    except Exception as e:
        print(f"⚠️ 量化失败: {e}")

if __name__ == "__main__":
    export_piano_transcription()

import torch
import torch.onnx
import os
import sys
# import demucs.api # 去掉这一行
from demucs.pretrained import get_model
from demucs.apply import apply_model
from onnxruntime.quantization import quantize_dynamic, QuantType
import onnx

def export_demucs():
    """
    导出 Demucs htdemucs 模型到 ONNX
    """
    try:
        print("正在加载 Demucs htdemucs 模型...")
        # 获取预训练模型
        bag = get_model('htdemucs')
        model = bag.models[0] # 获取实际的模型对象
        model.eval()
        
        # Demucs 默认处理 44.1kHz 的音频，双声道
        # dummy_input: (batch, channels, length)
        # 我们使用一个较短的长度进行导出
        dummy_input = torch.randn(1, 2, 44100 * 2) 

        project_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        onnx_path = os.path.join(project_root, 'flutter_app', 'assets', 'models', 'htdemucs.onnx')
        os.makedirs(os.path.dirname(onnx_path), exist_ok=True)

        print(f"开始导出 Demucs ONNX: {onnx_path}")
        
        # 尝试绕过 STFT 导出问题：
        # 我们创建一个包装类，它接受 STFT 后的实部和虚部作为输入
        class DemucsMobileWrapper(torch.nn.Module):
            def __init__(self, original_model):
                super().__init__()
                self.model = original_model
                
            def forward(self, mix_stft_real, mix_stft_imag, mix_raw):
                # 重新组合复数张量 (在内部使用，ONNX 导出时会追踪)
                z = torch.complex(mix_stft_real, mix_stft_imag)
                
                # 模拟 HTDemucs.forward 的中间部分
                mag = self.model._magnitude(z)
                x = mag
                B, C, Fq, T = x.shape
                
                # 归一化
                mean = x.mean(dim=(1, 2, 3), keepdim=True)
                std = x.std(dim=(1, 2, 3), keepdim=True)
                x = (x - mean) / (1e-5 + std)
                
                xt = mix_raw
                meant = xt.mean(dim=(1, 2), keepdim=True)
                stdt = xt.std(dim=(1, 2), keepdim=True)
                xt = (xt - meant) / (1e-5 + stdt)
                
                # ... 这里需要非常完整的实现，或者直接调用内部组件
                # 鉴于 HTDemucs 结构复杂，我们尝试直接调用其核心处理逻辑
                # 但由于 forward 中耦合了 STFT，我们需要稍微 hack 一下
                
                # 我们可以暂时只导出特征提取部分，或者寻找现成的 ONNX 模型
                # 考虑到时间，我们先尝试一个更简单的办法：强制使用旧版 STFT 导出
                return x, xt # 暂时仅作为测试占位

        # 实际上，Demucs 官方有提供转换为 TorchScript 的方法
        # 我们可以先转 TorchScript，再转 ONNX
        
        # 终极方案：由于 Demucs 导出极其复杂，建议在移动端使用更轻量级的模型（如 Spleeter 的 ONNX 版）
        # 或者使用预先转换好的模型。
        # 为了不耽误进度，我们先专注于钢琴转录模型的集成，那个已经成功了。
        print("⚠️ Demucs 导出逻辑复杂，优先进行钢琴转录模型的 Flutter 集成。")
        return
        
        # 量化
        quant_path = onnx_path.replace('.onnx', '_quant.onnx')
        quantize_onnx_model(onnx_path, quant_path)

    except Exception as e:
        print(f"❌ Demucs 导出失败: {e}")
        import traceback
        traceback.print_exc()

def quantize_onnx_model(onnx_path, quantized_path):
    try:
        print(f"正在量化: {os.path.basename(onnx_path)}...")
        import tempfile
        import shutil
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp_model_path = os.path.join(tmpdir, "model.onnx")
            tmp_quant_path = os.path.join(tmpdir, "quant.onnx")
            shutil.copy2(onnx_path, tmp_model_path)
            
            quantize_dynamic(
                tmp_model_path,
                tmp_quant_path,
                weight_type=QuantType.QUInt8
            )
            shutil.copy2(tmp_quant_path, quantized_path)
        print(f"✅ 量化完成: {os.path.basename(quantized_path)}")
    except Exception as e:
        print(f"⚠️ 量化失败: {e}")

if __name__ == "__main__":
    export_demucs()

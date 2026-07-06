import torch
import onnx
import sys
import traceback

print(f"Python executable: {sys.executable}")

try:
    # Demucs v2 API
    from demucs.pretrained import load_pretrained
    from demucs.model import Demucs
    print("demucs (v2) 导入成功！")
except ImportError as e:
    print("导入失败！确保安装的是 demucs<3")
    traceback.print_exc()
    exit(1)

# 定义一个包装类
class DemucsWrapper(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model
        
    def forward(self, mix):
        # Demucs v2 的 forward 应该可以直接调用
        # 且不包含 STFT (它是纯卷积)
        return self.model(mix)

def export_demucs():
    print("1. 加载 Demucs 模型 (demucs)...")
    try:
        # v2 默认模型通常叫 'demucs' 或 'demucs_extra'
        model = load_pretrained('demucs')
        model.cpu()
        model.eval()
    except Exception as e:
        print(f"加载模型失败: {e}")
        # 尝试备用名称
        try:
            print("尝试加载 demucs_extra...")
            model = load_pretrained('demucs_extra')
            model.cpu()
            model.eval()
        except Exception as e2:
            print(f"备用加载也失败: {e2}")
            return
    
    # 包装模型
    wrapped_model = DemucsWrapper(model)

    # 2. 定义输入尺寸
    segment_samples = 343980
    dummy_input = torch.randn(1, 2, segment_samples)

    output_path = "demucs_mobile.onnx"
    
    print(f"2. 正在导出为 ONNX (Opset 11)...")
    try:
        # Demucs v2 是纯卷积，Opset 11 应该完美支持
        torch.onnx.export(
            wrapped_model,
            dummy_input,
            output_path,
            opset_version=11,
            input_names=["input"],
            output_names=["output"],
            dynamic_axes=None  # 静态尺寸
        )
        print(f"导出成功: {output_path}")
    except Exception as e:
        print(f"导出失败: {e}")
        traceback.print_exc()
        return

    # 3. 尝试简化模型
    try:
        import onnxsim
        print("3. 正在使用 onnx-simplifier 简化模型...")
        model_sim, check = onnxsim.simplify(output_path)
        if check:
            sim_output_path = "assets/models/demucs.onnx"
            onnx.save(model_sim, sim_output_path)
            print(f"✅ 简化完成！已自动覆盖到项目路径: {sim_output_path}")
            print("请重新运行 Flutter 应用测试。")
        else:
            print("❌ 模型简化校验失败")
    except ImportError:
        print("⚠️ 未安装 onnx-simplifier，跳过简化步骤。")

if __name__ == "__main__":
    export_demucs()

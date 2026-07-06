import sys
import torch
from pathlib import Path
import os

# Add official demucs to path
sys.path.insert(0, os.path.join("tools", "demucs_official"))

from demucs.pretrained import get_model
from demucs.htdemucs import HTDemucs

def export():
    model_name = "htdemucs"
    print(f"Loading model {model_name}...")
    model = get_model(model_name)

    # HTDemucs in official repo has STFT inside forward()
    # We need to find the core model
    if isinstance(model, HTDemucs):
        core_model = model
    elif hasattr(model, 'models') and isinstance(model.models[0], HTDemucs):
        core_model = model.models[0]
    else:
        raise TypeError("Unsupported model type")

    core_model.eval()
    
    # We need to ensure the model is on CPU
    core_model.cpu()

    # Dummy input: Just waveform!
    # HTDemucs input is (batch, channels, samples)
    # Using a typical training segment length or similar
    dummy_input = torch.randn(1, 2, 343980)

    output_path = os.path.join("assets", "models", "htdemucs_full.onnx")
    
    # Ensure output dir exists
    os.makedirs(os.path.dirname(output_path), exist_ok=True)

    print(f"Exporting to {output_path}...")
    try:
        torch.onnx.export(
            core_model,
            dummy_input,
            output_path,
            export_params=True,
            opset_version=17, # Try 17 to support STFT
            do_constant_folding=True,
            input_names=['input'],
            output_names=['output'],
            # dynamic_axes might be risky if STFT requires fixed size, but let's try
            # dynamic_axes={'input': {0: 'batch', 2: 'time'}, 'output': {0: 'batch', 2: 'time'}}
        )
        print(f"Done: {output_path}")
    except Exception as e:
        print(f"Export failed: {e}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    export()

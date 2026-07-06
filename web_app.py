import os
import sys
import shutil
import streamlit as st

# 环境初始化
try:
    import imageio_ffmpeg
    ffmpeg_exe = imageio_ffmpeg.get_ffmpeg_exe()
    os.environ["IMAGEIO_FFMPEG_EXE"] = ffmpeg_exe
    
    # 抑制 pydub 找不到 ffmpeg 的 RuntimeWarning (因为我们随后会手动设置 converter)
    import warnings
    warnings.filterwarnings("ignore", category=RuntimeWarning, module="pydub.utils")
    
    from pydub import AudioSegment
    AudioSegment.converter = ffmpeg_exe
except Exception:
    pass

sys.path.append(os.getcwd())
from src.core import MusicConverter

st.set_page_config(page_title="Music Piano Converter", page_icon="🎹", layout="wide")
st.title("🎹 音乐处理与钢琴转换")

# UI 样式
st.markdown("""
<style>
.stButton > button {
    width: 100%;
    background-color: #2e86de;
    color: white;
    font-size: 18px;
    padding: 12px 0;
    border-radius: 8px;
    border: none;
    box-shadow: 0 4px 6px rgba(0,0,0,0.1);
    transition: all 0.3s ease;
}
.stButton > button:hover {
    background-color: #54a0ff;
    transform: translateY(-2px);
    box-shadow: 0 6px 8px rgba(0,0,0,0.15);
}
.stProgress > div > div > div > div {
    background-color: #2e86de;
}
h1 {
    color: #2e86de;
    font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
}
</style>
""", unsafe_allow_html=True)

# 侧边栏
with st.sidebar:
    st.title("🎹 控制面板")
    st.markdown("---")
    st.header("1. 处理模式")
    mode_map = {
        "人声分离": "separate",
        "伴奏提取": "accompaniment",
        "纯钢琴": "pure_piano",
        "增强纯钢琴": "enhanced_piano",
        "人声+钢琴": "vocal_piano"
    }
    mode_label = st.radio("选择功能", list(mode_map.keys()), index=3)
    if not mode_label:
        mode = "enhanced_piano" # Fallback default
    else:
        mode = mode_map[mode_label]
    
    st.markdown("---")
    st.header("2. 高级设置")
    device = st.selectbox("计算设备", ["cuda", "cpu"], index=1, help="如果有 NVIDIA 显卡请选择 cuda 加速") or "cpu"
    
    model_type = st.selectbox(
        "转录模型 (Transcription Model)", 
        ["piano_transcription", "basic_pitch"], 
        index=0,
        help="Piano Transcription: 适合钢琴曲转录 (默认)；Basic Pitch: 适合吉他、人声等多乐器转录"
    ) or "piano_transcription"
    
    default_sf = os.path.join("models", "SalamanderGrandPiano-master", "SalamanderGrandPiano-master", "Salamander Grand Piano V3.sfz")
    sf_path = st.text_input("SoundFont 路径", value=default_sf, help="指定 .sf2 或 .sfz 文件路径以获得更好的音色")
    
    st.markdown("---")
    st.info("ℹ️ 提示：使用“增强纯钢琴”模式并加载高质量 SoundFont 可获得最佳效果。")

# 主界面
st.subheader("📂 任务工作区")
uploaded_files = st.file_uploader("拖拽或点击上传音频 (支持多文件, mp3, wav, flac, m4a)", type=["mp3", "wav", "flac", "m4a"], accept_multiple_files=True)

def save_uploaded_file(uploaded_file, dest_path):
    os.makedirs(os.path.dirname(dest_path), exist_ok=True)
    with open(dest_path, "wb") as f:
        f.write(uploaded_file.getbuffer())
    return dest_path

def sanitize_filename(name):
    import uuid
    ext = os.path.splitext(name)[1]
    return f"f_{uuid.uuid4().hex[:8]}{ext}"

if st.button("🚀 开始处理队列"):
    if not uploaded_files:
        st.warning("⚠️ 请先上传音频文件")
    else:
        # 初始化转换器 (注入配置)
        converter = MusicConverter()
        converter.device = device
        if sf_path:
            converter.soundfont_path = sf_path

        total_files = len(uploaded_files)
        main_progress = st.progress(0)
        st.write(f"📊 队列总数: {total_files} 个文件")
        
        for idx, uploaded in enumerate(uploaded_files):
            try:
                current_file_num = idx + 1
                st.markdown(f"**[{current_file_num}/{total_files}] 正在处理: {uploaded.name}**")
                
                # 准备路径
                safe_name = sanitize_filename(uploaded.name)
                input_path = os.path.join("data", "input", safe_name)
                save_uploaded_file(uploaded, input_path)
                
                # 进度条控制
                progress_bar = st.progress(0)
                status_text = st.empty()
                
                def update_ui_progress(p, msg):
                    progress_bar.progress(p)
                    status_text.text(msg)
                
                # 调用核心逻辑
                result = converter.process(
                    input_path=input_path,
                    mode=mode,
                    model_type=model_type,
                    progress_callback=update_ui_progress
                )
                
                st.success(f"✅ {uploaded.name} 处理完成")
                
                # 展示结果
                if result.get('main') and os.path.exists(result['main']):
                    st.markdown("#### 🎹 生成结果 (Main Output)")
                    st.audio(result['main'])
                
                stems = result.get('stems')
                if stems and isinstance(stems, dict):
                    st.markdown("#### 📂 附属文件 (Stems)")
                    col1, col2 = st.columns(2)
                    
                    with col1:
                        v = stems.get('vocals')
                        if v and os.path.exists(v):
                            st.caption("人声 (Vocals)")
                            st.audio(v)
                    with col2:
                        # 优先展示伴奏，其次展示其他分轨
                        acc = stems.get('accompaniment')
                        piano_track = stems.get('piano_track')
                        other = stems.get('other')
                        
                        if piano_track and os.path.exists(piano_track):
                            st.caption("纯钢琴轨道 (Piano Track)")
                            st.audio(piano_track)
                        elif acc and os.path.exists(acc):
                            st.caption("纯伴奏 (Accompaniment)")
                            st.audio(acc)
                        elif other and os.path.exists(other):
                            st.caption("其他乐器 (Other)")
                            st.audio(other)
                
                main_progress.progress((idx + 1) / total_files)
                
            except Exception as e:
                st.error(f"❌ 处理 {uploaded.name} 时发生错误: {str(e)}")
                # 打印详细堆栈以便调试
                import traceback
                st.code(traceback.format_exc())

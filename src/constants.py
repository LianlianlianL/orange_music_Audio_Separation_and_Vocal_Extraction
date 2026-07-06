from enum import Enum

class Stems(str, Enum):
    VOCALS = "vocals"
    DRUMS = "drums"
    BASS = "bass"
    OTHER = "other"
    ACCOMPANIMENT = "accompaniment"
    PIANO_TRACK = "piano_track"

class ProcessingMode(str, Enum):
    SEPARATE = "separate"
    ACCOMPANIMENT = "accompaniment"
    PURE_PIANO = "pure_piano"
    ENHANCED_PIANO = "enhanced_piano"
    VOCAL_PIANO = "vocal_piano"

class ModelType(str, Enum):
    PIANO_TRANSCRIPTION = "piano_transcription"
    BASIC_PITCH = "basic_pitch"

class TaskStatus(str, Enum):
    PENDING = "pending"
    PROCESSING = "processing"
    COMPLETED = "completed"
    FAILED = "failed"

# Default Configuration
DEFAULT_CHUNK_SIZE = 30
DEFAULT_SAMPLE_RATE = 44100

enum ProcessingMode {
  separate,
  accompaniment,
  purePiano,
  enhancedPiano,
  vocalPiano,
}

enum ModelType {
  pianoTranscription,
  basicPitch,
}

class ProcessingTask {
  final String id;
  final String inputPath;
  final ProcessingMode mode;
  final ModelType modelType;
  double progress;
  String statusMessage;
  String? mainOutputPath;
  Map<String, String> stems;
  String? enhancedMidiPath;

  ProcessingTask({
    required this.id,
    required this.inputPath,
    required this.mode,
    required this.modelType,
    this.progress = 0.0,
    this.statusMessage = '等待中...',
    this.stems = const {},
  });
}

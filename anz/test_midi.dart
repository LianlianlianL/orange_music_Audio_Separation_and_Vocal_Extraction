import 'package:dart_midi_pro/dart_midi_pro.dart';

void main() {
  final tne = TrackNameEvent();
  tne.text = 'Test';
  tne.deltaTime = 0;
  
  final ste = SetTempoEvent();
  ste.microsecondsPerBeat = 500000;
  ste.deltaTime = 0;
  
  final eot = EndOfTrackEvent();
  eot.deltaTime = 0;
  
  print('Success');
}

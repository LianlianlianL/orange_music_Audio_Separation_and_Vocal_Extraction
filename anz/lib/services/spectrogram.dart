import 'dart:math' as math;
import 'dart:typed_data';
import 'package:fftea/fftea.dart';

class SpectrogramUtils {
  static const int nfft = 4096;
  static const int hopLength = 1024; // 4096 // 4

  /// Generates the input tensor for HTDemucs (Spectrogram + CAC)
  /// Input: [audioChannels] list of Float32List (L, R)
  /// Output: Float32List flattened tensor [1, 4, F, T]
  static Float32List computeHTDemucsSpectrogram(List<Float32List> audioChannels) {
    // 1. standalone_spec logic
    // Pad manually: pad = hl // 2 * 3 = 1536
    const int pad = 1536;
    final int length = audioChannels[0].length;
    final int le = (length / hopLength).ceil();
    
    // Total padded length calculation from htdemucs.py:
    // x = pad1d(x, (pad, pad + le * hl - x.shape[-1]), mode="reflect")
    final int rightPad = pad + le * hopLength - length;
    
    final List<List<Float64List>> complexSpecs = []; // [Channel][Frame][Freq (Complex)]
    
    for (var channelData in audioChannels) {
      // Manual Padding (Reflect)
      final paddedData = _padReflect(channelData, pad, rightPad);
      
      // STFT
      // Note: htdemucs calls spectro(x) which calls stft(center=True)
      // center=True pads the input with nfft//2 on both sides.
      // So we need to pad AGAIN or handle it in STFT.
      // Let's implement STFT with center=True behavior.
      final stftOut = _stft(paddedData, nfft, hopLength, center: true);
      
      // Slice: z[..., :-1, :] -> Remove last frequency bin?
      // PyTorch stft returns (N/2 + 1) bins. 4096 -> 2049 bins.
      // htdemucs removes the last bin -> 2048 bins.
      // And slice time: z[..., 2: 2 + le]
      
      final slicedFrames = <Float64List>[];
      final int timeFrames = stftOut.length;
      
      // Slicing time logic from htdemucs.py: z = z[..., 2: 2 + le]
      // We need to be careful about indices.
      // If stftOut has T frames, we take from index 2 to 2+le.
      for (int t = 2; t < 2 + le && t < timeFrames; t++) {
        // Remove last frequency bin (index 2048), keep 0..2047
        final frame = stftOut[t];
        // frame is 2049 complex numbers (Float64List of size 4098)
        // We want 2048 complex numbers (Float64List of size 4096)
        final slicedFrame = Float64List(4096);
        for (int i = 0; i < 4096; i++) {
          slicedFrame[i] = frame[i];
        }
        slicedFrames.add(slicedFrame);
      }
      
      complexSpecs.add(slicedFrames);
    }
    
    // 2. standalone_magnitude (CAC=True)
    // Input: [Channel][Frame][Freq_Complex]
    // Output: [1, 4, Freq, Frame] flattened
    // Channels: L_Real, L_Imag, R_Real, R_Imag
    
    final int frames = complexSpecs[0].length;
    final int freqs = 2048;
    final int outChannels = 4;
    
    final Float32List output = Float32List(1 * outChannels * freqs * frames);
    
    // Layout: B=1, C=4, F=2048, T=frames
    // Flattened index: c * (F * T) + f * T + t  <-- Wait, ONNX format usually NCHW?
    // ONNX shape: [1, 4, 2048, T]
    // So strides:
    // C stride: 2048 * T
    // F stride: T
    // T stride: 1
    
    for (int t = 0; t < frames; t++) {
      for (int f = 0; f < freqs; f++) {
        // Channel 0: L Real
        double lReal = complexSpecs[0][t][f * 2];
        // Channel 1: L Imag
        double lImag = complexSpecs[0][t][f * 2 + 1];
        // Channel 2: R Real
        double rReal = complexSpecs[1][t][f * 2];
        // Channel 3: R Imag
        double rImag = complexSpecs[1][t][f * 2 + 1];
        
        int idx = f * frames + t; // Base index for (f, t) in a channel plane
        
        output[0 * (freqs * frames) + idx] = lReal;
        output[1 * (freqs * frames) + idx] = lImag;
        output[2 * (freqs * frames) + idx] = rReal;
        output[3 * (freqs * frames) + idx] = rImag;
      }
    }
    
    return output;
  }

  /// Inverse HTDemucs Spectrogram
  /// Input: [specOut] flattened tensor [1, 4, 4, 2048, T]
  /// Output: List<Float32List> [L, R] waveform
  static List<List<Float32List>> inverseHTDemucsSpectrogram(Float32List specOut, int frames) {
    const int sources = 4;
    const int channels = 2; // Complex channels in specOut = 4 (L_Re, L_Im, R_Re, R_Im)
    const int freqs = 2048;
    const int nfft = 4096;
    const int hopLength = 1024;
    
    // We sum all sources to get the separated mix? 
    // Wait, the model returns separated sources. 
    // Usually we want to return ALL sources separately?
    // AudioService expects separate files for drums, bass, etc.
    // But here we are just helping AudioService decode the tensor.
    // AudioService handles writing to files.
    // But this function returns `List<Float32List>`?
    // It should return `Map<String, List<Float32List>>` or `List<List<Float32List>>` (Source -> Channel).
    
    // Let's return List<List<Float32List>> dimensions: [Source][Channel] -> Waveform
    
    final List<List<Float32List>> result = [];
    
    // specOut layout: [1, 4, 4, 2048, T]
    // Strides:
    // T stride: 1
    // F stride: T
    // C stride: F * T
    // S stride: C * F * T
    
    final int tStride = 1;
    final int fStride = frames;
    final int cStride = freqs * frames;
    final int sStride = 4 * freqs * frames;
    
    // Pre-calculate Window and NOLA normalization curve
    final window = Float64List(nfft);
    for (int i = 0; i < nfft; i++) {
      window[i] = 0.5 * (1 - math.cos(2 * math.pi * i / nfft));
    }
    
    // Calculate NOLA divisor (Sum of squared windows)
    // We can compute it lazily or assume constant?
    // For Hann with hop=N/4, it is constant.
    // Sum[w(n-kH)^2] = constant.
    // Let's compute it to be safe and accurate.
    // Since output length depends on frames, we can compute a buffer.
    // But for efficiency, maybe just constant scalar?
    // Hann^2 sum for 75% overlap is 1.5 * N / hop? No.
    // Let's implement full OLA divisor buffer to handle edges correctly.
    // But edges are discarded by Center trim?
    // PyTorch `center=True` pads input.
    // Output is also padded. We trim it later.
    
    // We will compute the full padded waveform, then trim.
    final int paddedLength = frames * hopLength + nfft; // Approx
    final nolaBuffer = Float64List(paddedLength);
    for (int t = 0; t < frames; t++) {
      final int start = t * hopLength;
      for (int i = 0; i < nfft; i++) {
        if (start + i < paddedLength) {
          double w = window[i];
          nolaBuffer[start + i] += w * w;
        }
      }
    }
    
    final fft = FFT(nfft);
    final double scale = math.sqrt(nfft); // Inverse of 1/sqrt(N)
    
    for (int s = 0; s < sources; s++) {
      final List<Float32List> sourceChannels = [];
      
      for (int c = 0; c < 2; c++) { // L, R
        final waveform = Float64List(paddedLength);
        
        for (int t = 0; t < frames; t++) {
          // Reconstruct spectrum for this frame
          // specOut has 2048 bins (0..2047). We need 2049 bins for IRFFT?
          // Or 4096 bins (full complex)?
          // PyTorch stft(onesided=True) returns 2049 bins.
          // HTDemucs stripped the last bin -> 2048 bins.
          // So we assume the last bin (Nyquist) is zero? Or mirror?
          // Usually Nyquist is real. We set it to 0.
          
          final complexFrame = Float64List(nfft * 2);
          
          // Re index: s, c*2, f, t
          // Im index: s, c*2+1, f, t
          int reOffset = s * sStride + (c * 2) * cStride + t;
          int imOffset = s * sStride + (c * 2 + 1) * cStride + t;
          
          for (int f = 0; f < freqs; f++) {
            // Bin f
            double re = specOut[reOffset + f * fStride];
            double im = specOut[imOffset + f * fStride];
            
            // Fill positive freq
            complexFrame[f * 2] = re * scale;
            complexFrame[f * 2 + 1] = im * scale;
            
            // Fill negative freq (conjugate symmetry) for real IFFT
            // Index nfft - f
            if (f > 0) {
              int negIdx = nfft - f;
              complexFrame[negIdx * 2] = re * scale;
              complexFrame[negIdx * 2 + 1] = -im * scale;
            }
          }
          
          // IFFT
          // Convert to Float64x2List for fftea
          final complexList = Float64x2List(nfft);
          for (int i = 0; i < nfft; i++) {
            complexList[i] = Float64x2(complexFrame[i * 2], complexFrame[i * 2 + 1]);
          }
          
          final timeFrame = fft.realInverseFft(complexList);
          // Result is Float64List (real part, already scaled by 1/N by fftea)
          // We assume input was scaled by sqrt(N), so result is scaled by 1/sqrt(N).
          // This matches PyTorch normalized ISTFT.
          
          // OLA
          final int start = t * hopLength;
          for (int i = 0; i < nfft; i++) {
            if (start + i < paddedLength) {
              waveform[start + i] += timeFrame[i] * window[i];
            }
          }
        }
        
        // Normalize by NOLA
        final Float32List finalWave = Float32List(paddedLength);
        for (int i = 0; i < paddedLength; i++) {
          double div = nolaBuffer[i];
          if (div > 1e-6) {
            finalWave[i] = (waveform[i] / div);
          } else {
            finalWave[i] = waveform[i];
          }
        }
        
        // Trim padding?
        // PyTorch center=True pads nfft//2.
        // We should remove nfft//2 from start.
        // And end?
        // htdemucs `_ispec`:
        // z = F.pad(z, (0, 0, 0, 1)) ... padding logic ...
        // x = x[..., pad: pad + length]
        // pad = hl // 2 * 3 = 1536.
        // We padded 1536 in analysis.
        // In synthesis, we should strip 1536.
        
        const int pad = 1536;
        final int outputLen = finalWave.length - 2 * pad;
        if (outputLen > 0) {
           final Float32List trimmed = Float32List(outputLen);
           for(int i=0; i<outputLen; i++) {
             trimmed[i] = finalWave[pad + i];
           }
           sourceChannels.add(trimmed);
        } else {
           sourceChannels.add(finalWave); // Fallback
        }
      }
      result.add(sourceChannels);
    }
    
    return result;
  }

  static Float32List _padReflect(Float32List data, int left, int right) {
    final int len = data.length;
    final out = Float32List(len + left + right);
    
    // Center
    for (int i = 0; i < len; i++) {
      out[left + i] = data[i];
    }
    
    // Left Reflect (1, 2, 3... -> 2, 1 | 1, 2, 3) - PyTorch "reflect" mode
    // PyTorch reflect: pads with the reflection of the vector mirrored on the first and last values of the vector along each axis.
    // e.g. [1, 2, 3, 4] pad(2, 2) -> [3, 2, 1, 2, 3, 4, 3, 2]
    // Indices:
    // Left: out[left - 1 - i] = data[1 + i]  (Skip index 0?)
    // Wait, PyTorch reflect docs:
    // "Pads with the reflection of the vector mirrored on the first and last values of the vector along each axis."
    // Input: 1, 2, 3, 4
    // Pad left 2: 3, 2 | 1, 2, 3, 4
    // Pad right 2: 1, 2, 3, 4 | 3, 2
    
    for (int i = 0; i < left; i++) {
      // data index: 1 + i
      int idx = 1 + i;
      if (idx < len) {
        out[left - 1 - i] = data[idx];
      }
    }
    
    for (int i = 0; i < right; i++) {
      // data index: len - 2 - i
      int idx = len - 2 - i;
      if (idx >= 0) {
        out[left + len + i] = data[idx];
      }
    }
    
    return out;
  }

  static List<Float64List> _stft(Float32List signal, int nfft, int hopLength, {bool center = true}) {
    Float32List input = signal;
    if (center) {
      // Pad with nfft // 2, reflect
      input = _padReflect(signal, nfft ~/ 2, nfft ~/ 2);
    }
    
    final int len = input.length;
    final int nFrames = (len - nfft) ~/ hopLength + 1;
    final List<Float64List> output = [];
    
    // Hann Window
    final window = Float64List(nfft);
    for (int i = 0; i < nfft; i++) {
      window[i] = 0.5 * (1 - math.cos(2 * math.pi * i / nfft));
    }
    
    // STFT
    final fft = FFT(nfft);
    
    // PyTorch normalized=True: multiply by 1/sqrt(nfft) ??
    // No, PyTorch docs say: "normalized (bool, optional) – controls whether to return the normalized STFT results"
    // "If True, then the output is scaled by 1/sqrt(N)"
    // BUT, we usually apply this to the window? No, applied to the result.
    // However, `spectro` code says: window = hann_window(nfft) (unscaled)
    // Then stft(..., normalized=True).
    // So we should scale the result.
    final double scale = 1.0 / math.sqrt(nfft);
    
    for (int i = 0; i < nFrames; i++) {
      final int start = i * hopLength;
      final chunk = Float64List(nfft);
      
      // Apply Window
      for (int j = 0; j < nfft; j++) {
        if (start + j < len) {
          chunk[j] = input[start + j] * window[j];
        }
      }
      
      // FFT
      final freqData = fft.realFft(chunk); 
      
      // Now we have nfft complex numbers (Float64x2List). We need the first nfft/2 + 1.
      // (0 to 2048 inclusive)
      final int bins = nfft ~/ 2 + 1;
      final frameResult = Float64List(bins * 2);
      
      for (int b = 0; b < bins; b++) {
        final complex = freqData[b];
        frameResult[b * 2] = complex.x * scale;
        frameResult[b * 2 + 1] = complex.y * scale;
      }
      
      output.add(frameResult);
    }
    
    return output;
  }
}

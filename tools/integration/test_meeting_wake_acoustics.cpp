// Mac file-only probe. Link to sherpa-onnx 1.13.4's host C API; never opens a microphone.
#include <sherpa-onnx/c-api/c-api.h>
#include <algorithm>
#include <cstdlib>
#include <iostream>
#include <string>
#include <vector>

int main(int argc, char **argv) {
  // model-dir vad-model (case-name wav-path prefix-silence-seconds expected-outcome)...
  if (argc < 7 || (argc - 3) % 4 != 0) return 2;
  std::string root = argv[1], vad_path = argv[2];
  std::string encoder = root + "/encoder.onnx", decoder = root + "/decoder.onnx";
  std::string joiner = root + "/joiner.onnx", tokens = root + "/tokens.txt";
  std::string keywords = root + "/keywords.txt";
  SherpaOnnxKeywordSpotterConfig config{};
  config.feat_config.sample_rate = 16000;
  config.feat_config.feature_dim = 80;
  config.model_config.transducer.encoder = encoder.c_str();
  config.model_config.transducer.decoder = decoder.c_str();
  config.model_config.transducer.joiner = joiner.c_str();
  config.model_config.tokens = tokens.c_str();
  config.model_config.num_threads = 1;
  config.model_config.provider = "cpu";
  config.max_active_paths = 4;
  config.num_trailing_blanks = 1;
  config.keywords_score = 1.0;
  config.keywords_threshold = 0.25;
  config.keywords_file = keywords.c_str();
  const auto *spotter = SherpaOnnxCreateKeywordSpotter(&config);
  if (!spotter) return 3;
  std::cout << "{\"runtimeVersion\":\"" << SherpaOnnxGetVersionStr()
            << "\",\"frameSize\":512,\"cases\":[";
  for (int arg = 3; arg < argc; arg += 4) {
    const auto *wave = SherpaOnnxReadWave(argv[arg + 1]);
    if (!wave || wave->sample_rate != 16000) return 4;
    int prefix = std::atoi(argv[arg + 2]) * 16000;
    std::vector<float> audio(prefix, 0);
    audio.insert(audio.end(), wave->samples, wave->samples + wave->num_samples);
    audio.insert(audio.end(), 16000 * 9, 0); // allows keyword-only capture to time out
    const auto *stream = SherpaOnnxCreateKeywordStream(spotter);
    SherpaOnnxVadModelConfig vad_config{};
    vad_config.silero_vad.model = vad_path.c_str();
    vad_config.silero_vad.threshold = 0.5;
    vad_config.silero_vad.min_speech_duration = 0.1;
    vad_config.silero_vad.min_silence_duration = 0.2;
    vad_config.silero_vad.max_speech_duration = 20;
    vad_config.silero_vad.window_size = 512;
    vad_config.sample_rate = 16000;
    vad_config.num_threads = 1;
    vad_config.provider = "cpu";
    const auto *vad = SherpaOnnxCreateVoiceActivityDetector(&vad_config, 60);
    if (!vad || !stream) return 5;
    if (arg != 3) std::cout << ',';
    std::cout << "{\"name\":\"" << argv[arg] << "\",\"expected\":\""
              << argv[arg + 3] << "\",\"sampleRate\":16000,\"prefixSamples\":"
              << prefix << ",\"waveSamples\":" << wave->num_samples << ",\"frames\":[";
    for (size_t start = 0; start < audio.size(); start += 512) {
      int count = std::min<size_t>(512, audio.size() - start);
      SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, audio.data() + start, count);
      int speech = SherpaOnnxVoiceActivityDetectorDetected(vad);
      SherpaOnnxVoiceActivityDetectorClear(vad);
      SherpaOnnxOnlineStreamAcceptWaveform(stream, 16000, audio.data() + start, count);
      if (start) std::cout << ',';
      std::cout << "{\"startSample\":" << start << ",\"endSample\":" << start + count
                << ",\"isSpeech\":" << (speech ? "true" : "false") << ",\"hits\":[";
      bool hit = false;
      while (SherpaOnnxIsKeywordStreamReady(spotter, stream)) {
        SherpaOnnxDecodeKeywordStream(spotter, stream);
        const auto *result = SherpaOnnxGetKeywordResult(spotter, stream);
        if (result && result->keyword && result->keyword[0]) {
          if (hit) std::cout << ',';
          hit = true;
          std::string json(result->json);
          json.pop_back();
          std::cout << json << ",\"hitEndSample\":" << start + count << '}';
          SherpaOnnxResetKeywordStream(spotter, stream);
        }
        if (result) SherpaOnnxDestroyKeywordResult(result);
      }
      std::cout << "]}";
    }
    std::cout << "]}";
    SherpaOnnxDestroyVoiceActivityDetector(vad);
    SherpaOnnxDestroyOnlineStream(stream);
    SherpaOnnxFreeWave(wave);
  }
  std::cout << "]}\n";
  SherpaOnnxDestroyKeywordSpotter(spotter);
}

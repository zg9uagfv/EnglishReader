import SwiftUI

struct PreferencesView: View {
    @ObservedObject var llmConfiguration: LLMConfiguration
    @Binding var accent: EnglishAccent
    @Binding var selectedVoiceIdentifier: String
    @Binding var speed: Double
    @Binding var childMode: Bool
    @Binding var wordPause: Double
    @Binding var fontStyle: DisplayFontStyle
    @Binding var fontSize: Double

    var body: some View {
        Form {
                Section {
                    Picker("英语口音", selection: $accent) {
                        ForEach(EnglishAccent.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("系统声音", selection: $selectedVoiceIdentifier) {
                        Text("自动选择高品质").tag("")
                        ForEach(EnglishVoiceOption.available(for: accent)) { voice in
                            Text(voice.displayName).tag(voice.identifier)
                        }
                    }

                    LabeledContent("语速") {
                        HStack {
                            Slider(value: $speed, in: 0.18...0.68, step: 0.01)
                            Text(speedLabel).monospacedDigit().frame(width: 96, alignment: .trailing)
                        }
                    }
                } header: {
                    Label("TTS 发音", systemImage: "speaker.wave.2.fill")
                } footer: {
                    Text("此语速同时控制系统朗读与上传音频播放。点词使用本地即时发音。")
                }

                Section {
                    Toggle("启用儿童模式", isOn: $childMode)
                    if childMode {
                        LabeledContent("单词间停顿") {
                            HStack {
                                Slider(value: $wordPause, in: 0.5...5.0, step: 0.5)
                                Text(String(format: "%.1f 秒", wordPause))
                                    .monospacedDigit()
                                    .frame(width: 62, alignment: .trailing)
                            }
                        }
                    }
                } header: {
                    Label("儿童模式", systemImage: "figure.and.child.holdinghands")
                } footer: {
                    Text("逐个朗读单词，并按设置时间停顿。")
                }

                Section {
                    Picker("字体", selection: $fontStyle) {
                        ForEach(DisplayFontStyle.allCases) { style in
                            Text(style.rawValue).tag(style)
                        }
                    }
                    LabeledContent("字号") {
                        HStack {
                            Slider(value: $fontSize, in: 14...34, step: 1)
                            Text("\(Int(fontSize)) pt")
                                .monospacedDigit()
                                .frame(width: 52, alignment: .trailing)
                        }
                    }
                    Text("The quick brown fox jumps over the lazy dog.")
                        .font(.system(size: min(fontSize, 26), design: fontStyle.design))
                        .padding(.vertical, 6)
                } header: {
                    Label("文字显示", systemImage: "textformat.size")
                }

                Section {
                    TextField("服务地址（例如 https://…/v1）", text: $llmConfiguration.baseURL)
                    TextField("语音转文字模型", text: $llmConfiguration.transcriptionModel)
                    TextField("文字转语音模型", text: $llmConfiguration.speechModel)
                    SecureField("API Key", text: $llmConfiguration.apiKey)
                } header: {
                    Label("大模型语音服务", systemImage: "brain.head.profile")
                } footer: {
                    Text("兼容 OpenAI 的 /audio/transcriptions 与 /audio/speech 接口。API Key 仅保存在本机钥匙串。")
                }

                Section {
                    Toggle("优先使用本地 Whisper（仅 macOS）", isOn: $llmConfiguration.localWhisperEnabled)
                    if llmConfiguration.localWhisperEnabled {
                        TextField("模型名", text: $llmConfiguration.localWhisperModel)
                        TextField("模型目录（可选）", text: $llmConfiguration.localWhisperModelDirectory)
                        TextField("Python / Whisper 运行时路径", text: $llmConfiguration.localWhisperPythonPath)
                    }
                } header: {
                    Label("本地 Whisper", systemImage: "laptopcomputer")
                } footer: {
                    Text("MacBook 上可配置例如 whisper-large-v3-turbo；iPad 自动回退到远程 API 或系统识别。运行时路径需指向已安装 mlx-whisper 的 Python。")
                }
        }
        .formStyle(.grouped)
        .navigationTitle("偏好设置")
    }

    private var speedLabel: String {
        switch speed {
        case ..<0.28: return "很慢 · \(String(format: "%.1f×", speed / 0.45))"
        case ..<0.39: return "慢速 · \(String(format: "%.1f×", speed / 0.45))"
        case ..<0.52: return "正常 · \(String(format: "%.1f×", speed / 0.45))"
        case ..<0.61: return "快速 · \(String(format: "%.1f×", speed / 0.45))"
        default: return "很快 · \(String(format: "%.1f×", speed / 0.45))"
        }
    }
}

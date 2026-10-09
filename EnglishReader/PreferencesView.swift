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
    @State private var isTTSExpanded = false
    @State private var isChildModeExpanded = false
    @State private var isTypographyExpanded = false
    @State private var isLLMExpanded = false
    @State private var isLocalWhisperExpanded = false

    var body: some View {
        Form {
                DisclosureGroup(isExpanded: $isTTSExpanded) {
                    LabeledContent("朗读引擎") {
                        Text("系统语音")
                    }

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

                    GroupBox {
                        VStack(alignment: .leading, spacing: 5) {
                            Label(
                                hasHighQualityVoice
                                    ? "可在系统设置中下载更多 Enhanced 或 Premium 英语声音。"
                                    : "尚未安装 Enhanced 或 Premium 英语声音。",
                                systemImage: hasHighQualityVoice ? "speaker.wave.2" : "arrow.down.circle"
                            )
                            .font(.subheadline.weight(.medium))
                            Text("前往“系统设置 → 辅助功能 → 朗读内容 → 系统声音 → 管理声音”，下载 English (US) 或 English (UK) 的 Enhanced / Premium 声音。下载完成后重新打开本应用。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    LabeledContent("语速") {
                        HStack {
                            Slider(value: $speed, in: 0.18...0.68, step: 0.01)
                            Text(speedLabel).monospacedDigit().frame(width: 96, alignment: .trailing)
                        }
                    }
                    Text("点词与文章朗读使用所选系统声音。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } label: {
                    Label("TTS 发音", systemImage: "speaker.wave.2.fill")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { isTTSExpanded.toggle() }
                }

                DisclosureGroup(isExpanded: $isChildModeExpanded) {
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
                        Text("逐个朗读单词，并按设置时间停顿。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                } label: {
                        Label("儿童模式", systemImage: "figure.and.child.holdinghands")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { isChildModeExpanded.toggle() }
                }

                DisclosureGroup(isExpanded: $isTypographyExpanded) {
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
                } label: {
                    Label("文字显示", systemImage: "textformat.size")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { isTypographyExpanded.toggle() }
                }

                DisclosureGroup(isExpanded: $isLLMExpanded) {
                    Button("使用 OpenAI 默认配置") {
                        llmConfiguration.useOpenAIDefaults()
                    }
                    .buttonStyle(ReaderOutlinedButtonStyle())
                    TextField("服务地址（例如 https://api.openai.com/v1）", text: $llmConfiguration.baseURL)
                    TextField("通用模型", text: $llmConfiguration.model)
                    SecureField("API Key", text: $llmConfiguration.apiKey)
                    Text("只配置一个通用大模型。具体任务由程序通过 prompt 告知模型；API Key 仅保存在本机钥匙串。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } label: {
                    Label("大模型服务", systemImage: "brain.head.profile")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { isLLMExpanded.toggle() }
                }

                DisclosureGroup(isExpanded: $isLocalWhisperExpanded) {
                    Toggle("优先使用本地 Whisper（仅 macOS）", isOn: $llmConfiguration.localWhisperEnabled)
                    if llmConfiguration.localWhisperEnabled {
                        TextField("模型名", text: $llmConfiguration.localWhisperModel)
                        TextField("模型目录（可选）", text: $llmConfiguration.localWhisperModelDirectory)
                        TextField("Python / Whisper 运行时路径", text: $llmConfiguration.localWhisperPythonPath)
                    }
                    Text("MacBook 上可配置例如 whisper-large-v3-turbo；iPad 自动回退到远程 API 或系统识别。运行时路径需指向已安装 whispermlx 的 Python。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } label: {
                    Label("本地 Whisper", systemImage: "laptopcomputer")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { isLocalWhisperExpanded.toggle() }
            }
        }
        .formStyle(.grouped)
        .font(.body)
        .scrollContentBackground(.hidden)
        .background(
            LinearGradient(
                colors: [Color(red: 0.94, green: 0.96, blue: 1.00), Color(red: 0.96, green: 1.00, blue: 0.96)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .tint(Color(red: 0.29, green: 0.37, blue: 0.90))
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

    private var hasHighQualityVoice: Bool {
        EnglishVoiceOption.available(for: accent).contains {
            $0.quality == .enhanced || $0.quality == .premium
        }
    }
}

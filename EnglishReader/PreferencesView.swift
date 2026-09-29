import SwiftUI

struct PreferencesView: View {
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
                    Text("点词使用本地即时发音。Enhanced 或 Premium 声音通常比标准声音更自然。")
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

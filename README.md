# EnglishReader

一个使用 SwiftUI 制作的英文阅读与跟读应用，同时支持 macOS 与 iPad。

## 功能

- 直接输入或粘贴英文文章
- 单一“选择文件”入口：自动识别 UTF-8/ASCII 文本、Markdown（`.txt`、`.md`、`.markdown`）和系统支持的音频文件；其他类型会给出格式提示
- 音频显示文件名与时长，并提供进度拖动、前后 15 秒、播放/暂停；播放速度与侧栏“语速”实时同步
- 美式英语与英式英语发音
- 连续调节朗读速度
- 开始、暂停、继续、停止及重新朗读
- 点词朗读，并显示音标、英英释义和英汉释义
- 自动整理粘贴文本的空格、换行与英文标点，并按句子排版
- 阅读字体、字号设置；单击单词重读，双击（iPad 上双击触碰）切换高亮
- 可选择设备已安装的英语声音；点读优先使用在线词典标准录音，离线时回退到系统语音
- 朗读时自动滚动保持当前单词可见；未读文本为黑色，已读文本高亮，当前词额外强调
- 音频按逐词时间戳生成阅读文本，并按语音停顿自动分段；文章与音频均提供统一的播放进度控制
- 儿童模式为常见功能词应用上下文弱读，避免将冠词 `a` 读成字母名
- 编辑与点词查询合并为同一文章区域；“进入阅读”后可直接点击任意单词
- 主窗口提供偏好设置入口，集中管理 TTS、儿童模式、字体与字号
- 可配置兼容 OpenAI 的翻译服务；API Key 只存储于系统钥匙串
- macOS 可调用本地 MLX Whisper 高精度转写，并将结果用于逐词高亮与进度同步

> 点词查询使用在线词典与翻译服务，需要设备联网；查询结果会在本次运行期间缓存。

## 环境要求

- Xcode 16.2 或更高版本
- macOS 15+（Apple Silicon）或 iPadOS 18+ 真机（本地 MLX Whisper 仅适用于 Apple Silicon；iOS 模拟器不支持 MLX）
- 音频转写首次使用时需要授予“语音识别”权限

## 编译与运行

1. 使用 Xcode 打开 `EnglishReader.xcodeproj`。
2. 在 Scheme 中选择 `EnglishReader`，并选择 `My Mac` 或 iPad 模拟器/真机。
3. 点击 Run（`⌘R`）编译并启动。

也可在项目根目录通过命令行构建 macOS Debug 版本：

```bash
xcodebuild -project EnglishReader.xcodeproj \
  -scheme EnglishReader \
  -sdk macosx \
  -configuration Debug \
  CODE_SIGNING_ALLOWED=NO build
```

## 文件导入

点击“选择文件”后，应用会自动识别：

- 文本：`.txt`
- Markdown：`.md`、`.markdown`
- 音频：系统支持的格式，例如 `.mp3`、`.m4a`、`.wav`

其他类型会显示格式提示。文本会进入编辑器；音频会显示播放器并将转写结果写入阅读区。

## 大模型服务

在左侧“偏好设置 → 大模型语音服务”填写以下内容：

- 服务地址：兼容 OpenAI API 的根地址，例如 `https://your-host/v1`
- API Key：保存在 macOS/iPadOS 钥匙串，不会写入仓库或 README

目前远程服务用于翻译；上传音频转写使用本地 Whisper 或系统语音识别。

## 本地 Whisper 部署（macOS / Apple Silicon）

本地转写使用 `whispermlx` 的 MLX 运行时；适合 M 系列芯片。新设备推荐使用仓库内的一键脚本（会安装运行时、对齐数据、默认高精度模型，构建并启动 macOS Debug 版）：

```bash
git clone git@github.com:zg9uagfv/EnglishReader.git
cd EnglishReader
./scripts/setup-local-whisper.sh
```

默认模型为 `mlx-community/whisper-large-v3-turbo`，会下载约 1.6GB 权重。仅准备运行时而暂不下载模型，可使用：

```bash
./scripts/setup-local-whisper.sh --skip-model
```

脚本完成后会显示需要填入应用偏好的 Python 路径。若需要手动部署或使用自定义模型，执行以下步骤：

```bash
python3 -m venv "$HOME/.local/share/englishreader-whisper"
"$HOME/.local/share/englishreader-whisper/bin/pip" install --upgrade pip
"$HOME/.local/share/englishreader-whisper/bin/pip" install whispermlx
```

WhisperMLX 的逐词对齐还需要 NLTK 的 `punkt_tab` 数据：

```bash
"$HOME/.local/share/englishreader-whisper/bin/python" -m nltk.downloader punkt_tab
```

如果电脑通过可信代理联网，NLTK 可能拒绝代理下载。确认代理可信后，可只为这一次下载运行：

```bash
NLTK_ALLOW_PROXIED_URLOPEN=1 \
  "$HOME/.local/share/englishreader-whisper/bin/python" -m nltk.downloader punkt_tab
```

然后在应用的“偏好设置 → 本地 Whisper”中：

1. 勾选“优先使用本地 Whisper”。
2. 模型名填写 `mlx-community/whisper-large-v3-turbo`（高精度推荐）；首次运行会自动下载模型。
3. Python / Whisper 运行时填写虚拟环境中的 Python 路径，例如：
   `~/.local/share/englishreader-whisper/bin/python`。
4. 模型目录可留空，或填写自定义的模型缓存目录。

`whisper-large-v3-turbo` 权重约 1.6GB。M1/M2 且 24GB 统一内存的 MacBook 适合单文件高精度转写；首次下载和长音频推理需要较长时间。选择音频后，系统识别会先显示预览文本；本地 Whisper 完成后，会自动以高精度结果替换预览，并保留逐词时间戳用于进度同步。

### 本地 Whisper 排错

- `Python / Whisper 运行时路径为空`：在偏好中填入虚拟环境的 `bin/python`。
- `No module named whispermlx`：确认在同一个虚拟环境内执行过 `pip install whispermlx`。
- `punkt_tab` 缺失：按上面的 NLTK 命令下载数据；标准位置为 `~/nltk_data`。
- `socksio` 或 SOCKS 代理错误：应用会清除子进程的代理变量。若仍需通过代理下载模型，请在终端中先完成模型下载，或使用远程转写服务。
- 文本暂时为空：高精度模型在下载或推理时只会在完成后返回最终结果；应用会同时显示系统识别的预览，完成后自动替换。

macOS 的优先级是：已启用的本地 Whisper → 已配置的远程 API → 系统语音识别。iPad 不支持启动本地 Python 进程，仍使用远程 API 或系统识别。

## 开发说明

构建产物和模型缓存不应提交。提交前请至少执行一次 Debug 构建，并确认 API Key、个人音频与临时模型文件均未被加入 Git。

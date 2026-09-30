#!/bin/zsh
# Bootstrap EnglishReader's local, offline ASR runtime on macOS Apple Silicon.
# Usage: ./scripts/setup-local-whisper.sh [--skip-model] [--model MODEL_ID]

set -euo pipefail

script_root="$(cd "$(dirname "$0")/.." && pwd)"
runtime_root="${HOME}/.local/share/englishreader-whisper"
python_path="${runtime_root}/bin/python"
model_name="mlx-community/whisper-large-v3-turbo"
download_model=true

while (( $# > 0 )); do
  case "$1" in
    --skip-model)
      download_model=false
      ;;
    --model)
      shift
      if (( $# == 0 )); then
        print -- "Missing model name after --model"
        exit 2
      fi
      model_name="$1"
      ;;
    -h|--help)
      print -- "Usage: $0 [--skip-model] [--model MODEL_ID]"
      exit 0
      ;;
    *)
      print -- "Unknown option: $1"
      exit 2
      ;;
  esac
  shift
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  print -- "This installer supports macOS only."
  exit 1
fi

if ! command -v python3 >/dev/null; then
  print -- "Python 3 is required. Install it with Xcode Command Line Tools or Homebrew, then run this script again."
  exit 1
fi

if ! command -v xcodebuild >/dev/null; then
  print -- "Xcode is required to build EnglishReader. Install Xcode, open it once to accept its license, then run this script again."
  exit 1
fi

if ! command -v curl >/dev/null || ! command -v unzip >/dev/null; then
  print -- "curl and unzip are required but unavailable."
  exit 1
fi

print -- "Creating local Whisper runtime at ${runtime_root}…"
if [[ ! -x "${python_path}" ]]; then
  python3 -m venv "${runtime_root}"
fi

print -- "Installing WhisperMLX…"
"${python_path}" -m pip install --upgrade pip
"${python_path}" -m pip install --upgrade whispermlx

# WhisperMLX uses NLTK for word-level sentence alignment. Download directly to
# the standard user path because NLTK can reject proxied downloads by design.
nltk_root="${HOME}/nltk_data"
nltk_tokenizers="${nltk_root}/tokenizers"
punkt_marker="${nltk_tokenizers}/punkt_tab/english/abbrev_types.txt"
if [[ ! -f "${punkt_marker}" ]]; then
  print -- "Installing NLTK punkt_tab alignment data…"
  mkdir -p "${nltk_tokenizers}"
  archive_path="${nltk_tokenizers}/punkt_tab.zip"
  curl -fL --retry 3 --connect-timeout 20 \
    -o "${archive_path}" \
    "https://raw.githubusercontent.com/nltk/nltk_data/gh-pages/packages/tokenizers/punkt_tab.zip"
  unzip -t "${archive_path}" >/dev/null
  unzip -oq "${archive_path}" -d "${nltk_tokenizers}"
fi

if [[ "${download_model}" == true ]]; then
  print -- "Downloading ${model_name}. This can use roughly 1.6 GB and may take several minutes…"
  # Match the app runtime: avoid inheriting SOCKS proxy variables unsupported
  # by httpx unless the user has explicitly installed socksio.
  ENGLISHREADER_MODEL_NAME="${model_name}" \
    env -u ALL_PROXY -u all_proxy -u HTTP_PROXY -u http_proxy -u HTTPS_PROXY -u https_proxy \
    "${python_path}" -c 'import os; from huggingface_hub import snapshot_download; snapshot_download(repo_id=os.environ["ENGLISHREADER_MODEL_NAME"])'
fi

print -- "Building EnglishReader macOS Debug app…"
cd "${script_root}"
derived_data="${script_root}/.build/EnglishReaderDerived"
xcodebuild -project EnglishReader.xcodeproj \
  -scheme EnglishReader \
  -sdk macosx \
  -configuration Debug \
  -derivedDataPath "${derived_data}" \
  CODE_SIGNING_ALLOWED=NO build

app_path="${derived_data}/Build/Products/Debug/EnglishReader.app"
if [[ -d "${app_path}" ]]; then
  open -n "${app_path}"
fi

print -- ""
print -- "Setup complete. EnglishReader has been launched. In EnglishReader → 偏好设置 → 本地 Whisper:"
print -- "  1. Enable 优先使用本地 Whisper"
print -- "  2. Model: ${model_name}"
print -- "  3. Python / Whisper runtime: ${python_path}"

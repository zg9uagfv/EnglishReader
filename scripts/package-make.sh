#!/bin/zsh
# 构建 Release 版本并生成 macOS 安装包（.pkg）。
#
# 用法：
#   scripts/package-make.sh            # 只生成安装包
#   scripts/package-make.sh install    # 生成后安装到 /Applications（需要管理员密码）
set -eu

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="EnglishReader"
CONFIGURATION="Release"
DERIVED_DATA="$PROJECT_DIR/build/Release"
APP_BUNDLE="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"

cd "$PROJECT_DIR"

echo "==> 构建 $CONFIGURATION 版本…"
xcodebuild \
    -project "$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    build | tail -1

[[ -d "$APP_BUNDLE" ]] || { echo "构建产物缺失：$APP_BUNDLE" >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_BUNDLE/Contents/Info.plist")
PKG_PATH="$PROJECT_DIR/build/$APP_NAME-$VERSION.pkg"

echo "==> 生成安装包（版本 $VERSION）…"
pkgbuild --component "$APP_BUNDLE" --install-location /Applications "$PKG_PATH"
echo "安装包已生成：$PKG_PATH"

if [[ "${1:-}" == "install" ]]; then
    echo "==> 安装到 /Applications（会提示输入管理员密码）…"
    sudo installer -pkg "$PKG_PATH" -target /
    echo "安装完成，可直接从“应用程序”打开 $APP_NAME。"
else
    echo "安装到本机：sudo installer -pkg $PKG_PATH -target /"
fi

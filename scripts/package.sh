#!/usr/bin/env bash
# Lambda デプロイパッケージを作成するスクリプト（デプロイは行わない）
# 使い方: bash scripts/package.sh [出力ZIPパス]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT="${1:-/tmp/web-scraper-function.zip}"
BUILD_DIR="/tmp/web-scraper-build"

echo "=== Lambda パッケージ作成 ==="
echo "出力先: $OUTPUT"
echo ""

# ビルドディレクトリを初期化
rm -rf "$BUILD_DIR" && mkdir -p "$BUILD_DIR"

# 依存ライブラリをビルドディレクトリにインストール
echo "依存ライブラリをインストール中..."
pip3 install \
  -r "$PROJECT_DIR/backend/requirements.txt" \
  -t "$BUILD_DIR" \
  --quiet \
  --disable-pip-version-check

# Lambda 関数本体をコピー
cp "$PROJECT_DIR/backend/lambda_function.py" "$BUILD_DIR/"

# ZIP 作成
echo "ZIP を作成中..."
(cd "$BUILD_DIR" && zip -r "$OUTPUT" . -q)

echo ""
echo "完了: $OUTPUT"
echo "サイズ: $(du -sh "$OUTPUT" | cut -f1)"

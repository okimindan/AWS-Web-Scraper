#!/usr/bin/env bash
# ============================================================
#  AWS Web Scraper - フルデプロイスクリプト
#  前提: AWS CLI v2, Python3, pip3, zip がインストール済み
#  使い方: bash scripts/deploy.sh
# ============================================================
set -euo pipefail

# ── 設定（必要に応じて変更） ──────────────────────────────────
REGION="${AWS_DEFAULT_REGION:-ap-northeast-1}"
FUNCTION_NAME="web-scraper-function"
ROLE_NAME="web-scraper-lambda-role"
API_NAME="web-scraper-api"
STAGE_NAME="prod"
RUNTIME="python3.12"
TIMEOUT=30       # 秒
MEMORY=256       # MB

# ── 内部変数 ─────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="/tmp/web-scraper-build"
ZIP_FILE="/tmp/web-scraper-function.zip"

# ── カラーログ ────────────────────────────────────────────────
_log()  { echo -e "\033[0;34m[INFO]\033[0m  $*"; }
_ok()   { echo -e "\033[0;32m[ OK ]\033[0m  $*"; }
_warn() { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
_err()  { echo -e "\033[0;31m[ERR ]\033[0m  $*"; exit 1; }

# ── 前提確認 ─────────────────────────────────────────────────
_log "前提確認中..."
command -v aws    >/dev/null 2>&1 || _err "aws CLI が見つかりません"
command -v python3 >/dev/null 2>&1 || _err "python3 が見つかりません"
command -v pip3   >/dev/null 2>&1 || _err "pip3 が見つかりません"
command -v zip    >/dev/null 2>&1 || _err "zip が見つかりません"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_NAME="web-scraper-frontend-${ACCOUNT_ID}"

echo ""
echo "============================================"
echo "  AWS Web Scraper デプロイ開始"
echo "============================================"
echo "  Region   : $REGION"
echo "  Account  : $ACCOUNT_ID"
echo "  S3 Bucket: $BUCKET_NAME"
echo "============================================"
echo ""

# ================================================================
# STEP 1: IAM ロール作成
# ================================================================
_log "1/6  IAM ロールを確認・作成中..."

TRUST_POLICY='{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"Service": "lambda.amazonaws.com"},
    "Action": "sts:AssumeRole"
  }]
}'

if aws iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  _warn "IAM ロール $ROLE_NAME は既に存在します。スキップ。"
  ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" \
    --query 'Role.Arn' --output text)
else
  ROLE_ARN=$(aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "$TRUST_POLICY" \
    --query 'Role.Arn' --output text)

  aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"

  _log "IAM ロール反映待機中 (10秒)..."
  sleep 10
fi
_ok "Role ARN: $ROLE_ARN"

# ================================================================
# STEP 2: Lambda デプロイパッケージ作成
# ================================================================
_log "2/6  Lambda パッケージを作成中..."

rm -rf "$BUILD_DIR" && mkdir -p "$BUILD_DIR"

pip3 install \
  -r "$PROJECT_DIR/backend/requirements.txt" \
  -t "$BUILD_DIR" \
  --quiet \
  --disable-pip-version-check

cp "$PROJECT_DIR/backend/lambda_function.py" "$BUILD_DIR/"

(cd "$BUILD_DIR" && zip -r "$ZIP_FILE" . -q)
_ok "ZIP 作成完了: $ZIP_FILE ($(du -sh "$ZIP_FILE" | cut -f1))"

# ================================================================
# STEP 3: Lambda 関数 作成 / コード更新
# ================================================================
_log "3/6  Lambda 関数を作成・更新中..."

if aws lambda get-function \
     --function-name "$FUNCTION_NAME" \
     --region "$REGION" >/dev/null 2>&1; then

  _warn "Lambda 関数 $FUNCTION_NAME は既に存在します。コードを更新します。"
  aws lambda update-function-code \
    --function-name "$FUNCTION_NAME" \
    --zip-file "fileb://$ZIP_FILE" \
    --region "$REGION" \
    --output json >/dev/null
else
  aws lambda create-function \
    --function-name  "$FUNCTION_NAME" \
    --runtime        "$RUNTIME" \
    --role           "$ROLE_ARN" \
    --handler        "lambda_function.lambda_handler" \
    --zip-file       "fileb://$ZIP_FILE" \
    --timeout        "$TIMEOUT" \
    --memory-size    "$MEMORY" \
    --region         "$REGION" \
    --output json >/dev/null
fi

# 更新完了まで待機
aws lambda wait function-updated \
  --function-name "$FUNCTION_NAME" \
  --region "$REGION"

FUNCTION_ARN=$(aws lambda get-function \
  --function-name "$FUNCTION_NAME" \
  --region "$REGION" \
  --query 'Configuration.FunctionArn' --output text)

_ok "Function ARN: $FUNCTION_ARN"

# ================================================================
# STEP 4: API Gateway HTTP API 作成
# ================================================================
_log "4/6  API Gateway を作成中..."

# 同名 API が既に存在するか確認
EXISTING_API=$(aws apigatewayv2 get-apis \
  --region "$REGION" \
  --query "Items[?Name=='$API_NAME'].ApiId" \
  --output text)

if [ -n "$EXISTING_API" ] && [ "$EXISTING_API" != "None" ]; then
  _warn "API '$API_NAME' は既に存在します (ID: $EXISTING_API)。スキップ。"
  API_ID="$EXISTING_API"
else
  # HTTP API を CORS 設定付きで作成
  API_ID=$(aws apigatewayv2 create-api \
    --name "$API_NAME" \
    --protocol-type HTTP \
    --cors-configuration '{
      "AllowOrigins":  ["*"],
      "AllowMethods":  ["POST","OPTIONS"],
      "AllowHeaders":  ["Content-Type","X-Amz-Date","Authorization","X-Api-Key"],
      "MaxAge":        86400
    }' \
    --region "$REGION" \
    --query 'ApiId' --output text)

  # Lambda プロキシ統合を作成
  INTEGRATION_ID=$(aws apigatewayv2 create-integration \
    --api-id "$API_ID" \
    --integration-type AWS_PROXY \
    --integration-uri \
      "arn:aws:apigateway:${REGION}:lambda:path/2015-03-31/functions/${FUNCTION_ARN}/invocations" \
    --payload-format-version "2.0" \
    --region "$REGION" \
    --query 'IntegrationId' --output text)

  # POST /scrape ルートを作成
  aws apigatewayv2 create-route \
    --api-id    "$API_ID" \
    --route-key "POST /scrape" \
    --target    "integrations/$INTEGRATION_ID" \
    --region    "$REGION" \
    --output json >/dev/null

  # 自動デプロイステージを作成
  aws apigatewayv2 create-stage \
    --api-id      "$API_ID" \
    --stage-name  "$STAGE_NAME" \
    --auto-deploy \
    --region      "$REGION" \
    --output json >/dev/null
fi

API_ENDPOINT="https://${API_ID}.execute-api.${REGION}.amazonaws.com/${STAGE_NAME}/scrape"

# API Gateway が Lambda を呼び出す権限を付与
# 既に付与済みの場合は警告を出してスキップ
aws lambda add-permission \
  --function-name  "$FUNCTION_NAME" \
  --statement-id   "AllowAPIGateway-$(date +%s)" \
  --action         "lambda:InvokeFunction" \
  --principal      "apigateway.amazonaws.com" \
  --source-arn     "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*/*/scrape" \
  --region         "$REGION" \
  --output json >/dev/null 2>&1 \
  || _warn "Lambda invoke permission は既に付与済みの可能性があります"

_ok "API Endpoint: $API_ENDPOINT"

# ================================================================
# STEP 5: S3 静的ウェブサイトバケット作成
# ================================================================
_log "5/6  S3 バケットを作成・設定中..."

if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
  _warn "バケット $BUCKET_NAME は既に存在します。設定を上書きします。"
else
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket \
      --bucket "$BUCKET_NAME" \
      --region "$REGION"
  else
    aws s3api create-bucket \
      --bucket "$BUCKET_NAME" \
      --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi
fi

# Block Public Access を無効化（静的ホスティングに必要）
aws s3api put-public-access-block \
  --bucket "$BUCKET_NAME" \
  --public-access-block-configuration \
    "BlockPublicAcls=false,IgnorePublicAcls=false,BlockPublicPolicy=false,RestrictPublicBuckets=false"

# 公開読み取りバケットポリシーを適用
BUCKET_POLICY=$(cat <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect":    "Allow",
    "Principal": "*",
    "Action":    "s3:GetObject",
    "Resource":  "arn:aws:s3:::${BUCKET_NAME}/*"
  }]
}
POLICY
)
aws s3api put-bucket-policy \
  --bucket "$BUCKET_NAME" \
  --policy "$BUCKET_POLICY"

# 静的ウェブサイトホスティングを有効化
aws s3api put-bucket-website \
  --bucket "$BUCKET_NAME" \
  --website-configuration \
    '{"IndexDocument":{"Suffix":"index.html"},"ErrorDocument":{"Key":"error.html"}}'

_ok "S3 バケット設定完了"

# ================================================================
# STEP 6: フロントエンドの API URL 書き換え & S3 へアップロード
# ================================================================
_log "6/6  フロントエンドを S3 へデプロイ中..."

TMP_HTML="/tmp/index_deploy.html"
cp "$PROJECT_DIR/frontend/index.html" "$TMP_HTML"

# macOS と Linux の sed 差異を吸収
if [[ "$OSTYPE" == "darwin"* ]]; then
  sed -i '' "s|__API_URL__|${API_ENDPOINT}|g" "$TMP_HTML"
else
  sed -i    "s|__API_URL__|${API_ENDPOINT}|g" "$TMP_HTML"
fi

aws s3 cp "$TMP_HTML" "s3://${BUCKET_NAME}/index.html" \
  --content-type "text/html; charset=utf-8" \
  --cache-control "no-cache, no-store, must-revalidate"

_ok "index.html をアップロードしました"

# ================================================================
# 完了メッセージ
# ================================================================
WEBSITE_URL="http://${BUCKET_NAME}.s3-website.${REGION}.amazonaws.com"

echo ""
echo "============================================"
echo -e "\033[0;32m  デプロイ完了!\033[0m"
echo "============================================"
echo ""
echo "  フロントエンド URL (S3 Static Website):"
echo "  $WEBSITE_URL"
echo ""
echo "  API エンドポイント:"
echo "  $API_ENDPOINT"
echo ""
echo "  テスト用 curl (検索モード):"
echo "  curl -s -X POST '$API_ENDPOINT' \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"keyword\": \"Python\"}' | python3 -m json.tool"
echo ""
echo "  テスト用 curl (スクレイピングモード):"
echo "  curl -s -X POST '$API_ENDPOINT' \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"keyword\": \"Python\", \"url\": \"https://www.python.org\"}' | python3 -m json.tool"
echo ""
echo "============================================"

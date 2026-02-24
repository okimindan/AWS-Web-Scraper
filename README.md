# AWS-Web-Scraper
## 作成されたリソース
| リソース | 詳細 |
| :--- | :--- |
| IAM ロール | web-scraper-lambda-role |
| Lambda 関数 | web-scraper-function |
| API Gateway | web-scraper-api |
| S3 バケット（静的ホスト/画像保存） | web-scraper-frontend-869807375374 |

- スクレイピングするためのAPI
  - Brave Search API


# AWS Web Scraper - 設計書

## 1. 概要

キーワードを入力するだけでWeb検索・スクレイピング・画像取得をワンストップで実行できる、フルサーバーレス構成のWebアプリケーション。

---

## 2. アーキテクチャ全体図

```
ユーザー (ブラウザ)
    │
    │ HTTP GET
    ▼
┌─────────────────────────────────────┐
│  S3 Static Website Hosting          │
│  web-scraper-frontend-{ACCOUNT_ID}  │
│  index.html                         │
└─────────────────────────────────────┘
    │
    │ POST /scrape (JSON)
    ▼
┌─────────────────────────────────────┐
│  API Gateway (HTTP API)             │
│  web-scraper-api                    │
│  CORS: AllowOrigins=*               │
└─────────────────────────────────────┘
    │
    │ Lambda Proxy統合
    ▼
┌─────────────────────────────────────┐
│  Lambda                             │
│  web-scraper-function               │
│  Python 3.12 / 256MB / 30秒         │
│                                     │
│  ┌──────────────┐ ┌───────────────┐ │
│  │ キーワードのみ │ │ キーワード+URL │ │
│  │  Brave検索   │ │  スクレイピング│ │
│  └──────┬───────┘ └──────┬────────┘ │
│         │               │          │
│         └───────┬────────┘          │
│                 │ 画像取得           │
└─────────────────┼────────────────────┘
                  │
        ┌─────────┴──────────┐
        │                    │
        ▼                    ▼
┌──────────────┐   ┌──────────────────────┐
│ Brave Search │   │  S3                  │
│ API          │   │  images/{md5}.jpg    │
│ Web検索      │   │  (取得画像を永続保存) │
│ 画像検索     │   └──────────────────────┘
└──────────────┘
```

---

## 3. AWSリソース一覧

| リソース | 名前 | 設定 |
|---------|------|------|
| S3 バケット | `web-scraper-frontend-{ACCOUNT_ID}` | Static Website Hosting, Public Read |
| API Gateway | `web-scraper-api` | HTTP API, CORS=*, POST /scrape |
| Lambda | `web-scraper-function` | Python 3.12, 256MB, 30秒 |
| IAM ロール | `web-scraper-lambda-role` | AWSLambdaBasicExecutionRole + S3 PutObject |

**リージョン:** ap-northeast-1 (東京)
**AWSアカウント:** 869807375374

---

## 4. エンドポイント

| 種類 | URL |
|------|-----|
| フロントエンド | `http://web-scraper-frontend-{ACCOUNT_ID}.s3-website.ap-northeast-1.amazonaws.com` |
| API | `https://gzn7saoar2.execute-api.ap-northeast-1.amazonaws.com/prod/scrape` |

---

## 5. API仕様

### リクエスト

```
POST /scrape
Content-Type: application/json
```

| パラメータ | 型 | 必須 | 説明 |
|-----------|-----|------|------|
| `keyword` | string | ✅ | 検索キーワード |
| `url` | string | ❌ | 省略時はBrave検索、指定時はスクレイピング |

### レスポンス（検索モード）

```json
{
  "mode": "search",
  "keyword": "メタモン",
  "results": [
    {
      "title": "ページタイトル",
      "url": "https://...",
      "snippet": "説明文",
      "display_url": "example.com"
    }
  ],
  "result_count": 10,
  "images": [
    {
      "original_url": "https://元画像URL",
      "s3_url": "https://...s3.ap-northeast-1.amazonaws.com/images/xxxx.jpg",
      "alt": "画像の説明"
    }
  ],
  "image_count": 10
}
```

### レスポンス（スクレイピングモード）

```json
{
  "mode": "scrape",
  "keyword": "Python",
  "url": "https://...",
  "title": "ページタイトル",
  "description": "meta description",
  "matches": ["キーワードを含む文章..."],
  "match_count": 5,
  "images": [...],
  "image_count": 10
}
```

---

## 6. Lambda 処理フロー

### 6-1. キーワードのみ（検索モード）

```
1. Brave Web Search API → 上位10件のURLとスニペットを取得
2. Brave Image Search API → 関連画像を最大10件取得
3. 各画像をダウンロードしてS3の images/ に保存
4. Web結果 + S3画像URLをまとめてJSONで返却
```

### 6-2. キーワード + URL（スクレイピングモード）

```
1. 指定URLにHTTPリクエスト
2. BeautifulSoupでHTMLをパース
3. <script><style>などのノイズタグを除去
4. キーワードを含む <p><h1><li> などのテキストを抽出（最大20件）
5. <img src="..."> を最大10枚抽出
6. 各画像をダウンロードしてS3の images/ に保存
7. テキスト + S3画像URLをまとめてJSONで返却
```

---

## 7. ファイル構成

```
aws-scraper/
├── backend/
│   ├── lambda_function.py   # Lambda本体
│   └── requirements.txt     # requests, beautifulsoup4
├── frontend/
│   └── index.html           # S3配信フロントエンド（__API_URL__プレースホルダー）
├── scripts/
│   ├── deploy.sh            # フルデプロイスクリプト（6ステップ）
│   └── package.sh           # Lambdaパッケージのみ作成
└── DESIGN.md                # 本設計書
```

---

## 8. 環境変数（Lambda）

| 変数名 | 値 | 説明 |
|--------|-----|------|
| `IMAGE_BUCKET` | `web-scraper-frontend-{ACCOUNT_ID}` | 画像保存先S3バケット |
| `AWS_REGION` | `ap-northeast-1` | AWSリージョン |
| `BRAVE_API_KEY` | `BSAlOxV...` | Brave Search APIキー |

---

## 9. IAMポリシー

### web-scraper-lambda-role にアタッチされているポリシー

**マネージドポリシー（AWS管理）**
- `AWSLambdaBasicExecutionRole` — CloudWatch Logsへの書き込み

**インラインポリシー（web-scraper-s3-images）**
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:PutObject", "s3:GetObject"],
    "Resource": "arn:aws:s3:::web-scraper-frontend-{ACCOUNT_ID}/images/*"
  }]
}
```

---

## 10. 外部サービス依存

| サービス | 用途 | 制限・費用 |
|---------|------|----------|
| Brave Search API (Web) | キーワード検索 | 無料: 2,000リクエスト/月 |
| Brave Search API (Images) | 関連画像検索 | 同上（Web検索と合算） |

> **注意:** DuckDuckGoはAWS LambdaのIPをブロックするため使用不可。Brave APIに切り替え済み。

---

## 11. デプロイ手順

### 初回デプロイ

```bash
# AWS認証確認
aws sts get-caller-identity

# フルデプロイ実行（6ステップ自動化）
bash scripts/deploy.sh
```

### コード変更後の再デプロイ

```bash
# Lambdaのみ更新
rm -rf /tmp/web-scraper-build && mkdir -p /tmp/web-scraper-build
pip3 install -r backend/requirements.txt -t /tmp/web-scraper-build --quiet
cp backend/lambda_function.py /tmp/web-scraper-build/
(cd /tmp/web-scraper-build && zip -r /tmp/web-scraper-function.zip . -q)
aws lambda update-function-code \
  --function-name web-scraper-function \
  --zip-file "fileb:///tmp/web-scraper-function.zip" \
  --region ap-northeast-1

# フロントエンドのみ更新
API_ENDPOINT="https://gzn7saoar2.execute-api.ap-northeast-1.amazonaws.com/prod/scrape"
cp frontend/index.html /tmp/index_deploy.html
sed -i '' "s|__API_URL__|${API_ENDPOINT}|g" /tmp/index_deploy.html
aws s3 cp /tmp/index_deploy.html s3://web-scraper-frontend-{ACCOUNT_ID}/index.html \
  --content-type "text/html; charset=utf-8" \
  --cache-control "no-cache, no-store, must-revalidate"
```

### 動作確認（curl）

```bash
# 検索モード
curl -s -X POST 'https://gzn7saoar2.execute-api.ap-northeast-1.amazonaws.com/prod/scrape' \
  -H 'Content-Type: application/json' \
  -d '{"keyword": "メタモン"}' | python3 -m json.tool

# スクレイピングモード
curl -s -X POST 'https://gzn7saoar2.execute-api.ap-northeast-1.amazonaws.com/prod/scrape' \
  -H 'Content-Type: application/json' \
  -d '{"keyword": "Python", "url": "https://www.python.org"}' | python3 -m json.tool
```

---

## 12. 将来的な拡張案

| 拡張 | 概要 |
|------|------|
| 検索履歴 | DynamoDBに検索ログを保存、過去の結果を再利用 |
| 認証 | Cognito + API Gatewayオーソライザーで利用者を制限 |
| 画像の定期削除 | S3ライフサイクルポリシーで古い画像を自動削除 |
| 非同期処理 | 重いスクレイピングをSQS + Lambda非同期で処理 |
| CloudFront | S3の前段にCDNを置いてHTTPS化・高速化 |
| 複数URL対応 | URLリストを受け取って並列スクレイピング |

"""
AWS Web Scraper - Lambda Function
----------------------------------
POST body (JSON):
  keyword  : str  (required) 検索キーワード
  url      : str  (optional) 指定URLをスクレイピング。省略時はDuckDuckGo検索。

Response (JSON):
  mode == "search" : { mode, keyword, results: [{title, url, snippet, display_url}], result_count }
  mode == "scrape" : { mode, keyword, url, title, description, matches: [str], match_count,
                       images: [{original_url, s3_url}], image_count }
"""

import hashlib
import json
import mimetypes
import os
import re
import urllib.parse

import boto3
import requests
from bs4 import BeautifulSoup

# ── 設定 ────────────────────────────────────────────────────────────────
IMAGE_BUCKET  = os.environ.get("IMAGE_BUCKET", "")
AWS_REGION    = os.environ.get("AWS_REGION", "ap-northeast-1")
BRAVE_API_KEY = os.environ.get("BRAVE_API_KEY", "")
MAX_IMAGES    = 10  # 1リクエストで保存する画像の上限

s3_client = boto3.client("s3", region_name=AWS_REGION)

# ── 共通リクエストヘッダー ────────────────────────────────────────────
REQUEST_HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/122.0.0.0 Safari/537.36"
    ),
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "ja,en-US;q=0.7,en;q=0.3",
    "Accept-Encoding": "gzip, deflate, br",
    "Connection": "keep-alive",
}

# ── CORS ヘッダー（全レスポンスに付与）──────────────────────────────────
CORS_HEADERS = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type,X-Amz-Date,Authorization,X-Api-Key",
    "Access-Control-Allow-Methods": "POST,OPTIONS",
    "Content-Type": "application/json; charset=utf-8",
}


# ── エントリポイント ──────────────────────────────────────────────────
def lambda_handler(event, context):
    # HTTP API (v2) / REST API (v1) 両対応で HTTP メソッド取得
    http_method = (
        event.get("requestContext", {}).get("http", {}).get("method")
        or event.get("httpMethod", "")
    )

    # CORS プリフライト（REST API の場合 Lambda まで届く）
    if http_method == "OPTIONS":
        return {"statusCode": 200, "headers": CORS_HEADERS, "body": ""}

    # リクエストボディのパース
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _error(400, "リクエストボディが不正な JSON です")

    keyword    = body.get("keyword", "").strip()
    target_url = body.get("url", "").strip()

    if not keyword:
        return _error(400, "keyword は必須パラメータです")

    # ── スクレイピング処理 ──────────────────────────────────────────────
    try:
        if target_url:
            result = scrape_url(target_url, keyword)
        else:
            result = search_brave(keyword)

    except requests.exceptions.Timeout:
        return _error(504, "リクエストがタイムアウトしました (15秒)")
    except requests.exceptions.HTTPError as e:
        return _error(502, f"対象サイトの HTTP エラー: {e.response.status_code}")
    except requests.exceptions.TooManyRedirects:
        return _error(502, "リダイレクトが多すぎます")
    except requests.exceptions.RequestException as e:
        return _error(502, f"HTTP リクエスト失敗: {str(e)}")
    except Exception as e:
        return _error(500, f"内部エラー: {str(e)}")

    return {
        "statusCode": 200,
        "headers": CORS_HEADERS,
        "body": json.dumps(result, ensure_ascii=False),
    }


# ── URL スクレイピング ────────────────────────────────────────────────
def scrape_url(url: str, keyword: str) -> dict:
    """指定 URL をフェッチし、keyword を含む要素と画像を抽出して返す。"""
    resp = requests.get(url, headers=REQUEST_HEADERS, timeout=15, allow_redirects=True)
    resp.raise_for_status()

    # 文字コードの自動検出
    resp.encoding = resp.apparent_encoding or "utf-8"

    soup = BeautifulSoup(resp.text, "html.parser")

    # 不要タグを除去してテキスト品質を上げる
    for tag in soup(["script", "style", "nav", "footer", "header", "aside",
                     "noscript", "iframe", "svg", "form"]):
        tag.decompose()

    # ページタイトル
    title_tag = soup.find("title")
    title = title_tag.get_text(strip=True) if title_tag else url

    # meta description
    meta = soup.find("meta", attrs={"name": re.compile(r"^description$", re.I)})
    description = (meta.get("content") or "").strip() if meta else ""

    # キーワードを含む要素を収集（重複除去・文字数フィルタ付き）
    kw_lower = keyword.lower()
    matches: list[str] = []
    seen: set[str] = set()

    for tag in soup.find_all(["p", "h1", "h2", "h3", "h4", "li", "td", "dt", "dd", "blockquote"]):
        text = tag.get_text(separator=" ", strip=True)
        # 短すぎる・長すぎるテキストはノイズが多いので除外
        if kw_lower in text.lower() and 15 < len(text) < 1500 and text not in seen:
            seen.add(text)
            matches.append(text)

    # ── 画像の抽出・S3アップロード ──────────────────────────────────
    images = _collect_images(soup, url)

    return {
        "mode":        "scrape",
        "keyword":     keyword,
        "url":         url,
        "title":       title,
        "description": description,
        "matches":     matches[:20],
        "match_count": len(matches),
        "images":      images,
        "image_count": len(images),
    }


def _collect_images(soup: BeautifulSoup, base_url: str) -> list[dict]:
    """<img> タグから画像URLを収集し、S3にアップロードして結果リストを返す。"""
    if not IMAGE_BUCKET:
        return []

    img_tags = soup.find_all("img", src=True)
    results  = []

    for img in img_tags:
        if len(results) >= MAX_IMAGES:
            break

        src = img.get("src", "").strip()
        if not src or src.startswith("data:"):
            continue

        # 相対URLを絶対URLに変換
        full_url = urllib.parse.urljoin(base_url, src)
        if not full_url.startswith(("http://", "https://")):
            continue

        s3_url = _upload_image_to_s3(full_url)
        if s3_url:
            results.append({
                "original_url": full_url,
                "s3_url":       s3_url,
                "alt":          img.get("alt", ""),
            })

    return results


def _upload_image_to_s3(img_url: str) -> str | None:
    """画像URLをダウンロードしてS3にアップロード。S3のURLを返す（失敗時はNone）。"""
    try:
        resp = requests.get(
            img_url, headers=REQUEST_HEADERS, timeout=10, stream=False
        )
        resp.raise_for_status()

        # Content-Type からファイル拡張子を推測
        content_type = resp.headers.get("Content-Type", "image/jpeg").split(";")[0].strip()
        if not content_type.startswith("image/"):
            return None

        ext = mimetypes.guess_extension(content_type) or ".jpg"
        if ext == ".jpe":
            ext = ".jpg"

        # URLのMD5ハッシュをファイル名に使用（同一画像の重複保存を防ぐ）
        filename = hashlib.md5(img_url.encode()).hexdigest() + ext
        s3_key   = f"images/{filename}"

        s3_client.put_object(
            Bucket=IMAGE_BUCKET,
            Key=s3_key,
            Body=resp.content,
            ContentType=content_type,
        )

        return (
            f"https://{IMAGE_BUCKET}.s3.{AWS_REGION}.amazonaws.com/{s3_key}"
        )

    except Exception:
        return None


# ── Brave Search 検索 ────────────────────────────────────────────────
def search_brave(keyword: str) -> dict:
    """Brave Search API でキーワード検索 + 画像検索を行い結果を返す。"""
    brave_headers = {
        "Accept":             "application/json",
        "Accept-Encoding":    "gzip",
        "X-Subscription-Token": BRAVE_API_KEY,
    }

    # ── Web 検索 ──
    web_resp = requests.get(
        "https://api.search.brave.com/res/v1/web/search",
        params={"q": keyword, "count": 10, "lang": "ja", "country": "jp"},
        headers=brave_headers,
        timeout=15,
    )
    web_resp.raise_for_status()
    web_data = web_resp.json()

    results = []
    for item in web_data.get("web", {}).get("results", []):
        results.append({
            "title":       item.get("title", ""),
            "url":         item.get("url", ""),
            "snippet":     item.get("description", ""),
            "display_url": item.get("meta_url", {}).get("hostname", ""),
        })

    # ── 画像検索 → S3 保存 ──
    images = []
    if IMAGE_BUCKET:
        img_resp = requests.get(
            "https://api.search.brave.com/res/v1/images/search",
            params={"q": keyword, "count": MAX_IMAGES, "safesearch": "strict"},
            headers=brave_headers,
            timeout=15,
        )
        if img_resp.ok:
            for item in img_resp.json().get("results", [])[:MAX_IMAGES]:
                src = item.get("properties", {}).get("url", "")
                if not src:
                    continue
                s3_url = _upload_image_to_s3(src)
                if s3_url:
                    images.append({
                        "original_url": src,
                        "s3_url":       s3_url,
                        "alt":          item.get("title", ""),
                    })

    return {
        "mode":         "search",
        "keyword":      keyword,
        "results":      results,
        "result_count": len(results),
        "images":       images,
        "image_count":  len(images),
    }


# ── エラーレスポンス生成 ──────────────────────────────────────────────
def _error(status_code: int, message: str) -> dict:
    return {
        "statusCode": status_code,
        "headers":    CORS_HEADERS,
        "body":       json.dumps({"error": message}, ensure_ascii=False),
    }

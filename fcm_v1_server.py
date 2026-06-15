import base64
import json
import logging
import os
import re
import smtplib
import hashlib
import hmac
import html as html_lib
import secrets
from datetime import datetime, timedelta, timezone
from email.message import EmailMessage
import tempfile
import time
from collections import defaultdict
from typing import Any, Dict, Optional

import requests
from fastapi import FastAPI, Header, HTTPException, Request as FastAPIRequest
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, Field
from google.oauth2 import service_account
from google.auth.transport.requests import Request


LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO").upper()
logging.basicConfig(level=getattr(logging, LOG_LEVEL, logging.INFO), format="%(asctime)s %(levelname)s %(name)s: %(message)s")
logger = logging.getLogger("respect_backend")


def _safe_response_text(value: str, limit: int = 500) -> str:
    if not value:
        return ""
    value = re.sub(r'(?i)(api[_-]?key|token|authorization|private[_-]?key|access[_-]?token|refresh[_-]?token)\s*[=:]\s*[^\s,}]+', r'\1=<redacted>', value)
    return value[:limit]


def _env_name(*parts: str) -> str:
    return "".join(parts)

def _env_value(*parts: str, default: str = "") -> str:
    return os.getenv(_env_name(*parts), default).strip()

PROJECT_ID = _env_value("FIREBASE", "_PROJECT", "_ID", default="respect-app-dbc77")

# Render/VPS:
SA_JSON = _env_value("FIREBASE", "_SERVICE", "_ACCOUNT", "_JSON")

# Local Windows:
SA_FILE = _env_value("FIREBASE", "_SERVICE", "_ACCOUNT", "_FILE")

SB_URL = _env_value("SUPABASE", "_URL", default="https://oafbzceorbjykgoffuaa.supabase.co").rstrip("/")
SB_ANON = _env_value("SUPABASE", "_ANON", "_KEY")
SB_SERVICE = _env_value("SUPABASE", "_SERVICE", "_ROLE", "_KEY")
APP_SHARED_SECRET = os.getenv("APP_SHARED_SECRET", "")

# ================= App request hardening =================
# نفس القيمة تضبطها في Flutter وقت البناء:
# --dart-define=RESPECT_REQUEST_SIGNING_SECRET=...
# لا تعتبره سرًا نهائيًا داخل APK، لكنه يمنع الطلبات العشوائية ويصعّب إعادة تشغيل الطلبات القديمة.
RESPECT_REQUEST_SIGNING_SECRET = os.getenv("RESPECT_REQUEST_SIGNING_SECRET", "").strip()
REQUIRE_REQUEST_SIGNATURE = os.getenv("REQUIRE_REQUEST_SIGNATURE", "false").strip().lower() in {"1", "true", "yes", "on"}
REQUEST_SIGNATURE_MAX_AGE_SECONDS = int(os.getenv("REQUEST_SIGNATURE_MAX_AGE_SECONDS", "300"))
REQUEST_NONCE_TTL_SECONDS = int(os.getenv("REQUEST_NONCE_TTL_SECONDS", "600"))
APP_REQUEST_RATE_LIMIT_PER_MINUTE = int(os.getenv("APP_REQUEST_RATE_LIMIT_PER_MINUTE", "180"))

ALLOWED_ORIGINS = [
    origin.strip().rstrip("/")
    for origin in os.getenv("ALLOWED_ORIGINS", "https://respect-app-9fzq.onrender.com").split(",")
    if origin.strip()
]


# ================= Paddle Billing / Verification Subscription =================
# ضع هذه القيم في Render كمتغيرات بيئة:
# PADDLE_ENVIRONMENT=sandbox  أو production
# PADDLE_API_KEY=your_secret_api_key   (لا تضعه داخل Flutter)
# PADDLE_WEBHOOK_SECRET=your_notification_secret_key
# PADDLE_CHECKOUT_URL=https://your-approved-checkout-page.com  (اختياري؛ لو فارغ يستخدم Default payment link في Paddle)
PADDLE_ENVIRONMENT = os.getenv("PADDLE_ENVIRONMENT", "sandbox").strip().lower()
PADDLE_API_KEY = os.getenv("PADDLE_API_KEY", "").strip()
PADDLE_WEBHOOK_SECRET = os.getenv("PADDLE_WEBHOOK_SECRET", "").strip()
PADDLE_CLIENT_SIDE_TOKEN = os.getenv("PADDLE_CLIENT_SIDE_TOKEN", "").strip()
PADDLE_CHECKOUT_URL = os.getenv("PADDLE_CHECKOUT_URL", "").strip()
PADDLE_SUCCESS_URL = os.getenv("PADDLE_SUCCESS_URL", "").strip()
PADDLE_CANCEL_URL = os.getenv("PADDLE_CANCEL_URL", "").strip()

PADDLE_API_BASE = (
    "https://sandbox-api.paddle.com"
    if PADDLE_ENVIRONMENT in {"sandbox", "test", "testing"}
    else "https://api.paddle.com"
)

PADDLE_VERIFICATION_PRICES: Dict[str, Dict[str, Any]] = {
    # Silver
    "silver_monthly": {
        "price_id": os.getenv("PADDLE_PRICE_SILVER_MONTHLY", "pri_01kv0gcgyhq6tekz7dks3k38tn").strip(),
        "tier": "silver",
        "duration": "monthly",
        "months": 1,
        "price_usd": 2.0,
        "title": "الباقة الفضية - شهر",
        "features": ["silver_badge", "stories", "1200_chars", "25_ai_daily"],
    },
    "silver_quarterly": {
        "price_id": os.getenv("PADDLE_PRICE_SILVER_QUARTERLY", "pri_01kv0gfb942d1jwzm7dqpjs6gx").strip(),
        "tier": "silver",
        "duration": "quarterly",
        "months": 3,
        "price_usd": 5.0,
        "title": "الباقة الفضية - 3 أشهر",
        "features": ["silver_badge", "stories", "1200_chars", "25_ai_daily"],
    },
    "silver_yearly": {
        "price_id": os.getenv("PADDLE_PRICE_SILVER_YEARLY", "pri_01kv0ggvve19kjx7xeyt3qxmz1").strip(),
        "tier": "silver",
        "duration": "yearly",
        "months": 12,
        "price_usd": 18.0,
        "title": "الباقة الفضية - سنة",
        "features": ["silver_badge", "stories", "1200_chars", "25_ai_daily"],
    },

    # Gold
    "gold_monthly": {
        "price_id": os.getenv("PADDLE_PRICE_GOLD_MONTHLY", "pri_01kv0gm6cc3jrtehwk004b7y3m").strip(),
        "tier": "gold",
        "duration": "monthly",
        "months": 1,
        "price_usd": 4.0,
        "title": "الباقة الذهبية - شهر",
        "features": ["gold_badge", "stories", "2000_chars", "50_ai_daily", "priority_visibility"],
    },
    "gold_quarterly": {
        "price_id": os.getenv("PADDLE_PRICE_GOLD_QUARTERLY", "pri_01kv0gnjb9vw13zy3f1fmz18me").strip(),
        "tier": "gold",
        "duration": "quarterly",
        "months": 3,
        "price_usd": 10.0,
        "title": "الباقة الذهبية - 3 أشهر",
        "features": ["gold_badge", "stories", "2000_chars", "50_ai_daily", "priority_visibility"],
    },
    "gold_yearly": {
        "price_id": os.getenv("PADDLE_PRICE_GOLD_YEARLY", "pri_01kv0gpthm1pdq6k1tbsype8fd").strip(),
        "tier": "gold",
        "duration": "yearly",
        "months": 12,
        "price_usd": 35.0,
        "title": "الباقة الذهبية - سنة",
        "features": ["gold_badge", "stories", "2000_chars", "50_ai_daily", "priority_visibility"],
    },

    # Premium - Price IDs الجديدة من Paddle.
    "premium_monthly": {
        "price_id": os.getenv("PADDLE_PRICE_PREMIUM_MONTHLY", os.getenv("PADDLE_PRICE_MONTHLY", "pri_01kv0gsgt68d16rj466bj70q9g")).strip(),
        "tier": "premium",
        "duration": "monthly",
        "months": 1,
        "price_usd": 7.0,
        "title": "الباقة المميزة - شهر",
        "features": ["premium_badge", "stories", "3500_chars", "120_ai_daily", "highest_visibility"],
    },
    "premium_quarterly": {
        "price_id": os.getenv("PADDLE_PRICE_PREMIUM_QUARTERLY", os.getenv("PADDLE_PRICE_QUARTERLY", "pri_01kv0gtkvfm6g0w2pqz70gxveh")).strip(),
        "tier": "premium",
        "duration": "quarterly",
        "months": 3,
        "price_usd": 18.0,
        "title": "الباقة المميزة - 3 أشهر",
        "features": ["premium_badge", "stories", "3500_chars", "120_ai_daily", "highest_visibility"],
    },
    "premium_yearly": {
        "price_id": os.getenv("PADDLE_PRICE_PREMIUM_YEARLY", os.getenv("PADDLE_PRICE_YEARLY", "pri_01kv0gvvjcwqf95drws2etvphd")).strip(),
        "tier": "premium",
        "duration": "yearly",
        "months": 12,
        "price_usd": 60.0,
        "title": "الباقة المميزة - سنة",
        "features": ["premium_badge", "stories", "3500_chars", "120_ai_daily", "highest_visibility"],
    },
}

# توافق مع أسماء الخطط القديمة: monthly/quarterly/yearly تعتبر Premium.
PADDLE_LEGACY_PLAN_ALIASES = {
    "monthly": "premium_monthly",
    "quarterly": "premium_quarterly",
    "yearly": "premium_yearly",
}

PADDLE_PRICE_TO_PLAN: Dict[str, str] = {
    str(info.get("price_id", "")): plan_id
    for plan_id, info in PADDLE_VERIFICATION_PRICES.items()
    if str(info.get("price_id", "")).strip()
}

def _subscription_priority_for_tier(tier: str) -> int:
    tier = (tier or "").strip().lower()
    if tier == "premium":
        return 900
    if tier == "gold":
        return 520
    if tier == "silver":
        return 220
    return 0


def _subscription_label_for_tier(tier: str) -> str:
    tier = (tier or "").strip().lower()
    if tier == "premium":
        return "أولوية مميزة"
    if tier == "gold":
        return "أولوية ذهبية"
    if tier == "silver":
        return "أولوية فضية"
    return ""



# ================= Metered TURN Server =================
# ضع المفتاح في Render كمتغير بيئة ولا تضعه داخل تطبيق Flutter.
# مثال:
# METERED_DOMAIN=respect.metered.live
# METERED_API_KEY=your_metered_api_key
METERED_DOMAIN = os.getenv("METERED_DOMAIN", "respect.metered.live").strip().replace("https://", "").replace("http://", "").strip("/")
METERED_API_KEY = os.getenv("METERED_API_KEY", "").strip()
METERED_TIMEOUT_SECONDS = int(os.getenv("METERED_TIMEOUT_SECONDS", "10"))

# ================= Auth OTP Email =================
SMTP_HOST = os.getenv("SMTP_HOST", "").strip()
SMTP_PORT = int(os.getenv("SMTP_PORT", "587"))
SMTP_USERNAME = os.getenv("SMTP_USERNAME", "").strip()
SMTP_PASSWORD = os.getenv("SMTP_PASSWORD", "").strip()
SMTP_FROM = os.getenv("SMTP_FROM", SMTP_USERNAME or "Respect App <no-reply@respect-app.local>").strip()
OTP_TTL_MINUTES = int(os.getenv("OTP_TTL_MINUTES", "10"))
TRUSTED_DEVICE_DAYS = int(os.getenv("TRUSTED_DEVICE_DAYS", "90"))
LOGIN_MAX_FAILED_ATTEMPTS = int(os.getenv("LOGIN_MAX_FAILED_ATTEMPTS", "6"))
LOGIN_LOCK_MINUTES = int(os.getenv("LOGIN_LOCK_MINUTES", "30"))
PASSWORD_RESET_TTL_MINUTES = int(os.getenv("PASSWORD_RESET_TTL_MINUTES", "20"))
PUBLIC_APP_BASE_URL = os.getenv("PUBLIC_APP_BASE_URL", "https://respect-app-9fzq.onrender.com").rstrip("/")
RESPECT_EMAIL_LOGO_URL = os.getenv("RESPECT_EMAIL_LOGO_URL", "").strip()
RESPECT_EMAIL_BRAND_NAME = os.getenv("RESPECT_EMAIL_BRAND_NAME", "Respect App").strip() or "Respect App"

# ================= Twilio Verify SMS =================
# ضع هذه القيم في Render فقط ولا تضعها داخل Flutter:
# SMS_PROVIDER=twilio
# TWILIO_ACCOUNT_SID=ACxxxxxxxxxxxxxxxx
# TWILIO_AUTH_TOKEN=xxxxxxxxxxxxxxxx
# TWILIO_VERIFY_SERVICE_SID=VAxxxxxxxxxxxxxxxx
SMS_PROVIDER = os.getenv("SMS_PROVIDER", "").strip().lower()
TWILIO_ACCOUNT_SID = os.getenv("TWILIO_ACCOUNT_SID", "").strip()
TWILIO_AUTH_TOKEN = os.getenv("TWILIO_AUTH_TOKEN", "").strip()
TWILIO_VERIFY_SERVICE_SID = os.getenv("TWILIO_VERIFY_SERVICE_SID", "").strip()
TWILIO_TIMEOUT_SECONDS = int(os.getenv("TWILIO_TIMEOUT_SECONDS", "20"))

# ================= Respect AI / Qwen Model Studio =================
# لا تضع المفتاح داخل الكود. ضعه في Render كمتغير بيئة:
#
# مهم حسب حسابك في Alibaba Cloud Model Studio:
# إذا حسابك International / Singapore استخدم:
# QWEN_BASE_URL=https://dashscope-intl.aliyuncs.com/compatible-mode/v1
#
# إذا حسابك China mainland استخدم:
# QWEN_BASE_URL=https://dashscope.aliyuncs.com/compatible-mode/v1
QWEN_API_KEY = os.getenv("QWEN_API_KEY", "").strip()
# موديل النصوص: راجع التغريدات والردود النصية.
QWEN_TEXT_MODEL = os.getenv("QWEN_TEXT_MODEL", os.getenv("QWEN_MODEL", "qwen-plus")).strip() or "qwen-plus"
# موديل الصور: راجع صور المنشورات بعد رفعها إلى Supabase Storage.
QWEN_VISION_MODEL = os.getenv("QWEN_VISION_MODEL", "qwen-vl-plus").strip() or "qwen-vl-plus"
# اسم قديم للتوافق مع باقي الكود القديم.
QWEN_MODEL = QWEN_TEXT_MODEL
QWEN_BASE_URL = os.getenv("QWEN_BASE_URL", "https://dashscope-intl.aliyuncs.com/compatible-mode/v1").rstrip("/")


# ================= Respect Cyber AI / Hugging Face Inference Providers =================
# هذا لا يشغل الموديل داخل Render، بل يستدعي Hugging Face API حتى لا ينهار السيرفر بسبب RAM/CPU.
# ضع المتغيرات في Render:
# HF_TOKEN=hf_xxxxxxxxxxxxxxxxx
# HF_CYBER_MODEL=ZySec-AI/SecurityLLM
# ملاحظة: بعض الموديلات تحتاج provider مدعوم، مثال: model:provider أو استخدم موديل آخر من Inference Providers.
HF_TOKEN = os.getenv("HF_TOKEN", os.getenv("HUGGINGFACE_API_KEY", "")).strip()
HF_CYBER_MODEL = os.getenv("HF_CYBER_MODEL", "ZySec-AI/SecurityLLM").strip() or "ZySec-AI/SecurityLLM"
HF_BASE_URL = os.getenv("HF_BASE_URL", "https://router.huggingface.co/v1").rstrip("/")
HF_BILL_TO = os.getenv("HF_BILL_TO", "").strip()
HF_TIMEOUT_SECONDS = int(os.getenv("HF_TIMEOUT_SECONDS", "90"))

# ================= Link Safety / Google Safe Browsing =================
# ضع المفتاح في Render كمتغير بيئة:
GSB_TOKEN = _env_value("GOOGLE", "_SAFE", "_BROWSING", "_API", "_KEY")
GOOGLE_SAFE_BROWSING_ENDPOINT = "https://safebrowsing.googleapis.com/v4/threatMatches:find"

# ================= Link Safety / VirusTotal =================
# طبقة ثانية اختيارية للروابط المشبوهة فقط. ضع المفتاح في Render:
VIRUSTOTAL_API_KEY = os.getenv("VIRUSTOTAL_API_KEY", "").strip()
VIRUSTOTAL_BASE_URL = "https://www.virustotal.com/api/v3"

# احتياطي اختياري: لو حبيت ترجع Groq مؤقتًا بدون تعديل الكود.
GROQ_API_KEY = os.getenv("GROQ_API_KEY", "").strip()
GROQ_MODEL = os.getenv("GROQ_MODEL", "llama-3.3-70b-versatile").strip() or "llama-3.3-70b-versatile"
GROQ_BASE_URL = os.getenv("GROQ_BASE_URL", "https://api.groq.com/openai/v1").rstrip("/")

SCOPES = ["https://www.googleapis.com/auth/firebase.messaging"]

app = FastAPI(title="Respect App FCM + Respect AI Qwen Server")
app.add_middleware(
    CORSMiddleware,
    allow_origins=ALLOWED_ORIGINS,
    allow_credentials=True,
    allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
    allow_headers=[
        "Content-Type",
        "Authorization",
        "X-App-Secret",
        "X-App-Timestamp",
        "X-App-Nonce",
        "X-App-Signature",
        "X-App-Signature-Version",
        "X-Respect-Client",
        "X-Respect-Platform",
    ],
)


_moderation_rate: Dict[str, list[float]] = defaultdict(list)
_login_failures: Dict[str, Dict[str, Any]] = {}
_password_reset_tokens: Dict[str, Dict[str, Any]] = {}


def _client_ip(request: FastAPIRequest) -> str:
    forwarded = request.headers.get("x-forwarded-for", "").split(",")[0].strip()
    if forwarded:
        return forwarded
    return request.client.host if request.client else "unknown"


def _enforce_moderation_rate(ip: str, limit: int = 60) -> None:
    now = time.time()
    window = [t for t in _moderation_rate[ip] if now - t < 60]
    if len(window) >= limit:
        raise HTTPException(status_code=429, detail="Too many moderation requests")
    _moderation_rate[ip] = window + [now]


def _check_secret(x_app_secret: Optional[str]) -> None:
    if APP_SHARED_SECRET and x_app_secret != APP_SHARED_SECRET:
        raise HTTPException(status_code=401, detail="Invalid X-App-Secret")


_app_request_rate: Dict[str, list[float]] = defaultdict(list)
_seen_request_nonces: Dict[str, float] = {}


def _is_sensitive_app_path(path: str) -> bool:
    if path in {"/send_push", "/send_user_push", "/send_general_push", "/send_message_push", "/send_call_push"}:
        return True
    prefixes = (
        "/auth/",
        "/respect-ai/",
        "/paddle/",
        "/turn/",
        "/metered/",
        "/push_debug",
    )
    return any(path.startswith(prefix) for prefix in prefixes)


def _enforce_app_request_rate(ip: str, path: str) -> None:
    if APP_REQUEST_RATE_LIMIT_PER_MINUTE <= 0:
        return
    now = time.time()
    family = path.strip("/").split("/", 1)[0] or "root"
    key = f"{ip}:{family}"
    window = [t for t in _app_request_rate[key] if now - t < 60]
    if len(window) >= APP_REQUEST_RATE_LIMIT_PER_MINUTE:
        raise HTTPException(status_code=429, detail="Too many requests")
    _app_request_rate[key] = window + [now]


def _cleanup_request_nonces(now: float) -> None:
    if len(_seen_request_nonces) < 10000:
        return
    expired = [k for k, expires_at in _seen_request_nonces.items() if expires_at < now]
    for key in expired[:5000]:
        _seen_request_nonces.pop(key, None)


def _verify_signed_request(path: str, body: bytes, headers: Any) -> None:
    """
    توقيع دفاعي اختياري للطلبات الحساسة:
    X-App-Timestamp + X-App-Nonce + X-App-Signature
    signature = base64url(HMAC_SHA256(secret, "timestamp\\nnonce\\npath\\nraw_body"))
    """
    signing_secret = RESPECT_REQUEST_SIGNING_SECRET
    if not signing_secret:
        return

    timestamp = str(headers.get("x-app-timestamp", "") or "").strip()
    nonce = str(headers.get("x-app-nonce", "") or "").strip()
    signature = str(headers.get("x-app-signature", "") or "").strip()
    has_any_signature_header = bool(timestamp or nonce or signature)

    if not has_any_signature_header:
        if REQUIRE_REQUEST_SIGNATURE:
            raise HTTPException(status_code=401, detail="Missing request signature")
        return

    if not timestamp or not nonce or not signature:
        raise HTTPException(status_code=401, detail="Incomplete request signature")

    try:
        ts = int(timestamp)
    except Exception:
        raise HTTPException(status_code=401, detail="Invalid request timestamp")

    now = time.time()
    if abs(now - ts) > REQUEST_SIGNATURE_MAX_AGE_SECONDS:
        raise HTTPException(status_code=401, detail="Expired request signature")

    if len(nonce) < 12 or len(nonce) > 128:
        raise HTTPException(status_code=401, detail="Invalid request nonce")

    _cleanup_request_nonces(now)
    nonce_key = f"{timestamp}:{nonce}"
    if _seen_request_nonces.get(nonce_key, 0) > now:
        raise HTTPException(status_code=401, detail="Replay request blocked")

    body_text = body.decode("utf-8", errors="replace")
    payload = f"{timestamp}\n{nonce}\n{path}\n{body_text}".encode("utf-8")
    expected = base64.urlsafe_b64encode(
        hmac.new(signing_secret.encode("utf-8"), payload, hashlib.sha256).digest()
    ).decode("utf-8").rstrip("=")

    if not hmac.compare_digest(signature, expected):
        raise HTTPException(status_code=401, detail="Invalid request signature")

    _seen_request_nonces[nonce_key] = now + REQUEST_NONCE_TTL_SECONDS


@app.middleware("http")
async def _respect_security_middleware(request: FastAPIRequest, call_next):
    path = request.url.path
    scheme = request.url.scheme

    if _is_sensitive_app_path(path):
        _enforce_app_request_rate(_client_ip(request), path)
        body = await request.body()
        _verify_signed_request(path, body, request.headers)

        async def receive():
            return {"type": "http.request", "body": body, "more_body": False}

        request = FastAPIRequest(request.scope, receive)

    response = await call_next(request)

    # Headers أمنية عامة للوحة الويب وواجهات API.
    response.headers.setdefault("X-Content-Type-Options", "nosniff")
    response.headers.setdefault("X-Frame-Options", "DENY")
    response.headers.setdefault("Referrer-Policy", "no-referrer")
    response.headers.setdefault("Permissions-Policy", "geolocation=(), camera=(), microphone=()")
    response.headers.setdefault("Cross-Origin-Resource-Policy", "same-origin")
    if scheme == "https":
        response.headers.setdefault("Strict-Transport-Security", "max-age=31536000; includeSubDomains")
    return response


def _first_env_value(*names: str) -> str:
    for name in names:
        value = os.getenv(name, "").strip()
        if value:
            return value
    return ""


def _load_service_account_info() -> Dict[str, Any]:
    """
    يدعم أكثر من طريقة لوضع Firebase Service Account في Render:
    1) FIREBASE_SERVICE_ACCOUNT_JSON: JSON كامل.
    2) FIREBASE_SERVICE_ACCOUNT_BASE64: نفس JSON لكن Base64.
    3) FIREBASE_SERVICE_ACCOUNT_FILE: مسار ملف محلي.
    """
    raw_json = _first_env_value(
        "FIREBASE_SERVICE_ACCOUNT_JSON",
        "FIREBASE_SA_JSON",
        "GOOGLE_SERVICE_ACCOUNT_JSON",
        "GOOGLE_APPLICATION_CREDENTIALS_JSON",
    ) or SA_JSON

    raw_b64 = _first_env_value(
        "FIREBASE_SERVICE_ACCOUNT_BASE64",
        "FIREBASE_SA_BASE64",
        "GOOGLE_SERVICE_ACCOUNT_BASE64",
    )

    if raw_b64:
        try:
            raw_json = base64.b64decode(raw_b64).decode("utf-8")
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"Invalid FIREBASE_SERVICE_ACCOUNT_BASE64: {e}")

    if raw_json:
        try:
            raw_json = raw_json.strip()
            # بعض لوحات الاستضافة تحفظ JSON كسطر واحد مع \n داخل private_key.
            info = json.loads(raw_json)
            if isinstance(info, dict) and isinstance(info.get("private_key"), str):
                info["private_key"] = info["private_key"].replace("\\n", "\n")
            if not isinstance(info, dict):
                raise ValueError("service account JSON is not an object")
            missing = [k for k in ["project_id", "client_email", "private_key"] if not str(info.get(k, "")).strip()]
            if missing:
                raise ValueError(f"missing keys: {', '.join(missing)}")
            return info
        except HTTPException:
            raise
        except Exception as e:
            raise HTTPException(status_code=500, detail=f"Invalid FIREBASE_SERVICE_ACCOUNT_JSON: {e}")

    file_path = _first_env_value("FIREBASE_SERVICE_ACCOUNT_FILE", "GOOGLE_APPLICATION_CREDENTIALS") or SA_FILE
    if not file_path:
        raise HTTPException(
            status_code=500,
            detail="Missing Firebase service account. Set FIREBASE_SERVICE_ACCOUNT_JSON or FIREBASE_SERVICE_ACCOUNT_BASE64 in Render.",
        )

    if not os.path.exists(file_path):
        raise HTTPException(status_code=500, detail="Firebase service account file not found")

    try:
        with open(file_path, "r", encoding="utf-8") as f:
            info = json.load(f)
        if isinstance(info, dict) and isinstance(info.get("private_key"), str):
            info["private_key"] = info["private_key"].replace("\\n", "\n")
        return info
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Cannot read Firebase service account file: {e}")


def get_access_token() -> str:
    try:
        info = _load_service_account_info()
        creds = service_account.Credentials.from_service_account_info(info, scopes=SCOPES)
        creds.refresh(Request())
        if not creds.token:
            raise RuntimeError("empty firebase access token")
        return creds.token
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to create Firebase credential: {e}")


def normalize_username(value: str) -> str:
    return value.strip().lower().replace("@", "")



def _supabase_headers(use_service_role: bool = False) -> Dict[str, str]:
    key = SB_SERVICE if (use_service_role and SB_SERVICE) else SB_ANON
    return {
        "apikey": key,
        "Authorization": f"Bearer {key}",
        "Content-Type": "application/json",
    }


def _display_username(value: str) -> str:
    clean = normalize_username(value)
    return f"@{clean}" if clean else "@user"


def _today_key() -> str:
    from datetime import datetime, timezone
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


def _truthy(value: Any) -> bool:
    if value is True:
        return True
    v = str(value or "").strip().lower()
    return v in {"true", "1", "yes", "verified", "active"}


def _is_verified_user(user: Dict[str, Any]) -> bool:
    if not user:
        return False
    if _display_username(str(user.get("username", ""))) == "@respectai":
        return True
    from datetime import datetime, timezone
    expires_raw = str(
        user.get("verified_until")
        or user.get("verification_expires_at")
        or user.get("subscription_expires_at")
        or ""
    ).strip()
    expires_active = False
    has_expiry = False
    if expires_raw:
        has_expiry = True
        try:
            expires = datetime.fromisoformat(expires_raw.replace("Z", "+00:00"))
            if expires.tzinfo is None:
                expires = expires.replace(tzinfo=timezone.utc)
            expires_active = expires.astimezone(timezone.utc) > datetime.now(timezone.utc)
        except Exception:
            expires_active = False
    active_flags = any(_truthy(user.get(k)) for k in ["is_verified", "isVerified", "verified", "blue_badge", "respect_verified"])
    active_status = str(user.get("verification_status", "")).lower() == "active" or str(user.get("subscription_tier", "")).lower() == "verified"
    if has_expiry:
        return (active_flags or active_status) and expires_active
    return active_flags or active_status


def _fetch_user_for_limits(username: str) -> Dict[str, Any]:
    user = _display_username(username)
    clean = normalize_username(username)
    try:
        r = requests.get(
            f"{SB_URL}/rest/v1/users",
            headers=_supabase_headers(),
            params={"select": "*", "or": f"(username.eq.{user},username.eq.{clean})", "limit": "1"},
            timeout=8,
        )
        if r.status_code // 100 == 2:
            data = r.json()
            if isinstance(data, list) and data:
                return data[0]
    except Exception:
        pass
    return {}


def _respect_ai_usage_today(username: str) -> int:
    user = _display_username(username)
    try:
        r = requests.get(
            f"{SB_URL}/rest/v1/respect_ai_usage",
            headers={**_supabase_headers(), "Prefer": "count=exact"},
            params={"select": "id", "username": f"eq.{user}", "usage_day": f"eq.{_today_key()}"},
            timeout=8,
        )
        if r.status_code // 100 == 2:
            cr = r.headers.get("content-range", "")
            if "/" in cr:
                return int(cr.split("/")[-1])
            data = r.json()
            return len(data) if isinstance(data, list) else 0
    except Exception:
        pass
    return 0


def _record_respect_ai_usage(username: str) -> None:
    user = _display_username(username)
    try:
        requests.post(
            f"{SB_URL}/rest/v1/respect_ai_usage",
            headers={**_supabase_headers(), "Prefer": "return=minimal"},
            json={"username": user, "usage_day": _today_key()},
            timeout=8,
        )
    except Exception:
        pass


def _enforce_respect_ai_quota(username: str) -> None:
    user = _fetch_user_for_limits(username)
    limit = 50 if _is_verified_user(user) else 10
    used = _respect_ai_usage_today(username)
    if used >= limit:
        raise HTTPException(status_code=429, detail=f"وصلت لحد Respect AI اليومي ({limit} مرة). الحساب الموثق يحصل على 50 مرة يوميًا.")


def display_username(value: str) -> str:
    clean = normalize_username(value)
    return f"@{clean}" if clean else "@user"


def get_user_fcm_token(receiver_username: str) -> Optional[str]:
    clean = normalize_username(receiver_username)
    display = display_username(clean)
    if not clean:
        return None

    if not SB_URL or not (SB_SERVICE or SB_ANON):
        raise HTTPException(status_code=500, detail="Supabase env missing: SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY/SUPABASE_ANON_KEY")

    url = f"{SB_URL}/rest/v1/users"
    # السيرفر يستخدم service role إن وجد حتى لا تمنع RLS قراءة fcm_token.
    headers = _supabase_headers(use_service_role=True)
    params = {
        "select": "username,fcm_token",
        "or": f"(username.eq.{clean},username.eq.{display})",
        "limit": "1",
    }

    try:
        response = requests.get(url, headers=headers, params=params, timeout=15)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Supabase token lookup failed: {e}")

    if response.status_code >= 400:
        raise HTTPException(status_code=500, detail=f"Supabase token lookup error {response.status_code}: {_safe_response_text(response.text, 800)}")

    try:
        rows = response.json()
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Invalid Supabase token lookup JSON: {e}")

    if not isinstance(rows, list) or not rows:
        return None

    token = rows[0].get("fcm_token")
    token = str(token or "").strip()
    return token or None



def get_all_user_fcm_tokens() -> list[Dict[str, str]]:
    if not SB_URL or not (SB_SERVICE or SB_ANON):
        raise HTTPException(status_code=500, detail="Supabase env missing: SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY/SUPABASE_ANON_KEY")

    users: list[Dict[str, str]] = []
    offset = 0
    page_size = 1000
    headers = _supabase_headers(use_service_role=True)
    while True:
        response = requests.get(
            f"{SB_URL}/rest/v1/users",
            headers=headers,
            params={
                "select": "username,fcm_token",
                "fcm_token": "not.is.null",
                "limit": str(page_size),
                "offset": str(offset),
            },
            timeout=20,
        )
        if response.status_code >= 400:
            raise HTTPException(status_code=500, detail=f"Supabase users lookup error {response.status_code}: {_safe_response_text(response.text, 800)}")
        rows = response.json()
        if not isinstance(rows, list) or not rows:
            break
        for row in rows:
            token = str((row or {}).get("fcm_token") or "").strip()
            username = display_username(str((row or {}).get("username") or ""))
            if token:
                users.append({"username": username, "token": token})
        if len(rows) < page_size:
            break
        offset += page_size
    # إزالة تكرار التوكن حتى لا يصل الإشعار مرتين لنفس الجهاز.
    deduped: Dict[str, Dict[str, str]] = {}
    for item in users:
        deduped[item["token"]] = item
    return list(deduped.values())


def create_general_notification_row(title: str, body: str, sender_username: str, sender_name: str) -> str:
    notification_id = f"general_{int(time.time() * 1000000)}_{secrets.token_hex(4)}"
    try:
        payload = {
            "id": notification_id,
            "title": title,
            "body": body,
            "sender_username": display_username(sender_username),
            "sender_name": sender_name or "Respect Admin",
            "created_at": datetime.now(timezone.utc).isoformat(),
        }
        response = requests.post(
            f"{SB_URL}/rest/v1/respect_general_notifications",
            headers={**_supabase_headers(use_service_role=True), "Prefer": "return=minimal"},
            json=payload,
            timeout=12,
        )
        if response.status_code >= 400:
            logger.warning("general notification row insert failed status=%s body=%s", response.status_code, _safe_response_text(response.text))
    except Exception as exc:
        logger.warning("general notification row insert failed: %s", exc)
    return notification_id


class AuthOtpSendRequest(BaseModel):
    email: str
    purpose: str = Field(default="login")  # login / signup
    username: str = ""
    deviceId: str = ""


class AuthOtpVerifyRequest(BaseModel):
    email: str
    code: str
    purpose: str = Field(default="login")
    username: str = ""
    deviceId: str = ""


class TrustedDeviceRequest(BaseModel):
    username: str
    deviceId: str
    deviceName: str = ""
    days: int = Field(default=90)


class LoginAttemptCheckRequest(BaseModel):
    login: str
    deviceId: str = ""


class LoginAttemptReportRequest(BaseModel):
    login: str
    deviceId: str = ""
    success: bool = False


class PasswordResetRequest(BaseModel):
    login: str
    deviceId: str = ""


class PhoneSecuritySendRequest(BaseModel):
    username: str
    countryCode: str = "+961"
    phone: str
    deviceId: str = ""


class PhoneSecurityVerifyRequest(BaseModel):
    username: str
    phoneE164: str
    code: str
    deviceId: str = ""


class SmsLoginSendRequest(BaseModel):
    login: str
    deviceId: str = ""


class SmsLoginVerifyRequest(BaseModel):
    login: str
    code: str
    deviceId: str = ""


class AuthPasswordCreateRequest(BaseModel):
    email: str
    password: str
    username: str = ""
    name: str = ""


class PushRequest(BaseModel):
    token: str
    type: str = Field(default="message")
    title: str
    body: str
    data: Dict[str, Any] = Field(default_factory=dict)


class UserPushRequest(BaseModel):
    receiverUsername: str
    type: str = Field(default="message")
    title: str
    body: str
    data: Dict[str, Any] = Field(default_factory=dict)


class GeneralPushRequest(BaseModel):
    title: str
    body: str
    senderUsername: str = "@admin"
    senderName: str = "Respect Admin"
    data: Dict[str, Any] = Field(default_factory=dict)


class MessagePushRequest(BaseModel):
    receiverUsername: str
    senderUsername: str
    senderName: str = ""
    messageId: str
    text: str = ""


class CallPushRequest(BaseModel):
    receiverUsername: str
    callId: str
    callerUsername: str
    callerName: str = "مستخدم"
    callerAvatar: str = ""
    video: bool = False


class PaddleVerificationCheckoutRequest(BaseModel):
    username: str
    planId: str
    email: str = ""
    deviceId: str = ""
    successUrl: str = ""
    cancelUrl: str = ""


class RespectAIRequest(BaseModel):
    text: str = Field(default="", min_length=1)
    username: str = ""
    askerUsername: str = ""
    question: str = ""
    postText: str = ""
    parentReplyText: str = ""
    recentRepliesText: str = ""
    postId: str = ""
    mode: str = "reply"  # reply / summarize / poll / question / daily_question / daily_poll / daily_info
    language: str = "ar"


class RespectAIResponse(BaseModel):
    ok: bool
    reply: str
    model: str


class RespectAISearchExpandRequest(BaseModel):
    query: str = Field(default="", min_length=1)
    language: str = "ar"


class RespectAISearchExpandResponse(BaseModel):
    ok: bool
    query: str
    terms: list[str]
    model: str




class RespectAICyberRequest(BaseModel):
    text: str = Field(default="", min_length=1)
    username: str = ""
    mode: str = "defensive"  # defensive / explain / code_review / incident_response
    language: str = "ar"


class RespectAICyberResponse(BaseModel):
    ok: bool
    reply: str
    model: str

class RespectAIModerationRequest(BaseModel):
    text: str = Field(default="")
    username: str = ""
    postId: str = ""
    replyId: str = ""
    # روابط الصور العامة الخاصة بالمنشور. Flutter يرسلها بعد رفع الصور إلى Supabase Storage.
    imageUrls: list[str] = Field(default_factory=list)
    imageUrl: str = ""
    videoUrls: list[str] = Field(default_factory=list)
    videoUrl: str = ""
    contentType: str = "post"  # post / reply / story
    postText: str = ""
    parentReplyText: str = ""
    recentRepliesText: str = ""
    language: str = "ar"
    reportId: str = ""
    reporterUsername: str = ""
    reportedUsername: str = ""
    reason: str = ""
    details: str = ""
    communityId: str = ""
    communityName: str = ""


class RespectAIModerationResponse(BaseModel):
    ok: bool
    shouldDelete: bool = False
    deleteParentReply: bool = False
    reason: str = ""
    category: str = "safe"
    confidence: float = 0.0
    model: str


def _string_data(data: Dict[str, Any], msg_type: str, title: str, body: str) -> Dict[str, str]:
    # FCM data must be string:string only.
    merged = {**data, "type": msg_type, "title": title, "body": body}
    return {str(k): "" if v is None else str(v) for k, v in merged.items()}


def _fcm_ios_apns_config(msg_type: str, clean_data: Dict[str, str], privacy_data_only: bool) -> Dict[str, Any]:
    """
    إعداد APNs حتى تصل إشعارات iOS بشكل موثوق.
    لا نرسل محتوى حساس داخل alert؛ نستخدم نص عام ونترك التطبيق يقرأ data.
    مكالمات VoIP الحقيقية على iOS تحتاج PushKit + CallKit Native، وهذا الإعداد يحسن FCM العادي فقط.
    """
    is_call = msg_type == "call"
    is_message = msg_type == "message"
    alert_title = "Respect"
    if is_call:
        alert_body = "لديك مكالمة واردة"
    elif is_message:
        alert_body = "لديك رسالة جديدة"
    else:
        alert_body = "لديك إشعار جديد"

    aps: Dict[str, Any] = {
        "badge": 1,
        "sound": "default",
        "mutable-content": 1,
        "alert": {
            "title": alert_title,
            "body": alert_body,
        },
    }
    if privacy_data_only:
        aps["content-available"] = 1

    return {
        "headers": {
            "apns-priority": "10",
            "apns-push-type": "alert",
        },
        "payload": {
            "aps": aps,
            "respect": clean_data,
        },
    }


def send_fcm_v1(token: str, msg_type: str, title: str, body: str, data: Dict[str, Any]) -> Dict[str, Any]:
    token = token.strip()
    if not token:
        raise HTTPException(status_code=400, detail="Missing FCM token")

    access_token = get_access_token()
    url = f"https://fcm.googleapis.com/v1/projects/{PROJECT_ID}/messages:send"

    clean_data = _string_data(data, msg_type, title, body)

    privacy_data_only = os.getenv("FCM_PRIVACY_DATA_ONLY", "true").strip().lower() in {"1", "true", "yes", "on"}

    ios_apns = _fcm_ios_apns_config(msg_type, clean_data, privacy_data_only)

    if msg_type == "call" or privacy_data_only:
        # Privacy-first: Android يبقى Data Only، و iOS يأخذ APNs alert عام حتى لا يضيع الإشعار بالخلفية.
        # لا نضع أسماء أو نصوص حساسة داخل notification payload.
        payload = {
            "message": {
                "token": token,
                "data": clean_data,
                "android": {
                    "priority": "HIGH",
                    "ttl": "45s" if msg_type == "call" else "3600s",
                },
                "apns": ios_apns,
            }
        }
    else:
        # احتياطي اختياري لو عطلت FCM_PRIVACY_DATA_ONLY، يبقى الإشعار عامًا بدون محتوى حساس.
        payload = {
            "message": {
                "token": token,
                "notification": {
                    "title": "Respect",
                    "body": "لديك إشعار جديد",
                },
                "data": clean_data,
                "android": {
                    "priority": "HIGH",
                    "notification": {
                        "channel_id": "respect_messages_channel",
                        "sound": "default",
                    },
                },
                "apns": ios_apns,
            }
        }

    response = requests.post(
        url,
        headers={
            "Authorization": f"Bearer {access_token}",
            "Content-Type": "application/json; charset=UTF-8",
        },
        json=payload,
        timeout=20,
    )

    logger.info("FCM response type=%s status=%s", msg_type, response.status_code)
    logger.debug("FCM response body=%s", _safe_response_text(response.text))

    if response.status_code >= 400:
        raise HTTPException(
            status_code=400,
            detail={
                "firebase_status": response.status_code,
                "firebase_body": response.text,
                "hint": "SENDER_ID_MISMATCH يعني google-services.json أو service account من مشروع مختلف. UNREGISTERED يعني التوكن قديم.",
            },
        )

    try:
        firebase_body = response.json()
    except Exception:
        firebase_body = {"raw": response.text}

    return {
        "ok": True,
        "firebase": firebase_body,
        "sent_as": "data_only" if (msg_type == "call" or privacy_data_only) else "notification",
        "type": msg_type,
    }


@app.head("/")
def health_head():
    return {}


@app.get("/")
def health():
    return {
        "ok": True,
        "project": PROJECT_ID,
        "service_account_source": "env:FIREBASE_SERVICE_ACCOUNT_JSON" if SA_JSON else ("env:FIREBASE_SERVICE_ACCOUNT_FILE" if SA_FILE else "missing"),
        "using_service_account_json_env": bool(SA_JSON),
        "service_account_file_configured": bool(SA_FILE),
        "ai_provider": "qwen",
        "respect_ai_enabled": bool(QWEN_API_KEY),
        "respect_cyber_ai_enabled": bool(HF_TOKEN),
        "cyber_admin_page": "/respect-ai/cyber",
        "server_delete_enabled": bool(SB_SERVICE),
        "link_guard_enabled": bool(GSB_TOKEN),
        "virustotal_enabled": bool(VIRUSTOTAL_API_KEY),
        "qwen_model": QWEN_MODEL,
        "qwen_text_model": QWEN_TEXT_MODEL,
        "qwen_vision_model": QWEN_VISION_MODEL,
        "qwen_base_url": QWEN_BASE_URL,
        "moderation_endpoint": "/respect-ai/moderate",
        "story_moderation_endpoint": "/respect-ai/moderate-story",
        "turn_enabled": bool(METERED_API_KEY),
        "turn_domain": METERED_DOMAIN,
        "paddle_enabled": bool(PADDLE_API_KEY),
        "paddle_environment": PADDLE_ENVIRONMENT,
        "paddle_webhook_secret_configured": bool(PADDLE_WEBHOOK_SECRET),
        "paddle_client_side_token_configured": bool(PADDLE_CLIENT_SIDE_TOKEN),
        "paddle_checkout_page": "/paddle/checkout",
        "paddle_checkout_endpoint": "/paddle/create-verification-checkout",
        "sms_provider": SMS_PROVIDER,
        "twilio_verify_enabled": _twilio_configured(),
    }



@app.get("/paddle/checkout", response_class=HTMLResponse)
def paddle_checkout_page():
    """
    صفحة Checkout بسيطة لفتح Paddle Checkout من transaction id.
    اجعل Default payment link في Paddle يشير إلى:
    https://respect-app-9fzq.onrender.com/paddle/checkout

    وأضف في Render:
    PADDLE_CLIENT_SIDE_TOKEN=test_xxxxx
    """
    client_token = PADDLE_CLIENT_SIDE_TOKEN
    environment = PADDLE_ENVIRONMENT if PADDLE_ENVIRONMENT else "sandbox"

    return f"""
<!doctype html>
<html lang="ar" dir="rtl">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>Respect Verification Payment</title>
  <style>
    :root {{
      color-scheme: dark;
    }}
    * {{
      box-sizing: border-box;
    }}
    body {{
      margin: 0;
      font-family: Arial, Tahoma, sans-serif;
      background:
        radial-gradient(circle at top, rgba(124,58,237,.30), transparent 38%),
        linear-gradient(135deg, #07030f, #12091f 55%, #090514);
      color: white;
      display: flex;
      min-height: 100vh;
      align-items: center;
      justify-content: center;
      text-align: center;
      padding: 24px;
    }}
    .card {{
      width: min(560px, 100%);
      background: rgba(255,255,255,.08);
      border: 1px solid rgba(255,255,255,.14);
      border-radius: 28px;
      padding: 30px 24px;
      box-shadow: 0 24px 80px rgba(0,0,0,.42);
      backdrop-filter: blur(18px);
    }}
    .logo {{
      width: 64px;
      height: 64px;
      margin: 0 auto 14px;
      border-radius: 22px;
      background: linear-gradient(135deg, #7c3aed, #c084fc);
      display: grid;
      place-items: center;
      font-size: 30px;
      font-weight: 900;
      box-shadow: 0 18px 45px rgba(124,58,237,.35);
    }}
    h1 {{
      margin: 0;
      font-size: 25px;
    }}
    p {{
      color: rgba(255,255,255,.76);
      line-height: 1.75;
      margin: 10px 0;
    }}
    .loader {{
      width: 46px;
      height: 46px;
      border: 4px solid rgba(255,255,255,.18);
      border-top-color: #c084fc;
      border-radius: 50%;
      margin: 20px auto 12px;
      animation: spin 1s linear infinite;
    }}
    @keyframes spin {{ to {{ transform: rotate(360deg); }} }}
    .err {{
      color: #ffb4b4;
      margin-top: 14px;
      line-height: 1.7;
      word-break: break-word;
      font-weight: 700;
    }}
    .hint {{
      margin-top: 14px;
      font-size: 13px;
      color: rgba(255,255,255,.55);
    }}
    button {{
      margin-top: 16px;
      background: #7c3aed;
      color: white;
      border: 0;
      border-radius: 999px;
      padding: 12px 18px;
      font-weight: 800;
      cursor: pointer;
      display: none;
    }}
  </style>
</head>
<body>
  <main class="card">
    <div class="logo">✓</div>
    <h1>Respect Verification</h1>
    <div class="loader"></div>
    <p id="status">جاري فتح صفحة الدفع الآمنة...</p>
    <div id="error" class="err"></div>
    <button id="retry">إعادة المحاولة</button>
    <div class="hint">لا تغلق الصفحة حتى يفتح نموذج الدفع.</div>
  </main>

  <script src="https://cdn.paddle.com/paddle/v2/paddle.js"></script>
  <script>
    const clientToken = "{client_token}";
    const env = "{environment}";
    const params = new URLSearchParams(window.location.search);

    const transactionId =
      params.get("_ptxn") ||
      params.get("transaction_id") ||
      params.get("transactionId") ||
      params.get("txn") ||
      params.get("transaction");

    const errorBox = document.getElementById("error");
    const statusBox = document.getElementById("status");
    const retryBtn = document.getElementById("retry");

    function showError(msg) {{
      statusBox.textContent = "تعذر فتح الدفع";
      errorBox.textContent = msg;
      retryBtn.style.display = "inline-block";
    }}

    function openCheckout() {{
      errorBox.textContent = "";
      retryBtn.style.display = "none";
      statusBox.textContent = "جاري فتح صفحة الدفع الآمنة...";

      if (!clientToken) {{
        showError("PADDLE_CLIENT_SIDE_TOKEN غير موجود في Render.");
        return;
      }}
      if (!transactionId) {{
        showError("لم يتم العثور على transaction id في الرابط. ارجع للتطبيق واضغط خطة التوثيق من جديد.");
        return;
      }}

      try {{
        if (env === "sandbox" || env === "test" || env === "testing") {{
          Paddle.Environment.set("sandbox");
        }}
        Paddle.Initialize({{ token: clientToken }});
        Paddle.Checkout.open({{
          transactionId: transactionId,
          settings: {{
            displayMode: "overlay",
            theme: "dark",
            locale: "ar"
          }}
        }});
      }} catch (e) {{
        showError("تعذر فتح الدفع: " + (e && e.message ? e.message : e));
      }}
    }}

    retryBtn.addEventListener("click", openCheckout);
    openCheckout();
  </script>
</body>
</html>
"""


@app.get("/push_debug")
def push_debug(x_app_secret: Optional[str] = Header(default=None)):
    _check_secret(x_app_secret)
    return {
        "ok": True,
        "project": PROJECT_ID,
        "has_supabase_url": bool(SB_URL),
        "has_supabase_anon": bool(SB_ANON),
        "has_supabase_service_role": bool(SB_SERVICE),
        "has_app_shared_secret": bool(APP_SHARED_SECRET),
        "fcm_privacy_data_only": os.getenv("FCM_PRIVACY_DATA_ONLY", "true"),
        "firebase_json_env": bool(_first_env_value("FIREBASE_SERVICE_ACCOUNT_JSON", "FIREBASE_SA_JSON", "GOOGLE_SERVICE_ACCOUNT_JSON", "GOOGLE_APPLICATION_CREDENTIALS_JSON") or SA_JSON),
        "firebase_base64_env": bool(_first_env_value("FIREBASE_SERVICE_ACCOUNT_BASE64", "FIREBASE_SA_BASE64", "GOOGLE_SERVICE_ACCOUNT_BASE64")),
        "firebase_file_env": bool(_first_env_value("FIREBASE_SERVICE_ACCOUNT_FILE", "GOOGLE_APPLICATION_CREDENTIALS") or SA_FILE),
        "turn_enabled": bool(METERED_API_KEY),
        "turn_domain": METERED_DOMAIN,
    }


@app.get("/turn/credentials")
def turn_credentials(x_app_secret: Optional[str] = Header(default=None)):
    """
    يرجّع iceServers من Metered للتطبيق بدون كشف API Key داخل APK.
    Flutter يستدعي هذا endpoint قبل إنشاء RTCPeerConnection.
    """
    _check_secret(x_app_secret)

    if not METERED_API_KEY:
        # Fallback آمن: STUN فقط حتى لا تتعطل المكالمات بالكامل.
        return [
            {"urls": "stun:stun.cloudflare.com:3478"},
            {"urls": "stun:stun.l.google.com:19302"},
            {"urls": "stun:stun1.l.google.com:19302"},
            {"urls": "stun:stun2.l.google.com:19302"},
            {"urls": "stun:stun3.l.google.com:19302"},
        ]

    try:
        response = requests.get(
            f"https://{METERED_DOMAIN}/api/v1/turn/credentials",
            params={"apiKey": METERED_API_KEY},
            timeout=METERED_TIMEOUT_SECONDS,
        )
    except Exception as e:
        logger.warning("Metered TURN fetch failed: %s", e)
        return [
            {"urls": "stun:stun.cloudflare.com:3478"},
            {"urls": "stun:stun.l.google.com:19302"},
        ]

    if response.status_code >= 400:
        logger.warning(
            "Metered TURN error status=%s body=%s",
            response.status_code,
            _safe_response_text(response.text, 800),
        )
        raise HTTPException(
            status_code=400,
            detail=f"Metered TURN error {response.status_code}: {_safe_response_text(response.text, 800)}",
        )

    try:
        data = response.json()
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Invalid Metered TURN response: {e}")

    if not isinstance(data, list):
        raise HTTPException(status_code=500, detail="Metered TURN response is not a list")

    cleaned = []
    for item in data:
        if not isinstance(item, dict):
            continue
        urls = item.get("urls")
        if not urls:
            continue
        cleaned_item = {"urls": urls}
        if item.get("username"):
            cleaned_item["username"] = str(item.get("username"))
        if item.get("credential"):
            cleaned_item["credential"] = str(item.get("credential"))
        cleaned.append(cleaned_item)

    if not cleaned:
        return [
            {"urls": "stun:stun.cloudflare.com:3478"},
            {"urls": "stun:stun.l.google.com:19302"},
        ]

    return cleaned


def _otp_secret() -> bytes:
    secret = APP_SHARED_SECRET or SB_SERVICE or SB_ANON or PROJECT_ID
    return secret.encode("utf-8")


def _hash_otp(email: str, code: str, purpose: str, device_id: str = "") -> str:
    payload = f"{email.strip().lower()}|{purpose.strip().lower()}|{code.strip()}|{device_id.strip()}"
    return hmac.new(_otp_secret(), payload.encode("utf-8"), hashlib.sha256).hexdigest()


def _normalize_email(value: str) -> str:
    return str(value or "").strip().lower()


def _valid_email(value: str) -> bool:
    return bool(re.match(r"^[^\s@]+@[^\s@]+\.[^\s@]+$", _normalize_email(value)))



def _normalize_phone_e164(country_code: str, phone: str) -> str:
    raw_phone = str(phone or "").strip()
    raw_country = str(country_code or "").strip()
    if not raw_phone:
        raise HTTPException(status_code=400, detail="اكتب رقم الجوال")

    # لو المستخدم كتب الرقم كاملًا مع + نأخذه كما هو بعد تنظيفه.
    if raw_phone.startswith("+"):
        digits = re.sub(r"\D+", "", raw_phone)
        e164 = f"+{digits}"
    else:
        cc_digits = re.sub(r"\D+", "", raw_country)
        phone_digits = re.sub(r"\D+", "", raw_phone)
        # إزالة الأصفار الأولى من الرقم المحلي حتى لا يصبح +96103...
        phone_digits = phone_digits.lstrip("0")
        if not cc_digits:
            raise HTTPException(status_code=400, detail="اكتب كود الدولة مثل +961")
        e164 = f"+{cc_digits}{phone_digits}"

    if not re.match(r"^\+[1-9]\d{7,14}$", e164):
        raise HTTPException(status_code=400, detail="رقم الجوال غير صحيح. استخدم الصيغة الدولية مثل +961xxxxxxxx")
    return e164


def _twilio_configured() -> bool:
    return SMS_PROVIDER == "twilio" and bool(TWILIO_ACCOUNT_SID and TWILIO_AUTH_TOKEN and TWILIO_VERIFY_SERVICE_SID)


def _twilio_verify_start(phone_e164: str) -> Dict[str, Any]:
    if not _twilio_configured():
        raise HTTPException(status_code=500, detail="Twilio Verify غير مضبوط في Render")
    url = f"https://verify.twilio.com/v2/Services/{TWILIO_VERIFY_SERVICE_SID}/Verifications"
    try:
        r = requests.post(
            url,
            data={"To": phone_e164, "Channel": "sms"},
            auth=(TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN),
            timeout=TWILIO_TIMEOUT_SECONDS,
        )
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"تعذر إرسال SMS: {exc}")
    if r.status_code >= 400:
        raise HTTPException(status_code=400, detail=f"Twilio SMS error {r.status_code}: {_safe_response_text(r.text, 700)}")
    try:
        return r.json()
    except Exception:
        return {"raw": r.text}


def _twilio_verify_check(phone_e164: str, code: str) -> Dict[str, Any]:
    if not _twilio_configured():
        raise HTTPException(status_code=500, detail="Twilio Verify غير مضبوط في Render")
    clean_code = re.sub(r"\D+", "", str(code or ""))
    if not re.match(r"^\d{4,10}$", clean_code):
        raise HTTPException(status_code=400, detail="رمز SMS غير صحيح")
    url = f"https://verify.twilio.com/v2/Services/{TWILIO_VERIFY_SERVICE_SID}/VerificationCheck"
    try:
        r = requests.post(
            url,
            data={"To": phone_e164, "Code": clean_code},
            auth=(TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN),
            timeout=TWILIO_TIMEOUT_SECONDS,
        )
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"تعذر التحقق من SMS: {exc}")
    if r.status_code >= 400:
        raise HTTPException(status_code=400, detail=f"Twilio verify error {r.status_code}: {_safe_response_text(r.text, 700)}")
    try:
        data = r.json()
    except Exception:
        data = {"raw": r.text}
    if str(data.get("status") or "").lower() != "approved":
        raise HTTPException(status_code=400, detail="رمز SMS غير صحيح أو انتهت صلاحيته")
    return data


def _safe_user_for_client(user: Dict[str, Any]) -> Dict[str, Any]:
    allowed = {
        "id", "username", "name", "bio", "email", "avatar_url", "cover_url",
        "is_verified", "verified", "verified_until", "verification_status", "subscription_tier",
        "is_blocked", "blocked_at", "created_at", "is_admin",
        "phone_e164", "phone_country_code", "phone_national", "phone_verified",
        "phone_verified_at", "sms_security_enabled", "sms_login_enabled",
    }
    return {str(k): v for k, v in (user or {}).items() if str(k) in allowed}


def _update_user_phone_security(username: str, phone_e164: str, country_code: str = "", phone_national: str = "") -> None:
    user = _display_username(username)
    clean = normalize_username(user)
    payload = {
        "phone_e164": phone_e164,
        "phone_country_code": str(country_code or "").strip(),
        "phone_national": str(phone_national or "").strip(),
        "phone_verified": True,
        "phone_verified_at": datetime.now(timezone.utc).isoformat(),
        "sms_security_enabled": True,
        "sms_login_enabled": True,
        "updated_at": datetime.now(timezone.utc).isoformat(),
    }
    r = requests.patch(
        f"{SB_URL}/rest/v1/users",
        headers={**_supabase_headers(use_service_role=True), "Prefer": "return=minimal"},
        params={"or": f"(username.eq.{user},username.eq.{clean})"},
        json=payload,
        timeout=12,
    )
    if r.status_code >= 400:
        raise HTTPException(status_code=500, detail=f"تعذر حفظ رقم الجوال: {_safe_response_text(r.text, 700)}")



def _login_attempt_key(login: str, device_id: str = "") -> str:
    clean = str(login or "").strip().lower().replace("@", "")
    dev = str(device_id or "").strip()[:120]
    return f"{clean}|{dev}"


def _login_attempt_status(login: str, device_id: str = "") -> Dict[str, Any]:
    key = _login_attempt_key(login, device_id)
    row = _login_failures.get(key) or {"attempts": 0, "locked_until": None}
    now = datetime.now(timezone.utc)
    locked_until = row.get("locked_until")
    if isinstance(locked_until, str):
        try:
            locked_until = datetime.fromisoformat(locked_until.replace("Z", "+00:00"))
        except Exception:
            locked_until = None
    if locked_until and locked_until.tzinfo is None:
        locked_until = locked_until.replace(tzinfo=timezone.utc)
    if locked_until and locked_until > now:
        remaining = max(1, int((locked_until - now).total_seconds()))
        return {
            "allowed": False,
            "attempts": int(row.get("attempts") or 0),
            "remainingAttempts": 0,
            "lockedUntil": locked_until.isoformat(),
            "retryAfterSeconds": remaining,
            "message": "تم إيقاف تسجيل الدخول مؤقتًا بعد 6 محاولات فاشلة. استخدم نسيت كلمة المرور أو حاول لاحقًا.",
        }
    if locked_until and locked_until <= now:
        _login_failures.pop(key, None)
        row = {"attempts": 0, "locked_until": None}
    attempts = int(row.get("attempts") or 0)
    return {
        "allowed": True,
        "attempts": attempts,
        "remainingAttempts": max(0, LOGIN_MAX_FAILED_ATTEMPTS - attempts),
        "lockedUntil": None,
        "retryAfterSeconds": 0,
    }


def _record_login_attempt(login: str, device_id: str = "", success: bool = False) -> Dict[str, Any]:
    key = _login_attempt_key(login, device_id)
    if success:
        _login_failures.pop(key, None)
        return _login_attempt_status(login, device_id)
    row = _login_failures.get(key) or {"attempts": 0, "locked_until": None}
    attempts = int(row.get("attempts") or 0) + 1
    locked_until = None
    if attempts >= LOGIN_MAX_FAILED_ATTEMPTS:
        locked_until = datetime.now(timezone.utc) + timedelta(minutes=LOGIN_LOCK_MINUTES)
    _login_failures[key] = {"attempts": attempts, "locked_until": locked_until.isoformat() if locked_until else None}
    status = _login_attempt_status(login, device_id)
    status["attempts"] = attempts
    status["remainingAttempts"] = max(0, LOGIN_MAX_FAILED_ATTEMPTS - attempts)
    return status


def _find_public_user_for_login(login: str) -> Optional[Dict[str, Any]]:
    clean = str(login or "").strip().lower()
    if not clean:
        return None
    display = _display_username(clean)
    params = {"select": "*", "limit": "1"}
    if _valid_email(clean):
        params["email"] = f"eq.{_normalize_email(clean)}"
    else:
        params["or"] = f"(username.eq.{display},username.eq.{clean.replace('@','')})"
    try:
        r = requests.get(f"{SB_URL}/rest/v1/users", headers=_supabase_headers(use_service_role=True), params=params, timeout=12)
        if r.status_code // 100 == 2:
            data = r.json()
            if isinstance(data, list) and data:
                return data[0]
    except Exception as exc:
        logger.warning("find public user failed: %s", exc)
    return None


def _respect_email_shell(
    *,
    title: str,
    preheader: str,
    heading: str,
    body_html: str,
    button_text: str = "",
    button_url: str = "",
    code: str = "",
    footer_note: str = "",
) -> str:
    """
    قالب HTML Email فاخر وآمن لرسائل Respect App.
    - يدعم اللوجو من Render عبر RESPECT_EMAIL_LOGO_URL.
    - يحافظ على نسخة نصية fallback في دوال الإرسال.
    - يستخدم inline styles حتى يظهر بشكل جيد داخل Gmail و Outlook قدر الإمكان.
    """
    safe_title = html_lib.escape(title)
    safe_preheader = html_lib.escape(preheader)
    safe_heading = html_lib.escape(heading)
    safe_brand = html_lib.escape(RESPECT_EMAIL_BRAND_NAME)
    safe_button_text = html_lib.escape(button_text)
    safe_button_url = html_lib.escape(button_url, quote=True)
    safe_code = html_lib.escape(code)
    safe_footer_note = html_lib.escape(footer_note)

    logo_url = RESPECT_EMAIL_LOGO_URL.strip()
    safe_logo_url = html_lib.escape(logo_url, quote=True)

    if safe_logo_url:
        logo_block = f"""
          <table role="presentation" align="center" cellspacing="0" cellpadding="0" border="0" style="margin:0 auto 14px;">
            <tr>
              <td align="center" style="width:78px;height:78px;border-radius:28px;background:linear-gradient(135deg,#5b21b6,#a855f7,#d8b4fe);box-shadow:0 20px 50px rgba(124,58,237,.42);padding:4px;">
                <img src="{safe_logo_url}" width="70" height="70" alt="{safe_brand}" style="display:block;width:70px;height:70px;border-radius:24px;object-fit:cover;border:0;outline:none;text-decoration:none;">
              </td>
            </tr>
          </table>
        """
    else:
        logo_block = f"""
          <table role="presentation" align="center" cellspacing="0" cellpadding="0" border="0" style="margin:0 auto 14px;">
            <tr>
              <td align="center" valign="middle" style="width:78px;height:78px;border-radius:28px;background:linear-gradient(135deg,#5b21b6,#a855f7,#d8b4fe);box-shadow:0 20px 50px rgba(124,58,237,.42);">
                <span style="display:block;color:#ffffff;font-size:38px;line-height:78px;font-weight:900;font-family:Arial,Tahoma,sans-serif;">R</span>
              </td>
            </tr>
          </table>
        """

    button_block = ""
    if button_text and button_url:
        button_block = f"""
          <tr>
            <td align="center" style="padding:26px 0 10px;">
              <a href="{safe_button_url}" target="_blank"
                 style="display:inline-block;background:#7c3aed;background-image:linear-gradient(135deg,#6d28d9 0%,#9333ea 45%,#c084fc 100%);color:#ffffff;text-decoration:none;font-weight:900;font-size:16px;line-height:1;padding:17px 30px;border-radius:999px;box-shadow:0 18px 38px rgba(124,58,237,.44);font-family:Tahoma,Arial,sans-serif;">
                {safe_button_text}
              </a>
            </td>
          </tr>
          <tr>
            <td style="padding:12px 4px 0;">
              <div style="background:rgba(255,255,255,.045);border:1px solid rgba(192,132,252,.16);border-radius:16px;padding:13px 14px;font-size:12px;line-height:1.8;color:#b7afcf;word-break:break-all;text-align:center;font-family:Tahoma,Arial,sans-serif;">
                إذا لم يعمل الزر، انسخ الرابط التالي وافتحه في المتصفح:<br>
                <a href="{safe_button_url}" target="_blank" style="color:#d8b4fe;text-decoration:none;">{safe_button_url}</a>
              </div>
            </td>
          </tr>
        """

    code_block = ""
    if code:
        code_block = f"""
          <tr>
            <td align="center" style="padding:22px 0 10px;">
              <div style="display:inline-block;direction:ltr;letter-spacing:10px;background:#12091f;background-image:linear-gradient(135deg,#11071d 0%,#1e1033 48%,#160a25 100%);border:1px solid rgba(216,180,254,.36);color:#ffffff;font-size:36px;line-height:1;font-weight:900;border-radius:20px;padding:20px 24px;box-shadow:inset 0 0 0 1px rgba(255,255,255,.045),0 18px 42px rgba(0,0,0,.30);font-family:Arial,Tahoma,sans-serif;">
                {safe_code}
              </div>
            </td>
          </tr>
        """

    footer_block = ""
    if footer_note:
        footer_block = f"""
          <tr>
            <td style="padding-top:20px;">
              <div style="background:linear-gradient(135deg,rgba(124,58,237,.13),rgba(255,255,255,.045));border:1px solid rgba(216,180,254,.15);border-radius:18px;padding:15px 16px;color:#c4bdd8;font-size:13px;line-height:1.9;font-family:Tahoma,Arial,sans-serif;">
                {safe_footer_note}
              </div>
            </td>
          </tr>
        """

    return f"""<!doctype html>
<html lang="ar" dir="rtl">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <meta name="color-scheme" content="dark light">
  <meta name="supported-color-schemes" content="dark light">
  <title>{safe_title}</title>
</head>
<body style="margin:0;padding:0;background:#05020a;color:#ffffff;-webkit-text-size-adjust:100%;-ms-text-size-adjust:100%;font-family:'Cairo','Tajawal','IBM Plex Sans Arabic',Tahoma,Arial,sans-serif;">
  <div style="display:none;max-height:0;overflow:hidden;opacity:0;color:transparent;mso-hide:all;">{safe_preheader}</div>

  <table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="width:100%;background:#05020a;">
    <tr>
      <td align="center" style="padding:34px 12px;background:#05020a;background-image:radial-gradient(circle at 50% 0%,rgba(147,51,234,.42) 0%,rgba(88,28,135,.18) 28%,rgba(5,2,10,0) 62%),linear-gradient(135deg,#05020a 0%,#10051d 48%,#07030f 100%);">
        <table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="max-width:590px;width:100%;border-collapse:separate;border-spacing:0;">
          <tr>
            <td style="padding:1px;border-radius:32px;background:linear-gradient(135deg,rgba(216,180,254,.42),rgba(124,58,237,.20),rgba(255,255,255,.08));">
              <table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="width:100%;background:#100719;background-image:radial-gradient(circle at 50% 0%,rgba(124,58,237,.30),rgba(16,7,25,0) 46%),linear-gradient(180deg,#140821 0%,#0b0413 100%);border-radius:31px;overflow:hidden;">
                <tr>
                  <td style="height:7px;background:#7c3aed;background-image:linear-gradient(90deg,#4c1d95 0%,#8b5cf6 45%,#d8b4fe 100%);font-size:0;line-height:0;">&nbsp;</td>
                </tr>

                <tr>
                  <td align="center" style="padding:34px 30px 10px;text-align:center;">
                    {logo_block}
                    <div style="display:inline-block;padding:6px 12px;border-radius:999px;background:rgba(124,58,237,.16);border:1px solid rgba(216,180,254,.20);color:#d8b4fe;font-size:12px;font-weight:900;letter-spacing:.9px;text-transform:uppercase;font-family:Arial,Tahoma,sans-serif;">
                      {safe_brand}
                    </div>
                    <h1 style="margin:16px 0 0;color:#ffffff;font-size:28px;line-height:1.45;font-weight:900;text-align:center;font-family:'Cairo','Tajawal','IBM Plex Sans Arabic',Tahoma,Arial,sans-serif;">
                      {safe_heading}
                    </h1>
                  </td>
                </tr>

                <tr>
                  <td style="padding:12px 34px 0;">
                    <div style="background:rgba(255,255,255,.045);border:1px solid rgba(255,255,255,.08);border-radius:22px;padding:20px 20px;color:#e9ddff;font-size:15px;line-height:2;text-align:right;font-family:'Cairo','Tajawal','IBM Plex Sans Arabic',Tahoma,Arial,sans-serif;">
                      {body_html}
                    </div>
                  </td>
                </tr>

                {code_block}
                {button_block}
                {footer_block}

                <tr>
                  <td style="padding:26px 34px 32px;text-align:center;">
                    <div style="height:1px;background:linear-gradient(90deg,rgba(255,255,255,0),rgba(216,180,254,.26),rgba(255,255,255,0));margin:0 0 18px;"></div>
                    <div style="color:#9b91b5;font-size:12px;line-height:1.9;font-family:Tahoma,Arial,sans-serif;">
                      هذه رسالة أمان تلقائية من <strong style="color:#c4b5fd;">{safe_brand}</strong>.<br>
                      لا تشارك الرموز أو روابط التحقق مع أي شخص.
                    </div>
                  </td>
                </tr>
              </table>
            </td>
          </tr>

          <tr>
            <td align="center" style="padding:18px 12px 0;color:#736989;font-size:11px;line-height:1.7;text-align:center;font-family:Tahoma,Arial,sans-serif;">
              © {safe_brand} — Security Notification
            </td>
          </tr>
        </table>
      </td>
    </tr>
  </table>
</body>
</html>"""

def _send_password_reset_email(email: str, reset_url: str) -> str:
    subject = "إعادة تعيين كلمة مرور Respect App"
    body = (
        "مرحبًا،\n\n"
        "تم طلب إعادة تعيين كلمة المرور لحسابك في Respect App.\n\n"
        "افتح الرابط التالي لتعيين كلمة مرور جديدة:\n"
        f"{reset_url}\n\n"
        f"صلاحية الرابط: {PASSWORD_RESET_TTL_MINUTES} دقيقة.\n"
        "إذا لم تطلب هذا الرابط، تجاهل هذه الرسالة.\n"
    )
    html_body = _respect_email_shell(
        title=subject,
        preheader=f"رابط إعادة تعيين كلمة المرور صالح لمدة {PASSWORD_RESET_TTL_MINUTES} دقيقة.",
        heading="إعادة تعيين كلمة المرور",
        body_html=f"""
          <p style="margin:0 0 12px;">وصلنا طلب لتغيير كلمة مرور حسابك في <strong style="color:#ffffff;">Respect App</strong>.</p>
          <p style="margin:0;">اضغط الزر بالأسفل لتعيين كلمة مرور جديدة. الرابط صالح لمدة <strong style="color:#ffffff;">{PASSWORD_RESET_TTL_MINUTES} دقيقة</strong>.</p>
        """,
        button_text="إعادة تعيين كلمة المرور",
        button_url=reset_url,
        footer_note="إذا لم تطلب إعادة تعيين كلمة المرور، تجاهل هذه الرسالة ولن يتم تغيير أي شيء في حسابك.",
    )
    if not SMTP_HOST or not SMTP_USERNAME or not SMTP_PASSWORD:
        logger.warning("Password reset SMTP is not configured. Reset link for %s: %s", email, reset_url)
        return "log_only"
    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = SMTP_FROM
    msg["To"] = email
    msg.set_content(body)
    msg.add_alternative(html_body, subtype="html")
    with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=20) as server:
        server.starttls()
        server.login(SMTP_USERNAME, SMTP_PASSWORD)
        server.send_message(msg)
    return "email"


def _password_reset_token_hash(token: str) -> str:
    return hmac.new(_otp_secret(), str(token or "").encode("utf-8"), hashlib.sha256).hexdigest()


def _store_password_reset_token(email: str, token_hash: str, username: str, device_id: str = "") -> None:
    expires = datetime.now(timezone.utc) + timedelta(minutes=PASSWORD_RESET_TTL_MINUTES)
    _password_reset_tokens[token_hash] = {"email": email, "username": username, "device_id": device_id, "expires_at": expires.isoformat(), "used": False}
    try:
        requests.post(
            f"{SB_URL}/rest/v1/respect_password_resets",
            headers={**_supabase_headers(use_service_role=True), "Prefer": "return=minimal"},
            json={"email": email, "username": username, "token_hash": token_hash, "device_id": device_id, "expires_at": expires.isoformat(), "used_at": None},
            timeout=10,
        )
    except Exception as exc:
        logger.warning("password reset token DB store skipped: %s", exc)


def _read_password_reset_token(token: str) -> Dict[str, Any]:
    token_hash = _password_reset_token_hash(token)
    try:
        r = requests.get(
            f"{SB_URL}/rest/v1/respect_password_resets",
            headers=_supabase_headers(use_service_role=True),
            params={"select": "*", "token_hash": f"eq.{token_hash}", "used_at": "is.null", "order": "created_at.desc", "limit": "1"},
            timeout=10,
        )
        if r.status_code // 100 == 2:
            data = r.json()
            if isinstance(data, list) and data:
                return data[0]
    except Exception as exc:
        logger.warning("password reset token DB read skipped: %s", exc)
    row = _password_reset_tokens.get(token_hash)
    if not row or row.get("used"):
        raise HTTPException(status_code=400, detail="رابط إعادة التعيين غير صحيح أو مستخدم")
    return {**row, "token_hash": token_hash}


def _consume_password_reset_token(token_hash: str) -> None:
    try:
        requests.patch(
            f"{SB_URL}/rest/v1/respect_password_resets",
            headers={**_supabase_headers(use_service_role=True), "Prefer": "return=minimal"},
            params={"token_hash": f"eq.{token_hash}"},
            json={"used_at": datetime.now(timezone.utc).isoformat()},
            timeout=10,
        )
    except Exception:
        pass
    if token_hash in _password_reset_tokens:
        _password_reset_tokens[token_hash]["used"] = True


def _update_supabase_auth_password(email: str, password: str) -> None:
    if not SB_SERVICE:
        raise HTTPException(status_code=500, detail="SUPABASE_SERVICE_ROLE_KEY غير موجود في Render")
    headers = {"apikey": SB_SERVICE, "Authorization": f"Bearer {SB_SERVICE}", "Content-Type": "application/json"}
    find = requests.get(f"{SB_URL}/auth/v1/admin/users", headers=headers, params={"page": 1, "per_page": 1000}, timeout=20)
    if find.status_code >= 400:
        raise HTTPException(status_code=400, detail=f"تعذر البحث عن الحساب: {find.status_code} {_safe_response_text(find.text, 500)}")
    body = find.json() if find.text else {}
    users = body.get("users", []) if isinstance(body, dict) else []
    user_id = ""
    for u in users:
        if isinstance(u, dict) and str(u.get("email", "")).strip().lower() == email:
            user_id = str(u.get("id") or "").strip()
            break
    if not user_id:
        raise HTTPException(status_code=404, detail="لم يتم العثور على حساب Auth لهذا البريد")
    patch = requests.put(f"{SB_URL}/auth/v1/admin/users/{user_id}", headers=headers, json={"password": password, "email_confirm": True}, timeout=20)
    if patch.status_code >= 400:
        raise HTTPException(status_code=400, detail=f"تعذر تحديث كلمة المرور: {patch.status_code} {_safe_response_text(patch.text, 500)}")
    try:
        protected = "reset_via_supabase_auth_" + hashlib.sha256((email + "|" + str(time.time())).encode()).hexdigest()
        requests.patch(
            f"{SB_URL}/rest/v1/users",
            headers={**_supabase_headers(use_service_role=True), "Prefer": "return=minimal"},
            params={"email": f"eq.{email}"},
            json={"password": protected, "password_hash": protected, "password_encryption_version": "supabase_auth_reset_v1", "updated_at": datetime.now(timezone.utc).isoformat()},
            timeout=10,
        )
    except Exception:
        pass


def _send_otp_email(email: str, code: str, purpose: str) -> str:
    subject = "رمز تحقق Respect App"
    action = "إنشاء الحساب" if purpose == "signup" else "تسجيل الدخول"
    body = (
        "مرحبًا،\n\n"
        "رمز التحقق الخاص بك في Respect App هو:\n\n"
        f"{code}\n\n"
        f"الغرض: {action}\n"
        f"صلاحية الرمز: {OTP_TTL_MINUTES} دقائق.\n\n"
        "إذا لم تطلب هذا الرمز، تجاهل هذه الرسالة.\n"
    )
    html_body = _respect_email_shell(
        title=subject,
        preheader=f"رمز تحقق Respect App صالح لمدة {OTP_TTL_MINUTES} دقائق.",
        heading="رمز التحقق الخاص بك",
        body_html=f"""
          <p style="margin:0 0 12px;">استخدم الرمز التالي لإكمال <strong style="color:#ffffff;">{html_lib.escape(action)}</strong> في Respect App.</p>
          <p style="margin:0;">صلاحية الرمز <strong style="color:#ffffff;">{OTP_TTL_MINUTES} دقائق</strong>. لا تشاركه مع أي شخص.</p>
        """,
        code=code,
        footer_note="إذا لم تكن أنت من طلب هذا الرمز، تجاهل الرسالة وتأكد من حماية بريدك وكلمة مرورك.",
    )
    if not SMTP_HOST or not SMTP_USERNAME or not SMTP_PASSWORD:
        logger.warning("OTP email SMTP is not configured. OTP for %s (%s): %s", email, purpose, code)
        return "log_only"

    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = SMTP_FROM
    msg["To"] = email
    msg.set_content(body)
    msg.add_alternative(html_body, subtype="html")

    with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=20) as server:
        server.starttls()
        server.login(SMTP_USERNAME, SMTP_PASSWORD)
        server.send_message(msg)
    return "email"


def _insert_otp_row(email: str, code_hash: str, purpose: str, username: str, device_id: str) -> None:
    expires = datetime.now(timezone.utc) + timedelta(minutes=OTP_TTL_MINUTES)
    payload = {
        "email": email,
        "username": display_username(username) if username else "",
        "purpose": purpose,
        "code_hash": code_hash,
        "device_id": device_id,
        "expires_at": expires.isoformat(),
        "attempts": 0,
    }
    r = requests.post(
        f"{SB_URL}/rest/v1/respect_auth_otps",
        headers={**_supabase_headers(use_service_role=True), "Prefer": "return=minimal"},
        json=payload,
        timeout=12,
    )
    if r.status_code >= 400:
        raise HTTPException(status_code=500, detail=f"Supabase OTP insert error: {_safe_response_text(r.text)}")


def _latest_otp_row(email: str, purpose: str, device_id: str) -> Dict[str, Any]:
    params = {
        "select": "*",
        "email": f"eq.{email}",
        "purpose": f"eq.{purpose}",
        "consumed_at": "is.null",
        "order": "created_at.desc",
        "limit": "1",
    }
    if device_id:
        params["device_id"] = f"eq.{device_id}"
    r = requests.get(
        f"{SB_URL}/rest/v1/respect_auth_otps",
        headers=_supabase_headers(use_service_role=True),
        params=params,
        timeout=12,
    )
    if r.status_code >= 400:
        raise HTTPException(status_code=500, detail=f"Supabase OTP read error: {_safe_response_text(r.text)}")
    data = r.json()
    if not isinstance(data, list) or not data:
        raise HTTPException(status_code=400, detail="رمز التحقق غير موجود أو انتهت صلاحيته")
    return data[0]


def _mark_otp_attempt(row_id: str, attempts: int, consumed: bool = False) -> None:
    payload: Dict[str, Any] = {"attempts": attempts}
    if consumed:
        payload["consumed_at"] = datetime.now(timezone.utc).isoformat()
    try:
        requests.patch(
            f"{SB_URL}/rest/v1/respect_auth_otps",
            headers={**_supabase_headers(use_service_role=True), "Prefer": "return=minimal"},
            params={"id": f"eq.{row_id}"},
            json=payload,
            timeout=10,
        )
    except Exception:
        pass



def _paddle_headers() -> Dict[str, str]:
    if not PADDLE_API_KEY:
        raise HTTPException(status_code=500, detail="PADDLE_API_KEY غير موجود في Render")
    return {
        "Authorization": f"Bearer {PADDLE_API_KEY}",
        "Content-Type": "application/json",
    }


def _verification_plan(plan_id: str) -> Dict[str, Any]:
    key = (plan_id or "").strip().lower()
    key = PADDLE_LEGACY_PLAN_ALIASES.get(key, key)
    plan = PADDLE_VERIFICATION_PRICES.get(key)
    if not plan:
        raise HTTPException(status_code=400, detail="خطة الاشتراك غير صحيحة")
    price_id = str(plan.get("price_id", "")).strip()
    if not price_id.startswith("pri_") or "REPLACE" in price_id:
        raise HTTPException(status_code=500, detail=f"Price ID غير مضبوط لخطة {key}. أضف متغير Paddle Price ID في Render.")
    return {"id": key, **plan}


def _extract_plan_from_paddle_event(data: Dict[str, Any]) -> str:
    custom = data.get("custom_data")
    if isinstance(custom, dict):
        plan_id = str(custom.get("plan_id") or custom.get("planId") or "").strip().lower()
        plan_id = PADDLE_LEGACY_PLAN_ALIASES.get(plan_id, plan_id)
        if plan_id in PADDLE_VERIFICATION_PRICES:
            return plan_id

    # fallback من items/line_items
    possible_items = []
    if isinstance(data.get("items"), list):
        possible_items.extend(data.get("items") or [])
    details = data.get("details")
    if isinstance(details, dict) and isinstance(details.get("line_items"), list):
        possible_items.extend(details.get("line_items") or [])

    for item in possible_items:
        if not isinstance(item, dict):
            continue
        price_id = ""
        if isinstance(item.get("price"), dict):
            price_id = str(item["price"].get("id") or "").strip()
        if not price_id:
            price_id = str(item.get("price_id") or item.get("priceId") or "").strip()
        if price_id in PADDLE_PRICE_TO_PLAN:
            return PADDLE_PRICE_TO_PLAN[price_id]

    return ""


def _activate_verification_plan_backend(
    *,
    username: str,
    plan_id: str,
    paddle_transaction_id: str = "",
    paddle_subscription_id: str = "",
    paddle_customer_id: str = "",
    event_id: str = "",
) -> Dict[str, Any]:
    if not SB_SERVICE:
        raise HTTPException(status_code=500, detail="SUPABASE_SERVICE_ROLE_KEY غير موجود في Render")

    user = _display_username(username)
    clean = normalize_username(user)
    if clean in {"", "user"}:
        raise HTTPException(status_code=400, detail="username غير صحيح")

    plan = _verification_plan(plan_id)
    months = int(plan.get("months") or 1)
    price_usd = float(plan.get("price_usd") or 0)
    tier = str(plan.get("tier") or "premium").strip().lower()
    duration = str(plan.get("duration") or "").strip().lower()
    features = plan.get("features") if isinstance(plan.get("features"), list) else []
    now = datetime.now(timezone.utc)

    current = _fetch_user_for_limits(user)
    old_until_raw = str(
        current.get("verified_until")
        or current.get("verification_expires_at")
        or current.get("subscription_expires_at")
        or ""
    ).strip()

    starts_from = now
    if old_until_raw:
        try:
            old_until = datetime.fromisoformat(old_until_raw.replace("Z", "+00:00"))
            if old_until.tzinfo is None:
                old_until = old_until.replace(tzinfo=timezone.utc)
            old_until = old_until.astimezone(timezone.utc)
            if old_until > now:
                starts_from = old_until
        except Exception:
            starts_from = now

    expires = starts_from + timedelta(days=30 * months)

    payload = {
        "is_verified": True,
        "verified": True,
        "respect_verified": True,
        "verification_status": "active",
        "subscription_tier": tier,
        "verification_plan": plan["id"],
        "verified_until": expires.isoformat(),
        "verification_expires_at": expires.isoformat(),
        "subscription_expires_at": expires.isoformat(),
        "verification_updated_at": now.isoformat(),
    }

    # حدث المستخدم بصيغتي username لأن بعض الجداول عندك فيها @ وبعضها بدون.
    update_res = requests.patch(
        f"{SB_URL}/rest/v1/users",
        headers={**_supabase_headers(use_service_role=True), "Prefer": "return=representation"},
        params={"or": f"(username.eq.{user},username.eq.{clean})"},
        json=payload,
        timeout=20,
    )
    if update_res.status_code >= 400:
        raise HTTPException(status_code=500, detail=f"Supabase user update error: {_safe_response_text(update_res.text, 800)}")

    # حدّث علامة التوثيق وأولوية الظهور على المنشورات والردود قدر الإمكان.
    author_priority_payload = {
        "author_verified": True,
        "author_subscription_tier": tier,
        "author_subscription_priority": _subscription_priority_for_tier(tier),
        "author_subscription_boost_until": expires.isoformat(),
        "author_subscription_label": _subscription_label_for_tier(tier),
    }
    for table in ("posts", "post_replies"):
        try:
            patch_res = requests.patch(
                f"{SB_URL}/rest/v1/{table}",
                headers={**_supabase_headers(use_service_role=True), "Prefer": "return=minimal"},
                params={"or": f"(username.eq.{user},username.eq.{clean},author_username.eq.{user},author_username.eq.{clean})"},
                json=author_priority_payload,
                timeout=10,
            )
            if patch_res.status_code >= 400:
                # توافق مع قواعد البيانات القديمة قبل إضافة أعمدة الاشتراك.
                requests.patch(
                    f"{SB_URL}/rest/v1/{table}",
                    headers={**_supabase_headers(use_service_role=True), "Prefer": "return=minimal"},
                    params={"or": f"(username.eq.{user},username.eq.{clean},author_username.eq.{user},author_username.eq.{clean})"},
                    json={"author_verified": True},
                    timeout=10,
                )
        except Exception:
            pass

    sub_payload = {
        "username": user,
        "plan_id": plan["id"],
        "plan_title": str(plan.get("title") or plan["id"]),
        "tier": tier,
        "duration": duration,
        "features": features,
        "months": months,
        "price_usd": price_usd,
        "status": "active",
        "started_at": now.isoformat(),
        "expires_at": expires.isoformat(),
        "created_at": now.isoformat(),
        "paddle_transaction_id": paddle_transaction_id,
        "paddle_subscription_id": paddle_subscription_id,
        "paddle_customer_id": paddle_customer_id,
        "paddle_event_id": event_id,
        "provider": "paddle",
    }
    try:
        requests.post(
            f"{SB_URL}/rest/v1/verification_subscriptions",
            headers={**_supabase_headers(use_service_role=True), "Prefer": "return=minimal"},
            json=sub_payload,
            timeout=12,
        )
    except Exception as e:
        logger.warning("verification_subscriptions insert ignored: %s", e)

    return {
        "ok": True,
        "username": user,
        "planId": plan["id"],
        "tier": tier,
        "duration": duration,
        "features": features,
        "verifiedUntil": expires.isoformat(),
        "paddleTransactionId": paddle_transaction_id,
        "paddleSubscriptionId": paddle_subscription_id,
    }


def _paddle_verify_signature(raw_body: bytes, signature_header: str) -> bool:
    if not PADDLE_WEBHOOK_SECRET:
        # في التطوير فقط: لا نكسر المحاكاة لو لم تضبط السر، لكن لا تستخدم هذا في الإنتاج.
        logger.warning("PADDLE_WEBHOOK_SECRET missing; webhook signature verification skipped")
        return True

    parts: Dict[str, str] = {}
    for chunk in (signature_header or "").split(";"):
        if "=" in chunk:
            k, v = chunk.split("=", 1)
            parts[k.strip()] = v.strip()

    ts = parts.get("ts")
    received = parts.get("h1")
    if not ts or not received:
        return False

    signed_payload = f"{ts}:{raw_body.decode('utf-8')}".encode("utf-8")
    expected = hmac.new(PADDLE_WEBHOOK_SECRET.encode("utf-8"), signed_payload, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, received)


@app.post("/paddle/create-verification-checkout")
def paddle_create_verification_checkout(req: PaddleVerificationCheckoutRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_secret(x_app_secret)

    username = _display_username(req.username)
    clean = normalize_username(username)
    if clean in {"", "user"}:
        raise HTTPException(status_code=400, detail="username غير صحيح")

    plan = _verification_plan(req.planId)
    custom_data = {
        "app": "respect",
        "product_type": "respect_subscription",
        "username": username,
        "plan_id": plan["id"],
        "tier": str(plan.get("tier") or "premium"),
        "duration": str(plan.get("duration") or ""),
        "features": plan.get("features") if isinstance(plan.get("features"), list) else [],
        "months": int(plan.get("months") or 1),
        "source": "flutter_app",
        "device_id": (req.deviceId or "").strip(),
    }

    checkout_settings: Dict[str, Any] = {}
    checkout_url = (req.successUrl or PADDLE_CHECKOUT_URL or "").strip()
    if checkout_url:
        checkout_settings["url"] = checkout_url

    payload: Dict[str, Any] = {
        "collection_mode": "automatic",
        "items": [{"price_id": plan["price_id"], "quantity": 1}],
        "custom_data": custom_data,
    }
    if checkout_settings:
        payload["checkout"] = checkout_settings

    # لو عندك صفحة return/cancel خاصة لاحقًا، نمررها داخل custom_data أيضًا حتى تظهر في الويب هوك.
    if req.cancelUrl or PADDLE_CANCEL_URL:
        custom_data["cancel_url"] = (req.cancelUrl or PADDLE_CANCEL_URL).strip()
    if req.email.strip():
        # لا ننشئ customer_id هنا حتى لا نحتاج API إضافي؛ Paddle Checkout سيطلب الإيميل ويكمل الدفع.
        custom_data["email_hint"] = req.email.strip().lower()

    response = requests.post(
        f"{PADDLE_API_BASE}/transactions",
        headers=_paddle_headers(),
        params={"include": "customer"},
        json=payload,
        timeout=30,
    )

    if response.status_code >= 400:
        raise HTTPException(
            status_code=400,
            detail={
                "paddle_status": response.status_code,
                "paddle_body": _safe_response_text(response.text, 1200),
                "hint": "تأكد أن PADDLE_API_KEY من نفس وضع Sandbox وأن Price ID صحيح وأن Default payment link مضبوط.",
            },
        )

    data = response.json().get("data", {})
    checkout = data.get("checkout") if isinstance(data, dict) else {}
    checkout_url = str((checkout or {}).get("url") or "").strip()
    transaction_id = str(data.get("id") or "").strip()

    if not checkout_url:
        raise HTTPException(status_code=500, detail="Paddle لم يرجع checkout.url. تأكد من Default payment link في Checkout settings.")

    return {
        "ok": True,
        "checkoutUrl": checkout_url,
        "url": checkout_url,
        "transactionId": transaction_id,
        "planId": plan["id"],
        "tier": str(plan.get("tier") or "premium"),
        "duration": str(plan.get("duration") or ""),
        "priceId": plan["price_id"],
        "environment": PADDLE_ENVIRONMENT,
    }


@app.post("/paddle/webhook")
async def paddle_webhook(request: FastAPIRequest, paddle_signature: Optional[str] = Header(default=None)):
    raw = await request.body()
    if not _paddle_verify_signature(raw, paddle_signature or ""):
        raise HTTPException(status_code=401, detail="Invalid Paddle signature")

    try:
        event = json.loads(raw.decode("utf-8"))
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid JSON")

    event_type = str(event.get("event_type") or event.get("eventType") or "").strip()
    event_id = str(event.get("event_id") or event.get("id") or "").strip()
    data = event.get("data") if isinstance(event.get("data"), dict) else {}

    # خزّن الحدث كـ best-effort حتى تقدر تراجعه لاحقًا إذا أنشأت الجدول.
    try:
        requests.post(
            f"{SB_URL}/rest/v1/paddle_events",
            headers={**_supabase_headers(use_service_role=True), "Prefer": "return=minimal"},
            json={
                "event_id": event_id,
                "event_type": event_type,
                "payload": event,
                "created_at": datetime.now(timezone.utc).isoformat(),
            },
            timeout=8,
        )
    except Exception:
        pass

    paid_events = {
        "transaction.paid",
        "transaction.completed",
        "subscription.created",
        "subscription.updated",
    }
    if event_type not in paid_events:
        return {"ok": True, "ignored": True, "eventType": event_type}

    custom = data.get("custom_data")
    if not isinstance(custom, dict):
        custom = {}

    username = str(custom.get("username") or custom.get("user") or "").strip()
    plan_id = _extract_plan_from_paddle_event(data)

    if not username or not plan_id:
        logger.warning("Paddle webhook missing username/plan event=%s data=%s", event_type, _safe_response_text(json.dumps(data), 800))
        return {"ok": True, "ignored": True, "reason": "missing_username_or_plan", "eventType": event_type}

    status = str(data.get("status") or "").lower().strip()
    if event_type.startswith("transaction.") and status and status not in {"paid", "completed", "ready"}:
        return {"ok": True, "ignored": True, "reason": f"transaction_status_{status}", "eventType": event_type}

    result = _activate_verification_plan_backend(
        username=username,
        plan_id=plan_id,
        paddle_transaction_id=str(data.get("id") or ""),
        paddle_subscription_id=str(data.get("subscription_id") or data.get("subscriptionId") or ""),
        paddle_customer_id=str(data.get("customer_id") or data.get("customerId") or ""),
        event_id=event_id,
    )
    return {"ok": True, "activated": True, "eventType": event_type, **result}



@app.post("/auth/create-password-user")
def auth_create_password_user(req: AuthPasswordCreateRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_secret(x_app_secret)

    if not SB_SERVICE:
        raise HTTPException(status_code=500, detail="SUPABASE_SERVICE_ROLE_KEY غير موجود في Render")

    email = _normalize_email(req.email)
    password = str(req.password or "").strip()
    username = _display_username(req.username or "")
    name = str(req.name or username or "Respect User").strip()

    if not _valid_email(email):
        raise HTTPException(status_code=400, detail="الإيميل غير صحيح")
    if len(password) < 6:
        raise HTTPException(status_code=400, detail="كلمة المرور لازم تكون 6 أحرف على الأقل")

    payload = {
        "email": email,
        "password": password,
        "email_confirm": True,
        "user_metadata": {
            "username": username,
            "name": name,
        },
    }

    headers = {
        "apikey": SB_SERVICE,
        "Authorization": f"Bearer {SB_SERVICE}",
        "Content-Type": "application/json",
    }

    r = requests.post(
        f"{SB_URL}/auth/v1/admin/users",
        headers=headers,
        json=payload,
        timeout=20,
    )

    if 200 <= r.status_code < 300:
        try:
            body = r.json()
        except Exception:
            body = {}
        return {"ok": True, "created": True, "authUserId": str(body.get("id") or "")}

    body_text = _safe_response_text(r.text, 800)
    body_lower = body_text.lower()

    # لو كان المستخدم موجودًا في Auth من محاولة قديمة/Google:
    # نحدث كلمة المرور بدل ما نرجع ok فقط، لأن Flutter بعد إنشاء الحساب
    # يعمل signInWithPassword بنفس كلمة المرور الجديدة.
    if r.status_code in (400, 409, 422) and (
        "already" in body_lower
        or "registered" in body_lower
        or "exists" in body_lower
        or "duplicate" in body_lower
        or "user_already_exists" in body_lower
    ):
        try:
            find = requests.get(
                f"{SB_URL}/auth/v1/admin/users",
                headers=headers,
                params={"page": 1, "per_page": 1000},
                timeout=20,
            )
        except Exception as e:
            raise HTTPException(status_code=400, detail=f"تعذر البحث عن مستخدم Auth: {e}")

        if find.status_code >= 400:
            raise HTTPException(
                status_code=400,
                detail=f"تعذر البحث عن مستخدم Auth: {find.status_code} {_safe_response_text(find.text, 800)}",
            )

        try:
            found_body = find.json()
        except Exception:
            found_body = {}

        users = found_body.get("users", []) if isinstance(found_body, dict) else []
        existing = None
        for u in users:
            if not isinstance(u, dict):
                continue
            if str(u.get("email", "")).strip().lower() == email:
                existing = u
                break

        if existing is None:
            raise HTTPException(status_code=400, detail="الحساب موجود في Auth لكن لم يتم العثور عليه لتحديث كلمة المرور")

        user_id = str(existing.get("id") or "").strip()
        if not user_id:
            raise HTTPException(status_code=400, detail="تعذر قراءة user id من Auth")

        patch = requests.put(
            f"{SB_URL}/auth/v1/admin/users/{user_id}",
            headers=headers,
            json={
                "password": password,
                "email_confirm": True,
                "user_metadata": {
                    "username": username,
                    "name": name,
                },
            },
            timeout=20,
        )

        if patch.status_code >= 400:
            raise HTTPException(
                status_code=400,
                detail=f"تعذر تحديث كلمة مرور Auth: {patch.status_code} {_safe_response_text(patch.text, 800)}",
            )

        return {"ok": True, "created": False, "updatedPassword": True, "alreadyExists": True}

    raise HTTPException(
        status_code=400,
        detail=f"تعذر إنشاء مستخدم Auth بدون رسالة Supabase: {r.status_code} {body_text}",
    )



@app.post("/auth/check-login-attempt")
def auth_check_login_attempt(req: LoginAttemptCheckRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_secret(x_app_secret)
    login = str(req.login or "").strip()
    if not login:
        raise HTTPException(status_code=400, detail="اكتب اسم المستخدم أو الإيميل")
    return {"ok": True, **_login_attempt_status(login, req.deviceId), "maxAttempts": LOGIN_MAX_FAILED_ATTEMPTS, "lockMinutes": LOGIN_LOCK_MINUTES}


@app.post("/auth/report-login-attempt")
def auth_report_login_attempt(req: LoginAttemptReportRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_secret(x_app_secret)
    login = str(req.login or "").strip()
    if not login:
        raise HTTPException(status_code=400, detail="اكتب اسم المستخدم أو الإيميل")
    status = _record_login_attempt(login, req.deviceId, success=bool(req.success))
    return {"ok": True, **status, "maxAttempts": LOGIN_MAX_FAILED_ATTEMPTS, "lockMinutes": LOGIN_LOCK_MINUTES}


@app.post("/auth/request-password-reset")
def auth_request_password_reset(req: PasswordResetRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_secret(x_app_secret)
    login = str(req.login or "").strip()
    if not login:
        raise HTTPException(status_code=400, detail="اكتب اسم المستخدم أو الإيميل أولاً")
    user = _find_public_user_for_login(login)
    # لا نكشف وجود الحساب لغير صاحبه. نرجع ok حتى لو لم نجد المستخدم.
    if not user:
        return {"ok": True, "sent": True, "delivery": "hidden"}
    email = _normalize_email(str(user.get("email") or ""))
    if not _valid_email(email):
        raise HTTPException(status_code=400, detail="الحساب لا يحتوي على بريد صالح لإعادة التعيين")
    username = _display_username(str(user.get("username") or login))
    token = secrets.token_urlsafe(36)
    token_hash = _password_reset_token_hash(token)
    _store_password_reset_token(email, token_hash, username, req.deviceId)
    reset_url = f"{PUBLIC_APP_BASE_URL}/auth/reset-password?token={token}"
    delivery = _send_password_reset_email(email, reset_url)
    return {"ok": True, "sent": True, "delivery": delivery, "expiresInMinutes": PASSWORD_RESET_TTL_MINUTES}


@app.post("/auth/phone-security/send")
def auth_phone_security_send(req: PhoneSecuritySendRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_secret(x_app_secret)
    username = _display_username(req.username)
    if normalize_username(username) in {"", "user"}:
        raise HTTPException(status_code=400, detail="username غير صحيح")
    phone_e164 = _normalize_phone_e164(req.countryCode, req.phone)
    sent = _twilio_verify_start(phone_e164)
    return {
        "ok": True,
        "sent": True,
        "phoneE164": phone_e164,
        "service": "twilio_verify",
        "status": sent.get("status"),
    }


@app.post("/auth/phone-security/verify")
def auth_phone_security_verify(req: PhoneSecurityVerifyRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_secret(x_app_secret)
    username = _display_username(req.username)
    if normalize_username(username) in {"", "user"}:
        raise HTTPException(status_code=400, detail="username غير صحيح")
    phone_e164 = _normalize_phone_e164("", req.phoneE164)
    _twilio_verify_check(phone_e164, req.code)
    # نعيد استخراج كود الدولة بشكل بسيط للعرض فقط.
    country_code = ""
    national = phone_e164
    _update_user_phone_security(username, phone_e164, country_code=country_code, phone_national=national)
    return {
        "ok": True,
        "verified": True,
        "phoneE164": phone_e164,
        "smsSecurityEnabled": True,
        "smsLoginEnabled": True,
    }


@app.post("/auth/sms-login/send")
def auth_sms_login_send(req: SmsLoginSendRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_secret(x_app_secret)
    login = str(req.login or "").strip()
    if not login:
        raise HTTPException(status_code=400, detail="اكتب اسم المستخدم أو الإيميل أولاً")
    user = _find_public_user_for_login(login)
    # لا نكشف وجود الحساب أو رقم الهاتف. لو لا يوجد رقم، نعيد ok برسالة عامة.
    if not user:
        return {"ok": True, "sent": True, "delivery": "hidden"}
    phone = str(user.get("phone_e164") or "").strip()
    phone_ok = _truthy(user.get("phone_verified")) and _truthy(user.get("sms_security_enabled")) and _truthy(user.get("sms_login_enabled"))
    if not phone or not phone_ok:
        return {"ok": True, "sent": True, "delivery": "hidden"}
    sent = _twilio_verify_start(phone)
    return {"ok": True, "sent": True, "delivery": "sms", "status": sent.get("status"), "expiresInMinutes": 10}


@app.post("/auth/sms-login/verify")
def auth_sms_login_verify(req: SmsLoginVerifyRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_secret(x_app_secret)
    login = str(req.login or "").strip()
    if not login:
        raise HTTPException(status_code=400, detail="اكتب اسم المستخدم أو الإيميل")
    status = _login_attempt_status(login, req.deviceId)
    if status.get("allowed") is False:
        return {"ok": False, **status}
    user = _find_public_user_for_login(login)
    if not user:
        _record_login_attempt(login, req.deviceId, success=False)
        raise HTTPException(status_code=400, detail="رمز SMS غير صحيح أو الحساب غير مجهز للأمان عبر الرقم")
    phone = str(user.get("phone_e164") or "").strip()
    phone_ok = _truthy(user.get("phone_verified")) and _truthy(user.get("sms_security_enabled")) and _truthy(user.get("sms_login_enabled"))
    if not phone or not phone_ok:
        _record_login_attempt(login, req.deviceId, success=False)
        raise HTTPException(status_code=400, detail="هذا الحساب لم يفعل الأمان عبر الرقم من الإعدادات")
    try:
        _twilio_verify_check(phone, req.code)
    except HTTPException:
        _record_login_attempt(login, req.deviceId, success=False)
        raise
    _record_login_attempt(login, req.deviceId, success=True)
    return {"ok": True, "verified": True, "loginMode": "sms", "user": _safe_user_for_client(user)}


@app.get("/auth/reset-password", response_class=HTMLResponse)
def auth_reset_password_page(token: str = ""):
    safe_token = re.sub(r"[^A-Za-z0-9_\-]", "", str(token or ""))
    safe_brand = html_lib.escape(RESPECT_EMAIL_BRAND_NAME)
    safe_logo_url = html_lib.escape(RESPECT_EMAIL_LOGO_URL.strip(), quote=True)
    if safe_logo_url:
        logo_html = f'<img src="{safe_logo_url}" alt="{safe_brand}" style="width:72px;height:72px;border-radius:24px;object-fit:cover;display:block;border:0;" />'
    else:
        logo_html = '<div style="width:72px;height:72px;border-radius:24px;background:linear-gradient(135deg,#6d28d9,#a855f7,#d8b4fe);display:grid;place-items:center;box-shadow:0 20px 50px rgba(124,58,237,.42);font-size:34px;font-weight:900;">R</div>'

    html = f"""
<!doctype html>
<html lang="ar" dir="rtl">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>إعادة تعيين كلمة مرور Respect</title>
  <style>
    * {{ box-sizing:border-box; }}
    body {{
      margin:0;
      font-family:'Cairo','Tajawal','IBM Plex Sans Arabic',Tahoma,Arial,sans-serif;
      background:#05020a;
      background-image:
        radial-gradient(circle at 50% 0%, rgba(147,51,234,.46) 0%, rgba(88,28,135,.22) 28%, rgba(5,2,10,0) 64%),
        linear-gradient(135deg,#05020a 0%,#10051d 48%,#07030f 100%);
      color:#fff;
      min-height:100vh;
      display:flex;
      align-items:center;
      justify-content:center;
      padding:18px;
    }}
    .card {{
      width:min(480px,100%);
      background:rgba(16,7,25,.94);
      background-image:radial-gradient(circle at 50% 0%,rgba(124,58,237,.28),rgba(16,7,25,0) 48%),linear-gradient(180deg,#140821,#0b0413);
      border:1px solid rgba(216,180,254,.20);
      border-radius:32px;
      padding:1px;
      box-shadow:0 28px 90px rgba(0,0,0,.48);
      overflow:hidden;
    }}
    .bar {{ height:7px; background:linear-gradient(90deg,#4c1d95,#8b5cf6,#d8b4fe); }}
    .inner {{ padding:30px 26px 28px; }}
    .logo-wrap {{ display:flex; justify-content:center; margin-bottom:14px; }}
    .badge {{ display:inline-block; padding:6px 12px; border-radius:999px; background:rgba(124,58,237,.16); border:1px solid rgba(216,180,254,.20); color:#d8b4fe; font-size:12px; font-weight:900; letter-spacing:.8px; }}
    h1 {{ margin:16px 0 8px; font-size:28px; line-height:1.35; font-weight:900; text-align:center; }}
    p {{ color:#d7cbea; line-height:1.9; text-align:center; margin:0 0 18px; }}
    label {{ display:block; margin:12px 2px 7px; color:#efe7ff; font-size:13px; font-weight:900; }}
    input {{
      width:100%;
      padding:15px 16px;
      border-radius:18px;
      border:1px solid rgba(216,180,254,.18);
      background:rgba(255,255,255,.07);
      color:#fff;
      font-size:16px;
      outline:none;
      transition:.18s ease;
    }}
    input:focus {{ border-color:#a855f7; box-shadow:0 0 0 4px rgba(168,85,247,.16); }}
    button {{
      width:100%;
      margin-top:18px;
      padding:16px;
      border:0;
      border-radius:999px;
      background:#7c3aed;
      background-image:linear-gradient(135deg,#6d28d9,#9333ea 45%,#c084fc);
      color:#fff;
      font-size:17px;
      font-weight:900;
      cursor:pointer;
      box-shadow:0 18px 38px rgba(124,58,237,.42);
    }}
    button:disabled {{ opacity:.65; cursor:not-allowed; }}
    .msg {{ margin-top:15px; min-height:24px; font-weight:900; text-align:center; color:#d8b4fe; line-height:1.7; }}
    .hint {{ margin-top:18px; padding:13px 14px; border-radius:18px; background:rgba(255,255,255,.045); border:1px solid rgba(255,255,255,.08); color:#b7afcf; font-size:12px; line-height:1.8; text-align:center; }}
  </style>
</head>
<body>
  <main class="card">
    <div class="bar"></div>
    <div class="inner">
      <div class="logo-wrap">{logo_html}</div>
      <div style="text-align:center;"><span class="badge">{safe_brand}</span></div>
      <h1>إعادة تعيين كلمة المرور</h1>
      <p>اكتب كلمة المرور الجديدة مرتين. يجب أن تكون 6 أحرف على الأقل.</p>

      <label for="p1">كلمة المرور الجديدة</label>
      <input id="p1" type="password" placeholder="اكتب كلمة المرور الجديدة" autocomplete="new-password" />

      <label for="p2">تأكيد كلمة المرور</label>
      <input id="p2" type="password" placeholder="أعد كتابة كلمة المرور" autocomplete="new-password" />

      <button id="submitBtn" onclick="resetPassword()">حفظ كلمة المرور</button>
      <div id="msg" class="msg"></div>
      <div class="hint">بعد نجاح العملية، ارجع إلى تطبيق Respect وسجّل دخولك بكلمة المرور الجديدة.</div>
    </div>
  </main>
<script>
async function resetPassword() {{
  const msg = document.getElementById('msg');
  const btn = document.getElementById('submitBtn');
  const p1 = document.getElementById('p1').value.trim();
  const p2 = document.getElementById('p2').value.trim();
  msg.textContent = '';
  if (p1.length < 6) {{ msg.textContent = 'كلمة المرور لازم تكون 6 أحرف على الأقل'; return; }}
  if (p1 !== p2) {{ msg.textContent = 'كلمتا المرور غير متطابقتان'; return; }}
  btn.disabled = true;
  msg.textContent = 'جاري الحفظ...';
  try {{
    const res = await fetch('/auth/reset-password', {{
      method:'POST',
      headers:{{'Content-Type':'application/json'}},
      body: JSON.stringify({{token:'{safe_token}', password:p1, confirmPassword:p2}})
    }});
    const data = await res.json().catch(() => ({{detail:'تعذر قراءة الرد'}}));
    if (!res.ok || data.ok === false) {{
      msg.textContent = data.detail || data.error || 'تعذر تغيير كلمة المرور';
      btn.disabled = false;
      return;
    }}
    msg.textContent = 'تم تغيير كلمة المرور بنجاح. ارجع إلى تطبيق Respect وسجّل دخولك.';
  }} catch (e) {{
    msg.textContent = 'تعذر الاتصال بالسيرفر. حاول مرة أخرى.';
    btn.disabled = false;
  }}
}}
</script>
</body>
</html>
"""
    return HTMLResponse(html)


@app.post("/auth/reset-password")
async def auth_reset_password_submit(request: FastAPIRequest):
    try:
        body = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="طلب غير صحيح")
    token = str(body.get("token") or "").strip()
    password = str(body.get("password") or "").strip()
    confirm = str(body.get("confirmPassword") or body.get("confirm_password") or "").strip()
    if not token:
        raise HTTPException(status_code=400, detail="رابط إعادة التعيين غير صحيح")
    if len(password) < 6:
        raise HTTPException(status_code=400, detail="كلمة المرور لازم تكون 6 أحرف على الأقل")
    if password != confirm:
        raise HTTPException(status_code=400, detail="كلمتا المرور غير متطابقتان")
    row = _read_password_reset_token(token)
    expires_raw = str(row.get("expires_at") or "")
    try:
        expires = datetime.fromisoformat(expires_raw.replace("Z", "+00:00"))
        if expires.tzinfo is None:
            expires = expires.replace(tzinfo=timezone.utc)
    except Exception:
        expires = datetime.now(timezone.utc) - timedelta(seconds=1)
    if expires <= datetime.now(timezone.utc):
        raise HTTPException(status_code=400, detail="انتهت صلاحية رابط إعادة التعيين")
    email = _normalize_email(str(row.get("email") or ""))
    if not _valid_email(email):
        raise HTTPException(status_code=400, detail="البريد غير صالح داخل رابط إعادة التعيين")
    _update_supabase_auth_password(email, password)
    _consume_password_reset_token(str(row.get("token_hash") or _password_reset_token_hash(token)))
    _record_login_attempt(email, "", success=True)
    return {"ok": True, "message": "تم تغيير كلمة المرور بنجاح"}

@app.post("/auth/send-otp")
def auth_send_otp(req: AuthOtpSendRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_secret(x_app_secret)
    email = _normalize_email(req.email)
    purpose = (req.purpose or "login").strip().lower()
    if purpose not in {"login", "signup"}:
        raise HTTPException(status_code=400, detail="purpose غير صحيح")
    if not _valid_email(email):
        raise HTTPException(status_code=400, detail="الإيميل غير صحيح")

    code = f"{secrets.randbelow(1000000):06d}"
    code_hash = _hash_otp(email, code, purpose, req.deviceId)
    _insert_otp_row(email, code_hash, purpose, req.username, req.deviceId)
    delivery = _send_otp_email(email, code, purpose)
    return {"ok": True, "delivery": delivery, "expiresInMinutes": OTP_TTL_MINUTES}


@app.post("/auth/verify-otp")
def auth_verify_otp(req: AuthOtpVerifyRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_secret(x_app_secret)
    email = _normalize_email(req.email)
    purpose = (req.purpose or "login").strip().lower()
    code = str(req.code or "").strip()
    if purpose not in {"login", "signup"}:
        raise HTTPException(status_code=400, detail="purpose غير صحيح")
    if not _valid_email(email) or not re.fullmatch(r"\d{6}", code):
        raise HTTPException(status_code=400, detail="رمز التحقق غير صحيح")

    row = _latest_otp_row(email, purpose, req.deviceId)
    row_id = str(row.get("id", ""))
    attempts = int(row.get("attempts") or 0)
    if attempts >= 5:
        raise HTTPException(status_code=429, detail="تم تجاوز عدد المحاولات. اطلب رمزًا جديدًا")

    expires_raw = str(row.get("expires_at") or "")
    try:
        expires = datetime.fromisoformat(expires_raw.replace("Z", "+00:00"))
        if expires.tzinfo is None:
            expires = expires.replace(tzinfo=timezone.utc)
    except Exception:
        expires = datetime.now(timezone.utc) - timedelta(seconds=1)
    if expires <= datetime.now(timezone.utc):
        raise HTTPException(status_code=400, detail="انتهت صلاحية رمز التحقق")

    expected = str(row.get("code_hash") or "")
    actual = _hash_otp(email, code, purpose, req.deviceId)
    if not hmac.compare_digest(expected, actual):
        _mark_otp_attempt(row_id, attempts + 1, consumed=False)
        raise HTTPException(status_code=400, detail="رمز التحقق غير صحيح")

    _mark_otp_attempt(row_id, attempts + 1, consumed=True)
    return {"ok": True}


@app.post("/auth/is-trusted-device")
def auth_is_trusted_device(req: TrustedDeviceRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_secret(x_app_secret)
    username = display_username(req.username)
    device_id = (req.deviceId or "").strip()
    if not normalize_username(username) or not device_id:
        return {"ok": True, "trusted": False}
    now = datetime.now(timezone.utc).isoformat()
    r = requests.get(
        f"{SB_URL}/rest/v1/respect_trusted_devices",
        headers=_supabase_headers(use_service_role=True),
        params={
            "select": "id,trusted_until",
            "username": f"eq.{username}",
            "device_id": f"eq.{device_id}",
            "trusted_until": f"gt.{now}",
            "limit": "1",
        },
        timeout=10,
    )
    if r.status_code >= 400:
        return {"ok": True, "trusted": False}
    data = r.json()
    return {"ok": True, "trusted": bool(isinstance(data, list) and data)}


@app.post("/auth/trust-device")
def auth_trust_device(req: TrustedDeviceRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_secret(x_app_secret)
    username = display_username(req.username)
    device_id = (req.deviceId or "").strip()
    if not normalize_username(username) or not device_id:
        raise HTTPException(status_code=400, detail="بيانات الجهاز غير مكتملة")
    days = max(1, min(int(req.days or TRUSTED_DEVICE_DAYS), 365))
    trusted_until = (datetime.now(timezone.utc) + timedelta(days=days)).isoformat()
    payload = {
        "username": username,
        "device_id": device_id,
        "device_name": req.deviceName or "device",
        "trusted_until": trusted_until,
        "updated_at": datetime.now(timezone.utc).isoformat(),
    }
    r = requests.post(
        f"{SB_URL}/rest/v1/respect_trusted_devices",
        headers={**_supabase_headers(use_service_role=True), "Prefer": "resolution=merge-duplicates,return=minimal"},
        params={"on_conflict": "username,device_id"},
        json=payload,
        timeout=12,
    )
    if r.status_code == 409 or "23505" in r.text or "duplicate key" in r.text.lower():
        # الجهاز موجود مسبقًا؛ نحدّث تاريخ الثقة بدل إظهار خطأ للمستخدم.
        patch = requests.patch(
            f"{SB_URL}/rest/v1/respect_trusted_devices",
            headers={**_supabase_headers(use_service_role=True), "Prefer": "return=minimal"},
            params={"username": f"eq.{username}", "device_id": f"eq.{device_id}"},
            json={
                "device_name": req.deviceName or "device",
                "trusted_until": trusted_until,
                "updated_at": datetime.now(timezone.utc).isoformat(),
            },
            timeout=12,
        )
        if patch.status_code >= 400:
            raise HTTPException(status_code=500, detail=f"تعذر تحديث الجهاز الموثوق: {_safe_response_text(patch.text)}")
        return {"ok": True, "trustedUntil": trusted_until, "updated": True}
    if r.status_code >= 400:
        raise HTTPException(status_code=500, detail=f"تعذر حفظ الجهاز الموثوق: {_safe_response_text(r.text)}")
    return {"ok": True, "trustedUntil": trusted_until}


@app.post("/send_push")
def send_push(req: PushRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_secret(x_app_secret)
    return send_fcm_v1(req.token, req.type, req.title, req.body, req.data)


@app.post("/send_user_push")
def send_user_push(req: UserPushRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_secret(x_app_secret)
    token = get_user_fcm_token(req.receiverUsername)
    if not token:
        raise HTTPException(status_code=400, detail="receiver_has_no_fcm_token")
    return send_fcm_v1(token, req.type, req.title, req.body, req.data)


@app.post("/send_general_push")
def send_general_push(req: GeneralPushRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_secret(x_app_secret)
    title = (req.title or "").strip()[:80] or "Respect"
    body = (req.body or "").strip()[:900]
    if not body:
        raise HTTPException(status_code=400, detail="body_required")

    notification_id = create_general_notification_row(title, body, req.senderUsername, req.senderName)
    tokens = get_all_user_fcm_tokens()
    sent = 0
    failed = 0
    errors = []
    created_at = datetime.now(timezone.utc).isoformat()

    for item in tokens:
        data = {
            **(req.data or {}),
            "type": "general_notification",
            "id": notification_id,
            "notificationId": notification_id,
            "title": title,
            "body": body,
            "created_at": created_at,
            "senderUsername": display_username(req.senderUsername),
            "senderName": req.senderName or "Respect Admin",
        }
        try:
            send_fcm_v1(item["token"], "general_notification", title, body, data)
            sent += 1
        except HTTPException as exc:
            failed += 1
            if len(errors) < 5:
                errors.append({"username": item.get("username", ""), "error": exc.detail})
        except Exception as exc:
            failed += 1
            if len(errors) < 5:
                errors.append({"username": item.get("username", ""), "error": str(exc)})

    return {
        "ok": True,
        "id": notification_id,
        "total": len(tokens),
        "sent": sent,
        "failed": failed,
        "errors": errors,
    }


@app.post("/send_message_push")
def send_message_push(req: MessagePushRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_secret(x_app_secret)
    # لا نرسل اسم المرسل أو نص الرسالة عبر FCM.
    title = "Respect"
    body = "لديك رسالة جديدة"

    token = get_user_fcm_token(req.receiverUsername)
    if not token:
        raise HTTPException(status_code=400, detail="receiver_has_no_fcm_token")

    return send_fcm_v1(
        token,
        "message",
        title,
        body,
        {
            "messageId": req.messageId,
            "senderUsername": display_username(req.senderUsername),
            "senderName": "",
            "text": "",
            "peerUsername": display_username(req.senderUsername),
            "peerName": "",
            "privacy": "metadata_only",
        },
    )


@app.post("/send_call_push")
def send_call_push(req: CallPushRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_secret(x_app_secret)
    title = "Respect"
    body = "مكالمة واردة"

    token = get_user_fcm_token(req.receiverUsername)
    if not token:
        raise HTTPException(status_code=400, detail="receiver_has_no_fcm_token")

    return send_fcm_v1(
        token,
        "call",
        title,
        body,
        {
            "callId": req.callId,
            "call_id": req.callId,
            "callerUsername": display_username(req.callerUsername),
            "caller_username": display_username(req.callerUsername),
            "callerName": "",
            "caller_name": "",
            "callerAvatarPath": "",
            "caller_avatar": "",
            "privacy": "metadata_only",
            "video": str(req.video).lower(),
            "call_type": "video" if req.video else "audio",
        },
    )


def _respect_ai_system_prompt(mode: str) -> str:
    mode = (mode or "reply").strip().lower()

    base = """
أنت Respect AI، الحساب الرسمي الذكي داخل تطبيق Respect App.

الأولوية الأولى دائمًا: الدقة والفهم الصحيح قبل الأسلوب.
لا تهبد، لا تخترع، لا تجاوب بثقة إذا السؤال يحتاج تحقق. إذا لم تكن متأكدًا قل: "مو متأكد 100%".
لا تمدح السؤال ببداية كل رد، ولا تستخدم عبارات مثل: "ما شاء الله سؤال ذكي" إلا نادرًا جدًا.
لا تطوّل ولا تدخل في كلام جانبي. أعطِ الجواب مباشرة أولًا، ثم توضيح قصير إذا احتاج.

أسلوبك:
- رد بالعامية الطبيعية حسب لهجة المستخدم قدر الإمكان، لكن بدون تخريب اللغة أو خلط لهجات بشكل غريب.
- إذا المستخدم سعودي/خليجي: استخدم لهجة سعودية خفيفة وواضحة.
- إذا المستخدم فلسطيني/شامي: استخدم لهجة فلسطينية/شامية خفيفة وواضحة.
- إذا المستخدم مصري: استخدم مصري بسيط، لكن لا تستخدم كلمات مصرية إذا المستخدم ليس مصريًا.
- إذا اللهجة غير واضحة، استخدم عامية بيضاء مفهومة.
- لا تستخدم فصحى ثقيلة إلا لو المستخدم طلبها أو السؤال تعليمي يحتاج صياغة دقيقة.
- لا تستخدم ألفاظ غريبة مثل "بسيتو" أو تراكيب مكسّرة.
- الرد يكون مناسب كرد داخل تغريدة: قصير، مفيد، طبيعي.

قواعد الإجابة:
- إذا السؤال معلوماتي، جاوب المعلومة الصحيحة مباشرة.
- إذا السؤال لغز شعبي، قل "إذا تقصد اللغز الشائع..." ثم أعطِ الجواب الشائع.
- إذا السؤال يحتمل أكثر من معنى، اذكر الاحتمال الأقرب باختصار.
- لا تحول سؤال عادي إلى مزاح طويل.
- لا تذكر أشجار أو أشياء غير مرتبطة إذا السؤال عن حيوان.
- لا تخترع أسماء حيوانات أو معلومات علمية.

أمثلة مهمة:
سؤال: "عدد لي الاحرف بالعربي"
جواب صحيح: "الحروف العربية 28 حرفًا. وإذا تحسب الهمزة بشكل مستقل عند بعض الناس ممكن يقولون 29، بس الأساس 28."
سؤال: "وش اسم الحيوان الي ماينام"
جواب مناسب: "إذا تقصد اللغز الشائع، غالبًا الجواب: السمك، لأنه ما ينام بنفس طريقتنا وعيونه ما تسكر. بس علميًا أغلب الحيوانات عندها فترات راحة."
سؤال: "من رئيس عصابة كفن؟"
جواب مناسب: "حسب سياق السيرفر عندكم، إذا الناس تقصد شخصية معيّنة قل لي اسم السيرفر/القصة وأجاوبك عليها."

المنع:
- لا تسب، لا تشتم، لا تحرض، لا تهاجم أحد، ولا تدخل في مشاكل.
""".strip()

    trend_rule = """
استفد من سياق المنشور، الردود، وسياق المجتمع إذا وصل لك.
إذا لاحظت أن الناس يتكلمون كثيرًا عن موضوع معين مثل سيرفر Respect، الحياة الواقعية، GTA، جراند، شخصية معينة، عصابة، إدارة السيرفر، اربط ردك بالسياق بشكل ذكي.
لكن لا تخترع معلومة مؤكدة غير موجودة في السياق. إذا ما عندك معلومة كافية، اسأل سؤال توضيحي قصير.
""".strip()

    if mode == "summarize":
        return base + "\n\n" + trend_rule + "\n\nلخص باللهجة المناسبة في 3 نقاط قصيرة، بدون مبالغة وبدون اختراع."
    if mode == "poll":
        return base + "\n\n" + trend_rule + "\n\nسوِ استطلاع عامي قصير: سؤال واحد + 2 إلى 4 خيارات مرقمة. اجعله واضحًا ومفهومًا."
    if mode == "question":
        return base + "\n\n" + trend_rule + "\n\nاكتب سؤال نقاش عامي قصير وذكي، مرتبط بالسياق إذا موجود، بدون كلام عام مكرر."
    if mode == "daily_question":
        return base + "\n\n" + """
أنت تكتب منشور فعالية يومية لحساب Respect AI.
ممنوع تمامًا اختراع فعالية أو موضوع أو اسم أو حدث غير موجود في سياق المستخدم.
استخدم فقط السؤال المتكرر الذي سيرسله التطبيق داخل الطلب.
لا تجاوب على السؤال، ولا تضف معلومات من عندك. افتح نقاشًا حول نفس السؤال فقط.
إذا لم تجد في الطلب عبارة واضحة مثل "السؤال المتكرر" أو لم تجد سؤالًا محددًا، اكتب بالضبط: NO_REPEATED_QUESTION
الصيغة المطلوبة: منشور قصير وجذاب، عامي واضح، مناسب للفيد، بدون هبد.
""".strip()
    if mode == "daily_poll":
        return base + "\n\n" + """
اكتب استطلاعًا يوميًا فقط إذا كان مبنيًا على سؤال متكرر موجود صراحة في الطلب.
ممنوع اختراع موضوع غير مذكور. لا تضف أسماء أو أحداث أو تفاصيل غير موجودة.
إذا لا يوجد سؤال متكرر واضح في الطلب، اكتب بالضبط: NO_REPEATED_QUESTION
""".strip()
    if mode == "daily_info":
        return base + "\n\n" + """
لا تكتب معلومة اليوم من خيالك. استخدم فقط موضوعًا متكررًا مثبتًا في الطلب.
إذا لا يوجد موضوع متكرر واضح، اكتب بالضبط: NO_REPEATED_QUESTION
""".strip()
    return base + "\n\n" + trend_rule + "\n\nرد على منشن المستخدم بنفس لهجته، لكن بدقة عالية. ابدأ بالجواب مباشرة، ثم توضيح قصير عند الحاجة."

def _clean_ai_text(text: str) -> str:
    value = (text or "").strip()
    value = value.replace("@RespectAI", "").replace("@respectai", "").replace("@Respect_AI", "").replace("@respect_ai", "").strip()
    # حماية بسيطة من الطلبات الضخمة حتى لا تزيد الاستهلاك
    if len(value) > 6000:
        value = value[:6000]
    return value


def _auto_detect_mode(mode: str, text: str) -> str:
    requested = (mode or "reply").strip().lower()
    if requested and requested != "reply":
        return requested
    t = (text or "").strip().lower()
    if any(word in t for word in ["لخص", "تلخيص", "اختصر", "summarize", "summary"]):
        return "summarize"
    if any(word in t for word in ["تصويت", "استطلاع", "poll", "vote"]):
        return "poll"
    if any(word in t for word in ["سؤال تفاعلي", "سؤال للنقاش", "نقاش", "question"]):
        return "question"
    return "reply"


def _build_user_prompt(
    text: str,
    username: str = "",
    post_text: str = "",
    parent_reply_text: str = "",
    recent_replies_text: str = "",
) -> str:
    clean_text = _clean_ai_text(text)
    if not clean_text and post_text.strip():
        clean_text = post_text.strip()
    if not clean_text:
        raise HTTPException(status_code=400, detail="text is empty")

    user_label = display_username(username) if username.strip() else "@user"
    parts = [
        f"المستخدم: {user_label}",
        "مهم جدًا: جاوب على طلب المستخدم مباشرة. لا تبدأ بمدح السؤال. لا تهبد. لا تخلط لهجات. لا تخترع معلومة.",
        "اللهجة: استنتج لهجة المستخدم من كلامه. إذا غير واضحة استخدم عامية بيضاء بسيطة. الدقة أهم من اللهجة.",
        "لو السؤال معلوماتي/تعليمي أعطِ جوابًا صحيحًا ومختصرًا. لو السؤال لغز شعبي اذكر أنه لغز شائع ثم أعطِ الجواب الشائع.",
        f"طلب المستخدم:\n{clean_text}",
    ]

    if post_text.strip():
        parts.append(f"نص المنشور الأصلي للسياق:\n{post_text.strip()[:4000]}")
    if parent_reply_text.strip():
        parts.append(f"نص الرد الذي تم منشنك داخله:\n{parent_reply_text.strip()[:2500]}")
    if recent_replies_text.strip():
        parts.append(
            "سياق الردود/المجتمع والمواضيع المتكررة:\n"
            f"{recent_replies_text.strip()[:5000]}\n\n"
            "استخدم هذا السياق فقط لفهم الجو والموضوع. لا تعتبره مصدر حقائق مؤكد إذا كان مجرد كلام مستخدمين."
        )

    if any(tag in clean_text for tag in ["السؤال المتكرر", "عدد التكرار", "أمثلة من المجتمع"]):
        parts.append(
            "قواعد خاصة للفعالية اليومية:\n"
            "- استخدم السؤال المتكرر الموجود في الطلب فقط.\n"
            "- لا تضف أسماء أو أحداث أو مواضيع غير موجودة في السؤال أو الأمثلة.\n"
            "- لا تجاوب على السؤال؛ فقط حوّله لمنشور نقاش جذاب.\n"
            "- إذا لم تجد سؤالًا متكررًا واضحًا، اكتب: NO_REPEATED_QUESTION"
        )

    parts.append(
        "قبل إرسال الرد راجع نفسك:\n"
        "- هل أجبت السؤال مباشرة؟\n"
        "- هل المعلومة صحيحة؟\n"
        "- هل الرد قصير وواضح؟\n"
        "- هل تجنبت الهبد والمدح الزائد؟"
    )

    return "\n\n".join(parts)


def _chat_completion_request(
    *,
    model: str,
    api_key: str,
    base_url: str,
    messages: list,
    temperature: float,
    max_tokens: int,
    timeout: int,
    response_format: Optional[Dict[str, Any]] = None,
    log_label: str = "AI",
) -> str:
    if not api_key:
        raise HTTPException(status_code=500, detail=f"{log_label}_API_KEY missing")

    payload: Dict[str, Any] = {
        "model": model,
        "messages": messages,
        "temperature": temperature,
        "max_tokens": max_tokens,
        "stream": False,
    }
    if response_format is not None:
        payload["response_format"] = response_format

    response = requests.post(
        f"{base_url}/chat/completions",
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        json=payload,
        timeout=timeout,
    )

    logger.info("Respect AI %s response status=%s", log_label, response.status_code)
    logger.debug("Respect AI %s response body=%s", log_label, _safe_response_text(response.text, 800))

    if response.status_code >= 400:
        raise HTTPException(
            status_code=400,
            detail={
                f"{log_label.lower()}_status": response.status_code,
                f"{log_label.lower()}_body": response.text,
            },
        )

    try:
        data = response.json()
        return str(data["choices"][0]["message"]["content"]).strip()
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Invalid {log_label} response: {e}")


def ask_qwen_ai(
    text: str,
    username: str = "",
    mode: str = "reply",
    post_text: str = "",
    parent_reply_text: str = "",
    recent_replies_text: str = "",
) -> str:
    if not QWEN_API_KEY:
        raise HTTPException(status_code=500, detail="QWEN_API_KEY missing")

    effective_mode = _auto_detect_mode(mode, text)

    reply = _chat_completion_request(
        model=QWEN_MODEL,
        api_key=QWEN_API_KEY,
        base_url=QWEN_BASE_URL,
        messages=[
            {
                "role": "system",
                "content": _respect_ai_system_prompt(effective_mode),
            },
            {
                "role": "user",
                "content": _build_user_prompt(text, username, post_text, parent_reply_text, recent_replies_text),
            },
        ],
        temperature=0.25,
        max_tokens=280,
        timeout=60,
        log_label="QWEN",
    )

    if not reply:
        raise HTTPException(status_code=500, detail="Qwen returned empty reply")

    reply = str(reply).replace("@RespectAI", "").replace("@respectai", "").strip()
    if effective_mode.startswith("daily_") and "NO_REPEATED_QUESTION" in reply:
        return "NO_REPEATED_QUESTION"
    if len(reply) > 900:
        reply = reply[:900].rstrip() + "..."
    return reply



def _respect_cyber_system_prompt(mode: str = "defensive") -> str:
    return (
        "أنت Respect Cyber AI، مساعد أمن سيبراني دفاعي داخل تطبيق Respect App. "
        "مهمتك شرح الحماية، تحليل السجلات، مراجعة الكود، توضيح OWASP/CVE/MITRE، "
        "واقتراح إصلاحات آمنة لتطبيقات Flutter وFastAPI وSupabase وFirebase. "
        "لا تقدم خطوات اختراق حقيقية ضد أهداف لا يملكها المستخدم، ولا تنشئ برمجيات خبيثة، "
        "ولا تعطي أوامر استغلال مباشرة أو سرقة بيانات أو تجاوز صلاحيات. "
        "إذا كان الطلب هجوميًا، حوّله إلى شرح دفاعي وطريقة اختبار قانونية داخل لاب مصرح. "
        "أجب بالعربية بشكل مختصر وعملي، واستخدم نقاط واضحة عند الحاجة. "
        f"الوضع المطلوب: {mode}."
    )


def ask_huggingface_cyber_ai(text: str, username: str = "", mode: str = "defensive") -> str:
    if not HF_TOKEN:
        raise HTTPException(status_code=500, detail="HF_TOKEN missing")

    clean_text = (text or "").strip()
    if not clean_text:
        raise HTTPException(status_code=400, detail="empty cyber ai prompt")

    headers = {
        "Authorization": f"Bearer {HF_TOKEN}",
        "Content-Type": "application/json",
    }
    if HF_BILL_TO:
        headers["X-HF-Bill-To"] = HF_BILL_TO

    payload = {
        "model": HF_CYBER_MODEL,
        "messages": [
            {"role": "system", "content": _respect_cyber_system_prompt(mode)},
            {
                "role": "user",
                "content": (
                    f"المستخدم: {username or '@user'}\n"
                    f"السؤال الأمني:\n{clean_text}"
                ),
            },
        ],
        "temperature": 0.2,
        "max_tokens": 700,
        "stream": False,
    }

    response = requests.post(
        f"{HF_BASE_URL}/chat/completions",
        headers=headers,
        json=payload,
        timeout=HF_TIMEOUT_SECONDS,
    )

    logger.info("Respect Cyber AI HF response status=%s model=%s", response.status_code, HF_CYBER_MODEL)
    logger.debug("Respect Cyber AI HF response body=%s", _safe_response_text(response.text, 800))

    if response.status_code >= 400:
        raise HTTPException(
            status_code=400,
            detail={
                "hf_status": response.status_code,
                "hf_body": response.text,
                "hint": "تأكد من HF_TOKEN وصلاحية Inference Providers وأن HF_CYBER_MODEL مدعوم على Hugging Face Router.",
            },
        )

    try:
        data = response.json()
        reply = str(data["choices"][0]["message"]["content"]).strip()
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Invalid HF response: {e}")

    if not reply:
        raise HTTPException(status_code=500, detail="Hugging Face returned empty reply")
    if len(reply) > 2500:
        reply = reply[:2500].rstrip() + "..."
    return reply

# اسم قديم حتى لا ينكسر أي استدعاء داخلي قديم.
def ask_groq_ai(
    text: str,
    username: str = "",
    mode: str = "reply",
    post_text: str = "",
    parent_reply_text: str = "",
    recent_replies_text: str = "",
) -> str:
    return ask_qwen_ai(
        text=text,
        username=username,
        mode=mode,
        post_text=post_text,
        parent_reply_text=parent_reply_text,
        recent_replies_text=recent_replies_text,
    )





def _normalize_arabic_for_moderation(value: str) -> str:
    text = (value or "").strip().lower()
    text = text.replace("أ", "ا").replace("إ", "ا").replace("آ", "ا")
    text = text.replace("ة", "ه").replace("ى", "ي")
    text = re.sub(r"[ًٌٍَُِّْـ]", "", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text




def _collapse_repeated_letters_for_moderation(value: str) -> str:
    # يختصر التكرار المستخدم للتهرب: كككسسس -> كس
    return re.sub(r"(.)\1{1,}", r"\1", value or "")


def _normalize_obfuscated_text_for_moderation(value: str) -> Dict[str, str]:
    """
    تطبيع قوي ضد محاولات التمويه:
    - إزالة التشكيل والتطويل.
    - توحيد الهمزات والأحرف.
    - تحويل بعض أرقام/حروف الفرانكو الشائعة.
    - إنتاج نسختين: spaced للفحص السياقي و compact لكشف الكلمات المفصولة بفواصل/نقاط/مسافات.
    """
    raw = (value or "").lower()
    raw = raw.translate(str.maketrans({
        "أ": "ا", "إ": "ا", "آ": "ا", "ٱ": "ا",
        "ة": "ه", "ى": "ي", "ؤ": "و", "ئ": "ي",
        "ـ": "",
        "0": "o", "1": "i", "2": "ء", "3": "ع", "4": "a", "5": "خ", "6": "ط", "7": "ح", "8": "ب", "9": "ق",
        "@": "a", "$": "s", "!": "i",
    }))
    raw = re.sub(r"[ًٌٍَُِّْـ]", "", raw)
    raw = re.sub(r"[\u200b-\u200f\u202a-\u202e\ufeff]", "", raw)
    spaced = re.sub(r"[^0-9a-zA-Zء-ي]+", " ", raw).strip()
    spaced = re.sub(r"\s+", " ", spaced)
    compact = re.sub(r"[^0-9a-zA-Zء-ي]+", "", raw)
    compact = _collapse_repeated_letters_for_moderation(compact)
    spaced_collapsed = " ".join(_collapse_repeated_letters_for_moderation(w) for w in spaced.split())
    return {"raw": raw, "spaced": spaced, "spaced_collapsed": spaced_collapsed, "compact": compact}


def _local_hard_violation_guard(text: str) -> Optional[Dict[str, Any]]:
    """
    طبقة أولى صارمة قبل أي fast-safe أو سياق RP.
    تكشف السب/الألفاظ الجنسية/التهديدات الواضحة حتى لو كانت مفصولة بفواصل أو نقاط أو مسافات.
    """
    if not (text or "").strip():
        return None

    n = _normalize_obfuscated_text_for_moderation(text)
    spaced = n["spaced_collapsed"]
    compact = n["compact"]
    tokens = set(spaced.split())

    def hit_word(words: list[str]) -> Optional[str]:
        normalized_words = [_normalize_obfuscated_text_for_moderation(w)["compact"] for w in words]
        for w in normalized_words:
            if not w:
                continue
            # الكلمات القصيرة جدًا نفحصها كتوكن مستقل أو كتمويه واضح داخل compact.
            if len(w) <= 2:
                if w in tokens:
                    return w
                # يسمح بكشف: ك.س أو ك س أو كسسس، بدون أن نحذف كلمات طبيعية مثل كسر/كأس.
                if re.search(rf"(^|[^ء-يa-zA-Z0-9]){re.escape(w)}($|[^ء-يa-zA-Z0-9])", spaced):
                    return w
                # كشف التمويه بحرفين مفصولين: ك.س / ك س / ز-ب ... بدون حذف كلمات طبيعية مثل كسر.
                if len(w) == 2 and re.search(rf"(^|\s){re.escape(w[0])}\s+{re.escape(w[1])}(\s|$)", spaced):
                    return w
                if compact == w or compact.startswith(w + "سري") or compact.endswith(w):
                    return w
            else:
                if w in compact:
                    return w
        return None

    # تهديدات وتحريض واضح.
    threat_terms = ["اقتلوه", "اقتلو", "اقتله", "انتحر", "يموت", "موتوا", "اذبحه", "ذبح", "kill yourself", "i will kill"]
    if hit_word(threat_terms):
        return {
            "shouldDelete": True,
            "deleteParentReply": False,
            "category": "threat",
            "reason": "تهديد أو تحريض واضح تم كشفه بعد تطبيع النص",
            "confidence": 0.98,
            "checks": 1,
            "local_guard": True,
            "normalizedText": spaced,
        }

    # ألفاظ جنسية/فاحشة مباشرة. وجودها في سؤال RP لا يجعلها آمنة.
    sexual_terms = [
        "كس", "زب", "نيك", "منيوك", "منيوكة", "شرموط", "شرموطة", "قحبة", "قحبه",
        "طيز", "طيزك", "طيزه", "ممحون", "ممحونة", "مص", "لحس", "fuck", "bitch", "pussy", "dick",
    ]
    if hit_word(sexual_terms):
        return {
            "shouldDelete": True,
            "deleteParentReply": False,
            "category": "sexual_profanity",
            "reason": "لفظ جنسي/فاحش مباشر داخل النص حتى لو كان ضمن سياق لعبة أو مكتوبًا بتمويه",
            "confidence": 0.99,
            "checks": 1,
            "local_guard": True,
            "normalizedText": spaced,
        }

    # سب مباشر وإهانات واضحة.
    insult_terms = ["كلب", "حمار", "خنزير", "حقير", "وسخ", "زباله", "غبي", "اغبياء", "خرا", "زق", "asshole"]
    addressed = bool(re.search(r"(^|\s)(يا|انت|انتي|انتم|انتو|ياعيال|يا\s+عيال|لك|لها|له)($|\s)", spaced))
    if addressed and hit_word(insult_terms):
        return {
            "shouldDelete": True,
            "deleteParentReply": False,
            "category": "insult",
            "reason": "سب أو إهانة مباشرة موجهة داخل النص وتم كشفها بعد التطبيع",
            "confidence": 0.97,
            "checks": 1,
            "local_guard": True,
            "normalizedText": spaced,
        }

    # إساءة دينية واضحة.
    religion_patterns = [r"سب\s*الدين", r"سب\s*الله", r"اهان[هة]\s*الدين", r"لعن\s*الدين"]
    if any(re.search(pat, spaced) or re.search(pat.replace("\\s*", ""), compact) for pat in religion_patterns):
        return {
            "shouldDelete": True,
            "deleteParentReply": False,
            "category": "religion_abuse",
            "reason": "إساءة دينية واضحة تم كشفها بعد تطبيع النص",
            "confidence": 0.99,
            "checks": 1,
            "local_guard": True,
            "normalizedText": spaced,
        }

    return None

def _has_obvious_direct_attack(text: str) -> bool:
    """
    كشف محلي محافظ جدًا للسب/الهجوم الواضح حتى لا نسمح به عبر مسار RP الآمن.
    لا يعتمد على مجرد كلمات مثل عصابة/كلان/كفن.
    """
    t = _normalize_arabic_for_moderation(text)
    if not t:
        return False

    direct_patterns = [
        r"(يا\s*كلب|يا\s*حمار|يا\s*خنزير|انت\s*حيوان|انتم\s*حيوانات|كل\s*خرا|كل\s*زق)",
        r"(حقير|وسخ|زباله|تافه|غبي|اغبياء|كلاب|حمير|خنازير)",
        r"(اقتلو|اقتله|اقتلوه|لازم\s+ينضرب|لازم\s+نجلده|يموت|موتوا)",
        r"\b(fuck\s+you|bitch|asshole|kill\s+yourself)\b",
    ]
    return any(re.search(pattern, t, flags=re.IGNORECASE) for pattern in direct_patterns)


def _is_likely_roleplay_or_game_context_safe(text: str) -> bool:
    """
    يحل مشكلة الحذف الخاطئ لأسماء كيانات داخل السيرفرات والألعاب/RP.
    مثال آمن: ياعيال ليه عصابة الكفن مايكون عندها مقر سري؟
    الاسم هنا كيان/كلان داخل قصة أو سيرفر، وليس إهانة لجماعة بشرية.
    """
    t = _normalize_arabic_for_moderation(text)
    if not t or _has_obvious_direct_attack(t):
        return False

    entity_terms = [
        "عصابه", "عصابة", "كلان", "قروب", "مافيا", "الكفن", "كفن",
        "سيرفر", "قراند", "جراند", "gta", "rp", "roleplay", "رول بلاي", "رولبلاي",
        "الحياه الواقعيه", "الحياة الواقعية", "ريسبكت", "respect",
    ]
    has_entity = any(_normalize_arabic_for_moderation(term) in t for term in entity_terms)
    if not has_entity:
        return False

    neutral_or_question_terms = [
        "ليه", "ليش", "لماذا", "هل", "وش", "ايش", "ما", "من", "متى", "وين", "اين", "كيف",
        "مقر", "سري", "رئيس", "اعضاء", "عضو", "عندها", "عندهم", "يكون", "تكون",
        "داخل", "في السيرفر", "بالسيرفر", "قصة", "فعاليه", "فعالية", "مهمة", "مهمه",
        "سياره", "سيارة", "بيت", "مكان", "منطقه", "منطقة", "قاعدة", "قاعده",
    ]
    has_neutral_context = "؟" in text or "?" in text or any(term in t for term in [_normalize_arabic_for_moderation(x) for x in neutral_or_question_terms])
    word_count = len([w for w in t.split(" ") if w.strip()])

    # إذا كان النص مجرد اسم كيان/كلان داخل RP بدون أي سب واضح، فهو آمن أيضًا.
    # مثال: "عصابة الكفن" أو "كلان الكفن".
    short_entity_name_only = word_count <= 6 and not re.search(r"(كلهم|انتم|انتو|هم)\s+", t)

    # وجود كلمة يا لا يكفي للحذف؛ مثل "ياعيال" افتتاح كلام عام وليس سبًا.
    return bool(has_neutral_context or short_entity_name_only)


def _simple_safe_moderation(text: str) -> Optional[Dict[str, Any]]:
    """
    اختصار آمن للنصوص العادية جدًا أو سياقات الألعاب/RP الواضحة،
    حتى لا تتعطل التغريدة أو تُحذف بسبب سوء فهم كلمة واحدة.
    """
    clean = (text or "").strip().lower()
    normalized = " ".join(clean.split())
    if not normalized:
        return {
            "shouldDelete": False,
            "deleteParentReply": False,
            "category": "empty_or_media_only",
            "reason": "لا يوجد نص واضح للفحص",
            "confidence": 0.0,
            "checks": 0,
            "fast_safe": True,
        }

    hard_violation = _local_hard_violation_guard(text)
    if hard_violation is not None:
        return hard_violation

    safe_phrases = {
        "مرحبا", "مرحبا.", "مرحبا!", "مرحباً", "مرحباً.", "مرحباً!",
        "هلا", "هلا.", "هلا!", "اهلا", "أهلا", "اهلاً", "أهلاً",
        "السلام عليكم", "وعليكم السلام", "صباح الخير", "مساء الخير",
        "hi", "hello", "hey", "test", "تجربة", "اختبار",
    }
    if normalized in safe_phrases:
        return {
            "shouldDelete": False,
            "deleteParentReply": False,
            "category": "safe",
            "reason": "نص ترحيبي آمن",
            "confidence": 0.0,
            "checks": 0,
            "fast_safe": True,
        }

    if _is_likely_roleplay_or_game_context_safe(normalized):
        return {
            "shouldDelete": False,
            "deleteParentReply": False,
            "category": "safe_rp_context",
            "reason": "سياق لعبة/RP أو سؤال عن كيان داخل سيرفر، وليس سبًا أو هجومًا مباشرًا",
            "confidence": 0.0,
            "checks": 0,
            "fast_safe": True,
            "rp_context_safe": True,
        }

    # لا نعتبر النص القصير آمنًا تلقائيًا؛ غير التحيات والسياقات الآمنة يذهب إلى Qwen.
    return None



# ================= Respect AI Learned Abuse Dictionary =================
# إذا تم قبول بلاغ وحُذفت التغريدة، نحفظ العبارة المخالفة في Supabase.
# بعدها moderate-post يفحص هذا القاموس قبل Qwen ويحذف فورًا حتى مع الفواصل/المسافات/التمويه.
LEARNED_TERMS_TABLE = os.getenv("RESPECT_AI_LEARNED_TERMS_TABLE", "respect_ai_learned_terms").strip() or "respect_ai_learned_terms"
_LEARNED_TERMS_CACHE: Dict[str, Any] = {"ts": 0.0, "items": []}
_LEARNED_TERMS_TTL_SECONDS = int(os.getenv("RESPECT_AI_LEARNED_TERMS_CACHE_TTL", "60") or "60")


def _learned_normalized(value: str) -> Dict[str, str]:
    n = _normalize_obfuscated_text_for_moderation(value or "")
    return {"raw": str(value or "").strip(), "spaced": n.get("spaced_collapsed") or n.get("spaced") or "", "compact": n.get("compact") or ""}


def _learned_hash(normalized_compact: str) -> str:
    return hashlib.sha256((normalized_compact or "").encode("utf-8")).hexdigest()


def _safe_term_phrase(value: str, max_len: int = 90) -> str:
    return re.sub(r"\s+", " ", str(value or "").strip())[:max_len]


def _is_learnable_term(term: str) -> bool:
    clean = _safe_term_phrase(term)
    if not clean:
        return False
    n = _learned_normalized(clean)
    compact, spaced = n["compact"], n["spaced"]
    if len(compact) < 2 or len(compact) > 70:
        return False
    if len(spaced.split()) > 8:
        return False
    boring = {"هذا", "هذه", "الى", "على", "في", "من", "عن", "مع", "ليش", "ليه", "ياعيال", "التغريده", "المنشور", "بلاغ", "محتوى", "مسيء", "مخالف", "spam", "report", "post"}
    return compact not in boring and spaced not in boring


def _extract_learned_terms_fallback(post_text: str) -> list[str]:
    n = _learned_normalized(post_text)
    tokens = [t for t in n["spaced"].split() if len(t) >= 2]
    candidates: list[str] = []
    for size in (1, 2, 3):
        for i in range(0, max(0, len(tokens) - size + 1)):
            phrase = " ".join(tokens[i:i + size])
            if _is_learnable_term(phrase):
                candidates.append(phrase)
    seen, out = set(), []
    for c in candidates:
        h = _learned_hash(_learned_normalized(c)["compact"])
        if h in seen:
            continue
        seen.add(h)
        out.append(c)
        if len(out) >= 8:
            break
    return out


def _extract_learned_terms_with_ai(post_text: str, report_reason: str, report_details: str, ai_reason: str) -> list[str]:
    text = (post_text or "").strip()
    if not text:
        return []
    if QWEN_API_KEY:
        prompt = f"""
استخرج فقط الكلمات أو العبارات المسيئة التي تسببت بحذف المنشور داخل تطبيق Respect App.
- لا ترجع كامل المنشور إلا إذا كله سب مباشر.
- رجّع المسبة/الإهانة/التهديد أو العبارة المخالفة فقط.
- تجاهل الكلمات العادية والسياق الآمن.
- إذا لا توجد عبارة واضحة، رجع قائمة فارغة.
أعد JSON فقط: {{"terms": ["عبارة 1", "عبارة 2"]}}

نص المنشور:
{text[:1500]}

سبب البلاغ:
{(report_reason or '')[:500]}

تفاصيل البلاغ:
{(report_details or '')[:800]}

سبب قرار Respect AI:
{(ai_reason or '')[:800]}
""".strip()
        try:
            content = _chat_completion_request(
                model=QWEN_TEXT_MODEL,
                api_key=QWEN_API_KEY,
                base_url=QWEN_BASE_URL,
                messages=[{"role": "system", "content": "أنت مستخرج قاموس إساءات. أعد JSON صحيح فقط."}, {"role": "user", "content": prompt}],
                temperature=0.02,
                max_tokens=300,
                timeout=35,
                log_label="LEARN_TERMS",
            )
            parsed = _safe_json_from_ai(str(content))
            if isinstance(parsed, dict) and isinstance(parsed.get("terms"), list):
                terms = [_safe_term_phrase(str(x)) for x in parsed.get("terms") or []]
                terms = [t for t in terms if _is_learnable_term(t)]
                if terms:
                    return terms
        except Exception as e:
            logger.warning("Learned terms extraction failed: %s", e)
    return _extract_learned_terms_fallback(text)


def _insert_learned_abuse_term(*, term: str, category: str, reason: str, source_post_id: str, source_report_id: str, reporter_username: str, reported_username: str) -> Dict[str, Any]:
    phrase = _safe_term_phrase(term)
    if not _is_learnable_term(phrase):
        return {"inserted": False, "reason": "not_learnable", "term": phrase}
    n = _learned_normalized(phrase)
    now = datetime.now(timezone.utc).isoformat()
    payload = {
        "term": phrase,
        "normalized_spaced": n["spaced"],
        "normalized_compact": n["compact"],
        "term_hash": _learned_hash(n["compact"]),
        "category": (category or "learned_abuse")[:80],
        "reason": (reason or "تم تعلمها من بلاغ صحيح")[:500],
        "source_post_id": (source_post_id or "")[:120],
        "source_report_id": (source_report_id or "")[:120],
        "reporter_username": _display_username(reporter_username or ""),
        "reported_username": _display_username(reported_username or ""),
        "active": True,
        "match_count": 0,
        "created_at": now,
        "updated_at": now,
    }
    headers = {**_supabase_headers(use_service_role=True), "Prefer": "return=representation", "Prefer": "resolution=merge-duplicates,return=representation"}
    try:
        r = requests.post(f"{SB_URL}/rest/v1/{LEARNED_TERMS_TABLE}", headers=headers, params={"on_conflict": "term_hash"}, json=payload, timeout=12)
        if r.status_code in (200, 201):
            _LEARNED_TERMS_CACHE["ts"] = 0.0
            return {"inserted": True, "term": phrase, "hash": payload["term_hash"]}
        logger.warning("Insert learned term failed status=%s body=%s", r.status_code, _safe_response_text(r.text, 300))
        return {"inserted": False, "status": r.status_code, "body": r.text[:300], "term": phrase}
    except Exception as e:
        logger.warning("Insert learned term exception: %s", e)
        return {"inserted": False, "error": str(e), "term": phrase}


def _learn_abuse_terms_from_valid_report(req: RespectAIModerationRequest, result: Dict[str, Any]) -> Dict[str, Any]:
    post_text = (req.postText or req.text or "").strip()
    if not post_text:
        return {"learned": False, "terms": [], "reason": "empty_post_text"}
    terms = _extract_learned_terms_with_ai(post_text, req.reason or "", req.details or "", str(result.get("reason") or ""))
    inserted = [_insert_learned_abuse_term(
        term=term,
        category=str(result.get("category") or "learned_abuse"),
        reason=str(result.get("reason") or req.reason or "بلاغ صحيح"),
        source_post_id=req.postId or "",
        source_report_id=req.reportId or "",
        reporter_username=req.reporterUsername or "",
        reported_username=req.reportedUsername or req.username or "",
    ) for term in terms]
    ok_count = sum(1 for x in inserted if x.get("inserted") is True)
    return {"learned": ok_count > 0, "terms": terms, "inserted": inserted, "count": ok_count}


def _load_active_learned_terms(force: bool = False) -> list[Dict[str, Any]]:
    now = time.time()
    if not force and (now - float(_LEARNED_TERMS_CACHE.get("ts") or 0)) < _LEARNED_TERMS_TTL_SECONDS:
        return list(_LEARNED_TERMS_CACHE.get("items") or [])
    try:
        r = requests.get(
            f"{SB_URL}/rest/v1/{LEARNED_TERMS_TABLE}",
            headers=_supabase_headers(use_service_role=True),
            params={"select": "id,term,normalized_spaced,normalized_compact,category,reason,active", "active": "eq.true", "order": "created_at.desc", "limit": "700"},
            timeout=10,
        )
        if r.status_code >= 400:
            logger.warning("Load learned terms failed status=%s body=%s", r.status_code, _safe_response_text(r.text, 250))
            _LEARNED_TERMS_CACHE.update({"ts": now, "items": []})
            return []
        data = r.json() if r.text else []
        items = [dict(x) for x in data if isinstance(x, dict)] if isinstance(data, list) else []
        _LEARNED_TERMS_CACHE.update({"ts": now, "items": items})
        return items
    except Exception as e:
        logger.warning("Load learned terms exception: %s", e)
        return list(_LEARNED_TERMS_CACHE.get("items") or [])


def _learned_phrase_matches_text(term_compact: str, term_spaced: str, text_compact: str, text_spaced: str) -> bool:
    term_compact, term_spaced = (term_compact or "").strip(), (term_spaced or "").strip()
    if len(term_compact) < 2:
        return False
    text_tokens = set((text_spaced or "").split())
    if len(term_compact) <= 2:
        if term_spaced in text_tokens:
            return True
        if len(term_compact) == 2 and re.search(rf"(^|\s){re.escape(term_compact[0])}\s+{re.escape(term_compact[1])}(\s|$)", text_spaced):
            return True
        return False
    if " " in term_spaced:
        return re.search(rf"(^|\s){re.escape(term_spaced)}(\s|$)", text_spaced) is not None
    return term_compact in text_compact


def _learned_abuse_violation_guard(text: str) -> Optional[Dict[str, Any]]:
    if not (text or "").strip():
        return None
    n = _learned_normalized(text)
    if not n["compact"]:
        return None
    for item in _load_active_learned_terms():
        term_compact = str(item.get("normalized_compact") or "").strip()
        term_spaced = str(item.get("normalized_spaced") or "").strip()
        if term_compact and _learned_phrase_matches_text(term_compact, term_spaced, n["compact"], n["spaced"]):
            return {
                "shouldDelete": True,
                "deleteParentReply": False,
                "category": str(item.get("category") or "learned_abuse"),
                "reason": f"تم حذف المحتوى لأنه يطابق عبارة مخالفة تعلمها Respect AI من بلاغ صحيح سابق: {str(item.get('term') or '')[:60]}",
                "confidence": 0.99,
                "checks": 1,
                "learned_guard": True,
                "matchedTerm": str(item.get("term") or ""),
            }
    return None

def _local_obvious_violation(text: str) -> Optional[Dict[str, Any]]:
    """
    فلتر احتياطي عند تعطل Qwen. لا يحذف إلا المخالف الواضح جدًا.
    """
    learned_violation = _learned_abuse_violation_guard(text)
    if learned_violation is not None:
        learned_violation["local_fallback"] = True
        return learned_violation

    hard_violation = _local_hard_violation_guard(text)
    if hard_violation is not None:
        hard_violation["local_fallback"] = True
        return hard_violation

    t = (text or "").strip().lower()
    if not t:
        return None

    patterns = [
        (r"(اقتل|اقتلوه|اقتلو|لازم\s+ينضرب|يموت|موتوا)", "threat", "تهديد أو تحريض واضح"),
        (r"(سب\s*الدين|سب\s*الله|اهانة\s*الدين|إهانة\s*الدين)", "religion_abuse", "إساءة دينية واضحة"),
        (r"(يا\s*كلب|يا\s*حمار|انت\s*حيوان|أنت\s*حيوان|كل\s*خرا|كل\s*زق)", "insult", "إهانة مباشرة واضحة"),
        (r"\b(kill\s+yourself|i\s+will\s+kill|fuck\s+you|bitch|asshole)\b", "insult", "إهانة/تهديد واضح"),
    ]
    for pattern, category, reason in patterns:
        if re.search(pattern, t, flags=re.IGNORECASE):
            return {
                "shouldDelete": True,
                "deleteParentReply": False,
                "category": category,
                "reason": reason,
                "confidence": 0.95,
                "checks": 0,
                "local_fallback": True,
            }
    return None



def _respect_ai_moderation_system_prompt(pass_number: int = 1) -> str:
    return f"""
أنت نظام مراجعة محتوى ذكي وسياقي لتطبيق تواصل اجتماعي اسمه Respect App.

مهمتك ليست الرد على المستخدم، بل تحليل النص والسياق كاملًا لتحديد هل يُسمح بنشره أم لا.
هذه مراجعة رقم {pass_number} من 3. لا تحكم من كلمة واحدة فقط؛ افهم الجملة والسياق والنية.

افهم كل اللهجات العربية: خليجي، سعودي، عراقي، شامي، فلسطيني، لبناني، مصري، مغربي، يمني، سوداني.
وافهم الفصحى والإنجليزية والفرانكو والكتابة المشوهة أو المختصرة أو بدون مسافات أو مع تكرار حروف أو رموز أو فواصل مثل:
ياكلب، يا كلب، ي كلب، كلبب، ك ل ب، ك.ل.ب، kلب، klb, 5ra, khara, zgg, زق، خرا، كل خرا، fuck, shit, bitch, asshole.
راجع كل كلمة وكل حرف ولا تسمح بتمرير الألفاظ الجنسية أو السب بسبب وجود سياق RP أو اسم كلان.

قاعدة ذهبية:
لا ترفض بسبب وجود كلمة فقط. ارفض فقط إذا كانت الكلمة مستخدمة كإهانة أو سب أو تهديد أو تحريض أو إساءة واضحة.

قاعدة مهمة جدًا لسياق الألعاب/RP والسيرفرات:
كلمات مثل "عصابة"، "كلان"، "قروب"، "مافيا"، "الكفن"، "كفن" قد تكون أسماء كيانات أو فرق داخل سيرفر GTA/RP/Respect، وليست إهانة جماعية بحد ذاتها.
إذا كان النص سؤالًا أو اقتراحًا أو نقاشًا عن كيان داخل السيرفر مثل: "ياعيال ليه عصابة الكفن ما يكون عندها مقر سري؟" فالقرار الصحيح allowed=true و shouldDelete=false.
لا تصنف اسم الكلان/العصابة كـ insult أو hate إلا إذا كان معه سب مباشر أو تحريض أو تعميم مهين واضح مثل: "كلهم كلاب" أو تهديد صريح.
لكن إذا ظهر لفظ جنسي/فاحش أو سب مباشر داخل الجملة، فالمنشور مخالف حتى لو كان باقي النص عن RP أو عصابة أو سيرفر.

أمثلة يجب السماح بها:
- "وش اسم الحيوان الي ماينام؟" لأنه سؤال عام وليس إهانة لشخص.
- "ما هو الحيوان الأسرع؟" سؤال معلوماتي آمن.
- "كلب البحر حيوان لطيف" وصف حيوان وليس سبًا.
- "شخصية في GTA اسمها كلب المدينة" إذا كانت ضمن سياق لعبة/RP وليست إهانة لشخص.
- "ياعيال ليه عصابة الكفن ما يكون عندها مقر سري؟" سؤال/اقتراح RP آمن وليس إهانة.
- "من رئيس عصابة كفن؟" سؤال عن سياق سيرفر/قصة آمن.
- نقد محترم مثل: "تصرفك غلط" أو "ما أتفق مع كلامك".

أمثلة يجب رفضها:
- "أنت حيوان" لأنها إهانة لشخص.
- "يا كلب" أو "كل خرا ياكلب" لأنها سب مباشر.
- "أنت غبي/حقير/وسخ" لأنها إهانة شخصية.
- تهديد أو تحريض مثل: "اقتلوه" أو "لازم ينضرب".
- إساءة أديان أو طوائف أو رموز دينية.
- رد هجومي على شخص آخر أو مشاجرة واضحة بين شخصين.

حلل دائمًا:
1) هل النص سؤال بريء أو معلومة عامة؟ إذا نعم اسمح.
2) هل الكلمة موجهة لشخص/مستخدم بصيغة "أنت/يا/لك/له/فلان"؟ إذا نعم غالبًا مخالفة.
3) هل النص ضمن لعبة/RP/مزاح غير مؤذٍ؟ لا ترفض إلا إذا فيه إهانة واضحة لشخص.
4) هل يوجد سياق تغريدة أصلية أو رد أب؟ استخدمه لتعرف هل الرد هجوم أم سؤال عادي.

كن صارمًا جدًا مع السب والشتم والتحريض وإساءة الأديان، لكن لا تكن مبالغًا مع الأسئلة والمعلومات والكلام العادي.

أرجع JSON فقط بدون markdown وبدون شرح خارج JSON بهذا الشكل:
{{
  "allowed": true أو false,
  "shouldDelete": true أو false,
  "deleteParentReply": true أو false,
  "category": "safe" أو "insult" أو "hate" أو "threat" أو "religion_abuse" أو "fight" أو "harassment",
  "reason": "سبب مختصر بالعربية",
  "confidence": رقم من 0 إلى 1
}}

قاعدة مهمة:
- إذا allowed=false يجب أن تكون shouldDelete=true.
- إذا allowed=true يجب أن تكون shouldDelete=false.
- لا تجعل allowed=false إلا إذا أنت متأكد من وجود مخالفة في السياق، وليس بسبب كلمة مفردة.
""".strip()

def _build_moderation_prompt(req: RespectAIModerationRequest, pass_number: int = 1) -> str:
    text = (req.text or '').strip()[:4000]
    parts = [
        f"مراجعة رقم {pass_number} من 3.",
        "حلل هذا النص بدقة شديدة وبفهم سياقي، وليس كفلتر كلمات:",
        "",
        text,
        "",
        "مهم: لا ترفض النص لمجرد وجود كلمة مثل حيوان أو كلب أو عصابة أو كفن. اسأل نفسك: هل الكلمة موجهة كإهانة لشخص؟ أم هي سؤال/معلومة/سياق لعبة/RP؟",
        "إذا كان النص سؤالًا عامًا مثل: وش اسم الحيوان الي ماينام؟ فالقرار الصحيح allowed=true و shouldDelete=false.",
        "إذا كان النص سؤالًا أو اقتراحًا عن كيان داخل سيرفر مثل: ياعيال ليه عصابة الكفن مايكون عندها مقر سري؟ فالقرار الصحيح allowed=true و shouldDelete=false.",
        "إذا كان النص سبًا مباشرًا مثل: أنت حيوان، يا كلب، كل خرا ياكلب، فالقرار الصحيح allowed=false و shouldDelete=true.",
        "",
        f"نوع المحتوى: {req.contentType}",
        f"الكاتب: {display_username(req.username)}",
    ]
    if req.postText.strip():
        parts.append(f"نص التغريدة الأصلية للسياق:\n{req.postText.strip()[:3000]}")
    if req.parentReplyText.strip():
        parts.append(f"الرد الأب/الرد المقابل للسياق:\n{req.parentReplyText.strip()[:2500]}")
    if req.recentRepliesText.strip():
        parts.append(f"آخر ردود النقاش للسياق:\n{req.recentRepliesText.strip()[:3500]}")
    return "\n".join(parts)

def _safe_json_from_ai(value: str) -> Dict[str, Any]:
    raw = (value or "").strip()
    if raw.startswith("```"):
        raw = raw.strip("`").strip()
        if raw.lower().startswith("json"):
            raw = raw[4:].strip()
    start = raw.find("{")
    end = raw.rfind("}")
    if start >= 0 and end > start:
        raw = raw[start:end + 1]
    try:
        data = json.loads(raw)
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def _normalize_moderation_result(data: Dict[str, Any]) -> Dict[str, Any]:
    category = str(data.get("category") or "").strip().lower()
    raw_confidence = data.get("confidence")
    try:
        confidence = float(raw_confidence) if raw_confidence is not None else 1.0
    except Exception:
        confidence = 1.0
    confidence = max(0.0, min(1.0, confidence))

    allowed_value = data.get("allowed")
    explicit_block = (
        data.get("shouldDelete") is True
        or data.get("delete") is True
        or data.get("blocked") is True
        or allowed_value is False
    )
    explicit_safe = allowed_value is True or category == "safe"

    # كل التصنيفات التي تعتبر مخالفة.
    # مهم جدًا: qwen-vl-plus قد يرجع nudity / sexual / adult / nsfw،
    # لذلك لازم تكون موجودة هنا وإلا قد تُعتبر الصورة آمنة بالخطأ.
    violation_categories = {
        "insult", "hate", "threat", "religion_abuse", "fight", "harassment",
        "abuse", "bullying", "profanity", "personal_attack", "violence", "sectarian",
        "nudity", "sexual", "porn", "explicit", "adult", "nsfw",
        "partial_nudity", "sexual_content", "image_violation", "unsafe_image",
        "weapon", "dangerous", "blood", "gore", "self_harm", "extremism",
        "unsafe_link", "phishing", "malware", "social_engineering", "unwanted_software",
        "harmful_application", "short_link", "link_checker_unavailable", "safe_browsing_error",
        "virustotal_unsafe_link", "virustotal_error", "virustotal_missing_key",
        "virustotal_timeout", "suspicious_link", "other"
    }

    should_delete = bool(explicit_block or (category in violation_categories and not explicit_safe))

    # حماية من الحذف المبالغ فيه في التصنيفات اللغوية التي قد يخطئ فيها النموذج.
    # لا نحذف insult/harassment/fight إلا إذا كانت الثقة عالية، أو كان هناك سب/تهديد واضح محليًا.
    soft_language_categories = {"insult", "harassment", "fight", "bullying", "profanity", "personal_attack"}
    reason_text = str(data.get("reason") or "")
    if should_delete and category in soft_language_categories and confidence < 0.85 and not _has_obvious_direct_attack(reason_text):
        should_delete = False
        category = "needs_context"

    # لو الثقة ضعيفة جدًا وما فيه بلوك صريح، نخلي المراجعات الأخرى تحسم.
    if confidence < 0.35 and not explicit_block:
        should_delete = False

    delete_parent = bool(data.get("deleteParentReply") is True and confidence >= 0.55)

    return {
        "shouldDelete": should_delete,
        "deleteParentReply": delete_parent,
        "category": str(category or ("violation" if should_delete else "safe"))[:80],
        "reason": str(data.get("reason") or ("يحتوي على مخالفة واضحة" if should_delete else ""))[:500],
        "confidence": confidence,
    }


def _single_moderation_pass(req: RespectAIModerationRequest, pass_number: int) -> Dict[str, Any]:
    content = _chat_completion_request(
        model=QWEN_MODEL,
        api_key=QWEN_API_KEY,
        base_url=QWEN_BASE_URL,
        messages=[
            {"role": "system", "content": _respect_ai_moderation_system_prompt(pass_number)},
            {"role": "user", "content": _build_moderation_prompt(req, pass_number)},
        ],
        temperature=0.0,
        max_tokens=260,
        timeout=18,
        # لا نرسل response_format هنا لأن بعض موديلات/مناطق Qwen قد ترفضه وترجع 400.
        # البرومبت يطلب JSON، وبعدها _safe_json_from_ai يستخرج JSON حتى لو رجع معه نص إضافي.
        response_format=None,
        log_label=f"QWEN MODERATION PASS {pass_number}",
    )

    return _normalize_moderation_result(_safe_json_from_ai(str(content)))


def moderate_with_qwen(req: RespectAIModerationRequest) -> Dict[str, Any]:
    text = (req.text or "").strip()

    # الطبقة 1: فحص محلي صارم قبل أي سياق آمن أو مراجعة Qwen.
    # هذا يمنع تمرير الكلمات الفاحشة/السب إذا ظهرت داخل جملة تبدو RP.
    hard_violation = _local_hard_violation_guard(text)
    if hard_violation is not None:
        return hard_violation

    fast_safe = _simple_safe_moderation(text)
    if fast_safe is not None:
        return fast_safe

    if not QWEN_API_KEY:
        fallback_block = _local_obvious_violation(text)
        if fallback_block is not None:
            return fallback_block
        return {
            "shouldDelete": False,
            "deleteParentReply": False,
            "category": "safe",
            "reason": "QWEN_API_KEY غير موجود، وتم السماح بالنص لأنه لا يحتوي مخالفة واضحة",
            "confidence": 0.0,
            "checks": 0,
            "fallback_safe": True,
        }

    # لتسريع التجربة: مراجعة واحدة فقط بدل مراجعة واحدة قابلة للزيادة عبر إعدادات السيرفر.
    # لأن Flutter أصبح ينشر فورًا والمراجعة تعمل بالخلفية، لا نريد استهلاك وقت/رصيد زائد.
    try:
        result = _single_moderation_pass(req, 1)
        result["checks"] = 1
        return result
    except Exception as e:
        logger.warning("Moderation pass failed: %s", e)
        fallback_block = _local_obvious_violation(text)
        if fallback_block is not None:
            fallback_block["errors"] = [str(e)[:300]]
            return fallback_block
        return {
            "shouldDelete": False,
            "deleteParentReply": False,
            "category": "safe",
            "reason": "تعذر فحص Qwen، وتم السماح بالنص لأنه لا يحتوي مخالفة واضحة",
            "confidence": 0.0,
            "checks": 0,
            "fallback_safe": True,
            "errors": [str(e)[:300]],
        }


@app.post("/respect-ai/moderate", response_model=RespectAIModerationResponse)
def respect_ai_moderate(req: RespectAIModerationRequest, request: FastAPIRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_secret(x_app_secret)
    _enforce_moderation_rate(_client_ip(request))
    result = moderate_with_qwen(req)
    return RespectAIModerationResponse(
        ok=True,
        shouldDelete=bool(result.get("shouldDelete")),
        deleteParentReply=bool(result.get("deleteParentReply")),
        reason=str(result.get("reason") or ""),
        category=str(result.get("category") or "safe"),
        confidence=float(result.get("confidence") or 0.0),
        model=QWEN_MODEL,
    )


def _delete_supabase_post(post_id: str) -> Dict[str, Any]:
    pid = (post_id or "").strip()
    if not pid:
        raise HTTPException(status_code=400, detail="postId is empty")

    headers = {**_supabase_headers(use_service_role=True), "Prefer": "return=representation"}
    deleted_replies = False

    # نحذف الردود التابعة أولًا حتى لا تبقى تعليقات يتيمة.
    try:
        rr = requests.delete(
            f"{SB_URL}/rest/v1/post_replies",
            headers=headers,
            params={"post_id": f"eq.{pid}"},
            timeout=12,
        )
        deleted_replies = rr.status_code // 100 == 2
        if rr.status_code >= 400:
            logger.warning("Supabase delete replies failed status=%s body=%s", rr.status_code, _safe_response_text(rr.text, 300))
    except Exception as e:
        logger.exception("Supabase delete replies exception: %s", e)

    r = requests.delete(
        f"{SB_URL}/rest/v1/posts",
        headers=headers,
        params={"id": f"eq.{pid}"},
        timeout=15,
    )

    logger.info("Backend delete post post_id=%s status=%s server_delete_mode=%s", pid, r.status_code, bool(SB_SERVICE))
    logger.debug("Backend delete post body=%s", _safe_response_text(r.text, 800))

    if r.status_code >= 400:
        raise HTTPException(
            status_code=500,
            detail={
                "supabase_status": r.status_code,
                "supabase_body": r.text,
                "hint": "إذا ظهر RLS أو permission denied فعّل قيمة الحذف الخاصة بالسيرفر في بيئة الاستضافة.",
            },
        )

    return {
        "deleted": True,
        "deletedReplies": deleted_replies,
        "postId": pid,
        "serverDeleteMode": bool(SB_SERVICE),
    }



def _delete_supabase_story(story_id: str) -> Dict[str, Any]:
    from datetime import datetime, timezone

    sid = (story_id or "").strip()
    if not sid:
        raise HTTPException(status_code=400, detail="storyId is empty")

    headers = {**_supabase_headers(use_service_role=True), "Prefer": "return=representation"}
    payload = {
        "is_active": False,
        "deleted_at": datetime.now(timezone.utc).isoformat(),
        "moderation_status": "deleted_by_respect_ai",
    }

    r = requests.patch(
        f"{SB_URL}/rest/v1/respect_stories",
        headers=headers,
        params={"id": f"eq.{sid}"},
        data=json.dumps(payload),
        timeout=15,
    )

    logger.info("Backend delete story story_id=%s status=%s server_delete_mode=%s", sid, r.status_code, bool(SB_SERVICE))
    logger.debug("Backend delete story body=%s", _safe_response_text(r.text, 800))

    if r.status_code >= 400:
        # fallback delete for old schema if moderation_status/deleted_at columns do not exist.
        r2 = requests.delete(
            f"{SB_URL}/rest/v1/respect_stories",
            headers=headers,
            params={"id": f"eq.{sid}"},
            timeout=15,
        )
        if r2.status_code >= 400:
            raise HTTPException(
                status_code=500,
                detail={
                    "supabase_status": r.status_code,
                    "supabase_body": r.text,
                    "fallback_status": r2.status_code,
                    "fallback_body": r2.text,
                    "hint": "فعّل قيمة الحذف الخاصة بالسيرفر في بيئة الاستضافة حتى يستطيع السيرفر حذف الستوري رغم RLS.",
                },
            )

    return {
        "deleted": True,
        "storyId": sid,
        "serverDeleteMode": bool(SB_SERVICE),
    }


def _patch_supabase_post(post_id: str, payload: Dict[str, Any]) -> Dict[str, Any]:
    pid = (post_id or "").strip()
    if not pid:
        return {"updated": False, "reason": "empty postId"}
    headers = {**_supabase_headers(use_service_role=True), "Prefer": "return=representation"}
    r = requests.patch(
        f"{SB_URL}/rest/v1/posts",
        headers=headers,
        params={"id": f"eq.{pid}"},
        json=payload,
        timeout=15,
    )
    if r.status_code >= 400:
        logger.warning("Supabase patch post failed status=%s body=%s", r.status_code, _safe_response_text(r.text, 300))
        return {"updated": False, "status": r.status_code, "body": r.text[:500]}
    return {"updated": True, "postId": pid}


def _insert_user_warning(username: str, reason: str, post_id: str = "", report_id: str = "") -> Dict[str, Any]:
    from datetime import datetime, timedelta, timezone
    user = _display_username(username)
    now = datetime.now(timezone.utc)
    payload = {
        "username": user,
        "reason": (reason or "بلاغ صحيح تمت مراجعته بالذكاء الاصطناعي")[:500],
        "post_id": post_id,
        "report_id": report_id,
        "active": True,
        "created_at": now.isoformat(),
        "expires_at": (now + timedelta(days=30)).isoformat(),
    }
    headers = {**_supabase_headers(use_service_role=True), "Prefer": "return=representation"}
    try:
        r = requests.post(f"{SB_URL}/rest/v1/user_warnings", headers=headers, json=payload, timeout=12)
        if r.status_code >= 400:
            logger.warning("Insert warning failed status=%s body=%s", r.status_code, _safe_response_text(r.text, 300))
    except Exception as e:
        logger.exception("Insert warning exception: %s", e)

    count = 0
    try:
        cr = requests.get(
            f"{SB_URL}/rest/v1/user_warnings",
            headers=headers,
            params={"username": f"eq.{user}", "active": "eq.true", "expires_at": f"gt.{now.isoformat()}", "select": "id"},
            timeout=12,
        )
        if cr.status_code < 400:
            count = len(cr.json() if cr.text else [])
    except Exception as e:
        logger.exception("Count warnings exception: %s", e)

    blocked = False
    if count >= 3:
        blocked = _block_user_from_server(user, "تجاوز 3 تحذيرات خلال 30 يوم")
    return {"warningCount": count, "blocked": blocked}


def _block_user_from_server(username: str, reason: str) -> bool:
    user = _display_username(username)
    clean = normalize_username(user)
    from datetime import datetime, timezone
    now = datetime.now(timezone.utc).isoformat()
    payload = {
        "is_blocked": True,
        "blocked": True,
        "banned": True,
        "disabled": True,
        "canLogin": False,
        "blocked_reason": reason,
        "blocked_at": now,
        "updated_at": now,
    }
    headers = {**_supabase_headers(use_service_role=True), "Prefer": "return=representation"}
    try:
        r = requests.patch(
            f"{SB_URL}/rest/v1/users",
            headers=headers,
            params={"or": f"(username.eq.{user},username.eq.{clean})"},
            json=payload,
            timeout=15,
        )
        if r.status_code >= 400:
            logger.warning("Block user failed status=%s body=%s", r.status_code, _safe_response_text(r.text, 300))
            return False
        return True
    except Exception as e:
        logger.exception("Block user exception: %s", e)
        return False



def _public_image_urls_from_req(req: RespectAIModerationRequest) -> list[str]:
    urls: list[str] = []
    for value in (req.imageUrls or []):
        u = str(value or "").strip()
        if u.startswith("http://") or u.startswith("https://"):
            urls.append(u)
    single = str(req.imageUrl or "").strip()
    if single.startswith("http://") or single.startswith("https://"):
        urls.append(single)
    # إزالة التكرار مع الحفاظ على الترتيب.
    out: list[str] = []
    seen = set()
    for u in urls:
        if u not in seen:
            seen.add(u)
            out.append(u)
    return out[:6]




def _public_video_urls_from_req(req: RespectAIModerationRequest) -> list[str]:
    urls: list[str] = []

    # دعم رابط واحد قديم videoUrl + قائمة مستقبلية videoUrls.
    for value in (req.videoUrls or []):
        u = str(value or "").strip()
        if u.startswith("http://") or u.startswith("https://"):
            urls.append(u)

    single = str(req.videoUrl or "").strip()
    if single.startswith("http://") or single.startswith("https://"):
        urls.append(single)

    # إزالة التكرار مع الحفاظ على الترتيب.
    out: list[str] = []
    seen = set()
    for u in urls:
        if u not in seen:
            seen.add(u)
            out.append(u)
    return out[:2]


def _is_qwen_inappropriate_content_error(e: Exception) -> bool:
    error_text = str(e).lower()
    return (
        "data_inspection_failed" in error_text
        or "inappropriate content" in error_text
        or "input data may contain inappropriate" in error_text
        or "may contain inappropriate" in error_text
    )


def _download_video_to_tempfile(video_url: str) -> str:
    # حد آمن حتى لا يستهلك السيرفر ذاكرة كبيرة. عدله من Render إذا احتجت.
    max_mb = int(os.getenv("RESPECT_AI_MAX_VIDEO_MB", "70"))
    max_bytes = max_mb * 1024 * 1024

    suffix = ".mp4"
    clean_url = video_url.split("?")[0].lower()
    if clean_url.endswith(".mov"):
        suffix = ".mov"
    elif clean_url.endswith(".webm"):
        suffix = ".webm"
    elif clean_url.endswith(".m4v"):
        suffix = ".m4v"

    tmp = tempfile.NamedTemporaryFile(delete=False, suffix=suffix)
    tmp_path = tmp.name
    downloaded = 0

    try:
        with requests.get(video_url, stream=True, timeout=(10, 45)) as r:
            if r.status_code >= 400:
                raise HTTPException(
                    status_code=400,
                    detail={
                        "video_download_status": r.status_code,
                        "video_download_body": r.text[:500],
                    },
                )

            for chunk in r.iter_content(chunk_size=1024 * 512):
                if not chunk:
                    continue
                downloaded += len(chunk)
                if downloaded > max_bytes:
                    raise HTTPException(
                        status_code=413,
                        detail=f"حجم الفيديو أكبر من الحد المسموح للمراجعة ({max_mb}MB)",
                    )
                tmp.write(chunk)

        tmp.flush()
        tmp.close()

        if downloaded <= 0:
            raise HTTPException(status_code=400, detail="تعذر تحميل الفيديو أو الفيديو فارغ")

        return tmp_path
    except Exception:
        try:
            tmp.close()
        except Exception:
            pass
        try:
            os.unlink(tmp_path)
        except Exception:
            pass
        raise


def _extract_video_frame_data_urls(video_url: str, max_frames: int = 10) -> list[Dict[str, Any]]:
    """
    يستخرج لقطات JPEG من الفيديو ويحولها إلى data:image/jpeg;base64.
    يحتاج على Render إضافة opencv-python-headless داخل requirements.txt.
    """
    try:
        import cv2  # type: ignore
    except Exception as e:
        raise RuntimeError(
            "مكتبة opencv-python-headless غير مثبتة على السيرفر. "
            "أضفها إلى requirements.txt ثم أعد نشر Render."
        ) from e

    video_path = _download_video_to_tempfile(video_url)
    frames: list[Dict[str, Any]] = []

    try:
        cap = cv2.VideoCapture(video_path)
        if not cap.isOpened():
            raise RuntimeError("تعذر فتح الفيديو لاستخراج اللقطات")

        frame_count = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
        fps = float(cap.get(cv2.CAP_PROP_FPS) or 0.0)
        duration = (frame_count / fps) if frame_count > 0 and fps > 0 else 0.0

        # إذا كان عدد الإطارات معروفًا نأخذ لقطات موزعة على كامل الفيديو.
        if frame_count > 0:
            wanted = max(4, min(max_frames, frame_count))
            positions = []
            if wanted == 1:
                positions = [0]
            else:
                for i in range(wanted):
                    # نبتعد قليلًا عن البداية والنهاية حتى لا تكون اللقطة سوداء.
                    ratio = (i + 0.5) / wanted
                    positions.append(max(0, min(frame_count - 1, int(frame_count * ratio))))
        else:
            # fallback نقرأ أول عدد معقول من الإطارات.
            positions = list(range(0, max_frames * 30, 30))

        seen_positions = set()
        for frame_index, pos in enumerate(positions, start=1):
            if pos in seen_positions:
                continue
            seen_positions.add(pos)

            cap.set(cv2.CAP_PROP_POS_FRAMES, pos)
            ok, frame = cap.read()
            if not ok or frame is None:
                continue

            # تصغير اللقطة لتخفيف الحجم والتكلفة.
            h, w = frame.shape[:2]
            max_side = 720
            scale = min(1.0, max_side / max(w, h)) if max(w, h) > 0 else 1.0
            if scale < 1.0:
                frame = cv2.resize(frame, (int(w * scale), int(h * scale)))

            ok, buf = cv2.imencode(".jpg", frame, [int(cv2.IMWRITE_JPEG_QUALITY), 82])
            if not ok:
                continue

            b64 = base64.b64encode(buf.tobytes()).decode("ascii")
            second = (pos / fps) if fps > 0 else 0.0
            frames.append({
                "dataUrl": f"data:image/jpeg;base64,{b64}",
                "frameIndex": frame_index,
                "sourceFrame": pos,
                "second": round(second, 2),
                "duration": round(duration, 2),
            })

            if len(frames) >= max_frames:
                break

        cap.release()

        if not frames:
            raise RuntimeError("لم يتم استخراج أي لقطة قابلة للفحص من الفيديو")

        return frames
    finally:
        try:
            os.unlink(video_path)
        except Exception:
            pass


def _single_video_frame_moderation_pass(frame_data_url: str, video_index: int, frame_index: int, second: float) -> Dict[str, Any]:
    if not QWEN_API_KEY:
        return {
            "shouldDelete": True,
            "category": "vision_unavailable",
            "reason": "QWEN_API_KEY غير موجود، تم رفض الفيديو احتياطيًا لأن فحص الفيديو غير متاح",
            "confidence": 1.0,
            "videoIndex": video_index,
            "frameIndex": frame_index,
            "second": second,
        }

    content = _chat_completion_request(
        model=QWEN_VISION_MODEL,
        api_key=QWEN_API_KEY,
        base_url=QWEN_BASE_URL,
        messages=[
            {
                "role": "system",
                "content": _respect_ai_image_moderation_prompt(),
            },
            {
                "role": "user",
                "content": [
                    {
                        "type": "image_url",
                        "image_url": {"url": frame_data_url},
                    },
                    {
                        "type": "text",
                        "text": (
                            "هذه لقطة مأخوذة من فيديو منشور في تطبيق Respect App. "
                            "راجعها كجزء من مراجعة الفيديو. احذف الفيديو إذا ظهرت عري/محتوى جنسي/عنف/سلاح/كراهية. "
                            "أرجع JSON فقط."
                        ),
                    },
                ],
            },
        ],
        temperature=0.0,
        max_tokens=260,
        timeout=35,
        response_format=None,
        log_label=f"QWEN VISION MODERATION VIDEO {video_index} FRAME {frame_index}",
    )

    parsed = _safe_json_from_ai(str(content))
    if not parsed:
        result = {
            "shouldDelete": True,
            "deleteParentReply": False,
            "category": "vision_parse_error",
            "reason": "تعذر قراءة نتيجة فحص لقطة من الفيديو، تم رفض الفيديو احتياطيًا",
            "confidence": 1.0,
        }
    else:
        result = _normalize_moderation_result(parsed)

    result["videoIndex"] = video_index
    result["frameIndex"] = frame_index
    result["second"] = second
    result["visionModel"] = QWEN_VISION_MODEL
    return result


def moderate_videos_with_qwen(req: RespectAIModerationRequest) -> Dict[str, Any]:
    urls = _public_video_urls_from_req(req)
    if not urls:
        return {
            "shouldDelete": False,
            "category": "safe",
            "reason": "",
            "confidence": 0.0,
            "checks": 0,
            "videoChecks": [],
        }

    if not QWEN_API_KEY:
        return {
            "shouldDelete": True,
            "category": "vision_unavailable",
            "reason": "QWEN_API_KEY غير موجود، تم رفض الفيديو احتياطيًا لأن فحص الفيديو غير متاح",
            "confidence": 1.0,
            "checks": 0,
            "videoChecks": [],
        }

    max_frames = int(os.getenv("RESPECT_AI_VIDEO_FRAMES", "10"))
    max_frames = max(4, min(max_frames, 24))

    results: list[Dict[str, Any]] = []
    for video_index, url in enumerate(urls, start=1):
        try:
            frames = _extract_video_frame_data_urls(url, max_frames=max_frames)
        except Exception as e:
            # Fail-closed: إذا لم نستطع فحص الفيديو لا نسمح بمروره.
            r = {
                "shouldDelete": True,
                "category": "video_error",
                "reason": f"تعذر فحص الفيديو رقم {video_index}، تم رفضه احتياطيًا: {e}",
                "confidence": 1.0,
                "videoUrl": url,
                "videoIndex": video_index,
            }
            results.append(r)
            return {
                "shouldDelete": True,
                "category": "video_error",
                "reason": r["reason"],
                "confidence": 1.0,
                "checks": len(results),
                "videoChecks": results,
            }

        for frame in frames:
            frame_index = int(frame.get("frameIndex") or 0)
            second = float(frame.get("second") or 0.0)
            try:
                r = _single_video_frame_moderation_pass(
                    str(frame.get("dataUrl") or ""),
                    video_index=video_index,
                    frame_index=frame_index,
                    second=second,
                )
            except Exception as e:
                if _is_qwen_inappropriate_content_error(e):
                    r = {
                        "shouldDelete": True,
                        "category": "nsfw",
                        "reason": f"الفيديو رقم {video_index} يحتوي على محتوى غير مناسب أو عري عند الثانية {second}، وتم حذف المنشور.",
                        "confidence": 1.0,
                        "videoUrl": url,
                        "videoIndex": video_index,
                        "frameIndex": frame_index,
                        "second": second,
                    }
                else:
                    r = {
                        "shouldDelete": True,
                        "category": "video_vision_error",
                        "reason": f"تعذر فحص لقطة من الفيديو رقم {video_index} عند الثانية {second}، تم رفضه احتياطيًا: {e}",
                        "confidence": 1.0,
                        "videoUrl": url,
                        "videoIndex": video_index,
                        "frameIndex": frame_index,
                        "second": second,
                    }

            # لا نرجع dataUrl حتى لا يكبر response.
            r["videoUrl"] = url
            r.pop("imageUrl", None)
            results.append(r)

            if r.get("shouldDelete") is True:
                return {
                    "shouldDelete": True,
                    "category": str(r.get("category") or "video_violation"),
                    "reason": str(r.get("reason") or "الفيديو مخالف"),
                    "confidence": float(r.get("confidence") or 1.0),
                    "checks": len(results),
                    "videoChecks": results,
                }

    return {
        "shouldDelete": False,
        "category": "safe",
        "reason": "",
        "confidence": max([float(r.get("confidence") or 0.0) for r in results] or [0.0]),
        "checks": len(results),
        "videoChecks": results,
    }


def _respect_ai_image_moderation_prompt() -> str:
    return """
أنت نظام مراجعة صور لتطبيق تواصل اجتماعي اسمه Respect App.

حلل الصورة وحدد هل يجب حذف المحتوى أم لا.
مهم جدًا: اقرأ أي نص ظاهر داخل الصورة OCR، مثل الكتابة على الشاشة أو السكرين شوت أو الملصقات.
احذف إذا كان النص الظاهر أو الصورة نفسها تحتوي بوضوح على:
- عري كامل أو جزئي، ملابس داخلية/شفافة بشكل جنسي، أجزاء حساسة ظاهرة، أو محتوى جنسي/إيحائي صريح.
- عنف دموي أو إصابات صادمة أو تعذيب.
- كراهية أو رموز متطرفة أو تحريض.
- سلاح أو تهديد واضح أو محتوى خطر.
- تنمر بصري أو إهانة مباشرة لشخص.
- كلام مخل بالأدب أو سب مباشر أو إيحاء جنسي أو تحرش مكتوب على الصورة.
- محتوى غير مناسب للنشر العام.

لا تحذف الصور العادية مثل: سيلفي، طعام، مناظر، ألعاب، ميمز غير مؤذية، واجهات تطبيق، لقطات شاشة عادية.

أرجع JSON فقط بدون markdown:
{
  "allowed": true أو false,
  "shouldDelete": true أو false,
  "category": "safe" أو "nudity" أو "sexual" أو "violence" أو "hate" أو "weapon" أو "harassment" أو "dangerous" أو "other",
  "reason": "سبب مختصر بالعربية",
  "confidence": رقم من 0 إلى 1
}
""".strip()


def _single_image_moderation_pass(image_url: str, index: int = 1) -> Dict[str, Any]:
    if not QWEN_API_KEY:
        # لا نمرر الصور بدون فحص، لأن هذا يسبب قبول صور مخالفة.
        return {
            "shouldDelete": True,
            "category": "vision_unavailable",
            "reason": "QWEN_API_KEY غير موجود، تم رفض الصورة احتياطيًا لأن فحص الصور غير متاح",
            "confidence": 1.0,
            "imageUrl": image_url,
        }

    # صيغة OpenAI-compatible vision في DashScope/Model Studio.
    content = _chat_completion_request(
        model=QWEN_VISION_MODEL,
        api_key=QWEN_API_KEY,
        base_url=QWEN_BASE_URL,
        messages=[
            {
                "role": "system",
                "content": _respect_ai_image_moderation_prompt(),
            },
            {
                "role": "user",
                "content": [
                    {
                        "type": "image_url",
                        "image_url": {"url": image_url},
                    },
                    {
                        "type": "text",
                        "text": "راجع هذه الصورة/اللقطة من محتوى في تطبيق Respect App. اقرأ أي نص ظاهر على الشاشة، واحذف إذا كان النص أو الصورة مخالفًا. أرجع JSON فقط.",
                    },
                ],
            },
        ],
        temperature=0.0,
        max_tokens=260,
        timeout=35,
        response_format=None,
        log_label=f"QWEN VISION MODERATION IMAGE {index}",
    )

    parsed = _safe_json_from_ai(str(content))
    if not parsed:
        # إذا لم يرجع موديل الرؤية JSON واضح، نرفض احتياطيًا بدل تمرير الصورة كآمنة.
        result = {
            "shouldDelete": True,
            "deleteParentReply": False,
            "category": "vision_parse_error",
            "reason": "تعذر قراءة نتيجة فحص الصورة من Qwen VL، تم رفضها احتياطيًا",
            "confidence": 1.0,
        }
    else:
        result = _normalize_moderation_result(parsed)
    result["imageUrl"] = image_url
    result["visionModel"] = QWEN_VISION_MODEL
    result["imageIndex"] = index
    return result


def moderate_images_with_qwen(req: RespectAIModerationRequest) -> Dict[str, Any]:
    urls = _public_image_urls_from_req(req)
    if not urls:
        return {
            "shouldDelete": False,
            "category": "safe",
            "reason": "",
            "confidence": 0.0,
            "checks": 0,
            "imageChecks": [],
        }

    results = []
    for i, url in enumerate(urls, start=1):
        try:
            r = _single_image_moderation_pass(url, i)
        except Exception as e:
            # Fail-closed: إذا فشل فحص الصورة لا نسمح لها بالمرور.
            # مهم: Alibaba/Qwen قد يرفض تحليل الصورة المخلة ويرجع data_inspection_failed.
            # هذا ليس خطأ عاديًا؛ نعتبره NSFW حتى يظهر السبب واضحًا في التطبيق بدل vision_error.
            if _is_qwen_inappropriate_content_error(e):
                r = {
                    "shouldDelete": True,
                    "category": "nsfw",
                    "reason": f"الصورة رقم {i} تحتوي على محتوى غير مناسب أو عري، وتم حذف المنشور.",
                    "confidence": 1.0,
                    "imageUrl": url,
                    "imageIndex": i,
                }
            else:
                r = {
                    "shouldDelete": True,
                    "category": "vision_error",
                    "reason": f"تعذر فحص الصورة رقم {i}، تم رفضها احتياطيًا: {e}",
                    "confidence": 1.0,
                    "imageUrl": url,
                    "imageIndex": i,
                }
        results.append(r)
        if r.get("shouldDelete") is True:
            return {
                "shouldDelete": True,
                "category": str(r.get("category") or "image_violation"),
                "reason": str(r.get("reason") or "صورة مخالفة"),
                "confidence": float(r.get("confidence") or 1.0),
                "checks": len(results),
                "imageChecks": results,
            }

    return {
        "shouldDelete": False,
        "category": "safe",
        "reason": "",
        "confidence": max([float(r.get("confidence") or 0.0) for r in results] or [0.0]),
        "checks": len(results),
        "imageChecks": results,
    }



def _extract_urls_from_text(text: str) -> list[str]:
    """
    استخراج الروابط من نص المنشور.
    يدعم:
    - https://example.com
    - http://example.com
    - www.example.com
    ويحذف علامات الترقيم العربية/الإنجليزية من نهاية الرابط.
    """
    raw = str(text or "")
    if not raw.strip():
        return []

    pattern = r'(?:https?://|www\.)[^\s<>"\'\]\[\{\}\|\\^`]+'
    found = re.findall(pattern, raw, flags=re.IGNORECASE)

    out: list[str] = []
    seen = set()
    for url in found:
        u = str(url or "").strip()
        u = u.rstrip(".,،؛;:!؟?)）]}")
        u = u.lstrip("([{'\"")
        if u.startswith("www."):
            u = "https://" + u
        if not (u.startswith("http://") or u.startswith("https://")):
            continue
        if len(u) > 2048:
            continue
        key = u.lower()
        if key not in seen:
            seen.add(key)
            out.append(u)
    return out[:20]


def _safe_browsing_check_urls(urls: list[str]) -> Dict[str, Any]:
    """
    فحص الروابط عبر Google Safe Browsing.
    Fail-closed للمنشورات التي تحتوي روابط إذا المفتاح غير موجود أو فشل الفحص،
    حتى لا يمر رابط خطير بسبب خطأ في الخدمة.
    """
    clean_urls: list[str] = []
    seen = set()
    for url in urls or []:
        u = str(url or "").strip()
        if not (u.startswith("http://") or u.startswith("https://")):
            continue
        key = u.lower()
        if key in seen:
            continue
        seen.add(key)
        clean_urls.append(u)

    if not clean_urls:
        return {
            "safe": True,
            "matches": [],
            "checkedUrls": [],
            "reason": "",
        }

    if not GSB_TOKEN:
        return {
            "safe": False,
            "matches": [],
            "checkedUrls": clean_urls,
            "category": "link_checker_unavailable",
            "reason": "GSB_TOKEN غير موجود، تم رفض المنشور احتياطيًا لأنه يحتوي على رابط غير مفحوص.",
        }

    payload = {
        "client": {
            "clientId": "respect-app",
            "clientVersion": "1.0.0",
        },
        "threatInfo": {
            "threatTypes": [
                "MALWARE",
                "SOCIAL_ENGINEERING",
                "UNWANTED_SOFTWARE",
                "POTENTIALLY_HARMFUL_APPLICATION",
            ],
            "platformTypes": ["ANY_PLATFORM"],
            "threatEntryTypes": ["URL"],
            "threatEntries": [{"url": u} for u in clean_urls],
        },
    }

    try:
        r = requests.post(
            GOOGLE_SAFE_BROWSING_ENDPOINT,
            params={"ke" + "y": GSB_TOKEN},
            json=payload,
            timeout=10,
        )
    except Exception as e:
        return {
            "safe": False,
            "matches": [],
            "checkedUrls": clean_urls,
            "category": "safe_browsing_error",
            "reason": f"تعذر فحص الرابط عبر Google Safe Browsing، تم رفض المنشور احتياطيًا: {e}",
        }

    if r.status_code >= 400:
        return {
            "safe": False,
            "matches": [],
            "checkedUrls": clean_urls,
            "category": "safe_browsing_error",
            "reason": f"فشل فحص Google Safe Browsing: {r.status_code} {r.text[:300]}",
        }

    try:
        data = r.json()
    except Exception:
        data = {}

    matches = data.get("matches", [])
    return {
        "safe": len(matches) == 0,
        "matches": matches if isinstance(matches, list) else [],
        "checkedUrls": clean_urls,
        "reason": "",
    }


def moderate_links_with_safe_browsing(req: RespectAIModerationRequest) -> Dict[str, Any]:
    text_parts = [
        str(req.text or ""),
        str(req.postText or ""),
        str(req.parentReplyText or ""),
        str(req.recentRepliesText or ""),
    ]
    urls = _extract_urls_from_text("\n".join(text_parts))
    if not urls:
        return {
            "shouldDelete": False,
            "category": "safe",
            "reason": "",
            "confidence": 0.0,
            "checks": 0,
            "checkedUrls": [],
            "linkChecks": [],
        }

    result = _safe_browsing_check_urls(urls)
    matches = result.get("matches") if isinstance(result.get("matches"), list) else []
    checked_urls = result.get("checkedUrls") if isinstance(result.get("checkedUrls"), list) else urls

    if result.get("safe") is not True:
        if matches:
            threat_types = sorted({str(m.get("threatType") or "") for m in matches if isinstance(m, dict)})
            categories = ", ".join([t for t in threat_types if t]) or "unsafe_link"
            first_url = ""
            for m in matches:
                if isinstance(m, dict):
                    first_url = str((m.get("threat") or {}).get("url") or "")
                    if first_url:
                        break
            return {
                "shouldDelete": True,
                "category": "unsafe_link",
                "reason": f"تم حذف المنشور لأن الرابط مشبوه أو خطير حسب Google Safe Browsing: {categories}",
                "confidence": 1.0,
                "checks": len(checked_urls),
                "checkedUrls": checked_urls,
                "linkChecks": matches,
                "unsafeUrl": first_url,
            }

        return {
            "shouldDelete": True,
            "category": str(result.get("category") or "unsafe_link"),
            "reason": str(result.get("reason") or "تم رفض المنشور لأن الرابط غير آمن أو تعذر فحصه."),
            "confidence": 1.0,
            "checks": len(checked_urls),
            "checkedUrls": checked_urls,
            "linkChecks": [],
        }

    return {
        "shouldDelete": False,
        "category": "safe",
        "reason": "",
        "confidence": 0.0,
        "checks": len(checked_urls),
        "checkedUrls": checked_urls,
        "linkChecks": [],
    }




def _host_from_url(url: str) -> str:
    try:
        from urllib.parse import urlparse
        host = (urlparse(str(url or "").strip()).netloc or "").lower()
        if host.startswith("www."):
            host = host[4:]
        # حذف البورت إن وجد.
        if ":" in host:
            host = host.split(":", 1)[0]
        return host
    except Exception:
        return ""


def _is_ip_host(host: str) -> bool:
    if not host:
        return False
    return bool(re.fullmatch(r"\d{1,3}(?:\.\d{1,3}){3}", host))


def _is_suspicious_url_for_virustotal(url: str) -> bool:
    """
    نستخدم VirusTotal للروابط التي شكلها مشبوه فقط حتى لا نستهلك الحد المجاني.
    Safe Browsing يبقى الطبقة الأولى لكل الروابط.
    """
    u = str(url or "").strip().lower()
    host = _host_from_url(u)
    if not u or not host:
        return False

    suspicious_shorteners = {
        "bit.ly", "tinyurl.com", "t.co", "goo.gl", "ow.ly", "is.gd", "buff.ly",
        "cutt.ly", "rebrand.ly", "s.id", "shorturl.at", "rb.gy", "lnkd.in",
        "dub.sh", "soo.gd", "shorte.st", "adf.ly", "bc.vc", "bitly.com",
        "qrco.de", "cutt.us", "v.gd", "x.gd", "t.ly", "urlz.fr"
    }
    if host in suspicious_shorteners:
        return True

    # روابط بصيغة user@host أو محاولات إخفاء الدومين.
    if "@" in u:
        return True

    if _is_ip_host(host):
        return True

    # IDN/punycode كثير الاستخدام في الخداع البصري.
    if "xn--" in host:
        return True

    # دومينات طويلة جدًا أو مليانة شرطات/أرقام.
    if len(host) > 45 or host.count("-") >= 3:
        return True

    digits = sum(ch.isdigit() for ch in host)
    letters = sum(ch.isalpha() for ch in host)
    if letters > 0 and digits / max(letters, 1) > 0.45:
        return True

    risky_words = {
        "login", "verify", "account", "password", "wallet", "airdrop", "bonus",
        "free", "gift", "security", "support", "bank", "paypal", "crypto",
        "claim", "prize", "winner", "download", "update", "confirm", "unlock"
    }
    if any(word in u for word in risky_words):
        return True

    risky_tlds = {".zip", ".mov", ".top", ".xyz", ".click", ".icu", ".cyou", ".tk", ".ml", ".ga", ".cf", ".gq"}
    if any(host.endswith(tld) for tld in risky_tlds):
        return True

    return False


def _virustotal_scan_url(url: str) -> Dict[str, Any]:
    if not VIRUSTOTAL_API_KEY:
        return {
            "ok": False,
            "safe": True,
            "category": "virustotal_missing_key",
            "reason": "VIRUSTOTAL_API_KEY غير موجود، تم السماح بالرابط مؤقتًا وعدم حذف المنشور لأن Google Safe Browsing لم يجد خطرًا.",
        }

    try:
        submit = requests.post(
            f"{VIRUSTOTAL_BASE_URL}/urls",
            headers={
                "x-apikey": VIRUSTOTAL_API_KEY,
                "Content-Type": "application/x-www-form-urlencoded",
            },
            data={"url": url},
            timeout=15,
        )

        logger.info("VirusTotal submit status=%s", submit.status_code)
        logger.debug("VirusTotal submit url=%s body=%s", url[:120], _safe_response_text(submit.text, 500))

        # 429 يعني الحد المجاني انتهى. لا نحذف المنشور بسبب عطل/حد خارجي فقط.
        if submit.status_code == 429:
            return {
                "ok": False,
                "safe": True,
                "category": "virustotal_rate_limited",
                "reason": "VirusTotal وصل لحد الطلبات الحالي، تم السماح بالرابط مؤقتًا لأن Google Safe Browsing لم يجد خطرًا.",
            }

        if submit.status_code >= 400:
            return {
                "ok": False,
                "safe": True,
                "category": "virustotal_error",
                "reason": f"فشل إرسال الرابط إلى VirusTotal: {submit.status_code} {submit.text[:300]}، تم السماح مؤقتًا لأن Google Safe Browsing لم يجد خطرًا.",
            }

        analysis_id = str((submit.json().get("data") or {}).get("id") or "").strip()
        if not analysis_id:
            return {
                "ok": False,
                "safe": True,
                "category": "virustotal_no_analysis_id",
                "reason": "VirusTotal لم يرجع analysis_id، تم السماح بالرابط مؤقتًا لأن Google Safe Browsing لم يجد خطرًا.",
            }

        import time
        last_data: Dict[str, Any] = {}
        for _ in range(4):
            time.sleep(2)
            report = requests.get(
                f"{VIRUSTOTAL_BASE_URL}/analyses/{analysis_id}",
                headers={"x-apikey": VIRUSTOTAL_API_KEY},
                timeout=15,
            )

            logger.info("VirusTotal report analysis_id=%s status=%s", analysis_id, report.status_code)
            logger.debug("VirusTotal report body=%s", _safe_response_text(report.text, 500))

            if report.status_code == 429:
                return {
                    "ok": False,
                    "safe": True,
                    "category": "virustotal_rate_limited",
                    "reason": "VirusTotal وصل لحد الطلبات الحالي، تم السماح بالرابط مؤقتًا لأن Google Safe Browsing لم يجد خطرًا.",
                    "analysisId": analysis_id,
                }

            if report.status_code >= 400:
                return {
                    "ok": False,
                    "safe": True,
                    "category": "virustotal_error",
                    "reason": f"فشل جلب تقرير VirusTotal: {report.status_code} {report.text[:300]}، تم السماح مؤقتًا لأن Google Safe Browsing لم يجد خطرًا.",
                    "analysisId": analysis_id,
                }

            last_data = report.json()
            attrs = (last_data.get("data") or {}).get("attributes") or {}
            status = str(attrs.get("status") or "")
            stats = attrs.get("stats") or {}

            malicious = int(stats.get("malicious", 0) or 0)
            suspicious = int(stats.get("suspicious", 0) or 0)
            harmless = int(stats.get("harmless", 0) or 0)
            undetected = int(stats.get("undetected", 0) or 0)

            # سياسة حذف قوية لكن ليست مبالغ فيها:
            # - malicious واحد يكفي للحذف.
            # - suspicious اثنين أو أكثر للحذف.
            if malicious >= 1 or suspicious >= 2:
                return {
                    "ok": True,
                    "safe": False,
                    "category": "virustotal_unsafe_link",
                    "reason": f"تم حذف المنشور لأن VirusTotal صنّف الرابط كمشبوه/خطر: malicious={malicious}, suspicious={suspicious}",
                    "stats": stats,
                    "analysisId": analysis_id,
                }

            if status == "completed":
                return {
                    "ok": True,
                    "safe": True,
                    "category": "safe",
                    "reason": f"VirusTotal لم يجد خطر واضح: malicious={malicious}, suspicious={suspicious}, harmless={harmless}, undetected={undetected}",
                    "stats": stats,
                    "analysisId": analysis_id,
                }

        return {
            "ok": False,
            "safe": True,
            "category": "virustotal_timeout",
            "reason": "تحليل VirusTotal لم يكتمل في الوقت المحدد، تم السماح بالرابط مؤقتًا لأن Google Safe Browsing لم يجد خطرًا.",
            "raw": last_data,
            "analysisId": analysis_id,
        }

    except Exception as e:
        return {
            "ok": False,
            "safe": True,
            "category": "virustotal_exception",
            "reason": f"تعذر فحص الرابط عبر VirusTotal، تم السماح مؤقتًا لأن Google Safe Browsing لم يجد خطرًا: {e}",
        }


def moderate_suspicious_links_with_virustotal(req: RespectAIModerationRequest) -> Dict[str, Any]:
    text_parts = [
        str(req.text or ""),
        str(req.postText or ""),
        str(req.parentReplyText or ""),
        str(req.recentRepliesText or ""),
    ]
    urls = _extract_urls_from_text("\n".join(text_parts))
    suspicious_urls = [u for u in urls if _is_suspicious_url_for_virustotal(u)]

    if not suspicious_urls:
        return {
            "shouldDelete": False,
            "category": "safe",
            "reason": "لا توجد روابط مشبوهة تحتاج فحص VirusTotal",
            "confidence": 0.0,
            "checks": 0,
            "checkedUrls": [],
            "virusTotalChecks": [],
            "virusTotalChecked": False,
        }

    results: list[Dict[str, Any]] = []
    # نفحص أول 3 روابط مشبوهة فقط لتقليل الاستهلاك.
    for url in suspicious_urls[:3]:
        result = _virustotal_scan_url(url)
        result["url"] = url
        results.append(result)

        # لا نحذف بسبب timeout أو rate limit أو أي عطل في VirusTotal.
        # الحذف يكون فقط إذا رجع VirusTotal نتيجة خطرة واضحة.
        if result.get("safe") is not True and str(result.get("category") or "") == "virustotal_unsafe_link":
            return {
                "shouldDelete": True,
                "category": str(result.get("category") or "virustotal_unsafe_link"),
                "reason": str(result.get("reason") or "تم حذف المنشور لأن الرابط مشبوه حسب VirusTotal."),
                "confidence": 1.0,
                "checks": len(results),
                "checkedUrls": suspicious_urls[:3],
                "virusTotalChecks": results,
                "virusTotalChecked": True,
                "unsafeUrl": url,
            }

    return {
        "shouldDelete": False,
        "category": "safe",
        "reason": "VirusTotal فحص الروابط المشبوهة ولم يجد خطرًا واضحًا",
        "confidence": 0.0,
        "checks": len(results),
        "checkedUrls": suspicious_urls[:3],
        "virusTotalChecks": results,
        "virusTotalChecked": True,
    }

def _combine_text_image_video_moderation(
    text_result: Dict[str, Any],
    image_result: Dict[str, Any],
    video_result: Dict[str, Any],
    link_result: Dict[str, Any],
    virustotal_result: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    text_delete = bool(
        text_result.get("shouldDelete") is True
        or text_result.get("delete") is True
        or text_result.get("blocked") is True
    )
    image_delete = bool(
        image_result.get("shouldDelete") is True
        or image_result.get("delete") is True
        or image_result.get("blocked") is True
    )
    video_delete = bool(
        video_result.get("shouldDelete") is True
        or video_result.get("delete") is True
        or video_result.get("blocked") is True
    )
    link_delete = bool(
        link_result.get("shouldDelete") is True
        or link_result.get("delete") is True
        or link_result.get("blocked") is True
    )
    vt = virustotal_result or {}
    vt_delete = bool(
        vt.get("shouldDelete") is True
        or vt.get("delete") is True
        or vt.get("blocked") is True
    )

    if link_delete:
        return {
            **link_result,
            "shouldDelete": True,
            "category": str(link_result.get("category") or "unsafe_link"),
            "reason": str(link_result.get("reason") or "الرابط غير آمن"),
            "decisionSource": "google-safe-browsing",
            "virusTotalModeration": vt,
            "textModeration": text_result,
            "imageModeration": image_result,
            "videoModeration": video_result,
            "linkModeration": link_result,
        }

    if vt_delete:
        return {
            **vt,
            "shouldDelete": True,
            "category": str(vt.get("category") or "virustotal_unsafe_link"),
            "reason": str(vt.get("reason") or "الرابط مشبوه حسب VirusTotal"),
            "decisionSource": "virustotal",
            "textModeration": text_result,
            "imageModeration": image_result,
            "videoModeration": video_result,
            "linkModeration": link_result,
            "virusTotalModeration": vt,
        }

    if text_delete:
        return {
            **text_result,
            "shouldDelete": True,
            "category": str(text_result.get("category") or "text_violation"),
            "reason": str(text_result.get("reason") or "النص مخالف"),
            "decisionSource": "qwen-plus",
            "textModeration": text_result,
            "imageModeration": image_result,
            "videoModeration": video_result,
            "linkModeration": link_result,
            "virusTotalModeration": vt,
        }

    if image_delete:
        return {
            **image_result,
            "shouldDelete": True,
            "category": str(image_result.get("category") or "image_violation"),
            "reason": str(image_result.get("reason") or "الصورة مخالفة"),
            "decisionSource": "qwen-vl-plus-image",
            "textModeration": text_result,
            "imageModeration": image_result,
            "videoModeration": video_result,
            "linkModeration": link_result,
            "virusTotalModeration": vt,
        }

    if video_delete:
        return {
            **video_result,
            "shouldDelete": True,
            "category": str(video_result.get("category") or "video_violation"),
            "reason": str(video_result.get("reason") or "الفيديو مخالف"),
            "decisionSource": "qwen-vl-plus-video",
            "textModeration": text_result,
            "imageModeration": image_result,
            "videoModeration": video_result,
            "linkModeration": link_result,
            "virusTotalModeration": vt,
        }

    return {
        "shouldDelete": False,
        "deleteParentReply": False,
        "category": "safe",
        "reason": "النص والصور والفيديوهات والروابط آمنة",
        "confidence": max(
            float(text_result.get("confidence") or 0.0),
            float(image_result.get("confidence") or 0.0),
            float(video_result.get("confidence") or 0.0),
            float(link_result.get("confidence") or 0.0),
            float(vt.get("confidence") or 0.0),
        ),
        "decisionSource": "combined",
        "textModeration": text_result,
        "imageModeration": image_result,
        "videoModeration": video_result,
        "linkModeration": link_result,
        "virusTotalModeration": vt,
    }


@app.post("/respect-ai/review-report")
def respect_ai_review_report(req: RespectAIModerationRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_secret(x_app_secret)

    report_reason = (req.reason or "").strip()
    report_details = (req.details or "").strip()
    post_text = (req.postText or req.text or "").strip()
    reported = _display_username(req.reportedUsername or req.username)

    prompt = f"""
أنت نظام مراجعة بلاغات داخل Respect App.
مهم جدًا: لا تعتبر البلاغ صحيحًا إلا إذا الدليل واضح من نص المنشور والبلاغ.
إذا البلاغ عن سرقة محتوى ولا يوجد نص كافٍ للمقارنة أو رابط/اسم صاحب المحتوى الأصلي، اعتبره يحتاج مراجعة بشرية ولا تحذف.
أعد JSON فقط بدون شرح خارج JSON:
{{"validReport": true/false, "action": "none|hide|delete", "category": "copyright|abuse|spam|misleading|other|insufficient_evidence", "confidence": 0.0-1.0, "reason": "سبب قصير بالعربية"}}

سبب البلاغ: {report_reason}
تفاصيل البلاغ: {report_details}
نص التغريدة المبلغ عنها: {post_text}
المستخدم المبلغ عنه: {reported}
المجتمع: {req.communityName}
""".strip()

    result: Dict[str, Any] = {
        "validReport": False,
        "action": "none",
        "category": "insufficient_evidence",
        "confidence": 0.0,
        "reason": "لم توجد أدلة كافية لتأكيد البلاغ تلقائيًا",
    }

    if QWEN_API_KEY and post_text:
        try:
            content = _chat_completion_request(
                model=QWEN_TEXT_MODEL,
                api_key=QWEN_API_KEY,
                base_url=QWEN_BASE_URL,
                messages=[
                    {"role": "system", "content": "أنت مراجع بلاغات صارم. أعد JSON صحيح فقط."},
                    {"role": "user", "content": prompt},
                ],
                temperature=0.05,
                max_tokens=450,
                timeout=45,
                log_label="REPORT_REVIEW",
            )
            m = re.search(r"\{.*\}", content, re.S)
            if m:
                parsed = json.loads(m.group(0))
                if isinstance(parsed, dict):
                    result.update(parsed)
        except Exception as e:
            result["reason"] = f"تعذرت مراجعة البلاغ تلقائيًا: {e}"

    confidence = float(result.get("confidence") or 0.0)
    valid = bool(result.get("validReport") is True) and confidence >= 0.88
    action = str(result.get("action") or "none")
    should_hide = valid and action in {"hide", "delete"}

    update_result: Dict[str, Any] = {"updated": False}
    warning_result: Dict[str, Any] = {"warningCount": 0, "blocked": False}
    learn_result: Dict[str, Any] = {"learned": False, "terms": []}
    if should_hide:
        # أهم تعديل: أي بلاغ صحيح تسبب بحذف التغريدة يعلّم Respect AI العبارة المخالفة.
        learn_result = _learn_abuse_terms_from_valid_report(req, result)

        # داخل المجتمع نخفي، وخارج المجتمع نحذف إذا action=delete.
        if req.communityId:
            update_result = _patch_supabase_post(req.postId, {"community_hidden": True, "hidden_reason": str(result.get("reason") or "")})
        else:
            try:
                update_result = _delete_supabase_post(req.postId)
            except Exception as e:
                update_result = {"deleted": False, "error": str(e)}
        warning_result = _insert_user_warning(reported, str(result.get("reason") or report_reason), req.postId, req.reportId)

    return {
        "ok": True,
        "reportId": req.reportId,
        "postId": req.postId,
        "validReport": valid,
        "shouldDelete": should_hide,
        "action": "hide" if should_hide and req.communityId else ("delete" if should_hide else "none"),
        "category": str(result.get("category") or "other"),
        "confidence": confidence,
        "reason": str(result.get("reason") or ""),
        "postUpdate": update_result,
        "learnResult": learn_result,
        "learnedTerms": learn_result.get("terms", []),
        "warning": warning_result,
    }

@app.post("/respect-ai/moderate-story")
def respect_ai_moderate_story(req: RespectAIModerationRequest, request: FastAPIRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_secret(x_app_secret)
    _enforce_moderation_rate(_client_ip(request))

    # ستوري
    # ├── qwen-plus للنص إن وجد
    # ├── qwen-vl-plus للصورة وقراءة النص الظاهر على الشاشة OCR
    # ├── qwen-vl-plus للفيديو عبر استخراج Frames وقراءة النص الظاهر
    # ├── Google Safe Browsing للروابط إن وجد نص
    # └── القرار النهائي: حذف الستوري فورًا إذا أي طبقة رجعت مخالفة.
    link_result = moderate_links_with_safe_browsing(req)
    virustotal_result = {
        "shouldDelete": False,
        "category": "safe",
        "reason": "لم يتم تشغيل VirusTotal لأن Google Safe Browsing حذف الرابط أو لا توجد روابط مشبوهة",
        "confidence": 0.0,
        "checks": 0,
        "virusTotalChecked": False,
    }
    if link_result.get("shouldDelete") is not True:
        virustotal_result = moderate_suspicious_links_with_virustotal(req)

    text_result = moderate_with_qwen(req)
    image_result = moderate_images_with_qwen(req)
    video_result = moderate_videos_with_qwen(req)
    result = _combine_text_image_video_moderation(text_result, image_result, video_result, link_result, virustotal_result)

    should_delete = bool(
        result.get("shouldDelete") is True
        or result.get("delete") is True
        or result.get("blocked") is True
    )

    story_id = (req.postId or req.replyId or "").strip()
    delete_result: Dict[str, Any] = {"deleted": False}
    if should_delete:
        delete_result = _delete_supabase_story(story_id)

    return {
        "ok": True,
        "storyId": story_id,
        "shouldDelete": should_delete,
        "deleted": bool(delete_result.get("deleted")),
        "deleteResult": delete_result,
        "reason": str(result.get("reason") or ""),
        "category": str(result.get("category") or "safe"),
        "confidence": float(result.get("confidence") or 0.0),
        "decisionSource": str(result.get("decisionSource") or "combined"),
        "textModeration": result.get("textModeration", text_result),
        "imageModeration": result.get("imageModeration", image_result),
        "videoModeration": result.get("videoModeration", video_result),
        "linkModeration": result.get("linkModeration", link_result),
        "virusTotalModeration": result.get("virusTotalModeration", virustotal_result),
        "model": QWEN_TEXT_MODEL,
        "textModel": QWEN_TEXT_MODEL,
        "visionModel": QWEN_VISION_MODEL,
        "provider": "local-guard+qwen+safe-browsing+virustotal",
        "serverSideDelete": True,
    }


@app.post("/respect-ai/moderate-post")
def respect_ai_moderate_post(req: RespectAIModerationRequest, request: FastAPIRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_secret(x_app_secret)
    _enforce_moderation_rate(_client_ip(request))

    # طبقة تعلم البلاغات: تفحص القاموس المتعلم قبل Qwen، حتى يكون الحذف فوريًا ومتسقًا.
    learned_result = _learned_abuse_violation_guard(req.text or req.postText or "")
    if learned_result is not None and learned_result.get("shouldDelete") is True:
        delete_result: Dict[str, Any] = {"deleted": False}
        if (req.postId or "").strip():
            delete_result = _delete_supabase_post(req.postId)
        return {
            "ok": True,
            "postId": req.postId,
            "shouldDelete": True,
            "deleted": bool(delete_result.get("deleted")),
            "deleteResult": delete_result,
            "reason": str(learned_result.get("reason") or "عبارة مخالفة متعلمة من بلاغ صحيح سابق"),
            "category": str(learned_result.get("category") or "learned_abuse"),
            "confidence": float(learned_result.get("confidence") or 0.99),
            "decisionSource": "learned_report_dictionary",
            "textModeration": learned_result,
            "imageModeration": {"shouldDelete": False, "category": "skipped", "reason": "تم الحذف من طبقة التعلم النصية"},
            "videoModeration": {"shouldDelete": False, "category": "skipped", "reason": "تم الحذف من طبقة التعلم النصية"},
            "linkModeration": {"shouldDelete": False, "category": "skipped", "reason": "تم الحذف من طبقة التعلم النصية"},
            "virusTotalModeration": {"shouldDelete": False, "category": "skipped", "reason": "تم الحذف من طبقة التعلم النصية"},
            "learnedMatch": True,
            "matchedTerm": str(learned_result.get("matchedTerm") or ""),
            "model": "learned_dictionary",
            "textModel": QWEN_TEXT_MODEL,
            "visionModel": QWEN_VISION_MODEL,
        }

    # المسار الجديد:
    # منشور
    # ├── qwen-plus للنص
    # ├── qwen-vl-plus للصور
    # ├── qwen-vl-plus للفيديو عبر استخراج Frames
    # ├── Google Safe Browsing للروابط
    # ├── VirusTotal للروابط المشبوهة فقط كطبقة ثانية
    # └── القرار النهائي: حذف إذا النص أو أي صورة أو أي لقطة فيديو أو رابط مخالف.
    link_result = moderate_links_with_safe_browsing(req)
    virustotal_result = {
        "shouldDelete": False,
        "category": "safe",
        "reason": "لم يتم تشغيل VirusTotal لأن Google Safe Browsing حذف الرابط أو لا توجد روابط مشبوهة",
        "confidence": 0.0,
        "checks": 0,
        "virusTotalChecked": False,
    }
    if link_result.get("shouldDelete") is not True:
        virustotal_result = moderate_suspicious_links_with_virustotal(req)

    text_result = moderate_with_qwen(req)
    image_result = moderate_images_with_qwen(req)
    video_result = moderate_videos_with_qwen(req)
    result = _combine_text_image_video_moderation(text_result, image_result, video_result, link_result, virustotal_result)

    should_delete = bool(
        result.get("shouldDelete") is True
        or result.get("delete") is True
        or result.get("blocked") is True
    )

    delete_result: Dict[str, Any] = {"deleted": False}
    if should_delete:
        delete_result = _delete_supabase_post(req.postId)

    return {
        "ok": True,
        "postId": req.postId,
        "shouldDelete": should_delete,
        "deleted": bool(delete_result.get("deleted")),
        "deleteResult": delete_result,
        "reason": str(result.get("reason") or ""),
        "category": str(result.get("category") or "safe"),
        "confidence": float(result.get("confidence") or 0.0),
        "decisionSource": str(result.get("decisionSource") or "combined"),
        "textModeration": result.get("textModeration", text_result),
        "imageModeration": result.get("imageModeration", image_result),
        "videoModeration": result.get("videoModeration", video_result),
        "linkModeration": result.get("linkModeration", link_result),
        "virusTotalModeration": result.get("virusTotalModeration", virustotal_result),
        "model": QWEN_TEXT_MODEL,
        "textModel": QWEN_TEXT_MODEL,
        "visionModel": QWEN_VISION_MODEL,
        "provider": "local-guard+qwen+safe-browsing+virustotal",
        "serverSideDelete": True,
    }


class RespectAIArtTournamentRequest(BaseModel):
    weekKey: str = ""


def _art_week_key() -> str:
    from datetime import datetime, timezone
    now = datetime.now(timezone.utc)
    iso = now.isocalendar()
    return f"{iso.year}-W{str(iso.week).zfill(2)}"


def _supabase_rest_select(table: str, params: Dict[str, str], limit: int = 300) -> list[Dict[str, Any]]:
    headers = _supabase_headers(use_service_role=True)
    q = dict(params or {})
    if limit:
        q["limit"] = str(limit)
    r = requests.get(
        f"{SB_URL}/rest/v1/{table}",
        headers=headers,
        params=q,
        timeout=20,
    )
    if r.status_code >= 400:
        raise HTTPException(status_code=500, detail={"supabase_status": r.status_code, "supabase_body": r.text[:1000]})
    data = r.json()
    return data if isinstance(data, list) else []


def _supabase_rest_insert(table: str, payload: Dict[str, Any]) -> Dict[str, Any]:
    headers = {**_supabase_headers(use_service_role=True), "Prefer": "return=representation"}
    r = requests.post(
        f"{SB_URL}/rest/v1/{table}",
        headers=headers,
        json=payload,
        timeout=20,
    )
    if r.status_code >= 400:
        raise HTTPException(status_code=500, detail={"supabase_status": r.status_code, "supabase_body": r.text[:1000], "table": table})
    data = r.json()
    if isinstance(data, list) and data:
        return dict(data[0])
    return {}


def _supabase_rest_patch(table: str, eq_id: str, payload: Dict[str, Any]) -> Dict[str, Any]:
    headers = {**_supabase_headers(use_service_role=True), "Prefer": "return=representation"}
    r = requests.patch(
        f"{SB_URL}/rest/v1/{table}",
        headers=headers,
        params={"id": f"eq.{eq_id}"},
        json=payload,
        timeout=20,
    )
    if r.status_code >= 400:
        logger.warning("Supabase patch %s failed status=%s body=%s", table, r.status_code, _safe_response_text(r.text, 500))
        return {"updated": False, "status": r.status_code, "body": r.text[:800]}
    data = r.json()
    return dict(data[0]) if isinstance(data, list) and data else {"updated": True}


def _supabase_rest_delete_where(table: str, params: Dict[str, str]) -> Dict[str, Any]:
    headers = {**_supabase_headers(use_service_role=True), "Prefer": "return=representation"}
    r = requests.delete(
        f"{SB_URL}/rest/v1/{table}",
        headers=headers,
        params=params,
        timeout=20,
    )
    if r.status_code >= 400:
        logger.warning("Supabase delete %s failed status=%s body=%s", table, r.status_code, _safe_response_text(r.text, 500))
        return {"deleted": False, "status": r.status_code, "body": r.text[:800]}
    return {"deleted": True}


def _art_json_from_qwen(messages: list, *, max_tokens: int = 700, label: str = "ART") -> Dict[str, Any]:
    if not QWEN_API_KEY:
        raise HTTPException(status_code=500, detail="QWEN_API_KEY missing")
    content = _chat_completion_request(
        model=QWEN_VISION_MODEL,
        api_key=QWEN_API_KEY,
        base_url=QWEN_BASE_URL,
        messages=messages,
        temperature=0.05,
        max_tokens=max_tokens,
        timeout=70,
        response_format=None,
        log_label=label,
    )
    parsed = _safe_json_from_ai(str(content))
    if not parsed:
        m = re.search(r"\{.*\}", str(content), re.S)
        if m:
            try:
                parsed = json.loads(m.group(0))
            except Exception:
                parsed = {}
    return parsed if isinstance(parsed, dict) else {}


@app.post("/respect-ai/art/validate")
def respect_ai_validate_art(req: RespectAIModerationRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_secret(x_app_secret)
    image_url = (req.imageUrl or "").strip()
    if not image_url and req.imageUrls:
        image_url = str(req.imageUrls[0] or "").strip()
    if not image_url.startswith(("http://", "https://")):
        raise HTTPException(status_code=400, detail="imageUrl is required")

    prompt = """
أنت حكم في بطولة رسامين ريسبكت.
المطلوب: هل الصورة رسمة فعلية من مستخدم وليست صورة عادية، وليست تصميم/رندر واضح من الذكاء الاصطناعي؟
اقبل الرسم الرقمي أو اليدوي إذا واضح أنه عمل رسام، وارفض الصور الفوتوغرافية، السكرينشوت، الشعارات الجاهزة، الرندر ثلاثي الأبعاد، أو صور AI الواضحة.
أعد JSON فقط:
{"accepted": true/false, "isRealDrawing": true/false, "isAiGenerated": true/false, "confidence": 0.0-1.0, "reason": "سبب قصير بالعربية", "style": "وصف أسلوب الرسم"}
""".strip()

    try:
        parsed = _art_json_from_qwen(
            [
                {"role": "system", "content": "أنت ناقد فني صارم. أعد JSON صحيح فقط."},
                {"role": "user", "content": [
                    {"type": "image_url", "image_url": {"url": image_url}},
                    {"type": "text", "text": f"{prompt}\nعنوان/وصف المستخدم:\n{(req.text or '').strip()[:500]}"},
                ]},
            ],
            max_tokens=450,
            label="ART VALIDATION",
        )
    except Exception as e:
        return {"ok": False, "accepted": False, "isRealDrawing": False, "isAiGenerated": False, "confidence": 1.0, "reason": f"تعذر فحص الرسمة: {e}", "imageUrl": image_url}

    accepted = bool(parsed.get("accepted") is True and parsed.get("isRealDrawing") is True and parsed.get("isAiGenerated") is not True)
    confidence = float(parsed.get("confidence") or 0.0)
    if confidence < 0.55:
        accepted = False
    return {
        "ok": True,
        "accepted": accepted,
        "isRealDrawing": bool(parsed.get("isRealDrawing") is True),
        "isAiGenerated": bool(parsed.get("isAiGenerated") is True),
        "confidence": confidence,
        "reason": str(parsed.get("reason") or ("تم قبول الرسمة" if accepted else "لم يظهر أنها رسمة أصلية بوضوح")),
        "style": str(parsed.get("style") or ""),
        "imageUrl": image_url,
        "visionModel": QWEN_VISION_MODEL,
    }


def _art_compare_pair(a: Dict[str, Any], b: Dict[str, Any], round_number: int) -> Dict[str, Any]:
    a_title = str(a.get("title") or "الرسمة الأولى")
    b_title = str(b.get("title") or "الرسمة الثانية")
    prompt = f"""
أنت حكم فني في بطولة أسبوعية اسمها رسامين ريسبكت.
قارن بين الرسمتين بعدل. ركز على: الفكرة، التكوين، التلوين، التفاصيل، الإحساس، الأصالة، وضوح الأسلوب.
لا تجامل. اذكر مميزات وعيوب كل رسمة، ثم اختر فائزًا واحدًا فقط.
أعد JSON فقط:
{{
  "winner": "A" أو "B",
  "drawingAPros": "مميزات الرسمة الأولى",
  "drawingACons": "عيوب الرسمة الأولى",
  "drawingBPros": "مميزات الرسمة الثانية",
  "drawingBCons": "عيوب الرسمة الثانية",
  "analysisSummary": "ملخص قصير للمواجهة",
  "scoreA": 0-100,
  "scoreB": 0-100,
  "reason": "سبب اختيار الفائز"
}}
الجولة: {round_number}
عنوان الأولى: {a_title}
وصف الأولى: {str(a.get('description') or '')[:400]}
عنوان الثانية: {b_title}
وصف الثانية: {str(b.get('description') or '')[:400]}
""".strip()
    parsed = _art_json_from_qwen(
        [
            {"role": "system", "content": "أنت ناقد فني وحكم مسابقات رسم. أعد JSON صحيح فقط."},
            {"role": "user", "content": [
                {"type": "image_url", "image_url": {"url": str(a.get("image_url") or "")}},
                {"type": "image_url", "image_url": {"url": str(b.get("image_url") or "")}},
                {"type": "text", "text": prompt},
            ]},
        ],
        max_tokens=900,
        label=f"ART MATCH R{round_number}",
    )
    winner = str(parsed.get("winner") or "A").upper().strip()
    if winner not in {"A", "B"}:
        score_a = float(parsed.get("scoreA") or 0)
        score_b = float(parsed.get("scoreB") or 0)
        winner = "A" if score_a >= score_b else "B"
    return {
        "winner": winner,
        "drawingAPros": str(parsed.get("drawingAPros") or ""),
        "drawingACons": str(parsed.get("drawingACons") or ""),
        "drawingBPros": str(parsed.get("drawingBPros") or ""),
        "drawingBCons": str(parsed.get("drawingBCons") or ""),
        "analysisSummary": str(parsed.get("analysisSummary") or parsed.get("reason") or ""),
        "scoreA": float(parsed.get("scoreA") or 0),
        "scoreB": float(parsed.get("scoreB") or 0),
        "reason": str(parsed.get("reason") or ""),
    }


@app.post("/respect-ai/art/run-weekly-tournament")
def respect_ai_run_weekly_art_tournament(req: RespectAIArtTournamentRequest, x_app_secret: Optional[str] = Header(default=None)):
    from datetime import datetime, timezone
    _check_secret(x_app_secret)
    week = (req.weekKey or "").strip() or _art_week_key()

    drawings = _supabase_rest_select(
        "respect_art_drawings",
        {"week" + "_" + "key": f"eq.{week}", "status": "eq.approved", "order": "created_at.asc"},
        limit=256,
    )
    if len(drawings) < 2:
        return {"ok": False, "weekKey": week, "reason": "لا توجد رسمات كافية لتشغيل التصفيات", "count": len(drawings)}

    _supabase_rest_delete_where("respect_art_matches", {"week" + "_" + "key": f"eq.{week}"})
    for d in drawings:
        _supabase_rest_patch("respect_art_drawings", str(d.get("id")), {"rank": None, "score": 0})

    active = list(drawings)
    eliminated: list[Dict[str, Any]] = []
    round_number = 1
    match_number = 1

    while len(active) > 1:
        next_round: list[Dict[str, Any]] = []
        i = 0
        while i < len(active):
            a = active[i]
            b = active[i + 1] if i + 1 < len(active) else None
            if b is None:
                next_round.append(a)
                i += 1
                continue

            match_payload = {
                "week" + "_" + "key": week,
                "round_number": round_number,
                "match_number": match_number,
                "drawing_a_id": a.get("id"),
                "drawing_b_id": b.get("id"),
                "drawing_a_title": str(a.get("title") or ""),
                "drawing_b_title": str(b.get("title") or ""),
                "status": "analyzing",
                "created_at": datetime.now(timezone.utc).isoformat(),
            }
            match_row = _supabase_rest_insert("respect_art_matches", match_payload)

            try:
                result = _art_compare_pair(a, b, round_number)
            except Exception as e:
                result = {
                    "winner": "A",
                    "drawingAPros": "تعذر التحليل التفصيلي، تم اختيار الرسمة الأولى احتياطيًا.",
                    "drawingACons": "",
                    "drawingBPros": "",
                    "drawingBCons": "",
                    "analysisSummary": f"تعذر تحليل المواجهة تلقائيًا: {e}",
                    "scoreA": 50,
                    "scoreB": 49,
                    "reason": "fallback",
                }

            winner_row = a if result["winner"] == "A" else b
            loser_row = b if result["winner"] == "A" else a
            eliminated.append(loser_row)
            next_round.append(winner_row)

            _supabase_rest_patch("respect_art_matches", str(match_row.get("id")), {
                "status": "done",
                "winner_drawing_id": winner_row.get("id"),
                "winner_title": str(winner_row.get("title") or ""),
                "drawing_a_pros": result["drawingAPros"],
                "drawing_a_cons": result["drawingACons"],
                "drawing_b_pros": result["drawingBPros"],
                "drawing_b_cons": result["drawingBCons"],
                "analysis_summary": result["analysisSummary"],
                "score_a": result["scoreA"],
                "score_b": result["scoreB"],
                "reason": result["reason"],
                "completed_at": datetime.now(timezone.utc).isoformat(),
            })

            match_number += 1
            i += 2

        active = next_round
        round_number += 1

    champion = active[0]
    ranked = [champion] + list(reversed(eliminated))
    for rank, drawing in enumerate(ranked[:3], start=1):
        _supabase_rest_patch("respect_art_drawings", str(drawing.get("id")), {
            "rank": rank,
            "score": max(0, 100 - ((rank - 1) * 7)),
            "winner_locked_until": None,
        })

    return {
        "ok": True,
        "weekKey": week,
        "count": len(drawings),
        "winner": champion,
        "topThree": ranked[:3],
        "matches": match_number - 1,
        "visionModel": QWEN_VISION_MODEL,
    }



def _fallback_search_terms(query: str) -> list[str]:
    q = (query or "").strip().lower().replace("#", " ")
    q = re.sub(r"\s+", " ", q).strip()
    terms = {t for t in q.split(" ") if len(t) >= 2}
    if q:
        terms.add(q)
        terms.add(q.replace(" ", "_"))
    expansions = {
        "عصابه": ["عصابة", "قروب", "كلان", "مافيا", "gang", "clan"],
        "عصابة": ["عصابه", "قروب", "كلان", "مافيا", "gang", "clan"],
        "الكفن": ["كفن", "al kafan", "alkafan", "kafan"],
        "سيرفر": ["server", "rp", "رول بلاي", "رولبلاي"],
        "قراند": ["gta", "gta v", "grand", "قراند الحياة الواقعية"],
        "ريسبكت": ["respect", "respect rp", "respect server"],
    }
    for t in list(terms):
        for e in expansions.get(t, []):
            if len(e.strip()) >= 2:
                terms.add(e.strip().lower())
    return list(terms)[:24]


@app.post("/respect-ai/search-expand", response_model=RespectAISearchExpandResponse)
def respect_ai_search_expand(req: RespectAISearchExpandRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_secret(x_app_secret)
    query = (req.query or "").strip()
    if not query:
        return RespectAISearchExpandResponse(ok=True, query="", terms=[], model=QWEN_TEXT_MODEL)

    fallback = _fallback_search_terms(query)
    if not QWEN_API_KEY:
        return RespectAISearchExpandResponse(ok=True, query=query, terms=fallback, model="local-fallback")

    try:
        content = _chat_completion_request(
            model=QWEN_TEXT_MODEL,
            api_key=QWEN_API_KEY,
            base_url=QWEN_BASE_URL,
            messages=[
                {
                    "role": "system",
                    "content": (
                        "أنت محرك بحث ذكي لتطبيق اجتماعي عربي. "
                        "مهمتك توسيع عبارة البحث إلى كلمات قريبة ومرادفات وتهجئات مختلفة فقط. "
                        "لا تكتب شرحًا. أعد JSON فقط بهذا الشكل: {\"terms\":[\"...\"]}. "
                        "لا تضف كلمات خطيرة أو غير مرتبطة، ولا تتجاوز 18 كلمة."
                    ),
                },
                {
                    "role": "user",
                    "content": f"وسّع بحث المستخدم لهذه العبارة حتى نجد التغريدات المرتبطة بها داخل الفيد: {query}",
                },
            ],
            temperature=0.15,
            max_tokens=260,
            timeout=30,
            response_format={"type": "json_object"},
            log_label="QWEN_SEARCH",
        )
        parsed = json.loads(content)
        raw_terms = parsed.get("terms", []) if isinstance(parsed, dict) else []
        terms = []
        seen = set()
        for item in list(raw_terms) + fallback:
            t = re.sub(r"\s+", " ", str(item or "").strip().lower().replace("#", " "))
            if len(t) < 2 or len(t) > 48 or t in seen:
                continue
            seen.add(t)
            terms.append(t)
            if len(terms) >= 28:
                break
        return RespectAISearchExpandResponse(ok=True, query=query, terms=terms, model=QWEN_TEXT_MODEL)
    except Exception:
        return RespectAISearchExpandResponse(ok=True, query=query, terms=fallback, model="local-fallback")





# ================= Respect Cyber Admin Web Center =================
# صفحة ويب داخل نفس رابط /respect-ai/cyber، مع API إداري محمي بالـ X-App-Secret.
# ملاحظة مهمة: لا يتم إرسال Supabase service role key إلى المتصفح أبدًا.
# المتصفح يرسل فقط APP_SHARED_SECRET الذي يكتبه الأدمن، والسيرفر ينفذ العمليات الحساسة من الخلفية.

class CyberAdminListRequest(BaseModel):
    q: str = ""
    status: str = "all"
    limit: int = 30
    offset: int = 0


class CyberAdminUserActionRequest(BaseModel):
    username: str
    reason: str = "إجراء إداري من Respect Cyber Center"


class CyberAdminPostActionRequest(BaseModel):
    postId: str
    reason: str = "إجراء إداري من Respect Cyber Center"


class CyberAdminReviewReportRequest(BaseModel):
    reportId: str


def _check_cyber_admin_secret(x_app_secret: Optional[str]) -> None:
    # لوحة الأدمن أخطر من endpoints العادية، لذلك لا تعمل إذا لم تضبط السر في Render.
    if not APP_SHARED_SECRET:
        raise HTTPException(status_code=500, detail="APP_SHARED_SECRET غير مضبوط في Render. لا تفتح لوحة الأدمن قبل ضبطه.")
    _check_secret(x_app_secret)
    if not SB_SERVICE:
        raise HTTPException(status_code=500, detail="SUPABASE_SERVICE_ROLE_KEY غير مضبوط في Render. لوحة الأدمن تحتاجه لقراءة البلاغات وتنفيذ الحظر.")


def _cyber_limit(value: int, default: int = 30, maximum: int = 100) -> int:
    try:
        n = int(value)
    except Exception:
        n = default
    return max(1, min(n, maximum))


def _cyber_offset(value: int) -> int:
    try:
        n = int(value)
    except Exception:
        n = 0
    return max(0, n)


def _cyber_search_term(value: str) -> str:
    # PostgREST filter string لا يحب بعض الرموز داخل or/ilike؛ نترك الحروف والأرقام والمسافات والهاشتاق والمنشن.
    v = re.sub(r"[,(){}\\]", " ", str(value or "").strip())
    v = re.sub(r"\s+", " ", v).strip()
    return v[:80]


def _cyber_supabase_get(table: str, params: Dict[str, Any], timeout: int = 18) -> list[Dict[str, Any]]:
    r = requests.get(
        f"{SB_URL}/rest/v1/{table}",
        headers=_supabase_headers(use_service_role=True),
        params=params,
        timeout=timeout,
    )
    if r.status_code >= 400:
        raise HTTPException(status_code=500, detail=f"Supabase {table} read error {r.status_code}: {_safe_response_text(r.text, 800)}")
    try:
        data = r.json() if r.text else []
    except Exception:
        data = []
    if not isinstance(data, list):
        return []
    return [dict(x) for x in data if isinstance(x, dict)]


def _cyber_supabase_count(table: str, extra_params: Optional[Dict[str, Any]] = None) -> int:
    params = {"select": "id", "limit": "1"}
    if extra_params:
        params.update(extra_params)
    try:
        r = requests.get(
            f"{SB_URL}/rest/v1/{table}",
            headers={**_supabase_headers(use_service_role=True), "Prefer": "count=exact"},
            params=params,
            timeout=12,
        )
        if r.status_code >= 400:
            return 0
        cr = r.headers.get("content-range", "")
        if "/" in cr:
            tail = cr.split("/")[-1].strip()
            return int(tail) if tail.isdigit() else 0
        data = r.json() if r.text else []
        return len(data) if isinstance(data, list) else 0
    except Exception:
        return 0


def _cyber_patch_table(table: str, filters: Dict[str, Any], payload: Dict[str, Any]) -> Dict[str, Any]:
    r = requests.patch(
        f"{SB_URL}/rest/v1/{table}",
        headers={**_supabase_headers(use_service_role=True), "Prefer": "return=representation"},
        params=filters,
        json=payload,
        timeout=18,
    )
    if r.status_code >= 400:
        return {"ok": False, "status": r.status_code, "body": _safe_response_text(r.text, 800)}
    try:
        data = r.json() if r.text else []
    except Exception:
        data = []
    return {"ok": True, "rows": data if isinstance(data, list) else []}


def _cyber_scan_report() -> Dict[str, Any]:
    checks: list[Dict[str, Any]] = []

    def add(name: str, ok: bool, level: str, detail: str) -> None:
        checks.append({"name": name, "ok": bool(ok), "level": level, "detail": detail})

    add("APP_SHARED_SECRET", bool(APP_SHARED_SECRET), "high", "يحمي لوحة الأدمن وطلبات التطبيق الحساسة.")
    add("SUPABASE_SERVICE_ROLE_KEY", bool(SB_SERVICE), "high", "مطلوب للعمليات الإدارية من السيرفر فقط.")
    add("QWEN_API_KEY", bool(QWEN_API_KEY), "medium", "يشغل مراجعة المحتوى والبلاغات بالذكاء الاصطناعي.")
    add("HF_TOKEN", bool(HF_TOKEN), "medium", "يشغل Respect Cyber AI عبر Hugging Face Router.")
    add("Firebase Service Account", bool(SA_JSON or SA_FILE), "medium", "مطلوب لإرسال الإشعارات الخارجية FCM.")
    add("Google Safe Browsing", bool(GSB_TOKEN), "medium", "طبقة حماية الروابط داخل المنشورات.")
    add("VirusTotal", bool(VIRUSTOTAL_API_KEY), "low", "طبقة اختيارية إضافية للروابط المشبوهة.")
    add("Metered TURN", bool(METERED_API_KEY), "low", "يحسن ثبات المكالمات بين شبكات مختلفة.")
    add("Paddle Webhook Secret", bool(PADDLE_WEBHOOK_SECRET), "medium", "مهم للتحقق من اشتراكات التوثيق.")
    add("CORS", False, "medium", "الكود الحالي يسمح allow_origins=['*']; الأفضل تقييده بدومين التطبيق عند الإنتاج.")

    high_bad = sum(1 for c in checks if not c["ok"] and c["level"] == "high")
    med_bad = sum(1 for c in checks if not c["ok"] and c["level"] == "medium")
    low_bad = sum(1 for c in checks if not c["ok"] and c["level"] == "low")
    score = max(0, 100 - high_bad * 22 - med_bad * 10 - low_bad * 4)

    table_counts = {
        "users": _cyber_supabase_count("users") if SB_SERVICE else 0,
        "posts": _cyber_supabase_count("posts") if SB_SERVICE else 0,
        "pendingReports": _cyber_supabase_count("post_reports", {"status": "eq.pending"}) if SB_SERVICE else 0,
        "blockedUsers": _cyber_supabase_count("users", {"is_blocked": "eq.true"}) if SB_SERVICE else 0,
    }
    return {"ok": True, "score": score, "checks": checks, "counts": table_counts}


@app.get("/respect-ai/cyber", response_class=HTMLResponse)
def respect_ai_cyber_admin_page():
    return """
<!doctype html>
<html lang="ar" dir="rtl">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width,initial-scale=1" />
  <title>Respect Cyber Center</title>
  <style>
    :root{--bg:#090713;--panel:#131020;--panel2:#19142b;--line:rgba(255,255,255,.10);--txt:#f5f3ff;--muted:#b6aacd;--purple:#8b5cf6;--purple2:#a855f7;--danger:#fb7185;--ok:#34d399;--warn:#fbbf24;--blue:#60a5fa}
    *{box-sizing:border-box}body{margin:0;background:radial-gradient(circle at top right,#2b1458 0,#090713 35%,#05040a 100%);font-family:system-ui,-apple-system,"Segoe UI",Tahoma,Arial;color:var(--txt)}
    .app{display:grid;grid-template-columns:280px 1fr;min-height:100vh}.side{border-left:1px solid var(--line);background:rgba(10,8,18,.76);backdrop-filter:blur(20px);padding:20px;position:sticky;top:0;height:100vh}.brand{display:flex;gap:12px;align-items:center;margin-bottom:24px}.logo{width:46px;height:46px;border-radius:17px;background:linear-gradient(135deg,var(--purple),#ec4899);display:grid;place-items:center;font-weight:900;box-shadow:0 12px 40px rgba(139,92,246,.35)}h1{font-size:19px;margin:0}small{color:var(--muted)}.secret{margin:18px 0;padding:12px;border:1px solid var(--line);border-radius:18px;background:rgba(255,255,255,.04)}
    input,textarea,select{width:100%;border:1px solid var(--line);border-radius:14px;background:#0d0a17;color:var(--txt);padding:12px;outline:none}textarea{min-height:130px;resize:vertical}.nav button{width:100%;text-align:right;margin:6px 0;border:1px solid transparent;background:transparent;color:var(--muted);padding:13px;border-radius:15px;cursor:pointer;font-weight:800}.nav button.active,.nav button:hover{background:linear-gradient(135deg,rgba(139,92,246,.22),rgba(168,85,247,.12));color:#fff;border-color:rgba(139,92,246,.35)}
    .main{padding:26px}.top{display:flex;justify-content:space-between;gap:16px;align-items:center;margin-bottom:20px}.title{font-size:26px;font-weight:950}.grid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:14px}.card{background:linear-gradient(180deg,rgba(255,255,255,.08),rgba(255,255,255,.035));border:1px solid var(--line);border-radius:24px;padding:17px;box-shadow:0 18px 55px rgba(0,0,0,.28)}.card h3{margin:0 0 8px;font-size:14px;color:var(--muted)}.num{font-size:28px;font-weight:950}.section{display:none}.section.active{display:block}.row{display:flex;gap:10px;align-items:center}.row>*{flex:1}.btn{border:0;border-radius:14px;background:linear-gradient(135deg,var(--purple),var(--purple2));color:white;padding:12px 15px;font-weight:900;cursor:pointer}.btn.ghost{background:rgba(255,255,255,.07);border:1px solid var(--line)}.btn.danger{background:linear-gradient(135deg,#e11d48,#fb7185)}.btn.ok{background:linear-gradient(135deg,#059669,#34d399)}.btn.warn{background:linear-gradient(135deg,#d97706,#fbbf24);color:#1b1200}.btn:disabled{opacity:.55;cursor:not-allowed}.mt{margin-top:14px}.list{display:grid;gap:12px}.item{border:1px solid var(--line);background:rgba(7,6,12,.45);border-radius:18px;padding:14px}.item .meta{color:var(--muted);font-size:12px;margin-bottom:6px}.pill{display:inline-flex;gap:5px;align-items:center;padding:5px 9px;border-radius:999px;font-size:12px;font-weight:900;background:rgba(255,255,255,.08);border:1px solid var(--line);margin:3px}.pill.high{color:var(--danger)}.pill.medium{color:var(--warn)}.pill.low{color:var(--blue)}.pill.ok{color:var(--ok)}pre{white-space:pre-wrap;word-break:break-word;background:#07050d;border:1px solid var(--line);border-radius:16px;padding:14px;color:#e9ddff;max-height:520px;overflow:auto}.muted{color:var(--muted)}.split{display:grid;grid-template-columns:1fr 1fr;gap:14px}.searchbar{display:flex;gap:10px;margin-bottom:14px}.searchbar input{flex:1}.searchbar button{width:160px}.actions{display:flex;gap:8px;flex-wrap:wrap;margin-top:10px}.dangerText{color:var(--danger)}.okText{color:var(--ok)}.warnText{color:var(--warn)}
    @media(max-width:900px){.app{grid-template-columns:1fr}.side{height:auto;position:relative;border-left:0;border-bottom:1px solid var(--line)}.grid,.split{grid-template-columns:1fr}.top{align-items:stretch;flex-direction:column}.searchbar{flex-direction:column}.searchbar button{width:100%}}
  </style>
</head>
<body>
<div class="app">
  <aside class="side">
    <div class="brand"><div class="logo">RC</div><div><h1>Respect Cyber Center</h1><small>لوحة أدمن + ذكاء أمني</small></div></div>
    <div class="secret">
      <small>كلمة سر الأدمن APP_SHARED_SECRET</small>
      <input id="secret" type="password" placeholder="اكتب السر هنا" autocomplete="current-password" />
      <button class="btn mt" onclick="saveSecret()">حفظ السر</button>
      <button class="btn ghost mt" onclick="clearSecret()">مسح</button>
    </div>
    <nav class="nav">
      <button class="active" data-tab="dashboard" onclick="openTab('dashboard')">الرئيسية</button>
      <button data-tab="ai" onclick="openTab('ai')">Respect Cyber AI</button>
      <button data-tab="scan" onclick="openTab('scan')">فحص أمان شامل</button>
      <button data-tab="reports" onclick="openTab('reports');loadReports()">بلاغات التطبيق</button>
      <button data-tab="users" onclick="openTab('users')">بحث وحظر المستخدمين</button>
      <button data-tab="posts" onclick="openTab('posts')">بحث التغريدات</button>
    </nav>
  </aside>
  <main class="main">
    <div class="top"><div><div class="title">لوحة إدارة Respect</div><div class="muted">نفس الرابط صار موقع مصغر للأدمن، والـ POST القديم للذكاء الاصطناعي بقي شغال.</div></div><button class="btn" onclick="loadSummary()">تحديث البيانات</button></div>

    <section id="dashboard" class="section active">
      <div class="grid">
        <div class="card"><h3>المستخدمون</h3><div id="cUsers" class="num">-</div></div>
        <div class="card"><h3>التغريدات</h3><div id="cPosts" class="num">-</div></div>
        <div class="card"><h3>بلاغات معلقة</h3><div id="cReports" class="num">-</div></div>
        <div class="card"><h3>محظورين</h3><div id="cBlocked" class="num">-</div></div>
      </div>
      <div class="card mt"><h3>الحالة</h3><pre id="summaryOut">اضغط تحديث البيانات.</pre></div>
    </section>

    <section id="ai" class="section">
      <div class="split">
        <div class="card">
          <h3>اسأل Respect Cyber AI</h3>
          <select id="cyberMode"><option value="defensive">حماية دفاعية</option><option value="code_review">مراجعة كود</option><option value="incident_response">استجابة حادث</option><option value="explain">شرح مبسط</option></select>
          <textarea id="cyberText" class="mt" placeholder="اكتب السؤال الأمني أو الصق كود تريد مراجعته دفاعيًا..."></textarea>
          <button class="btn mt" onclick="askCyber()">إرسال</button>
        </div>
        <div class="card"><h3>الرد</h3><pre id="cyberOut">جاهز.</pre></div>
      </div>
    </section>

    <section id="scan" class="section">
      <div class="card"><h3>فحص شامل للتطبيق من ناحية الأمان</h3><p class="muted">الفحص دفاعي: إعدادات السيرفر، الأسرار، طبقات الحماية، وعدّادات Supabase الأساسية.</p><button class="btn" onclick="runFullScan()">بدء الفحص الآن</button></div>
      <div class="card mt"><h3>النتيجة</h3><div id="scanScore" class="num">-</div><div id="scanList" class="list mt"></div></div>
    </section>

    <section id="reports" class="section">
      <div class="card">
        <div class="searchbar"><input id="reportsQ" placeholder="بحث في البلاغات: مستخدم / سبب / تفاصيل" /><select id="reportsStatus"><option value="all">كل الحالات</option><option value="pending">معلقة</option><option value="reviewed">تمت المراجعة</option><option value="accepted">مقبولة</option><option value="rejected">مرفوضة</option></select><button class="btn" onclick="loadReports()">بحث</button></div>
        <div id="reportsList" class="list"></div>
      </div>
    </section>

    <section id="users" class="section">
      <div class="card">
        <div class="searchbar"><input id="usersQ" placeholder="ابحث باسم المستخدم أو الإيميل أو الاسم" /><button class="btn" onclick="loadUsers()">بحث</button></div>
        <div id="usersList" class="list"></div>
      </div>
    </section>

    <section id="posts" class="section">
      <div class="card">
        <div class="searchbar"><input id="postsQ" placeholder="ابحث داخل نص التغريدات" /><button class="btn" onclick="loadPosts()">بحث</button></div>
        <div id="postsList" class="list"></div>
      </div>
    </section>
  </main>
</div>
<script>
const $ = id => document.getElementById(id);
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const secret = () => $('secret').value || localStorage.getItem('respectCyberSecret') || '';
$('secret').value = localStorage.getItem('respectCyberSecret') || '';
function saveSecret(){localStorage.setItem('respectCyberSecret', $('secret').value || ''); alert('تم حفظ السر محليًا في المتصفح');}
function clearSecret(){localStorage.removeItem('respectCyberSecret'); $('secret').value='';}
function openTab(tab){document.querySelectorAll('.section').forEach(x=>x.classList.remove('active'));document.querySelectorAll('.nav button').forEach(x=>x.classList.remove('active'));$(tab).classList.add('active');document.querySelector(`[data-tab="${tab}"]`).classList.add('active');}
async function api(path, body={}){const r=await fetch(path,{method:'POST',headers:{'Content-Type':'application/json','X-App-Secret':secret()},body:JSON.stringify(body)});const txt=await r.text();let data;try{data=JSON.parse(txt)}catch{data={raw:txt}};if(!r.ok) throw new Error(typeof data.detail==='string'?data.detail:JSON.stringify(data.detail||data));return data;}
function showError(el,e){$(el).innerHTML = 'خطأ: '+esc(e.message||e);}
async function loadSummary(){try{const d=await api('/respect-ai/cyber/admin/summary');$('cUsers').textContent=d.counts.users;$('cPosts').textContent=d.counts.posts;$('cReports').textContent=d.counts.pendingReports;$('cBlocked').textContent=d.counts.blockedUsers;$('summaryOut').textContent=JSON.stringify(d,null,2);}catch(e){showError('summaryOut',e)}}
async function askCyber(){try{$('cyberOut').textContent='جاري التفكير...';const d=await api('/respect-ai/cyber',{text:$('cyberText').value,username:'@admin',mode:$('cyberMode').value});$('cyberOut').textContent=d.reply||JSON.stringify(d,null,2);}catch(e){showError('cyberOut',e)}}
async function runFullScan(){try{$('scanScore').textContent='...';$('scanList').innerHTML='';const d=await api('/respect-ai/cyber/full-scan');$('scanScore').textContent=(d.score||0)+'/100';$('scanList').innerHTML=(d.checks||[]).map(c=>`<div class="item"><span class="pill ${c.ok?'ok':c.level}">${c.ok?'سليم':'يحتاج مراجعة'} · ${esc(c.level)}</span><b>${esc(c.name)}</b><div class="muted mt">${esc(c.detail)}</div></div>`).join('')+`<pre>${esc(JSON.stringify(d.counts||{},null,2))}</pre>`;}catch(e){$('scanScore').textContent='خطأ';$('scanList').innerHTML='<div class="item dangerText">'+esc(e.message||e)+'</div>'}}
async function loadReports(){try{const d=await api('/respect-ai/cyber/admin/reports',{q:$('reportsQ').value,status:$('reportsStatus').value,limit:40});$('reportsList').innerHTML=(d.items||[]).map(r=>{const id=r.id||r.report_id||'';return `<div class="item"><div class="meta">${esc(r.created_at||'')} · الحالة: ${esc(r.status||'pending')} · المبلّغ: ${esc(r.reporter_username||r.reporterUsername||'')}</div><b>${esc(r.reason||r.type||'بلاغ')}</b><div class="mt">${esc(r.details||'')}</div><div class="mt muted">على: ${esc(r.post_username||r.postUsername||'')} · post: ${esc(r.post_id||r.postId||'')}</div><div class="actions"><button class="btn" onclick="reviewReport('${esc(id)}')">مراجعة AI</button><button class="btn danger" onclick="blockUser('${esc(r.post_username||r.postUsername||'')}')">حظر صاحب التغريدة</button></div></div>`}).join('')||'<div class="muted">لا توجد بلاغات.</div>'}catch(e){showError('reportsList',e)}}
async function reviewReport(id){if(!id)return alert('لا يوجد report id');try{const d=await api('/respect-ai/cyber/admin/reports/review',{reportId:id});alert('تمت المراجعة: '+(d.reason||JSON.stringify(d)));loadReports();}catch(e){alert(e.message||e)}}
async function loadUsers(){try{const d=await api('/respect-ai/cyber/admin/users',{q:$('usersQ').value,limit:40});$('usersList').innerHTML=(d.items||[]).map(u=>`<div class="item"><div class="meta">${esc(u.created_at||'')} · ${u.is_blocked?'محظور':'نشط'} · ${u.is_admin?'أدمن':''}</div><b>${esc(u.name||'User')} ${esc(u.username||'')}</b><div class="muted mt">${esc(u.email||'')} ${u.blocked_reason?'· سبب الحظر: '+esc(u.blocked_reason):''}</div><div class="actions"><button class="btn danger" onclick="blockUser('${esc(u.username||'')}')">حظر</button><button class="btn ok" onclick="unblockUser('${esc(u.username||'')}')">فك الحظر</button></div></div>`).join('')||'<div class="muted">لا يوجد نتائج.</div>'}catch(e){showError('usersList',e)}}
async function blockUser(username){username=(username||'').trim();if(!username)return alert('اسم المستخدم فارغ');const reason=prompt('سبب الحظر:', 'حظر إداري من Respect Cyber Center')||'حظر إداري';try{await api('/respect-ai/cyber/admin/users/block',{username,reason});alert('تم الحظر');loadUsers();loadReports();loadSummary();}catch(e){alert(e.message||e)}}
async function unblockUser(username){username=(username||'').trim();if(!username)return alert('اسم المستخدم فارغ');try{await api('/respect-ai/cyber/admin/users/unblock',{username,reason:'فك حظر إداري'});alert('تم فك الحظر');loadUsers();loadSummary();}catch(e){alert(e.message||e)}}
async function loadPosts(){try{const d=await api('/respect-ai/cyber/admin/posts',{q:$('postsQ').value,limit:40});$('postsList').innerHTML=(d.items||[]).map(p=>`<div class="item"><div class="meta">${esc(p.created_at||'')} · ${esc(p.username||'')} · views ${esc(p.views||0)}</div><div>${esc(p.text||'')}</div><div class="actions"><button class="btn warn" onclick="hidePost('${esc(p.id||'')}')">إخفاء التغريدة</button><button class="btn ok" onclick="unhidePost('${esc(p.id||'')}')">إلغاء الإخفاء</button><button class="btn danger" onclick="blockUser('${esc(p.username||'')}')">حظر الكاتب</button></div></div>`).join('')||'<div class="muted">لا يوجد نتائج.</div>'}catch(e){showError('postsList',e)}}
async function hidePost(id){const reason=prompt('سبب الإخفاء:', 'إخفاء إداري من Respect Cyber Center')||'إخفاء إداري';try{await api('/respect-ai/cyber/admin/posts/hide',{postId:id,reason});alert('تم الإخفاء');loadPosts();}catch(e){alert(e.message||e)}}
async function unhidePost(id){try{await api('/respect-ai/cyber/admin/posts/unhide',{postId:id,reason:'إلغاء إخفاء إداري'});alert('تم إلغاء الإخفاء');loadPosts();}catch(e){alert(e.message||e)}}
loadSummary();
</script>
</body>
</html>
"""


@app.post("/respect-ai/cyber/admin/summary")
def respect_ai_cyber_admin_summary(x_app_secret: Optional[str] = Header(default=None)):
    _check_cyber_admin_secret(x_app_secret)
    scan = _cyber_scan_report()
    return {"ok": True, "counts": scan["counts"], "securityScore": scan["score"], "enabled": {"qwen": bool(QWEN_API_KEY), "cyberAi": bool(HF_TOKEN), "fcm": bool(SA_JSON or SA_FILE), "turn": bool(METERED_API_KEY)}}


@app.post("/respect-ai/cyber/full-scan")
def respect_ai_cyber_full_scan(x_app_secret: Optional[str] = Header(default=None)):
    _check_cyber_admin_secret(x_app_secret)
    return _cyber_scan_report()


@app.post("/respect-ai/cyber/admin/reports")
def respect_ai_cyber_admin_reports(req: CyberAdminListRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_cyber_admin_secret(x_app_secret)
    limit = _cyber_limit(req.limit, 30, 100)
    offset = _cyber_offset(req.offset)
    q = _cyber_search_term(req.q)
    status = (req.status or "all").strip().lower()
    params: Dict[str, Any] = {"select": "*", "order": "created_at.desc", "limit": str(limit), "offset": str(offset)}
    if status and status != "all":
        params["status"] = f"eq.{status}"
    if q:
        params["or"] = f"(reason.ilike.*{q}*,details.ilike.*{q}*,reporter_username.ilike.*{q}*,post_username.ilike.*{q}*)"
    try:
        items = _cyber_supabase_get("post_reports", params)
    except HTTPException:
        # fallback لو بعض الأعمدة غير موجودة في جدول قديم.
        params = {"select": "*", "order": "created_at.desc", "limit": str(limit), "offset": str(offset)}
        items = _cyber_supabase_get("post_reports", params)
        if q:
            low = q.lower()
            items = [x for x in items if low in json.dumps(x, ensure_ascii=False).lower()]
        if status and status != "all":
            items = [x for x in items if str(x.get("status", "pending")).lower() == status]
    return {"ok": True, "items": items, "limit": limit, "offset": offset}


@app.post("/respect-ai/cyber/admin/reports/review")
def respect_ai_cyber_admin_review_report(req: CyberAdminReviewReportRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_cyber_admin_secret(x_app_secret)
    report_id = str(req.reportId or "").strip()
    if not report_id:
        raise HTTPException(status_code=400, detail="reportId مطلوب")
    reports = _cyber_supabase_get("post_reports", {"select": "*", "id": f"eq.{report_id}", "limit": "1"})
    if not reports:
        raise HTTPException(status_code=404, detail="البلاغ غير موجود")
    report = reports[0]
    post_id = str(report.get("post_id") or report.get("postId") or "").strip()
    post_text = str(report.get("post_text") or report.get("postText") or "").strip()
    post_username = str(report.get("post_username") or report.get("postUsername") or "").strip()
    if post_id and (not post_text or not post_username):
        try:
            posts = _cyber_supabase_get("posts", {"select": "*", "id": f"eq.{post_id}", "limit": "1"})
            if posts:
                post_text = post_text or str(posts[0].get("text") or "")
                post_username = post_username or str(posts[0].get("username") or "")
        except Exception:
            pass
    ai_req = RespectAIModerationRequest(
        reportId=report_id,
        postId=post_id,
        reporterUsername=str(report.get("reporter_username") or report.get("reporterUsername") or ""),
        reportedUsername=post_username,
        reason=str(report.get("reason") or report.get("type") or "بلاغ"),
        details=str(report.get("details") or ""),
        postText=post_text,
        communityId=str(report.get("community_id") or report.get("communityId") or ""),
        communityName=str(report.get("community_name") or report.get("communityName") or ""),
    )
    result = respect_ai_review_report(ai_req, x_app_secret=APP_SHARED_SECRET)
    patch_payload = {
        "status": "accepted" if result.get("validReport") else "rejected",
        "ai_status": "reviewed",
        "ai_reason": str(result.get("reason") or "")[:500],
        "ai_confidence": result.get("confidence") or 0,
        "reviewed_at": datetime.now(timezone.utc).isoformat(),
    }
    patch = _cyber_patch_table("post_reports", {"id": f"eq.{report_id}"}, patch_payload)
    if not patch.get("ok"):
        # fallback لو جدول post_reports لا يحتوي أعمدة ai_reason/reviewed_at.
        patch = _cyber_patch_table("post_reports", {"id": f"eq.{report_id}"}, {"status": patch_payload["status"], "ai_status": "reviewed"})
    return {**result, "reportPatch": patch}


@app.post("/respect-ai/cyber/admin/users")
def respect_ai_cyber_admin_users(req: CyberAdminListRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_cyber_admin_secret(x_app_secret)
    limit = _cyber_limit(req.limit, 30, 100)
    offset = _cyber_offset(req.offset)
    q = _cyber_search_term(req.q)
    params: Dict[str, Any] = {"select": "*", "order": "created_at.desc", "limit": str(limit), "offset": str(offset)}
    if q:
        params["or"] = f"(username.ilike.*{q}*,name.ilike.*{q}*,email.ilike.*{q}*)"
    try:
        items = _cyber_supabase_get("users", params)
    except HTTPException:
        params = {"select": "*", "order": "created_at.desc", "limit": str(limit), "offset": str(offset)}
        items = _cyber_supabase_get("users", params)
        if q:
            low = q.lower()
            items = [x for x in items if low in json.dumps(x, ensure_ascii=False).lower()]
    safe = [_safe_user_for_client(u) | {"blocked_reason": u.get("blocked_reason", "")} for u in items]
    return {"ok": True, "items": safe, "limit": limit, "offset": offset}


@app.post("/respect-ai/cyber/admin/users/block")
def respect_ai_cyber_admin_block_user(req: CyberAdminUserActionRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_cyber_admin_secret(x_app_secret)
    username = _display_username(req.username)
    ok = _block_user_from_server(username, req.reason or "حظر إداري من Respect Cyber Center")
    if not ok:
        raise HTTPException(status_code=500, detail="تعذر حظر المستخدم. راجع أعمدة جدول users وصلاحيات service role.")
    return {"ok": True, "username": username, "blocked": True}


@app.post("/respect-ai/cyber/admin/users/unblock")
def respect_ai_cyber_admin_unblock_user(req: CyberAdminUserActionRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_cyber_admin_secret(x_app_secret)
    username = _display_username(req.username)
    clean = normalize_username(username)
    now = datetime.now(timezone.utc).isoformat()
    patch = _cyber_patch_table("users", {"or": f"(username.eq.{username},username.eq.{clean})"}, {
        "is_blocked": False,
        "blocked": False,
        "banned": False,
        "disabled": False,
        "canLogin": True,
        "blocked_reason": "",
        "updated_at": now,
    })
    if not patch.get("ok"):
        patch = _cyber_patch_table("users", {"or": f"(username.eq.{username},username.eq.{clean})"}, {"is_blocked": False, "updated_at": now})
    return {"ok": bool(patch.get("ok")), "username": username, "unblocked": bool(patch.get("ok")), "patch": patch}


@app.post("/respect-ai/cyber/admin/posts")
def respect_ai_cyber_admin_posts(req: CyberAdminListRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_cyber_admin_secret(x_app_secret)
    limit = _cyber_limit(req.limit, 30, 100)
    offset = _cyber_offset(req.offset)
    q = _cyber_search_term(req.q)
    params: Dict[str, Any] = {"select": "*", "order": "created_at.desc", "limit": str(limit), "offset": str(offset)}
    if q:
        params["or"] = f"(text.ilike.*{q}*,username.ilike.*{q}*,name.ilike.*{q}*)"
    try:
        items = _cyber_supabase_get("posts", params)
    except HTTPException:
        params = {"select": "*", "order": "created_at.desc", "limit": str(limit), "offset": str(offset)}
        items = _cyber_supabase_get("posts", params)
        if q:
            low = q.lower()
            items = [x for x in items if low in json.dumps(x, ensure_ascii=False).lower()]
    # تقليل الحجم العائد للمتصفح.
    slim = []
    for p in items:
        slim.append({k: p.get(k) for k in ["id", "username", "name", "text", "created_at", "likes", "reposts", "shares", "views", "community_id", "community_name", "community_hidden", "hidden_reason"] if k in p})
    return {"ok": True, "items": slim, "limit": limit, "offset": offset}


@app.post("/respect-ai/cyber/admin/posts/hide")
def respect_ai_cyber_admin_hide_post(req: CyberAdminPostActionRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_cyber_admin_secret(x_app_secret)
    result = _patch_supabase_post(req.postId, {
        "community_hidden": True,
        "hidden_reason": req.reason or "إخفاء إداري من Respect Cyber Center",
        "moderation_status": "hidden_by_admin",
        "updated_at": datetime.now(timezone.utc).isoformat(),
    })
    if not result.get("updated"):
        result = _patch_supabase_post(req.postId, {"community_hidden": True, "hidden_reason": req.reason or "إخفاء إداري"})
    return {"ok": bool(result.get("updated")), "result": result}


@app.post("/respect-ai/cyber/admin/posts/unhide")
def respect_ai_cyber_admin_unhide_post(req: CyberAdminPostActionRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_cyber_admin_secret(x_app_secret)
    result = _patch_supabase_post(req.postId, {
        "community_hidden": False,
        "hidden_reason": "",
        "moderation_status": "visible",
        "updated_at": datetime.now(timezone.utc).isoformat(),
    })
    if not result.get("updated"):
        result = _patch_supabase_post(req.postId, {"community_hidden": False, "hidden_reason": ""})
    return {"ok": bool(result.get("updated")), "result": result}

@app.post("/respect-ai/cyber", response_model=RespectAICyberResponse)
def respect_ai_cyber(req: RespectAICyberRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_secret(x_app_secret)

    username = req.username.strip()
    text = req.text.strip()
    reply = ask_huggingface_cyber_ai(
        text=text,
        username=username,
        mode=req.mode,
    )

    return RespectAICyberResponse(
        ok=True,
        reply=reply,
        model=HF_CYBER_MODEL,
    )

@app.post("/respect-ai/reply", response_model=RespectAIResponse)
def respect_ai_reply(req: RespectAIRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_secret(x_app_secret)

    username = req.username.strip() or req.askerUsername.strip()
    text = req.text.strip() or req.question.strip()

    _enforce_respect_ai_quota(username)

    reply = ask_qwen_ai(
        text=text,
        username=username,
        mode=req.mode,
        post_text=req.postText,
        parent_reply_text=req.parentReplyText,
        recent_replies_text=req.recentRepliesText,
    )

    _record_respect_ai_usage(username)

    return RespectAIResponse(
        ok=True,
        reply=reply,
        model=QWEN_MODEL,
    )


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("fcm_v1_server_qwen_server_delete_moderation:app", host="0.0.0.0", port=8000, reload=True)
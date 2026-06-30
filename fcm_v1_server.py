from __future__ import annotations
import base64
import json
import logging
import os
import re
import smtplib
import hashlib
import hmac
import math
import html as html_lib
import secrets
from datetime import datetime, timedelta, timezone
from email.message import EmailMessage
import tempfile
import subprocess
import time
import threading
from concurrent.futures import ThreadPoolExecutor
from collections import defaultdict
from difflib import SequenceMatcher
from typing import Any, Dict, Optional

import requests
try:
    import redis as redis_lib
except Exception:  # redis package is optional; the server keeps working without it.
    redis_lib = None
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
# موديل الترجمة الفورية داخل الدردشة. تستطيع جعله qwen-max إذا متاح في حساب Alibaba.
QWEN_TRANSLATION_MODEL = os.getenv("QWEN_TRANSLATION_MODEL", QWEN_TEXT_MODEL).strip() or QWEN_TEXT_MODEL
# موديل الصور: راجع صور المنشورات بعد رفعها إلى Supabase Storage.
QWEN_VISION_MODEL = os.getenv("QWEN_VISION_MODEL", "qwen-vl-plus").strip() or "qwen-vl-plus"

# ================= Respect AI Media Understanding Memory =================
# ذاكرة الصور والفيديوهات: تحفظ فهم Qwen للوسائط + قرار المراجعة.
# الهدف: إذا تكررت نفس الصورة/الفيديو أو صورة قريبة بصريًا، يستخدم Respect AI الذاكرة أولًا.
RESPECT_AI_MEDIA_MEMORY_TABLE = os.getenv("RESPECT_AI_MEDIA_MEMORY_TABLE", "respect_ai_media_memory").strip() or "respect_ai_media_memory"
AI_MEDIA_MEMORY_ENABLED = os.getenv("AI_MEDIA_MEMORY_ENABLED", "true").strip().lower() not in {"0", "false", "no", "off"}
AI_MEDIA_MEMORY_ALLOW_MIN_CONFIDENCE = float(os.getenv("AI_MEDIA_MEMORY_ALLOW_MIN_CONFIDENCE", "0.82") or "0.82")
AI_MEDIA_MEMORY_DELETE_MIN_CONFIDENCE = float(os.getenv("AI_MEDIA_MEMORY_DELETE_MIN_CONFIDENCE", "0.88") or "0.88")
AI_MEDIA_MEMORY_QA_MIN_CONFIDENCE = float(os.getenv("AI_MEDIA_MEMORY_QA_MIN_CONFIDENCE", "0.55") or "0.55")
AI_MEDIA_MEMORY_MAX_IMAGE_BYTES = int(os.getenv("AI_MEDIA_MEMORY_MAX_IMAGE_BYTES", "6500000") or "6500000")
AI_MEDIA_MEMORY_QA_SUMMARY_MAX_CHARS = int(os.getenv("AI_MEDIA_MEMORY_QA_SUMMARY_MAX_CHARS", "1600") or "1600")
# اسم قديم للتوافق مع باقي الكود القديم.
QWEN_MODEL = QWEN_TEXT_MODEL
QWEN_BASE_URL = os.getenv("QWEN_BASE_URL", "https://dashscope-intl.aliyuncs.com/compatible-mode/v1").rstrip("/")

# ================= Respect AI Topic Memory =================
# ذاكرة جانبية تقلل استدعاءات الذكاء الاصطناعي:
# إذا وجدت الذاكرة تطابقًا قويًا، يتم التصنيف بدون Qwen.
AI_TOPIC_MEMORY_MIN_CONFIDENCE = float(os.getenv("AI_TOPIC_MEMORY_MIN_CONFIDENCE", "0.58"))
AI_TOPIC_MEMORY_MAX_ROWS = int(os.getenv("AI_TOPIC_MEMORY_MAX_ROWS", "3000"))
AI_TOPIC_MEMORY_LEARN_MIN_CONFIDENCE = float(os.getenv("AI_TOPIC_MEMORY_LEARN_MIN_CONFIDENCE", "0.62"))
AI_TOPIC_MEMORY_MAX_TERMS_PER_POST = int(os.getenv("AI_TOPIC_MEMORY_MAX_TERMS_PER_POST", "22"))
POST_TOPIC_STORE_MIN_CONFIDENCE = float(os.getenv("POST_TOPIC_STORE_MIN_CONFIDENCE", "0.35"))

# ================= Respect AI Unified Local Memory =================
# جدول واحد لكل ما يتعلمه الذكاء المحلي:
# - moderation: قرارات حذف/سماح للمنشورات والردود والبلاغات.
# - qa: أجوبة Respect AI المتكررة.
# لو عندك جداول قديمة تقدر تترك env كما هو، لكن الوضع الافتراضي الجديد موحد.
RESPECT_AI_LOCAL_MEMORY_TABLE = os.getenv("RESPECT_AI_LOCAL_MEMORY_TABLE", "respect_ai_local_memory").strip() or "respect_ai_local_memory"

# ================= Respect AI Q&A Reply Memory =================
# ذاكرة الأسئلة والأجوبة تقلل استدعاءات Qwen للأسئلة المتكررة.
# الفكرة: إذا تكرر نفس السؤال أو سؤال شديد التشابه في نفس السياق، يرجع Respect AI الجواب المتعلم مباشرة.
RESPECT_AI_QA_MEMORY_TABLE = os.getenv("RESPECT_AI_QA_MEMORY_TABLE", RESPECT_AI_LOCAL_MEMORY_TABLE).strip() or RESPECT_AI_LOCAL_MEMORY_TABLE
RESPECT_AI_QA_MEMORY_ENABLED = os.getenv("RESPECT_AI_QA_MEMORY_ENABLED", "true").strip().lower() not in {"0", "false", "no", "off"}
RESPECT_AI_QA_MEMORY_AUTO_APPROVE = os.getenv("RESPECT_AI_QA_MEMORY_AUTO_APPROVE", "true").strip().lower() not in {"0", "false", "no", "off"}
RESPECT_AI_QA_MEMORY_MATCH_THRESHOLD = float(os.getenv("RESPECT_AI_QA_MEMORY_MATCH_THRESHOLD", "0.88"))
RESPECT_AI_QA_MEMORY_MIN_CONFIDENCE = float(os.getenv("RESPECT_AI_QA_MEMORY_MIN_CONFIDENCE", "0.10"))
RESPECT_AI_QA_MEMORY_MIN_QUESTION_CHARS = int(os.getenv("RESPECT_AI_QA_MEMORY_MIN_QUESTION_CHARS", "1"))
RESPECT_AI_QA_MEMORY_MAX_QUESTION_CHARS = int(os.getenv("RESPECT_AI_QA_MEMORY_MAX_QUESTION_CHARS", "520"))
RESPECT_AI_QA_MEMORY_MAX_ANSWER_CHARS = int(os.getenv("RESPECT_AI_QA_MEMORY_MAX_ANSWER_CHARS", "2000"))
RESPECT_AI_QA_MEMORY_SIMILAR_SCAN_LIMIT = int(os.getenv("RESPECT_AI_QA_MEMORY_SIMILAR_SCAN_LIMIT", "350"))
# إذا true: Respect AI يتعلم حتى التحيات والأسئلة القصيرة جدًا.
# يبقى يمنع فقط حفظ الأسرار الواضحة مثل passwords/tokens/otp حماية للمستخدمين.
RESPECT_AI_QA_MEMORY_LEARN_EVERYTHING = os.getenv("RESPECT_AI_QA_MEMORY_LEARN_EVERYTHING", "true").strip().lower() not in {"0", "false", "no", "off"}
RESPECT_AI_QA_MEMORY_ALLOW_FRESH_TOPICS = os.getenv("RESPECT_AI_QA_MEMORY_ALLOW_FRESH_TOPICS", "true").strip().lower() not in {"0", "false", "no", "off"}
RESPECT_AI_QA_MEMORY_ALLOW_MEDICAL_LEGAL = os.getenv("RESPECT_AI_QA_MEMORY_ALLOW_MEDICAL_LEGAL", "true").strip().lower() not in {"0", "false", "no", "off"}

def _qa_memory_uses_unified_table() -> bool:
    """True when Q&A memory is stored inside the unified local-memory table."""
    return (
        (RESPECT_AI_QA_MEMORY_TABLE or "").strip().lower()
        == (RESPECT_AI_LOCAL_MEMORY_TABLE or "").strip().lower()
    )


def _qa_memory_apply_scope(payload: Dict[str, Any] | Dict[str, str]) -> Dict[str, Any]:
    """Keep Q&A rows under memory_scope=qa when using the unified table."""
    out: Dict[str, Any] = dict(payload or {})
    if _qa_memory_uses_unified_table():
        out["memory_scope"] = "qa"
    return out




# ================= Respect App AI Fixer / GitHub =================
# يقرأ ملفات المشروع من GitHub، يجعل Qwen3-Coder يحلل البلاغ، ثم بعد موافقة الأدمن
# ينشئ Pull Request بدل تعديل التطبيق مباشرة من جهاز المستخدم.
RESPECT_REPO_URL = os.getenv("RESPECT_REPO_URL", "https://github.com/nawafnawaf123/Respect-app.git").strip()
RESPECT_REPO_OWNER = os.getenv("RESPECT_REPO_OWNER", "").strip()
RESPECT_REPO_NAME = os.getenv("RESPECT_REPO_NAME", "").strip()
GITHUB_TOKEN = os.getenv("GITHUB_TOKEN", "").strip()
GITHUB_DEFAULT_BRANCH = os.getenv("GITHUB_DEFAULT_BRANCH", "").strip()
GITHUB_API_BASE = os.getenv("GITHUB_API_BASE", "https://api.github.com").rstrip("/")
QWEN_CODER_MODEL = os.getenv("QWEN_CODER_MODEL", "qwen3-coder-plus").strip() or "qwen3-coder-plus"
QWEN_CODER_TIMEOUT_SECONDS = int(os.getenv("QWEN_CODER_TIMEOUT_SECONDS", "300"))
AI_FIX_ADMIN_USERNAMES = {
    normalize.strip().lower().replace("@", "")
    for normalize in os.getenv("AI_FIX_ADMIN_USERNAMES", "mjakcon8,nawafrp,nawaf_city,nawafnawaf123").split(",")
    if normalize.strip()
}
APP_AI_FEEDBACK_TABLE = os.getenv("APP_AI_FEEDBACK_TABLE", "app_ai_feedback").strip() or "app_ai_feedback"
AI_FIX_MAX_FILES = int(os.getenv("AI_FIX_MAX_FILES", "10"))
AI_FIX_MAX_FILE_CHARS = int(os.getenv("AI_FIX_MAX_FILE_CHARS", "18000"))

# ================= Respect App Triple AI Patch Review =================
# أقوى تركيبة صينية مجانية عبر OpenRouter:
# 1) Qwen3-Coder Free يصنع unified diff فقط.
# 2) DeepSeek V4 Flash Free يراجع التصحيح syntax/logic.
# 3) Kimi K2.6 Free يراجع مراجعة النموذج الثاني ويعطي القرار النهائي.
# ضع OPENROUTER_API_KEY في Render فقط، ولا تضعه داخل Flutter.
OPENROUTER_API_KEY = os.getenv("OPENROUTER_API_KEY", "").strip()
OPENROUTER_BASE_URL = os.getenv("OPENROUTER_BASE_URL", "https://openrouter.ai/api/v1").rstrip("/")

# ================= AI Fixer OpenRouter multi-model fallback =================
# تستطيع إضافة موديلات كثيرة من Render بدون تعديل الكود:
# AI_FIX_EXTRA_MODELS=qwen/qwen3-coder:free,deepseek/deepseek-v4-flash:free,moonshotai/kimi-k2.6:free,openai/gpt-oss-120b:free
#
# النظام يجرب النموذج المطلوب أولًا، ثم بقية القائمة بالترتيب.
# إذا رجع 429/402/503/timeout/JSON invalid ينتقل للنموذج التالي بدل أن يفشل البلاغ.
AI_FIX_MODEL_1 = os.getenv("AI_FIX_MODEL_1", "qwen/qwen3-coder:free").strip() or "qwen/qwen3-coder:free"
AI_FIX_MODEL_2 = os.getenv("AI_FIX_MODEL_2", "deepseek/deepseek-v4-flash:free").strip() or "deepseek/deepseek-v4-flash:free"
AI_FIX_MODEL_3 = os.getenv("AI_FIX_MODEL_3", "moonshotai/kimi-k2.6:free").strip() or "moonshotai/kimi-k2.6:free"
AI_FIX_EXTRA_MODELS = os.getenv(
    "AI_FIX_EXTRA_MODELS",
    (
        "openrouter/free,"
        "qwen/qwen3-coder:free,"
        "deepseek/deepseek-v4-flash:free,"
        "moonshotai/kimi-k2.6:free,"
        "openai/gpt-oss-120b:free,"
        "meta-llama/llama-3.3-70b-instruct:free,"
        "google/gemma-3-27b-it:free,"
        "mistralai/mistral-small-3.2-24b-instruct:free,"
        "z-ai/glm-4.5-air:free"
    ),
).strip()
AI_FIX_REVIEW_MODE = os.getenv("AI_FIX_REVIEW_MODE", "multi_free_fallback_patch").strip() or "multi_free_fallback_patch"
AI_FIX_PATCH_ONLY = os.getenv("AI_FIX_PATCH_ONLY", "true").strip().lower() not in {"0", "false", "no", "off"}
AI_FIX_MAX_PATCH_CHARS = int(os.getenv("AI_FIX_MAX_PATCH_CHARS", "90000"))
AI_FIX_MAX_MODEL_ATTEMPTS = int(os.getenv("AI_FIX_MAX_MODEL_ATTEMPTS", "12"))


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

# ================= Shared Redis / Cross-instance state =================
# اختياري لكنه مهم للإنتاج على Render مع أكثر من instance:
# REDIS_URL=redis://...
# إذا لم يكن Redis متاحًا يرجع السيرفر تلقائيًا للذاكرة المحلية القديمة بدون أن يتوقف.
REDIS_URL = os.getenv("REDIS_URL", "").strip()
REDIS_PREFIX = os.getenv("REDIS_PREFIX", "respect").strip() or "respect"
REDIS_SOCKET_TIMEOUT_SECONDS = float(os.getenv("REDIS_SOCKET_TIMEOUT_SECONDS", "2") or "2")
REDIS_CLIENT = None
if REDIS_URL and redis_lib is not None:
    try:
        REDIS_CLIENT = redis_lib.from_url(
            REDIS_URL,
            decode_responses=True,
            socket_timeout=REDIS_SOCKET_TIMEOUT_SECONDS,
            socket_connect_timeout=REDIS_SOCKET_TIMEOUT_SECONDS,
            health_check_interval=30,
        )
        REDIS_CLIENT.ping()
        logger.info("Redis enabled for shared Respect state")
    except Exception as exc:
        logger.warning("Redis disabled/fallback to local memory: %s", exc)
        REDIS_CLIENT = None
elif REDIS_URL and redis_lib is None:
    logger.warning("REDIS_URL is set but redis package is not installed. Add redis to requirements.txt to enable shared state.")


def _redis_available() -> bool:
    return REDIS_CLIENT is not None


def _redis_key(*parts: str) -> str:
    clean_parts = [re.sub(r"[^A-Za-z0-9_.:-]+", "_", str(p or "").strip()) for p in parts if str(p or "").strip()]
    return ":".join([REDIS_PREFIX, *clean_parts])


def _redis_get_json(key: str) -> Any:
    if not _redis_available():
        return None
    try:
        raw = REDIS_CLIENT.get(key)
        if not raw:
            return None
        return json.loads(raw)
    except Exception as exc:
        logger.debug("redis get json failed key=%s error=%s", key, exc)
        return None


def _redis_set_json(key: str, value: Any, ttl_seconds: int) -> bool:
    if not _redis_available():
        return False
    try:
        REDIS_CLIENT.setex(key, max(1, int(ttl_seconds)), json.dumps(value, ensure_ascii=False, default=str))
        return True
    except Exception as exc:
        logger.debug("redis set json failed key=%s error=%s", key, exc)
        return False


def _redis_delete(key: str) -> None:
    if not _redis_available():
        return
    try:
        REDIS_CLIENT.delete(key)
    except Exception as exc:
        logger.debug("redis delete failed key=%s error=%s", key, exc)


def _redis_incr_with_ttl(key: str, ttl_seconds: int) -> Optional[int]:
    if not _redis_available():
        return None
    try:
        pipe = REDIS_CLIENT.pipeline()
        pipe.incr(key, 1)
        pipe.ttl(key)
        count, ttl = pipe.execute()
        if int(ttl or -1) < 0:
            REDIS_CLIENT.expire(key, max(1, int(ttl_seconds)))
        return int(count)
    except Exception as exc:
        logger.debug("redis incr failed key=%s error=%s", key, exc)
        return None


HTTP_SESSION = requests.Session()


def _redis_set_nx_ttl(key: str, ttl_seconds: int, value: str = "1") -> Optional[bool]:
    if not _redis_available():
        return None
    try:
        return bool(REDIS_CLIENT.set(key, value, ex=max(1, int(ttl_seconds)), nx=True))
    except Exception as exc:
        logger.debug("redis setnx failed key=%s error=%s", key, exc)
        return None


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
# ================= Background execution / moderation queue =================
# يخفف تجمد API: الطلب يرجع بسرعة، والفحص الثقيل للصور/الفيديو/Qwen يعمل بالخلفية.
RESPECT_MODERATION_ASYNC = os.getenv("RESPECT_MODERATION_ASYNC", "true").strip().lower() not in {"0", "false", "no", "off"}
RESPECT_GENERAL_PUSH_ASYNC = os.getenv("RESPECT_GENERAL_PUSH_ASYNC", "true").strip().lower() not in {"0", "false", "no", "off"}
RESPECT_BACKGROUND_WORKERS = max(1, int(os.getenv("RESPECT_BACKGROUND_WORKERS", "2") or "2"))
RESPECT_VIDEO_MODERATION_MAX_CONCURRENCY = max(1, int(os.getenv("RESPECT_VIDEO_MODERATION_MAX_CONCURRENCY", "1") or "1"))
# فشل فحص الفيديو ليس سببًا للحذف. نخلي الفيديو معلقًا ونحاول فحصه لاحقًا.
RESPECT_VIDEO_MODERATION_RETRY_ENABLED = os.getenv("RESPECT_VIDEO_MODERATION_RETRY_ENABLED", "true").strip().lower() not in {"0", "false", "no", "off"}
RESPECT_VIDEO_MODERATION_MAX_RETRIES = max(0, int(os.getenv("RESPECT_VIDEO_MODERATION_MAX_RETRIES", "5") or "5"))
RESPECT_VIDEO_MODERATION_RETRY_DELAYS_SECONDS = os.getenv("RESPECT_VIDEO_MODERATION_RETRY_DELAYS_SECONDS", "600,1800,3600,7200,14400").strip()
# يقلل الحذف الخاطئ عند قراءة OCR داخل الصور/الفيديوهات:
# مثال: نص ديني أو تعليمي عادي عن "المرأة" أو "يوم القيامة" لا يعتبر محتوى جنسيًا ولا إساءة دينية.
RESPECT_VISION_TEXT_CONTEXT_RELAXATION = os.getenv("RESPECT_VISION_TEXT_CONTEXT_RELAXATION", "true").strip().lower() not in {"0", "false", "no", "off"}
_background_executor = ThreadPoolExecutor(max_workers=RESPECT_BACKGROUND_WORKERS, thread_name_prefix="respect-bg")
_video_moderation_semaphore = threading.BoundedSemaphore(RESPECT_VIDEO_MODERATION_MAX_CONCURRENCY)
_video_moderation_retry_lock = threading.Lock()
_video_moderation_retry_attempts: Dict[str, int] = {}


def _model_to_dict(model: Any) -> Dict[str, Any]:
    if hasattr(model, "model_dump"):
        return dict(model.model_dump())
    if hasattr(model, "dict"):
        return dict(model.dict())
    if isinstance(model, dict):
        return dict(model)
    return {}


def _new_background_job_id(prefix: str) -> str:
    return f"{prefix}_{int(time.time() * 1000)}_{secrets.token_hex(5)}"


def _run_background_job(job_name: str, fn: Any, *args: Any, **kwargs: Any) -> None:
    try:
        fn(*args, **kwargs)
    except HTTPException as exc:
        logger.warning("background job %s failed status=%s detail=%s", job_name, exc.status_code, _safe_response_text(str(exc.detail), 500))
    except Exception as exc:
        logger.exception("background job %s crashed: %s", job_name, exc)


def _submit_background_job(job_name: str, fn: Any, *args: Any, **kwargs: Any) -> str:
    job_id = _new_background_job_id(job_name)
    _background_executor.submit(_run_background_job, job_id, fn, *args, **kwargs)
    return job_id


def _video_moderation_retry_delays() -> list[int]:
    raw = RESPECT_VIDEO_MODERATION_RETRY_DELAYS_SECONDS or "600,1800,3600"
    delays: list[int] = []
    for part in raw.split(","):
        try:
            value = int(float(part.strip()))
        except Exception:
            continue
        if value > 0:
            delays.append(value)
    return delays or [600, 1800, 3600]


def _pending_video_moderation_result(
    *,
    category: str = "video_pending_review",
    reason: str = "تعذر فحص الفيديو مؤقتًا، وسيعاد فحصه لاحقًا بدون حذف المنشور.",
    confidence: float = 0.0,
    checks: int = 0,
    video_checks: Optional[list[Dict[str, Any]]] = None,
    extra: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    payload: Dict[str, Any] = {
        "shouldDelete": False,
        "delete": False,
        "blocked": False,
        "category": category or "video_pending_review",
        "reason": reason or "تعذر فحص الفيديو مؤقتًا، وسيعاد فحصه لاحقًا بدون حذف المنشور.",
        "confidence": float(confidence or 0.0),
        "checks": int(checks or 0),
        "videoChecks": video_checks or [],
        "deferred": True,
        "retryable": True,
        "moderationPending": True,
        "videoModerationPending": True,
        "reviewStatus": "pending_video_scan",
    }
    if extra:
        payload.update(extra)
    return payload


def _is_video_moderation_pending(result: Dict[str, Any]) -> bool:
    if not isinstance(result, dict):
        return False
    if result.get("videoModerationPending") is True or result.get("moderationPending") is True:
        return True
    if result.get("deferred") is True and str(result.get("category") or "").startswith("video_"):
        return True
    if result.get("retryable") is True and str(result.get("category") or "").startswith("video_"):
        return True
    return str(result.get("reviewStatus") or "").strip().lower() == "pending_video_scan"


def _video_moderation_retry_key(req: RespectAIModerationRequest) -> str:
    urls = _public_video_urls_from_req(req)
    raw = "|".join([
        str(req.postId or req.replyId or ""),
        str(req.username or req.reportedUsername or ""),
        *urls,
    ])
    return hashlib.sha256(raw.encode("utf-8", errors="ignore")).hexdigest()


def _clear_pending_video_moderation_retry(req: RespectAIModerationRequest) -> None:
    key = _video_moderation_retry_key(req)
    if not key:
        return
    with _video_moderation_retry_lock:
        _video_moderation_retry_attempts.pop(key, None)


def _schedule_pending_video_moderation_retry(req: RespectAIModerationRequest, video_result: Dict[str, Any]) -> Dict[str, Any]:
    if not RESPECT_VIDEO_MODERATION_RETRY_ENABLED:
        return {"scheduled": False, "reason": "retry_disabled"}
    if not _public_video_urls_from_req(req):
        return {"scheduled": False, "reason": "no_video_urls"}
    if not (req.postId or req.replyId or "").strip():
        return {"scheduled": False, "reason": "missing_content_id"}

    key = _video_moderation_retry_key(req)
    delays = _video_moderation_retry_delays()
    with _video_moderation_retry_lock:
        attempt = int(_video_moderation_retry_attempts.get(key, 0))
        if attempt >= RESPECT_VIDEO_MODERATION_MAX_RETRIES:
            return {
                "scheduled": False,
                "reason": "max_retries_reached",
                "attempt": attempt,
                "maxRetries": RESPECT_VIDEO_MODERATION_MAX_RETRIES,
            }
        _video_moderation_retry_attempts[key] = attempt + 1

    delay = delays[min(attempt, len(delays) - 1)]
    req_data = _model_to_dict(req)

    def _enqueue_retry() -> None:
        try:
            _submit_background_job("video_moderation_retry", _run_post_moderation_job, req_data)
        except Exception as exc:
            logger.warning("failed to enqueue pending video moderation retry post_id=%s error=%s", req.postId, exc)

    timer = threading.Timer(delay, _enqueue_retry)
    timer.daemon = True
    timer.start()

    logger.warning(
        "video moderation pending post_id=%s retry_attempt=%s/%s retry_after_seconds=%s category=%s reason=%s",
        req.postId,
        attempt + 1,
        RESPECT_VIDEO_MODERATION_MAX_RETRIES,
        delay,
        str(video_result.get("category") or "video_pending_review"),
        _safe_response_text(str(video_result.get("reason") or ""), 350),
    )
    return {
        "scheduled": True,
        "attempt": attempt + 1,
        "maxRetries": RESPECT_VIDEO_MODERATION_MAX_RETRIES,
        "retryAfterSeconds": delay,
    }


_moderation_rate: Dict[str, list[float]] = defaultdict(list)
_login_failures: Dict[str, Dict[str, Any]] = {}
_password_reset_tokens: Dict[str, Dict[str, Any]] = {}


def _client_ip(request: FastAPIRequest) -> str:
    forwarded = request.headers.get("x-forwarded-for", "").split(",")[0].strip()
    if forwarded:
        return forwarded
    return request.client.host if request.client else "unknown"


def _enforce_moderation_rate(ip: str, limit: int = 60) -> None:
    if limit <= 0:
        return
    key = _redis_key("rate", "moderation", hashlib.sha256(str(ip or "unknown").encode("utf-8")).hexdigest())
    count = _redis_incr_with_ttl(key, 60)
    if count is not None:
        if count > limit:
            raise HTTPException(status_code=429, detail="Too many moderation requests")
        return

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
    family = path.strip("/").split("/", 1)[0] or "root"
    key_hash = hashlib.sha256(f"{ip}:{family}".encode("utf-8")).hexdigest()
    redis_key = _redis_key("rate", "app", key_hash)
    count = _redis_incr_with_ttl(redis_key, 60)
    if count is not None:
        if count > APP_REQUEST_RATE_LIMIT_PER_MINUTE:
            raise HTTPException(status_code=429, detail="Too many requests")
        return

    now = time.time()
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
    nonce_hash = hashlib.sha256(nonce_key.encode("utf-8")).hexdigest()
    redis_nonce_key = _redis_key("nonce", nonce_hash)

    body_text = body.decode("utf-8", errors="replace")
    payload = f"{timestamp}\n{nonce}\n{path}\n{body_text}".encode("utf-8")
    expected = base64.urlsafe_b64encode(
        hmac.new(signing_secret.encode("utf-8"), payload, hashlib.sha256).digest()
    ).decode("utf-8").rstrip("=")

    if not hmac.compare_digest(signature, expected):
        raise HTTPException(status_code=401, detail="Invalid request signature")

    redis_set = _redis_set_nx_ttl(redis_nonce_key, REQUEST_NONCE_TTL_SECONDS)
    if redis_set is False:
        raise HTTPException(status_code=401, detail="Replay request blocked")
    if redis_set is None:
        if _seen_request_nonces.get(nonce_key, 0) > now:
            raise HTTPException(status_code=401, detail="Replay request blocked")
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



SUPPORTED_APP_LANGUAGES = {"ar", "en", "fr", "es", "de", "tr", "id", "hi", "ur", "fa", "ru", "pt"}

def normalize_language(value: str) -> str:
    v = (value or "").strip().lower().replace("_", "-")
    if not v:
        return "ar"
    primary = v.split("-", 1)[0]
    return primary if primary in SUPPORTED_APP_LANGUAGES else "ar"


def _language_display_name(code: str) -> str:
    names = {
        "ar": "Arabic",
        "en": "English",
        "fr": "French",
        "es": "Spanish",
        "de": "German",
        "tr": "Turkish",
        "id": "Indonesian",
        "hi": "Hindi",
        "ur": "Urdu",
        "fa": "Persian",
        "ru": "Russian",
        "pt": "Portuguese",
    }
    return names.get(normalize_language(code), "Arabic")


def _language_from_user_row(row: Dict[str, Any], fallback: str = "ar") -> str:
    if not isinstance(row, dict):
        return normalize_language(fallback)
    for key in ("app_language", "language", "locale", "preferred_language"):
        value = str(row.get(key) or "").strip()
        if value:
            return normalize_language(value)
    return normalize_language(fallback)


def _t_push(key: str, language: str, **kwargs: Any) -> str:
    lang = normalize_language(language)
    translations: Dict[str, Dict[str, str]] = {
        "ar": {
            "respect": "Respect",
            "new_message": "لديك رسالة جديدة",
            "incoming_call": "مكالمة واردة",
            "incoming_video_call": "مكالمة فيديو واردة",
            "incoming_audio_call": "مكالمة صوتية واردة",
            "new_post": "نشر تغريدة جديدة",
            "new_notification": "لديك إشعار جديد",
            "report_result": "نتيجة البلاغ",
            "report_accepted": "تم قبول البلاغ",
            "post_deleted": "تم حذف تغريدتك",
        },
        "en": {
            "respect": "Respect",
            "new_message": "You have a new message",
            "incoming_call": "Incoming call",
            "incoming_video_call": "Incoming video call",
            "incoming_audio_call": "Incoming voice call",
            "new_post": "posted a new tweet",
            "new_notification": "You have a new notification",
            "report_result": "Report result",
            "report_accepted": "Report accepted",
            "post_deleted": "Your tweet was deleted",
        },
        "fr": {
            "respect": "Respect",
            "new_message": "Vous avez un nouveau message",
            "incoming_call": "Appel entrant",
            "incoming_video_call": "Appel vidéo entrant",
            "incoming_audio_call": "Appel vocal entrant",
            "new_post": "a publié un nouveau tweet",
            "new_notification": "Vous avez une nouvelle notification",
            "report_result": "Résultat du signalement",
            "report_accepted": "Signalement accepté",
            "post_deleted": "Votre tweet a été supprimé",
        },
        "es": {
            "respect": "Respect",
            "new_message": "Tienes un mensaje nuevo",
            "incoming_call": "Llamada entrante",
            "incoming_video_call": "Videollamada entrante",
            "incoming_audio_call": "Llamada de voz entrante",
            "new_post": "publicó un nuevo tweet",
            "new_notification": "Tienes una notificación nueva",
            "report_result": "Resultado del reporte",
            "report_accepted": "Reporte aceptado",
            "post_deleted": "Tu tweet fue eliminado",
        },
        "de": {
            "respect": "Respect",
            "new_message": "Du hast eine neue Nachricht",
            "incoming_call": "Eingehender Anruf",
            "incoming_video_call": "Eingehender Videoanruf",
            "incoming_audio_call": "Eingehender Sprachanruf",
            "new_post": "hat einen neuen Tweet gepostet",
            "new_notification": "Du hast eine neue Benachrichtigung",
            "report_result": "Meldeergebnis",
            "report_accepted": "Meldung akzeptiert",
            "post_deleted": "Dein Tweet wurde gelöscht",
        },
        "tr": {
            "respect": "Respect",
            "new_message": "Yeni bir mesajın var",
            "incoming_call": "Gelen arama",
            "incoming_video_call": "Gelen görüntülü arama",
            "incoming_audio_call": "Gelen sesli arama",
            "new_post": "yeni bir tweet paylaştı",
            "new_notification": "Yeni bir bildirimin var",
            "report_result": "Şikayet sonucu",
            "report_accepted": "Şikayet kabul edildi",
            "post_deleted": "Tweetin silindi",
        },
        "pt": {
            "respect": "Respect",
            "new_message": "Você tem uma nova mensagem",
            "incoming_call": "Chamada recebida",
            "incoming_video_call": "Chamada de vídeo recebida",
            "incoming_audio_call": "Chamada de voz recebida",
            "new_post": "publicou um novo tweet",
            "new_notification": "Você tem uma nova notificação",
            "report_result": "Resultado da denúncia",
            "report_accepted": "Denúncia aceita",
            "post_deleted": "Seu tweet foi excluído",
        },
        "ru": {
            "respect": "Respect",
            "new_message": "У вас новое сообщение",
            "incoming_call": "Входящий звонок",
            "incoming_video_call": "Входящий видеозвонок",
            "incoming_audio_call": "Входящий голосовой звонок",
            "new_post": "опубликовал новый твит",
            "new_notification": "У вас новое уведомление",
            "report_result": "Результат жалобы",
            "report_accepted": "Жалоба принята",
            "post_deleted": "Ваш твит был удалён",
        },
        "id": {
            "respect": "Respect",
            "new_message": "Anda memiliki pesan baru",
            "incoming_call": "Panggilan masuk",
            "incoming_video_call": "Panggilan video masuk",
            "incoming_audio_call": "Panggilan suara masuk",
            "new_post": "memposting tweet baru",
            "new_notification": "Anda memiliki notifikasi baru",
            "report_result": "Hasil laporan",
            "report_accepted": "Laporan diterima",
            "post_deleted": "Tweet Anda dihapus",
        },
        "hi": {
            "respect": "Respect",
            "new_message": "आपके पास नया संदेश है",
            "incoming_call": "इनकमिंग कॉल",
            "incoming_video_call": "इनकमिंग वीडियो कॉल",
            "incoming_audio_call": "इनकमिंग वॉइस कॉल",
            "new_post": "ने नया ट्वीट पोस्ट किया",
            "new_notification": "आपके पास नई सूचना है",
            "report_result": "रिपोर्ट परिणाम",
            "report_accepted": "रिपोर्ट स्वीकार हुई",
            "post_deleted": "आपका ट्वीट हटा दिया गया",
        },
        "ur": {
            "respect": "Respect",
            "new_message": "آپ کے پاس نیا پیغام ہے",
            "incoming_call": "آنے والی کال",
            "incoming_video_call": "آنے والی ویڈیو کال",
            "incoming_audio_call": "آنے والی وائس کال",
            "new_post": "نے نیا ٹویٹ پوسٹ کیا",
            "new_notification": "آپ کے پاس نیا نوٹیفکیشن ہے",
            "report_result": "رپورٹ کا نتیجہ",
            "report_accepted": "رپورٹ قبول ہوگئی",
            "post_deleted": "آپ کا ٹویٹ حذف کر دیا گیا",
        },
        "fa": {
            "respect": "Respect",
            "new_message": "شما یک پیام جدید دارید",
            "incoming_call": "تماس ورودی",
            "incoming_video_call": "تماس ویدیویی ورودی",
            "incoming_audio_call": "تماس صوتی ورودی",
            "new_post": "یک توییت جدید منتشر کرد",
            "new_notification": "شما یک اعلان جدید دارید",
            "report_result": "نتیجه گزارش",
            "report_accepted": "گزارش پذیرفته شد",
            "post_deleted": "توییت شما حذف شد",
        },
    }
    text = (translations.get(lang) or translations["ar"]).get(key) or translations["ar"].get(key) or key
    try:
        return text.format(**kwargs)
    except Exception:
        return text


def _localized_data(data: Dict[str, Any], language: str, title: str, body: str) -> Dict[str, Any]:
    lang = normalize_language(language)
    merged = dict(data or {})
    merged["language"] = lang
    merged["localizedTitle"] = title
    merged["localizedBody"] = body
    return merged


def get_user_push_target(receiver_username: str, fallback_language: str = "ar") -> Optional[Dict[str, str]]:
    clean = normalize_username(receiver_username)
    display = display_username(clean)
    if not clean:
        return None

    if not SB_URL or not (SB_SERVICE or SB_ANON):
        raise HTTPException(status_code=500, detail="Supabase env missing: SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY/SUPABASE_ANON_KEY")

    url = f"{SB_URL}/rest/v1/users"
    headers = _supabase_headers(use_service_role=True)
    params = {
        "select": "*",
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

    row = rows[0] if isinstance(rows[0], dict) else {}
    token = str(row.get("fcm_token") or "").strip()
    if not token:
        return None

    return {
        "username": display_username(str(row.get("username") or display)),
        "token": token,
        "language": _language_from_user_row(row, fallback=fallback_language),
    }


def get_user_fcm_token(receiver_username: str) -> Optional[str]:
    target = get_user_push_target(receiver_username)
    return target.get("token") if target else None


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
                "select": "*",
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
            if not isinstance(row, dict):
                continue
            token = str(row.get("fcm_token") or "").strip()
            username = display_username(str(row.get("username") or ""))
            if token:
                users.append({
                    "username": username,
                    "token": token,
                    "language": _language_from_user_row(row),
                })
        if len(rows) < page_size:
            break
        offset += page_size

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
    language: str = "ar" 


class GeneralPushRequest(BaseModel):
    title: str
    body: str
    senderUsername: str = "@admin"
    senderName: str = "Respect Admin"
    data: Dict[str, Any] = Field(default_factory=dict)
    language: str = "ar" 


class MessagePushRequest(BaseModel):
    receiverUsername: str
    senderUsername: str
    senderName: str = ""
    messageId: str
    text: str = ""
    language: str = "ar"


class CallPushRequest(BaseModel):
    receiverUsername: str
    callId: str
    callerUsername: str
    callerName: str = "مستخدم"
    callerAvatar: str = ""
    video: bool = False
    language: str = "ar" 


class PaddleVerificationCheckoutRequest(BaseModel):
    username: str
    planId: str
    email: str = ""
    deviceId: str = ""
    successUrl: str = ""
    cancelUrl: str = ""


class RespectAIRequest(BaseModel):
    text: str = ""
    username: str = ""
    askerUsername: str = ""
    question: str = ""
    postText: str = ""
    parentReplyText: str = ""
    recentRepliesText: str = ""
    postId: str = ""
    mode: str = "reply"  # reply / chat / coding / file_review / creative / study / moderation
    language: str = "ar"
    imageUrls: list[str] = Field(default_factory=list)
    imageUrl: str = ""
    videoUrls: list[str] = Field(default_factory=list)
    videoUrl: str = ""
    mediaType: str = "text"
    conversationContext: str = ""
    deepThinking: bool = False
    fileAttachments: list[Dict[str, Any]] = Field(default_factory=list)


class RespectAIResponse(BaseModel):
    ok: bool
    reply: str
    model: str
    source: str = "respect_ai"
    memoryUsed: bool = False
    qaMemoryUsed: bool = False
    mediaMemoryUsed: bool = False
    memoryId: str = ""
    confidence: float = 0.0
    category: str = ""
    thinkingSummary: str = ""
    usedMode: str = ""


class RespectAIChatTranslateRequest(BaseModel):
    text: str = Field(default="", min_length=1)
    targetLanguage: str = "ar"
    targetDialect: str = "auto"
    sourceLanguage: str = "auto"
    username: str = ""
    context: str = "chat"


class RespectAIChatTranslateResponse(BaseModel):
    ok: bool
    translatedText: str
    model: str
    targetLanguage: str
    targetDialect: str = "auto"


class RespectAISearchExpandRequest(BaseModel):
    query: str = Field(default="", min_length=1)
    language: str = "ar"


class RespectAISearchExpandResponse(BaseModel):
    ok: bool
    query: str
    terms: list[str]
    model: str


class RespectAIPostClassifyRequest(BaseModel):
    postId: str = ""
    username: str = ""
    text: str = ""
    imageUrls: list[str] = Field(default_factory=list)
    imageUrl: str = ""
    videoUrl: str = ""
    voiceUrl: str = ""
    mediaType: str = "text"  # text / image / video / voice / gif
    language: str = "ar"


class RespectAIPostClassifyResponse(BaseModel):
    ok: bool
    topics: list[str]
    primaryTopic: str = "general"
    confidence: float = 0.0
    model: str = ""
    stored: bool = False
    fallback: bool = False
    memoryUsed: bool = False
    source: str = ""
    reason: str = ""
    keywords: list[str] = Field(default_factory=list)


class AppAIFeedbackSubmitRequest(BaseModel):
    username: str = ""
    name: str = ""
    title: str = Field(default="بلاغ مشكلة في Respect App", min_length=1)
    note: str = Field(default="", min_length=8)
    screen: str = ""
    appVersion: str = ""
    mediaUrl: str = ""
    mediaType: str = ""
    mediaName: str = ""
    mediaUrls: list[str] = Field(default_factory=list)
    imageUrls: list[str] = Field(default_factory=list)
    videoUrls: list[str] = Field(default_factory=list)
    mediaAttachments: list[Dict[str, Any]] = Field(default_factory=list)
    deviceInfo: Dict[str, Any] = Field(default_factory=dict)
    language: str = "ar"


class AppAIFeedbackApproveRequest(BaseModel):
    reportId: str = Field(default="", min_length=3)
    approvedBy: str = ""


class AppFeedbackListRequest(BaseModel):
    adminUsername: str = ""
    status: str = "all"
    limit: int = 120


class AppFeedbackActionRequest(BaseModel):
    reportId: str = Field(default="", min_length=3)
    adminUsername: str = ""
    adminNote: str = ""



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

def _android_channel_id_for_type(msg_type: str) -> str:
    kind = (msg_type or "").strip().lower()
    if kind in {"general", "general_notification"}:
        return "respect_general_channel"
    if kind == "call":
        return "respect_calls_channel"
    if kind in {
        "post",
        "post_event",
        "post_moderation_deleted",
        "post_deleted_by_moderation",
        "reply_moderation_deleted",
        "reply_deleted_by_moderation",
        "app_feedback_resolved",
        "community_report_rejected",
        "community_report_accepted",
        "report_rejected_reporter",
        "report_accepted_reporter",
        "report_accepted_owner",
    }:
        return "respect_posts_channel"
    return "respect_messages_channel"


def _android_should_include_notification(msg_type: str, privacy_data_only: bool) -> bool:
    kind = (msg_type or "").strip().lower()
    if kind == "call":
        return False
    # Default to Android data-only so the native FirebaseMessagingService can
    # build the same high-priority channels while the Flutter process is dead.
    if privacy_data_only:
        return False
    return True


def _is_bad_fcm_token_error(detail: Any) -> bool:
    text = str(detail or "").upper()
    return any(marker in text for marker in [
        "UNREGISTERED",
        "NOT_FOUND",
        "INVALID_ARGUMENT",
        "SENDER_ID_MISMATCH",
        "INVALID_REGISTRATION",
    ])


def clear_fcm_token_value(token: str) -> None:
    clean = (token or "").strip()
    if not clean or not SB_URL or not (SB_SERVICE or SB_ANON):
        return
    try:
        requests.patch(
            f"{SB_URL}/rest/v1/users",
            headers={**_supabase_headers(use_service_role=True), "Prefer": "return=minimal"},
            params={"fcm_token": f"eq.{clean}"},
            json={"fcm_token": None, "fcm_updated_at": datetime.now(timezone.utc).isoformat()},
            timeout=12,
        )
    except Exception as exc:
        logger.warning("Failed to clear stale FCM token: %s", exc)


def _fcm_ios_apns_config(msg_type: str, clean_data: Dict[str, str], privacy_data_only: bool, title: str, body: str) -> Dict[str, Any]:
    """
    إعداد APNs حتى تصل إشعارات iOS بشكل موثوق.
    النص هنا صار يأخذ اللغة التي حددها السيرفر للمستخدم المستقبل.
    """
    alert_title = (title or "Respect").strip() or "Respect"
    alert_body = (body or "").strip() or clean_data.get("localizedBody") or clean_data.get("body") or "Respect"

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

    ios_apns = _fcm_ios_apns_config(msg_type, clean_data, privacy_data_only, title, body)
    include_android_notification = _android_should_include_notification(msg_type, privacy_data_only)
    channel_id = _android_channel_id_for_type(msg_type)

    if msg_type == "call" or not include_android_notification:
        # Android data-only lets the app's native service render calls/messages
        # even when Flutter is not alive. iOS still receives the APNs alert below.
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
        # Android يحتاج notification payload حتى يظهر الإشعار عندما التطبيق مقفل/مقتول.
        payload = {
            "message": {
                "token": token,
                "notification": {
                    "title": title or "Respect",
                    "body": body or clean_data.get("localizedBody", "Respect"),
                },
                "data": clean_data,
                "android": {
                    "priority": "HIGH",
                    "ttl": "3600s",
                    "notification": {
                        "channel_id": channel_id,
                        "sound": "default",
                        "default_sound": True,
                        "notification_priority": "PRIORITY_HIGH",
                    },
                },
                "apns": ios_apns,
            }
        }

    response = HTTP_SESSION.post(
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
        detail = {
            "firebase_status": response.status_code,
            "firebase_body": response.text,
            "hint": "SENDER_ID_MISMATCH يعني google-services.json أو service account من مشروع مختلف. UNREGISTERED يعني التوكن قديم.",
        }
        if _is_bad_fcm_token_error(detail):
            clear_fcm_token_value(token)
        raise HTTPException(status_code=400, detail=detail)

    try:
        firebase_body = response.json()
    except Exception:
        firebase_body = {"raw": response.text}

    return {
        "ok": True,
        "firebase": firebase_body,
        "sent_as": "notification" if include_android_notification else "data_only",
        "type": msg_type,
    }


def _moderation_delete_source_kind(decision_source: str, memory_used: bool = False) -> str:
    """
    يرجع نوع مصدر قرار الحذف بشكل موحد حتى يظهر للمستخدم:
    - memory: ذاكرة Respect AI أو قاموس البلاغات المتعلم.
    - ai: مراجعة Respect AI/Qwen.
    - link_guard: فحص الروابط الخارجي.
    - local: حماية محلية احتياطية.
    """
    src = (decision_source or "").strip().lower()
    if memory_used or src in {
        "respect_ai_moderation_memory",
        "moderation_memory",
        "learned_report_dictionary",
        "learned_dictionary",
        "topic_memory",
    }:
        return "memory"
    if "memory" in src or "learned" in src:
        return "memory"
    if "safe-browsing" in src or "virustotal" in src or "link" in src:
        return "link_guard"
    if "local" in src or "fallback" in src:
        return "local"
    return "ai"


def _moderation_delete_source_label(kind: str, language: str = "ar") -> str:
    lang = normalize_language(language)
    k = (kind or "").strip().lower()
    if lang == "ar":
        if k == "memory":
            return "ذاكرة Respect AI"
        if k == "link_guard":
            return "فحص الروابط الأمني"
        if k == "local":
            return "نظام الحماية المحلي"
        return "Respect AI"
    if k == "memory":
        return "Respect AI Memory"
    if k == "link_guard":
        return "Link Safety Guard"
    if k == "local":
        return "Local Safety Guard"
    return "Respect AI"


def _moderation_delete_body(language: str, source_label: str, category: str, reason: str) -> str:
    lang = normalize_language(language)
    clean_reason = (reason or "").strip()
    clean_category = (category or "violation").strip()
    if lang == "ar":
        if clean_reason:
            return f"تم حذف تغريدتك بواسطة {source_label}. السبب: {clean_reason[:180]}"
        return f"تم حذف تغريدتك بواسطة {source_label}. التصنيف: {clean_category}"
    if clean_reason:
        return f"Your tweet was deleted by {source_label}. Reason: {clean_reason[:180]}"
    return f"Your tweet was deleted by {source_label}. Category: {clean_category}"


def _moderation_delete_reply_body(language: str, source_label: str, category: str, reason: str) -> str:
    lang = normalize_language(language)
    clean_reason = (reason or "").strip()
    clean_category = (category or "violation").strip()
    if lang == "ar":
        if clean_reason:
            return f"تم حذف ردك بواسطة {source_label}. السبب: {clean_reason[:180]}"
        return f"تم حذف ردك بواسطة {source_label}. التصنيف: {clean_category}"
    if clean_reason:
        return f"Your reply was deleted by {source_label}. Reason: {clean_reason[:180]}"
    return f"Your reply was deleted by {source_label}. Category: {clean_category}"


def _moderation_reply_deleted_title(language: str) -> str:
    return "تم حذف ردك" if normalize_language(language) == "ar" else "Your reply was deleted"


def _send_post_moderation_deleted_push(
    username: str,
    post_id: str,
    reason: str,
    category: str,
    confidence: float,
    decision_source: str,
    memory_used: bool = False,
    matched_term: str = "",
    fallback_language: str = "ar",
) -> Dict[str, Any]:
    """
    يرسل إشعارًا لصاحب التغريدة عند حذفها بواسطة مراقبة Respect AI.
    مهم: لا يجعل فشل FCM يفشل حذف المنشور؛ يرجع نتيجة واضحة في response والـ logs.
    """
    user = display_username(username)
    pid = (post_id or "").strip()
    if not user or user == "@user":
        return {"sent": False, "reason": "missing_username", "postId": pid}

    try:
        target = get_user_push_target(user, fallback_language=fallback_language)
        if not target:
            return {"sent": False, "reason": "missing_fcm_token", "username": user, "postId": pid}

        language = normalize_language(target.get("language") or fallback_language)
        kind = _moderation_delete_source_kind(decision_source, memory_used=memory_used)
        source_label = _moderation_delete_source_label(kind, language)
        title = _t_push("post_deleted", language)
        body = _moderation_delete_body(language, source_label, category, reason)

        data = _localized_data(
            {
                "postId": pid,
                "username": user,
                "category": category or "violation",
                "reason": (reason or "")[:700],
                "confidence": round(float(confidence or 0.0), 4),
                "decisionSource": decision_source or ("respect_ai_moderation_memory" if kind == "memory" else "respect_ai"),
                "decisionSourceKind": kind,
                "decisionSourceLabel": source_label,
                "deletedBy": source_label,
                "memoryUsed": bool(memory_used),
                "moderationMemoryUsed": bool(memory_used),
                "matchedTerm": (matched_term or "")[:160],
            },
            language,
            title,
            body,
        )

        result = send_fcm_v1(
            target["token"],
            "post_moderation_deleted",
            title,
            body,
            data,
        )
        return {
            "sent": True,
            "username": user,
            "postId": pid,
            "decisionSourceKind": kind,
            "decisionSourceLabel": source_label,
            "firebase": result.get("firebase"),
        }
    except Exception as exc:
        logger.warning(
            "post moderation delete push failed username=%s post_id=%s source=%s error=%s",
            user,
            pid,
            decision_source,
            exc,
        )
        return {
            "sent": False,
            "reason": "push_exception",
            "error": str(exc)[:500],
            "username": user,
            "postId": pid,
        }



def _send_reply_moderation_deleted_push(
    username: str,
    reply_id: str,
    post_id: str,
    reason: str,
    category: str,
    confidence: float,
    decision_source: str,
    memory_used: bool = False,
    matched_term: str = "",
    fallback_language: str = "ar",
) -> Dict[str, Any]:
    """
    يرسل إشعارًا لصاحب الرد عند حذف رده بواسطة مراقبة Respect AI أو بلاغ صحيح.
    فشل FCM لا يفشل الحذف؛ فقط يرجع نتيجة واضحة في response والـ logs.
    """
    user = display_username(username)
    rid = (reply_id or "").strip()
    pid = (post_id or "").strip()
    if not user or user == "@user":
        return {"sent": False, "reason": "missing_username", "replyId": rid, "postId": pid}

    try:
        target = get_user_push_target(user, fallback_language=fallback_language)
        if not target:
            return {"sent": False, "reason": "missing_fcm_token", "username": user, "replyId": rid, "postId": pid}

        language = normalize_language(target.get("language") or fallback_language)
        kind = _moderation_delete_source_kind(decision_source, memory_used=memory_used)
        source_label = _moderation_delete_source_label(kind, language)
        title = _moderation_reply_deleted_title(language)
        body = _moderation_delete_reply_body(language, source_label, category, reason)

        data = _localized_data(
            {
                "postId": pid,
                "post_id": pid,
                "replyId": rid,
                "reply_id": rid,
                "username": user,
                "category": category or "violation",
                "reason": (reason or "")[:700],
                "confidence": round(float(confidence or 0.0), 4),
                "decisionSource": decision_source or ("respect_ai_moderation_memory" if kind == "memory" else "respect_ai"),
                "decisionSourceKind": kind,
                "decisionSourceLabel": source_label,
                "deletionSource": kind,
                "deletedBy": source_label,
                "memoryUsed": bool(memory_used),
                "moderationMemoryUsed": bool(memory_used),
                "matchedTerm": (matched_term or "")[:160],
            },
            language,
            title,
            body,
        )

        result = send_fcm_v1(
            target["token"],
            "reply_moderation_deleted",
            title,
            body,
            data,
        )
        return {
            "sent": True,
            "username": user,
            "replyId": rid,
            "postId": pid,
            "decisionSourceKind": kind,
            "decisionSourceLabel": source_label,
            "firebase": result.get("firebase"),
        }
    except Exception as exc:
        logger.warning(
            "reply moderation delete push failed username=%s reply_id=%s post_id=%s source=%s error=%s",
            user,
            rid,
            pid,
            decision_source,
            exc,
        )
        return {
            "sent": False,
            "reason": "push_exception",
            "error": str(exc)[:500],
            "username": user,
            "replyId": rid,
            "postId": pid,
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
        "topic_taxonomy_version": "v4_primary_secondary",
        "respect_ai_enabled": bool(QWEN_API_KEY),
        "respect_cyber_ai_enabled": bool(HF_TOKEN),
        "cyber_admin_page": "/respect-ai/cyber",
        "server_delete_enabled": bool(SB_SERVICE),
        "link_guard_enabled": bool(GSB_TOKEN),
        "virustotal_enabled": bool(VIRUSTOTAL_API_KEY),
        "qwen_model": QWEN_MODEL,
        "qwen_text_model": QWEN_TEXT_MODEL,
        "qwen_vision_model": QWEN_VISION_MODEL,
        "qwen_coder_model": QWEN_CODER_MODEL,
        "qwen_coder_timeout_seconds": QWEN_CODER_TIMEOUT_SECONDS,
        "qwen_base_url": QWEN_BASE_URL,
        "openrouter_enabled": bool(OPENROUTER_API_KEY),
        "ai_fix_review_mode": AI_FIX_REVIEW_MODE,
        "ai_fix_patch_only": AI_FIX_PATCH_ONLY,
        "ai_fix_model_1": AI_FIX_MODEL_1,
        "ai_fix_model_2": AI_FIX_MODEL_2,
        "ai_fix_model_3": AI_FIX_MODEL_3,
        "ai_fix_extra_models": AI_FIX_EXTRA_MODELS,
        "ai_fix_model_chain": AI_FIX_MODEL_CHAIN,
        "ai_fix_max_model_attempts": AI_FIX_MAX_MODEL_ATTEMPTS,
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


def _login_failure_redis_key(key: str) -> str:
    return _redis_key("login_failures", hashlib.sha256(key.encode("utf-8")).hexdigest())


def _read_login_failure_row(key: str) -> Dict[str, Any]:
    cached = _redis_get_json(_login_failure_redis_key(key))
    if isinstance(cached, dict):
        return cached
    return _login_failures.get(key) or {"attempts": 0, "locked_until": None}


def _write_login_failure_row(key: str, row: Dict[str, Any]) -> None:
    _login_failures[key] = dict(row)
    ttl = max(3600, LOGIN_LOCK_MINUTES * 60 + 300)
    _redis_set_json(_login_failure_redis_key(key), row, ttl)


def _clear_login_failure_row(key: str) -> None:
    _login_failures.pop(key, None)
    _redis_delete(_login_failure_redis_key(key))


def _login_attempt_status(login: str, device_id: str = "") -> Dict[str, Any]:
    key = _login_attempt_key(login, device_id)
    row = _read_login_failure_row(key)
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
        _clear_login_failure_row(key)
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
        _clear_login_failure_row(key)
        return _login_attempt_status(login, device_id)
    row = _read_login_failure_row(key)
    attempts = int(row.get("attempts") or 0) + 1
    locked_until = None
    if attempts >= LOGIN_MAX_FAILED_ATTEMPTS:
        locked_until = datetime.now(timezone.utc) + timedelta(minutes=LOGIN_LOCK_MINUTES)
    _write_login_failure_row(key, {"attempts": attempts, "locked_until": locked_until.isoformat() if locked_until else None})
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


def _password_reset_redis_key(token_hash: str) -> str:
    return _redis_key("password_reset", hashlib.sha256(str(token_hash or "").encode("utf-8")).hexdigest())


def _store_password_reset_token(email: str, token_hash: str, username: str, device_id: str = "") -> None:
    expires = datetime.now(timezone.utc) + timedelta(minutes=PASSWORD_RESET_TTL_MINUTES)
    row = {"email": email, "username": username, "device_id": device_id, "expires_at": expires.isoformat(), "used": False, "token_hash": token_hash}
    _password_reset_tokens[token_hash] = dict(row)
    _redis_set_json(_password_reset_redis_key(token_hash), row, PASSWORD_RESET_TTL_MINUTES * 60)
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
    redis_row = _redis_get_json(_password_reset_redis_key(token_hash))
    row = redis_row if isinstance(redis_row, dict) else _password_reset_tokens.get(token_hash)
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
    _redis_delete(_password_reset_redis_key(token_hash))
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
    language = normalize_language(str((req.data or {}).get("language") or "ar"))
    title = (req.title or _t_push("respect", language)).strip()
    body = (req.body or _t_push("new_notification", language)).strip()
    return send_fcm_v1(req.token, req.type, title, body, _localized_data(req.data, language, title, body))


@app.post("/send_user_push")
def send_user_push(req: UserPushRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_secret(x_app_secret)
    target = get_user_push_target(req.receiverUsername, fallback_language=req.language)
    if not target:
        raise HTTPException(status_code=400, detail="receiver_has_no_fcm_token")
    language = target.get("language", normalize_language(req.language))
    title = (req.title or _t_push("respect", language)).strip()
    body = (req.body or _t_push("new_notification", language)).strip()
    return send_fcm_v1(
        target["token"],
        req.type,
        title,
        body,
        _localized_data(req.data, language, title, body),
    )


def _send_general_push_background(
    *,
    notification_id: str,
    tokens: list[Dict[str, Any]],
    title: str,
    body: str,
    req_data: Dict[str, Any],
    created_at: str,
) -> Dict[str, Any]:
    sent = 0
    failed = 0
    errors = []
    sender_username = display_username(str(req_data.get("senderUsername") or ""))
    sender_name = str(req_data.get("senderName") or "Respect Admin")
    base_data = req_data.get("data") if isinstance(req_data.get("data"), dict) else {}
    language_fallback = str(req_data.get("language") or "ar")

    for item in tokens:
        language = normalize_language(item.get("language") or language_fallback)
        localized_title = title or _t_push("respect", language)
        localized_body = body or _t_push("new_notification", language)
        data = _localized_data({
            **base_data,
            "type": "general_notification",
            "id": notification_id,
            "notificationId": notification_id,
            "title": title,
            "body": body,
            "created_at": created_at,
            "senderUsername": sender_username,
            "senderName": sender_name,
        }, language, localized_title, localized_body)
        try:
            send_fcm_v1(item["token"], "general_notification", localized_title, localized_body, data)
            sent += 1
        except HTTPException as exc:
            failed += 1
            if len(errors) < 10:
                errors.append({"username": item.get("username", ""), "error": exc.detail})
        except Exception as exc:
            failed += 1
            if len(errors) < 10:
                errors.append({"username": item.get("username", ""), "error": str(exc)})
    logger.info("general push finished id=%s total=%s sent=%s failed=%s", notification_id, len(tokens), sent, failed)
    if errors:
        logger.warning("general push errors id=%s sample=%s", notification_id, _safe_response_text(json.dumps(errors, ensure_ascii=False), 1000))
    return {"ok": True, "id": notification_id, "total": len(tokens), "sent": sent, "failed": failed, "errors": errors}


@app.post("/send_general_push")
def send_general_push(req: GeneralPushRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_secret(x_app_secret)
    title = (req.title or "").strip()[:80] or "Respect"
    body = (req.body or "").strip()[:900]
    if not body:
        raise HTTPException(status_code=400, detail="body_required")

    notification_id = create_general_notification_row(title, body, req.senderUsername, req.senderName)
    tokens = get_all_user_fcm_tokens()
    created_at = datetime.now(timezone.utc).isoformat()
    req_data = {
        "data": req.data or {},
        "language": req.language,
        "senderUsername": req.senderUsername,
        "senderName": req.senderName,
    }

    if RESPECT_GENERAL_PUSH_ASYNC:
        job_id = _submit_background_job(
            "general_push",
            _send_general_push_background,
            notification_id=notification_id,
            tokens=tokens,
            title=title,
            body=body,
            req_data=req_data,
            created_at=created_at,
        )
        return {
            "ok": True,
            "id": notification_id,
            "total": len(tokens),
            "queued": True,
            "jobId": job_id,
            "sent": 0,
            "failed": 0,
            "errors": [],
        }

    return _send_general_push_background(
        notification_id=notification_id,
        tokens=tokens,
        title=title,
        body=body,
        req_data=req_data,
        created_at=created_at,
    )


@app.post("/send_message_push")
def send_message_push(req: MessagePushRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_secret(x_app_secret)
    # لا نرسل اسم المرسل أو نص الرسالة عبر FCM.
    target = get_user_push_target(req.receiverUsername, fallback_language=req.language)
    if not target:
        raise HTTPException(status_code=400, detail="receiver_has_no_fcm_token")

    language = target.get("language", normalize_language(req.language))
    title = _t_push("respect", language)
    body = _t_push("new_message", language)

    return send_fcm_v1(
        target["token"],
        "message",
        title,
        body,
        _localized_data({
            "messageId": req.messageId,
            "senderUsername": display_username(req.senderUsername),
            "senderName": "",
            "text": "",
            "peerUsername": display_username(req.senderUsername),
            "peerName": "",
            "privacy": "metadata_only",
        }, language, title, body),
    )


@app.post("/send_call_push")
def send_call_push(req: CallPushRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_secret(x_app_secret)
    target = get_user_push_target(req.receiverUsername, fallback_language=req.language)
    if not target:
        raise HTTPException(status_code=400, detail="receiver_has_no_fcm_token")

    language = target.get("language", normalize_language(req.language))
    title = _t_push("respect", language)
    body = _t_push("incoming_video_call" if req.video else "incoming_audio_call", language)

    return send_fcm_v1(
        target["token"],
        "call",
        title,
        body,
        _localized_data({
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
        }, language, title, body),
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
    if mode in {"chat", "general"}:
        return base + "\n\n" + trend_rule + "\n\nأنت داخل صفحة Respect AI الخاصة. جاوب كدردشة مفيدة وواضحة، واذكر الخطوات فقط عند الحاجة."
    if mode == "coding":
        return base + "\n\n" + trend_rule + "\n\nوضع البرمجة: كن قويًا في Flutter/Dart/FastAPI/Supabase/Firebase. شخّص الخطأ، أعطِ سببًا واضحًا، ثم أعطِ كودًا عمليًا عند الحاجة. لا تعطِ كلامًا عامًا."
    if mode == "file_review":
        return base + "\n\n" + trend_rule + "\n\nوضع فحص الملفات: اقرأ مقتطفات الملفات بعناية، اذكر أهم الملاحظات، الأخطاء، والتحسينات. إذا الملف غير قابل للقراءة قل ذلك بوضوح."
    if mode == "creative":
        return base + "\n\n" + trend_rule + "\n\nوضع الإبداع: أعطِ صياغات جميلة، أفكار قوية، أسلوب تسويقي/تشويقي، مع اختصار ووضوح."
    if mode == "study":
        return base + "\n\n" + trend_rule + "\n\nوضع التعلم: اشرح ببساطة، أعطِ مثالًا قصيرًا، ثم خلاصة."
    if mode == "moderation":
        return base + "\n\n" + trend_rule + "\n\nوضع الحماية: حلل المحتوى من ناحية الإساءات والمخالفات والبلاغات، أعطِ قرارًا واضحًا وسببًا مختصرًا بدون تهويل."
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
    if any(word in t for word in ["كود", "برمجة", "flutter", "dart", "fastapi", "supabase", "firebase", "bug", "error"]):
        return "coding"
    if any(word in t for word in ["ملف", "افحص", "راجع الملف", "file", "review"]):
        return "file_review"
    return "chat" if requested in {"chat", "general"} else "reply"


def _build_user_prompt(
    text: str,
    username: str = "",
    post_text: str = "",
    parent_reply_text: str = "",
    recent_replies_text: str = "",
    conversation_context: str = "",
    file_attachments: Optional[list[Dict[str, Any]]] = None,
    deep_thinking: bool = False,
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

    clean_context = (conversation_context or "").strip()
    if clean_context:
        parts.append(
            "سياق آخر الرسائل في محادثة Respect AI:\n"
            f"{clean_context[:6000]}\n\n"
            "استخدمه لفهم المحادثة فقط، ولا تكرر الكلام القديم إلا إذا احتاج الرد."
        )

    attachments = file_attachments or []
    if attachments:
        file_parts = []
        for item in attachments[:8]:
            if not isinstance(item, dict):
                continue
            name = str(item.get("name") or item.get("fileName") or "file").strip()[:180]
            ftype = str(item.get("type") or item.get("mediaType") or "file").strip()[:40]
            url = str(item.get("url") or item.get("fileUrl") or "").strip()[:500]
            extracted = str(item.get("text") or item.get("content") or item.get("textSnippet") or "").strip()
            block = f"- الملف: {name} | النوع: {ftype}"
            if url:
                block += f" | الرابط: {url}"
            if extracted:
                block += f"\nمقتطف قابل للقراءة من الملف:\n{extracted[:12000]}"
            file_parts.append(block)
        if file_parts:
            parts.append(
                "ملفات أرفقها المستخدم داخل محادثة Respect AI:\n"
                + "\n\n".join(file_parts)
                + "\n\nحلل الملفات بناءً على المقتطفات المتاحة. إذا كان الملف صورة استخدم الصورة المرسلة. إذا كان PDF/ملف ثنائي ولا يوجد مقتطف نصي، وضح أنك تحتاج محتواه النصي أو صورة منه."
            )

    if deep_thinking:
        parts.append(
            "وضع التفكير العميق مفعل: خذ وقتك في التحليل، دقق المنطق، ثم أعطِ الرد النهائي فقط. "
            "يمكنك إضافة قسم قصير بعنوان: ملخص التفكير، يكون عبارة عن نقاط عالية المستوى فقط بدون كشف تفكير داخلي تفصيلي."
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
        # مهم: لا نحول كل أخطاء مزود الذكاء إلى 400.
        # 429 مثلًا تعني Rate Limit، ونحتاج أن يعرف endpoint بلاغات التطبيق أنها مشكلة مؤقتة
        # حتى يحفظ البلاغ بدل أن يفشله بالكامل.
        provider_status = int(response.status_code)
        client_status = provider_status if provider_status in {408, 409, 425, 429, 500, 502, 503, 504} else 400
        raise HTTPException(
            status_code=client_status,
            detail={
                f"{log_label.lower()}_status": provider_status,
                f"{log_label.lower()}_body": response.text,
                "provider_status": provider_status,
                "provider": base_url,
                "model": model,
                "retryable": provider_status in {408, 409, 425, 429, 500, 502, 503, 504},
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
    conversation_context: str = "",
    file_attachments: Optional[list[Dict[str, Any]]] = None,
    deep_thinking: bool = False,
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
                "content": _build_user_prompt(
                    text,
                    username,
                    post_text,
                    parent_reply_text,
                    recent_replies_text,
                    conversation_context=conversation_context,
                    file_attachments=file_attachments,
                    deep_thinking=deep_thinking,
                ),
            },
        ],
        temperature=0.18 if deep_thinking else 0.25,
        max_tokens=900 if deep_thinking else 420,
        timeout=95 if deep_thinking else 60,
        log_label="QWEN",
    )

    if not reply:
        raise HTTPException(status_code=500, detail="Qwen returned empty reply")

    reply = str(reply).replace("@RespectAI", "").replace("@respectai", "").strip()
    if effective_mode.startswith("daily_") and "NO_REPEATED_QUESTION" in reply:
        return "NO_REPEATED_QUESTION"
    max_reply_chars = 2400 if deep_thinking else 1200
    if len(reply) > max_reply_chars:
        reply = reply[:max_reply_chars].rstrip() + "..."
    return reply




def _respect_ai_reply_image_urls(req: RespectAIRequest) -> list[str]:
    urls: list[str] = []
    raw_items = [*(req.imageUrls or []), req.imageUrl]
    for item in (req.fileAttachments or []):
        if not isinstance(item, dict):
            continue
        item_type = str(item.get("type") or item.get("mediaType") or "").strip().lower()
        item_url = str(item.get("url") or item.get("fileUrl") or "").strip()
        if item_type == "image" and item_url:
            raw_items.append(item_url)
    for raw in raw_items:
        url = str(raw or "").strip()
        if not url:
            continue
        if not url.startswith(("http://", "https://", "data:image/")):
            continue
        if url not in urls:
            urls.append(url)
    return urls[:3]


def _respect_ai_question_with_images(text: str, image_urls: list[str]) -> str:
    clean = (text or "").strip() or "حلل هذه الصورة"
    if not image_urls:
        return clean
    # ندخل روابط الصور داخل مفتاح الذاكرة حتى لا يخلط بين سؤال مثل "وش في الصورة؟" على صور مختلفة.
    joined = " | ".join(image_urls[:3])
    return f"{clean}\n[RespectAI image context: {joined}]"


def _respect_ai_reply_video_urls(req: RespectAIRequest) -> list[str]:
    urls: list[str] = []
    raw_items = [*(getattr(req, "videoUrls", []) or []), getattr(req, "videoUrl", "")]
    for item in (req.fileAttachments or []):
        if not isinstance(item, dict):
            continue
        item_type = str(item.get("type") or item.get("mediaType") or "").strip().lower()
        item_url = str(item.get("url") or item.get("fileUrl") or "").strip()
        if item_type == "video" and item_url:
            raw_items.append(item_url)
    for raw in raw_items:
        url = str(raw or "").strip()
        if not url or not url.startswith(("http://", "https://")):
            continue
        if url not in urls:
            urls.append(url)
    return urls[:2]


def _respect_ai_question_with_media(text: str, image_urls: list[str], video_urls: list[str]) -> str:
    clean = (text or "").strip() or ("حلل هذا الفيديو" if video_urls else "حلل هذه الصورة")
    parts = []
    if image_urls:
        parts.append("images=" + " | ".join(image_urls[:3]))
    if video_urls:
        parts.append("videos=" + " | ".join(video_urls[:2]))
    if not parts:
        return clean
    return f"{clean}\n[RespectAI media context: {' ; '.join(parts)}]"


def _media_memory_enabled() -> bool:
    return bool(AI_MEDIA_MEMORY_ENABLED and SB_URL and SB_SERVICE and RESPECT_AI_MEDIA_MEMORY_TABLE)


def _media_memory_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _media_memory_url_hash(url: str) -> str:
    return hashlib.sha256(str(url or "").strip().encode("utf-8")).hexdigest()


def _media_memory_key(kind: str, value: str) -> str:
    return hashlib.sha256(f"{kind}:{value}".encode("utf-8")).hexdigest()


def _media_memory_decode_data_url(data_url: str) -> bytes:
    if not str(data_url or "").startswith("data:"):
        return b""
    try:
        payload = str(data_url).split(",", 1)[1]
        return base64.b64decode(payload, validate=False)
    except Exception:
        return b""


def _media_memory_download_bytes(url: str, *, max_bytes: Optional[int] = None) -> bytes:
    clean = str(url or "").strip()
    if not clean:
        return b""
    if clean.startswith("data:image/"):
        return _media_memory_decode_data_url(clean)[: (max_bytes or AI_MEDIA_MEMORY_MAX_IMAGE_BYTES)]
    if not clean.startswith(("http://", "https://")):
        return b""
    limit = int(max_bytes or AI_MEDIA_MEMORY_MAX_IMAGE_BYTES)
    out = bytearray()
    try:
        with requests.get(clean, stream=True, timeout=(8, 22)) as r:
            if r.status_code >= 400:
                return b""
            for chunk in r.iter_content(chunk_size=1024 * 256):
                if not chunk:
                    continue
                out.extend(chunk)
                if len(out) >= limit:
                    break
        return bytes(out[:limit])
    except Exception as e:
        logger.debug("media_memory download skipped: %s", e)
        return b""


def _media_memory_image_phash_from_bytes(raw: bytes) -> str:
    if not raw:
        return ""
    try:
        import cv2  # type: ignore
        import numpy as np  # type: ignore
        arr = np.frombuffer(raw, dtype=np.uint8)
        img = cv2.imdecode(arr, cv2.IMREAD_GRAYSCALE)
        if img is None:
            return ""
        small = cv2.resize(img, (16, 16), interpolation=cv2.INTER_AREA)
        avg = float(small.mean())
        bits = ["1" if int(v) >= avg else "0" for v in small.flatten()]
        return hex(int("".join(bits), 2))[2:].zfill(64)
    except Exception as e:
        logger.debug("media_memory image phash skipped: %s", e)
        return ""


def _media_memory_image_phash(url: str) -> str:
    return _media_memory_image_phash_from_bytes(_media_memory_download_bytes(url))


def _media_memory_keys_for(media_type: str, url: str) -> list[Dict[str, str]]:
    clean_type = "video" if str(media_type or "").lower() == "video" else "image"
    clean_url = str(url or "").strip()
    if not clean_url:
        return []
    keys: list[Dict[str, str]] = []
    url_hash = _media_memory_url_hash(clean_url)
    if clean_type == "image":
        phash = _media_memory_image_phash(clean_url)
        if phash:
            keys.append({"kind": "image_phash", "value": phash, "key": _media_memory_key("image_phash", phash)})
    # رابط الفيديو/الصورة يبقى كطبقة دقيقة حتى لو فشل phash أو كان الفيديو كبيرًا.
    keys.append({"kind": f"{clean_type}_url", "value": url_hash, "key": _media_memory_key(f"{clean_type}_url", url_hash)})
    seen = set()
    out = []
    for item in keys:
        if item["key"] in seen:
            continue
        seen.add(item["key"])
        out.append(item)
    return out


def _media_memory_rest_get_by_key(media_key: str, purpose: str) -> Optional[Dict[str, Any]]:
    if not _media_memory_enabled() or not media_key:
        return None
    try:
        r = requests.get(
            f"{SB_URL}/rest/v1/{RESPECT_AI_MEDIA_MEMORY_TABLE}",
            headers=_supabase_headers(use_service_role=True),
            params={
                "select": "id,media_key,media_type,key_type,key_value,purpose,decision,category,reason,confidence,hits,ai_hits,memory_hits,ai_summary,ocr_text,source,model,active,updated_at",
                "media_key": f"eq.{media_key}",
                "purpose": f"eq.{purpose}",
                "active": "eq.true",
                "limit": "1",
            },
            timeout=8,
        )
        if r.status_code == 404 or (r.status_code == 400 and "does not exist" in r.text.lower()):
            logger.warning("Media memory table is missing. Run the SQL migration for %s", RESPECT_AI_MEDIA_MEMORY_TABLE)
            return None
        if r.status_code >= 400:
            logger.debug("media_memory lookup failed status=%s body=%s", r.status_code, _safe_response_text(r.text, 250))
            return None
        data = r.json() if r.text else []
        if isinstance(data, list) and data:
            return dict(data[0])
    except Exception as e:
        logger.debug("media_memory lookup exception: %s", e)
    return None


def _media_memory_touch(row: Dict[str, Any]) -> None:
    if not _media_memory_enabled():
        return
    row_id = str(row.get("id") or "").strip()
    if not row_id:
        return
    try:
        payload = {
            "hits": int(float(row.get("hits") or 0)) + 1,
            "memory_hits": int(float(row.get("memory_hits") or 0)) + 1,
            "last_used_at": _media_memory_now(),
            "updated_at": _media_memory_now(),
        }
        requests.patch(
            f"{SB_URL}/rest/v1/{RESPECT_AI_MEDIA_MEMORY_TABLE}",
            headers={**_supabase_headers(use_service_role=True), "Prefer": "return=minimal"},
            params={"id": f"eq.{row_id}"},
            json=payload,
            timeout=6,
        )
    except Exception as e:
        logger.debug("media_memory touch skipped: %s", e)


def _media_memory_moderation_result(row: Dict[str, Any], media_type: str, url: str) -> Dict[str, Any]:
    _media_memory_touch(row)
    decision = str(row.get("decision") or "allow").strip().lower()
    should_delete = decision == "delete"
    category = str(row.get("category") or ("media_violation" if should_delete else "safe"))
    reason = str(row.get("reason") or ("قرار من ذاكرة فهم الوسائط" if should_delete else "وسائط آمنة حسب ذاكرة Respect AI"))
    return {
        "shouldDelete": should_delete,
        "deleteParentReply": False,
        "category": category,
        "reason": reason,
        "confidence": float(row.get("confidence") or (0.93 if should_delete else 0.86)),
        "checks": 1,
        "memoryUsed": True,
        "mediaMemoryUsed": True,
        "moderationMemoryUsed": True,
        "decisionSource": "respect_ai_media_memory",
        "source": "respect_ai_media_memory",
        "model": str(row.get("model") or "respect_ai_media_memory_v1"),
        "memoryId": str(row.get("id") or ""),
        "mediaType": media_type,
        "mediaUrl": url,
        "ocrText": str(row.get("ocr_text") or ""),
        "aiSummary": str(row.get("ai_summary") or ""),
    }


def _media_memory_lookup_moderation(media_type: str, url: str) -> Optional[Dict[str, Any]]:
    for item in _media_memory_keys_for(media_type, url):
        row = _media_memory_rest_get_by_key(item.get("key", ""), "moderation")
        if not row:
            continue
        decision = str(row.get("decision") or "").strip().lower()
        confidence = float(row.get("confidence") or 0.0)
        if decision == "delete" and confidence >= AI_MEDIA_MEMORY_DELETE_MIN_CONFIDENCE:
            return _media_memory_moderation_result(row, media_type, url)
        if decision == "allow" and confidence >= AI_MEDIA_MEMORY_ALLOW_MIN_CONFIDENCE:
            return _media_memory_moderation_result(row, media_type, url)
    return None


def _media_memory_lookup_summary(media_type: str, url: str) -> Optional[Dict[str, Any]]:
    for item in _media_memory_keys_for(media_type, url):
        row = _media_memory_rest_get_by_key(item.get("key", ""), "understanding")
        if not row:
            continue
        if float(row.get("confidence") or 0.0) >= AI_MEDIA_MEMORY_QA_MIN_CONFIDENCE:
            _media_memory_touch(row)
            return row
    return None


def _media_memory_extract_summary(result: Dict[str, Any], fallback: str = "") -> str:
    values = []
    for key in ("aiSummary", "summary", "description", "reason", "ocrText"):
        v = str(result.get(key) or "").strip()
        if v:
            values.append(v)
    if not values and fallback:
        values.append(str(fallback).strip())
    text = "\n".join(dict.fromkeys(values)).strip()
    return text[:AI_MEDIA_MEMORY_QA_SUMMARY_MAX_CHARS]


def _media_memory_upsert(payload: Dict[str, Any]) -> Dict[str, Any]:
    if not _media_memory_enabled():
        return {"ok": False, "reason": "disabled_or_missing_service_role"}
    media_key = str(payload.get("media_key") or "").strip()
    purpose = str(payload.get("purpose") or "moderation").strip().lower()
    if not media_key:
        return {"ok": False, "reason": "missing_media_key"}
    headers = _supabase_headers(use_service_role=True)
    now = _media_memory_now()
    try:
        r = requests.get(
            f"{SB_URL}/rest/v1/{RESPECT_AI_MEDIA_MEMORY_TABLE}",
            headers=headers,
            params={"select": "id,hits,ai_hits,confidence", "media_key": f"eq.{media_key}", "purpose": f"eq.{purpose}", "limit": "1"},
            timeout=8,
        )
        if r.status_code == 404 or (r.status_code == 400 and "does not exist" in r.text.lower()):
            return {"ok": False, "reason": "table_missing"}
        rows = r.json() if r.status_code < 400 and r.text else []
        existing = dict(rows[0]) if isinstance(rows, list) and rows else None
        clean_payload = dict(payload)
        clean_payload["updated_at"] = now
        clean_payload.setdefault("active", True)
        clean_payload.setdefault("hits", 1)
        clean_payload.setdefault("ai_hits", 1)
        clean_payload.setdefault("memory_hits", 0)
        if existing:
            row_id = str(existing.get("id") or "")
            # مهم: عند التعلم من Qwen نزيد ai_hits، لكن لا نعيد تصفير memory_hits.
            # سابقًا كان clean_payload يحتوي memory_hits=0 فيمسح عدّاد استخدام الذاكرة بعد كل تكرار.
            clean_payload.pop("memory_hits", None)
            clean_payload["hits"] = int(float(existing.get("hits") or 0)) + 1
            clean_payload["ai_hits"] = int(float(existing.get("ai_hits") or 0)) + 1
            clean_payload["confidence"] = max(float(existing.get("confidence") or 0.0), float(clean_payload.get("confidence") or 0.0))
            rr = requests.patch(
                f"{SB_URL}/rest/v1/{RESPECT_AI_MEDIA_MEMORY_TABLE}",
                headers={**headers, "Prefer": "return=minimal"},
                params={"id": f"eq.{row_id}"},
                json=clean_payload,
                timeout=8,
            )
            if rr.status_code >= 400:
                return {"ok": False, "status": rr.status_code, "body": rr.text[:300]}
            return {"ok": True, "updated": True, "mediaKey": media_key, "purpose": purpose}
        clean_payload.setdefault("created_at", now)
        rr = requests.post(
            f"{SB_URL}/rest/v1/{RESPECT_AI_MEDIA_MEMORY_TABLE}",
            headers={**headers, "Prefer": "return=minimal"},
            json=clean_payload,
            timeout=8,
        )
        if rr.status_code >= 400:
            return {"ok": False, "status": rr.status_code, "body": rr.text[:300]}
        return {"ok": True, "inserted": True, "mediaKey": media_key, "purpose": purpose}
    except Exception as e:
        logger.debug("media_memory upsert exception: %s", e)
        return {"ok": False, "error": str(e)[:250]}


def _media_memory_learn_moderation(media_type: str, url: str, result: Dict[str, Any], *, source: str = "vision_moderation") -> Dict[str, Any]:
    try:
        should_delete = bool(result.get("shouldDelete") is True or result.get("delete") is True or result.get("blocked") is True)
        confidence = max(0.0, min(1.0, float(result.get("confidence") or (0.91 if should_delete else 0.84))))
        if should_delete and confidence < AI_MEDIA_MEMORY_DELETE_MIN_CONFIDENCE:
            return {"learned": False, "reason": "delete_confidence_too_low"}
        if not should_delete and confidence < AI_MEDIA_MEMORY_ALLOW_MIN_CONFIDENCE:
            return {"learned": False, "reason": "allow_confidence_too_low"}
        keys = _media_memory_keys_for(media_type, url)
        if not keys:
            return {"learned": False, "reason": "no_media_key"}
        now = _media_memory_now()
        category = str(result.get("category") or ("media_violation" if should_delete else "safe"))[:80]
        reason = str(result.get("reason") or "")[:900]
        ocr_text = str(result.get("ocrText") or result.get("ocr_text") or "")[:1200]
        summary = _media_memory_extract_summary(result, fallback=reason or ocr_text)
        rows = []
        for item in keys:
            rows.append({
                "media_key": item["key"],
                "media_type": "video" if str(media_type).lower() == "video" else "image",
                "key_type": item["kind"],
                "key_value": item["value"][:260],
                "url_hash": _media_memory_url_hash(url),
                "purpose": "moderation",
                "decision": "delete" if should_delete else "allow",
                "category": category,
                "reason": reason,
                "confidence": confidence,
                "ai_summary": summary,
                "ocr_text": ocr_text,
                "sample_text": summary[:900],
                "source": source,
                "model": str(result.get("visionModel") or result.get("model") or QWEN_VISION_MODEL)[:120],
                "active": True,
                "created_at": now,
                "updated_at": now,
            })
        results = [_media_memory_upsert(row) for row in rows]
        ok = [x for x in results if x.get("ok") is True]
        return {"learned": bool(ok), "count": len(ok), "results": results[:4], "table": RESPECT_AI_MEDIA_MEMORY_TABLE}
    except Exception as e:
        return {"learned": False, "reason": "exception", "error": str(e)[:250]}


def _media_memory_learn_understanding(media_type: str, url: str, *, question: str, reply: str, source: str = "respect_ai_reply") -> Dict[str, Any]:
    try:
        clean_reply = str(reply or "").strip()
        if not clean_reply:
            return {"learned": False, "reason": "empty_reply"}
        keys = _media_memory_keys_for(media_type, url)
        if not keys:
            return {"learned": False, "reason": "no_media_key"}
        summary = clean_reply[:AI_MEDIA_MEMORY_QA_SUMMARY_MAX_CHARS]
        confidence = 0.72 if len(summary) >= 80 else 0.58
        now = _media_memory_now()
        rows = []
        for item in keys:
            rows.append({
                "media_key": item["key"],
                "media_type": "video" if str(media_type).lower() == "video" else "image",
                "key_type": item["kind"],
                "key_value": item["value"][:260],
                "url_hash": _media_memory_url_hash(url),
                "purpose": "understanding",
                "decision": "understand",
                "category": _qa_memory_category(question, "chat")[:80],
                "reason": "فهم وسائط تعلمه Respect AI من محادثة سابقة",
                "confidence": confidence,
                "ai_summary": summary,
                "ocr_text": "",
                "sample_text": str(question or "")[:900],
                "source": source,
                "model": QWEN_VISION_MODEL,
                "active": True,
                "created_at": now,
                "updated_at": now,
            })
        results = [_media_memory_upsert(row) for row in rows]
        ok = [x for x in results if x.get("ok") is True]
        return {"learned": bool(ok), "count": len(ok), "results": results[:4], "table": RESPECT_AI_MEDIA_MEMORY_TABLE}
    except Exception as e:
        return {"learned": False, "reason": "exception", "error": str(e)[:250]}


def _respect_ai_cached_media_context_details(image_urls: list[str], video_urls: list[str]) -> tuple[str, bool, bool, str, float]:
    """يرجع سياق الوسائط المحفوظ + هل استُخدمت الذاكرة + هل كل الوسائط مغطاة.

    الفرق مهم جدًا:
    - any_used: وجدنا ذاكرة لوسيط واحد على الأقل.
    - all_covered: كل الصور/الفيديوهات المرفقة لها ذاكرة صالحة، وهنا نستطيع تجنب Qwen Vision بالكامل.
    """
    lines: list[str] = []
    memory_ids: list[str] = []
    confidence_values: list[float] = []
    checked = 0
    covered = 0

    for i, url in enumerate(image_urls[:3], start=1):
        checked += 1
        row = _media_memory_lookup_summary("image", url) or _media_memory_lookup_moderation("image", url)
        if not row:
            continue
        if isinstance(row, dict) and row.get("mediaMemoryUsed"):
            summary = str(row.get("aiSummary") or row.get("reason") or "")
            memory_id = str(row.get("memoryId") or row.get("id") or "")
        else:
            summary = str(row.get("ai_summary") or row.get("reason") or "")
            memory_id = str(row.get("id") or "")
        if summary.strip():
            covered += 1
            lines.append(f"ملخص الصورة {i} من ذاكرة Respect AI: {summary.strip()[:900]}")
            if memory_id and memory_id not in memory_ids:
                memory_ids.append(memory_id)
            try:
                confidence_values.append(float(row.get("confidence") or 0.0))
            except Exception:
                pass

    for i, url in enumerate(video_urls[:2], start=1):
        checked += 1
        row = _media_memory_lookup_summary("video", url) or _media_memory_lookup_moderation("video", url)
        if not row:
            continue
        if isinstance(row, dict) and row.get("mediaMemoryUsed"):
            summary = str(row.get("aiSummary") or row.get("reason") or "")
            memory_id = str(row.get("memoryId") or row.get("id") or "")
        else:
            summary = str(row.get("ai_summary") or row.get("reason") or "")
            memory_id = str(row.get("id") or "")
        if summary.strip():
            covered += 1
            lines.append(f"ملخص الفيديو {i} من ذاكرة Respect AI: {summary.strip()[:1200]}")
            if memory_id and memory_id not in memory_ids:
                memory_ids.append(memory_id)
            try:
                confidence_values.append(float(row.get("confidence") or 0.0))
            except Exception:
                pass

    any_used = covered > 0
    all_covered = checked > 0 and covered == checked
    confidence = max(confidence_values) if confidence_values else 0.0
    return "\n".join(lines), any_used, all_covered, ",".join(memory_ids[:6]), confidence


def _respect_ai_cached_media_context(image_urls: list[str], video_urls: list[str]) -> tuple[str, bool]:
    context, any_used, _all_covered, _memory_id, _confidence = _respect_ai_cached_media_context_details(image_urls, video_urls)
    return context, any_used

def _respect_ai_video_frame_parts(video_urls: list[str], *, max_frames_per_video: int = 4) -> list[Dict[str, Any]]:
    parts: list[Dict[str, Any]] = []
    for video_index, url in enumerate(video_urls[:2], start=1):
        try:
            frames = _extract_video_frame_data_urls(url, max_frames=max(2, min(max_frames_per_video, 6)))
            for frame in frames[:max_frames_per_video]:
                second = frame.get("second")
                parts.append({"type": "text", "text": f"لقطة من الفيديو رقم {video_index} عند الثانية {second}:"})
                parts.append({"type": "image_url", "image_url": {"url": str(frame.get("dataUrl") or "")}})
        except Exception as e:
            parts.append({"type": "text", "text": f"تعذر استخراج لقطات الفيديو رقم {video_index} مؤقتًا: {e}"})
    return parts


def ask_qwen_ai_multimodal(
    text: str,
    username: str = "",
    mode: str = "chat",
    post_text: str = "",
    parent_reply_text: str = "",
    recent_replies_text: str = "",
    image_urls: Optional[list[str]] = None,
    video_urls: Optional[list[str]] = None,
    conversation_context: str = "",
    file_attachments: Optional[list[Dict[str, Any]]] = None,
    deep_thinking: bool = False,
) -> str:
    urls = [str(u or "").strip() for u in (image_urls or []) if str(u or "").strip()]
    vurls = [str(u or "").strip() for u in (video_urls or []) if str(u or "").strip()]
    cached_context, media_memory_used, media_memory_all_covered, _media_memory_id, _media_memory_confidence = _respect_ai_cached_media_context_details(urls, vurls)
    if not urls and not vurls:
        return ask_qwen_ai(
            text=text,
            username=username,
            mode=mode,
            post_text=post_text,
            parent_reply_text=parent_reply_text,
            recent_replies_text=recent_replies_text,
            conversation_context=conversation_context,
            file_attachments=file_attachments,
            deep_thinking=deep_thinking,
        )
    # لا نستدعي Qwen Vision إذا كانت كل الصور/الفيديوهات مفهومة سابقًا في ذاكرة الوسائط.
    # نستخدم Qwen النصي فقط لصياغة جواب حسب سؤال المستخدم، مع سياق الوسائط المحفوظ.
    if media_memory_all_covered and cached_context and not deep_thinking:
        return ask_qwen_ai(
            text=f"{text}\n\nسياق وسائط محفوظ من ذاكرة Respect AI:\n{cached_context}",
            username=username,
            mode=mode,
            post_text=post_text,
            parent_reply_text=parent_reply_text,
            recent_replies_text=recent_replies_text,
            conversation_context=conversation_context,
            file_attachments=file_attachments,
            deep_thinking=deep_thinking,
        )
    if not QWEN_API_KEY:
        raise HTTPException(status_code=500, detail="QWEN_API_KEY missing")

    effective_mode = _auto_detect_mode(mode, text)
    prompt_text = _build_user_prompt(
        (text or "").strip() or "حلل هذه الصورة ورد باختصار.",
        username,
        post_text,
        parent_reply_text,
        recent_replies_text,
        conversation_context=conversation_context,
        file_attachments=file_attachments,
        deep_thinking=deep_thinking,
    )
    prompt_text += (
        "\n\nالمستخدم أرفق صورة أو أكثر. حلل الصورة بدقة، وإذا كان السؤال عن محتوى الصورة فأجب بناءً عليها. "
        "إذا لم تستطع معرفة شيء من الصورة قل ذلك بوضوح بدون اختلاق."
    )

    content_parts: list[Dict[str, Any]] = [{"type": "text", "text": prompt_text}]
    for url in urls[:3]:
        content_parts.append({"type": "image_url", "image_url": {"url": url}})

    reply = _chat_completion_request(
        model=QWEN_VISION_MODEL,
        api_key=QWEN_API_KEY,
        base_url=QWEN_BASE_URL,
        messages=[
            {"role": "system", "content": _respect_ai_system_prompt(effective_mode)},
            {"role": "user", "content": content_parts},
        ],
        temperature=0.15 if deep_thinking else 0.20,
        max_tokens=1100 if deep_thinking else 620,
        timeout=120 if deep_thinking else 90,
        log_label="QWEN_VISION_REPLY",
    )

    if not reply:
        raise HTTPException(status_code=500, detail="Qwen vision returned empty reply")
    reply = str(reply).replace("@RespectAI", "").replace("@respectai", "").strip()
    max_reply_chars = 2600 if deep_thinking else 1400
    if len(reply) > max_reply_chars:
        reply = reply[:max_reply_chars].rstrip() + "..."
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







# ================= Respect AI Q&A Reply Memory Helpers =================
def _qa_memory_enabled() -> bool:
    return bool(RESPECT_AI_QA_MEMORY_ENABLED and SB_URL and (SB_SERVICE or SB_ANON))


def _qa_memory_clean_question(value: str) -> str:
    text = str(value or "").strip()
    text = re.sub(r"(?i)@?respect\s*ai|@respectai|@respect_ai|ريسبكت\s*ai|رسبكت\s*اي", " ", text)
    text = _normalize_arabic_for_moderation(text)
    text = re.sub(r"[\u200b-\u200f\u202a-\u202e\ufeff]", "", text)
    text = re.sub(r"https?://\S+|www\.\S+", " ", text, flags=re.IGNORECASE)
    text = re.sub(r"[^0-9a-zA-Z\u0600-\u06FF\s؟?]+", " ", text)
    text = re.sub(r"(.)\1{2,}", r"\1\1", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text[:RESPECT_AI_QA_MEMORY_MAX_QUESTION_CHARS]


def _qa_memory_context_text(post_text: str = "", parent_reply_text: str = "", recent_replies_text: str = "") -> str:
    parts = [
        str(post_text or "").strip(),
        str(parent_reply_text or "").strip(),
        str(recent_replies_text or "").strip(),
    ]
    clean = "\n".join(p for p in parts if p)
    clean = re.sub(r"\s+", " ", clean).strip()
    return clean[:1500]


def _qa_memory_context_hash(post_text: str = "", parent_reply_text: str = "", recent_replies_text: str = "") -> str:
    context = _qa_memory_context_text(post_text, parent_reply_text, recent_replies_text)
    if not context:
        return "global"
    normalized = _qa_memory_clean_question(context)
    return hashlib.sha256(normalized.encode("utf-8")).hexdigest() if normalized else "global"


def _qa_memory_hash(normalized_question: str, mode: str, context_hash: str) -> str:
    base = f"{mode or 'reply'}|{context_hash or 'global'}|{normalized_question}"
    return hashlib.sha256(base.encode("utf-8")).hexdigest()


def _qa_memory_category(question: str, mode: str = "reply") -> str:
    q = _qa_memory_clean_question(question)
    m = (mode or "reply").strip().lower()
    if m.startswith("daily_"):
        return "daily"
    if any(x in q for x in ["كود", "برمجه", "برمجة", "flutter", "dart", "python", "sql", "supabase", "fastapi"]):
        return "programming"
    if any(x in q for x in ["اشرح", "شرح", "ماهو", "ما هو", "كيف", "ليش", "لماذا"]):
        return "question"
    if any(x in q for x in ["لخص", "تلخيص", "اختصر"]):
        return "summary"
    return "general"


def _qa_memory_has_fresh_or_sensitive_topic(question: str, answer: str = "") -> bool:
    text = _qa_memory_clean_question(f"{question} {answer}")
    if not text:
        return True
    fresh_terms = {
        "الان", "حاليا", "اليوم", "امس", "بكره", "غدا", "اخر", "آخر", "اخبار", "خبر", "ترند",
        "سعر", "اسعار", "بورصه", "بورصة", "سهم", "اسهم", "عملة", "دولار", "طقس", "مباراه", "مباراة",
        "نتيجه", "نتيجة", "رئيس", "وزير", "انتخابات", "قانون", "رسوم", "موعد", "جدول",
        "today", "now", "latest", "news", "price", "weather", "stock", "crypto", "election", "president",
    }
    sensitive_terms = {
        "كلمه المرور", "كلمة المرور", "باسورد", "رمز التحقق", "otp", "token", "api key", "secret",
        "ايميلي", "ايميل", "رقمي", "عنواني", "بطاقتي", "حسابي", "خصوصي", "private", "password",
    }
    medical_legal_terms = {
        "تشخيص", "دواء", "علاج", "محكمه", "محكمة", "قضيه", "قضية", "فتوى", "حلال", "حرام",
        "diagnosis", "medicine", "lawyer", "court", "legal",
    }

    # لا نحفظ الأسرار الواضحة حتى مع وضع التعلم الكامل، حماية للمستخدمين.
    if any(term in text for term in sensitive_terms):
        return True
    if not RESPECT_AI_QA_MEMORY_ALLOW_FRESH_TOPICS and any(term in text for term in fresh_terms):
        return True
    if not RESPECT_AI_QA_MEMORY_ALLOW_MEDICAL_LEGAL and any(term in text for term in medical_legal_terms):
        return True
    return False


def _qa_memory_is_cacheable(question: str, answer: str = "", mode: str = "reply") -> bool:
    q = _qa_memory_clean_question(question)
    a = str(answer or "").strip()
    m = (mode or "reply").strip().lower()
    if not _qa_memory_enabled():
        return False

    # الوضع الجديد: يتعلم أي سؤال/تحية/كلام قصير، بدل فلترة الأسئلة العامة.
    if not RESPECT_AI_QA_MEMORY_LEARN_EVERYTHING:
        if m.startswith("daily_") or m in {"poll", "daily_poll", "daily_question", "daily_info"}:
            return False

    if len(q) < RESPECT_AI_QA_MEMORY_MIN_QUESTION_CHARS:
        return False
    if len(q) > RESPECT_AI_QA_MEMORY_MAX_QUESTION_CHARS:
        return False
    if answer is not None:
        if len(a) < 1 or len(a) > RESPECT_AI_QA_MEMORY_MAX_ANSWER_CHARS:
            return False
        if "NO_REPEATED_QUESTION" in a:
            return False
    if _qa_memory_has_fresh_or_sensitive_topic(q, a):
        return False
    return True


def _qa_memory_confidence(question: str, answer: str, context_hash: str) -> float:
    q = _qa_memory_clean_question(question)
    a = str(answer or "").strip()
    score = 0.80
    if len(q) >= 18:
        score += 0.04
    if len(a) >= 25:
        score += 0.04
    if context_hash and context_hash != "global":
        score += 0.03
    return round(min(0.93, max(0.70, score)), 3)


def _qa_memory_rest_get(params: Dict[str, str], *, limit: int = 1) -> list[Dict[str, Any]]:
    if not _qa_memory_enabled():
        return []
    try:
        q = dict(params or {})
        if _qa_memory_uses_unified_table() and "memory_scope" not in q:
            q["memory_scope"] = "eq.qa"
        if limit:
            q["limit"] = str(limit)
        r = requests.get(
            f"{SB_URL}/rest/v1/{RESPECT_AI_QA_MEMORY_TABLE}",
            headers=_supabase_headers(use_service_role=True),
            params=q,
            timeout=8,
        )
        if r.status_code >= 400:
            logger.warning("qa_memory read skipped status=%s body=%s", r.status_code, _safe_response_text(r.text, 300))
            return []
        data = r.json()
        return data if isinstance(data, list) else []
    except Exception as e:
        logger.warning("qa_memory read exception: %s", e)
        return []

def _qa_memory_touch(row: Dict[str, Any], *, memory_hit: bool = True, ai_hit: bool = False) -> None:
    try:
        row_id = str(row.get("id") or "").strip()
        if not row_id:
            return
        payload = {
            "hits": int(row.get("hits") or 0) + 1,
            "memory_hits": int(row.get("memory_hits") or 0) + (1 if memory_hit else 0),
            "ai_hits": int(row.get("ai_hits") or 0) + (1 if ai_hit else 0),
            "last_used_at": datetime.now(timezone.utc).isoformat(),
            "updated_at": datetime.now(timezone.utc).isoformat(),
        }
        if _qa_memory_uses_unified_table():
            payload["memory_scope"] = "qa"
        requests.patch(
            f"{SB_URL}/rest/v1/{RESPECT_AI_QA_MEMORY_TABLE}",
            headers={**_supabase_headers(use_service_role=True), "Prefer": "return=minimal"},
            params={"id": f"eq.{row_id}"},
            json=payload,
            timeout=8,
        )
    except Exception as e:
        logger.debug("qa_memory touch skipped: %s", e)


def _qa_memory_similarity(a: str, b: str) -> float:
    a = _qa_memory_clean_question(a)
    b = _qa_memory_clean_question(b)
    if not a or not b:
        return 0.0
    if a == b:
        return 1.0
    ratio = SequenceMatcher(None, a, b).ratio()
    at = set(a.split())
    bt = set(b.split())
    token_ratio = (len(at & bt) / max(1, len(at | bt))) if at and bt else 0.0
    return max(ratio, token_ratio)


def _qa_memory_row_to_reply(row: Dict[str, Any], *, match_score: float) -> Dict[str, Any]:
    _qa_memory_touch(row, memory_hit=True, ai_hit=False)
    return {
        "reply": str(row.get("answer") or "").strip(),
        "model": str(row.get("model") or "respect_ai_qa_memory_v1"),
        "memoryUsed": True,
        "memoryId": str(row.get("id") or ""),
        "source": "qa_memory",
        "confidence": float(row.get("confidence") or match_score or 0.0),
        "category": str(row.get("category") or "general"),
        "matchScore": float(match_score or 0.0),
    }


def _qa_memory_lookup(
    question: str,
    *,
    mode: str = "reply",
    post_text: str = "",
    parent_reply_text: str = "",
    recent_replies_text: str = "",
) -> Optional[Dict[str, Any]]:
    if not _qa_memory_is_cacheable(question, answer="cached", mode=mode):
        return None

    normalized = _qa_memory_clean_question(question)
    context_hash = _qa_memory_context_hash(post_text, parent_reply_text, recent_replies_text)
    safe_mode = (mode or "reply").strip().lower() or "reply"
    q_hash = _qa_memory_hash(normalized, safe_mode, context_hash)

    select_cols = "id,question_hash,normalized_question,answer,category,confidence,hits,ai_hits,memory_hits,source,model,active,approved,context_hash,mode"
    exact_rows = _qa_memory_rest_get(
        {
            "select": select_cols,
            "question_hash": f"eq.{q_hash}",
            "active": "eq.true",
            "limit": "1",
        },
        limit=1,
    )
    for row in exact_rows:
        if row.get("approved") is False:
            continue
        answer = str(row.get("answer") or "").strip()
        confidence = float(row.get("confidence") or 0.0)
        if answer and confidence >= RESPECT_AI_QA_MEMORY_MIN_CONFIDENCE:
            return _qa_memory_row_to_reply(row, match_score=1.0)

    # التشابه العام فقط بدون سياق حتى لا نستخدم جواب منشور في منشور مختلف.
    if context_hash != "global":
        return None

    rows = _qa_memory_rest_get(
        {
            "select": select_cols,
            "context_hash": "eq.global",
            "mode": f"eq.{safe_mode}",
            "active": "eq.true",
            "approved": "eq.true",
            "order": "hits.desc,updated_at.desc",
        },
        limit=RESPECT_AI_QA_MEMORY_SIMILAR_SCAN_LIMIT,
    )
    best: Optional[Dict[str, Any]] = None
    best_score = 0.0
    for row in rows:
        answer = str(row.get("answer") or "").strip()
        confidence = float(row.get("confidence") or 0.0)
        if not answer or confidence < RESPECT_AI_QA_MEMORY_MIN_CONFIDENCE:
            continue
        score = _qa_memory_similarity(normalized, str(row.get("normalized_question") or ""))
        if score > best_score:
            best = row
            best_score = score

    if best is not None and best_score >= RESPECT_AI_QA_MEMORY_MATCH_THRESHOLD:
        return _qa_memory_row_to_reply(best, match_score=best_score)
    return None


def _qa_memory_learn(
    question: str,
    answer: str,
    *,
    mode: str = "reply",
    username: str = "",
    post_text: str = "",
    parent_reply_text: str = "",
    recent_replies_text: str = "",
    model: str = "",
) -> Dict[str, Any]:
    if not _qa_memory_is_cacheable(question, answer=answer, mode=mode):
        return {"ok": False, "learned": False, "reason": "not_cacheable"}

    normalized = _qa_memory_clean_question(question)
    safe_mode = (mode or "reply").strip().lower() or "reply"
    context_hash = _qa_memory_context_hash(post_text, parent_reply_text, recent_replies_text)
    q_hash = _qa_memory_hash(normalized, safe_mode, context_hash)
    now = datetime.now(timezone.utc).isoformat()

    existing = _qa_memory_rest_get(
        {"select": "id,hits,ai_hits,memory_hits,confidence", "question_hash": f"eq.{q_hash}", "limit": "1"},
        limit=1,
    )
    confidence = _qa_memory_confidence(normalized, answer, context_hash)
    sample_question = re.sub(r"\s+", " ", str(question or "").strip())[:RESPECT_AI_QA_MEMORY_MAX_QUESTION_CHARS]
    clean_answer = str(answer or "").strip()[:RESPECT_AI_QA_MEMORY_MAX_ANSWER_CHARS]

    if existing:
        row = existing[0]
        row_id = str(row.get("id") or "")
        payload = _qa_memory_apply_scope({
            "answer": clean_answer,
            "confidence": max(float(row.get("confidence") or 0.0), confidence),
            "hits": int(row.get("hits") or 0) + 1,
            "ai_hits": int(row.get("ai_hits") or 0) + 1,
            "sample_question": sample_question,
            "sample_username": _display_username(username),
            "model": model or QWEN_MODEL,
            "source": "respect_ai",
            "active": True,
            "updated_at": now,
        })
        try:
            r = requests.patch(
                f"{SB_URL}/rest/v1/{RESPECT_AI_QA_MEMORY_TABLE}",
                headers={**_supabase_headers(use_service_role=True), "Prefer": "return=representation"},
                params={"id": f"eq.{row_id}"},
                json=payload,
                timeout=10,
            )
            if r.status_code >= 400:
                logger.warning("qa_memory patch failed status=%s body=%s", r.status_code, _safe_response_text(r.text, 300))
                return {"ok": False, "learned": False, "reason": "patch_failed", "status": r.status_code}
            return {"ok": True, "learned": True, "updated": True, "memoryId": row_id}
        except Exception as e:
            logger.warning("qa_memory patch exception: %s", e)
            return {"ok": False, "learned": False, "reason": "patch_exception"}

    payload = _qa_memory_apply_scope({
        "question_hash": q_hash,
        "normalized_question": normalized,
        "sample_question": sample_question,
        "answer": clean_answer,
        "category": _qa_memory_category(normalized, safe_mode),
        "mode": safe_mode,
        "context_hash": context_hash,
        "confidence": confidence,
        "hits": 1,
        "ai_hits": 1,
        "memory_hits": 0,
        "approved": bool(RESPECT_AI_QA_MEMORY_AUTO_APPROVE),
        "active": True,
        "source": "respect_ai",
        "model": model or QWEN_MODEL,
        "sample_username": _display_username(username),
        "created_at": now,
        "updated_at": now,
        "last_used_at": now,
    })
    try:
        r = requests.post(
            f"{SB_URL}/rest/v1/{RESPECT_AI_QA_MEMORY_TABLE}",
            headers={**_supabase_headers(use_service_role=True), "Prefer": "return=representation"},
            json=payload,
            timeout=10,
        )
        if r.status_code >= 400:
            logger.warning("qa_memory insert failed status=%s body=%s", r.status_code, _safe_response_text(r.text, 300))
            return {"ok": False, "learned": False, "reason": "insert_failed", "status": r.status_code}
        data = r.json()
        row = data[0] if isinstance(data, list) and data else {}
        return {"ok": True, "learned": True, "inserted": True, "memoryId": str(row.get("id") or "")}
    except Exception as e:
        logger.warning("qa_memory insert exception: %s", e)
        return {"ok": False, "learned": False, "reason": "insert_exception"}

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
    ترجع matchedTerm/matchedTerms حتى تتعلم الذاكرة الكلمة المسيئة فورًا وليس الجملة فقط.
    """
    if not (text or "").strip():
        return None

    n = _normalize_obfuscated_text_for_moderation(text)
    spaced = n["spaced_collapsed"]
    compact = n["compact"]
    tokens = set(spaced.split())

    def hit_word(words: list[str]) -> Optional[str]:
        normalized_words: list[tuple[str, str]] = []
        for original in words:
            normalized = _normalize_obfuscated_text_for_moderation(original)["compact"]
            if normalized:
                normalized_words.append((str(original), normalized))

        for original, w in normalized_words:
            # الكلمات القصيرة جدًا نفحصها كتوكن مستقل أو كتمويه واضح داخل compact.
            if len(w) <= 2:
                if w in tokens:
                    return original
                # يسمح بكشف: ك.س أو ك س أو كسسس، بدون أن نحذف كلمات طبيعية مثل كسر/كأس.
                if re.search(rf"(^|[^ء-يa-zA-Z0-9]){re.escape(w)}($|[^ء-يa-zA-Z0-9])", spaced):
                    return original
                # كشف التمويه بحرفين مفصولين: ك.س / ك س / ز-ب ... بدون حذف كلمات طبيعية مثل كسر.
                if len(w) == 2 and re.search(rf"(^|\s){re.escape(w[0])}\s+{re.escape(w[1])}(\s|$)", spaced):
                    return original
                if compact == w or compact.startswith(w + "سري") or compact.endswith(w):
                    return original
            else:
                if w in tokens or w in compact:
                    return original
        return None

    def result(category: str, reason: str, confidence: float, matched: str) -> Dict[str, Any]:
        clean_match = _safe_term_phrase(matched or "", 120)
        return {
            "shouldDelete": True,
            "deleteParentReply": False,
            "category": category,
            "reason": reason,
            "confidence": confidence,
            "checks": 1,
            "local_guard": True,
            "normalizedText": spaced,
            "matchedTerm": clean_match,
            "matchedTerms": [clean_match] if clean_match else [],
        }

    # تهديدات وتحريض واضح.
    threat_terms = ["اقتلوه", "اقتلو", "اقتله", "انتحر", "يموت", "موتوا", "اذبحه", "ذبح", "kill yourself", "i will kill"]
    hit = hit_word(threat_terms)
    if hit:
        return result(
            "threat",
            "تهديد أو تحريض واضح تم كشفه بعد تطبيع النص",
            0.98,
            hit,
        )

    # ألفاظ جنسية/فاحشة مباشرة. وجودها في سؤال RP لا يجعلها آمنة.
    sexual_terms = [
        "كس", "زب", "زبي", "زبك", "زبه", "زبها", "نيك", "منيوك", "منيوكة", "شرموط", "شرموطة", "قحبة", "قحبه",
        "طيز", "طيزي", "طيزك", "طيزه", "طيزها", "طيزهم", "ممحون", "ممحونة", "مص", "لحس", "fuck", "bitch", "pussy", "dick",
    ]
    hit = hit_word(sexual_terms)
    if hit:
        return result(
            "sexual_profanity",
            "لفظ جنسي/فاحش مباشر داخل النص حتى لو كان ضمن سياق لعبة أو مكتوبًا بتمويه",
            0.99,
            hit,
        )

    # سب مباشر وإهانات واضحة.
    insult_terms = ["كلب", "حمار", "خنزير", "حقير", "وسخ", "زباله", "غبي", "اغبياء", "خرا", "زق", "asshole"]
    addressed = bool(re.search(r"(^|\s)(يا|انت|انتي|انتم|انتو|ياعيال|يا\s+عيال|لك|لها|له)($|\s)", spaced))
    hit = hit_word(insult_terms)
    if addressed and hit:
        return result(
            "insult",
            "سب أو إهانة مباشرة موجهة داخل النص وتم كشفها بعد التطبيع",
            0.97,
            hit,
        )

    # إساءة دينية واضحة.
    religion_patterns = [r"سب\s*الدين", r"سب\s*الله", r"اهان[هة]\s*الدين", r"لعن\s*الدين"]
    for pat in religion_patterns:
        if re.search(pat, spaced) or re.search(pat.replace("\\s*", ""), compact):
            return result(
                "religion_abuse",
                "إساءة دينية واضحة تم كشفها بعد تطبيع النص",
                0.99,
                "إساءة دينية",
            )

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
        # _simple_safe_moderation لا يملك req؛ التعلم يتم في moderate_with_qwen قبل الوصول هنا.
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
# توافق قديم مع مسار البلاغات، لكنه الآن يكتب في نفس جدول الذاكرة المحلي الموحد.
# لا نستخدم جدولًا منفصلًا للبلاغات حتى تصبح ذاكرة المنشورات والردود والبلاغات واحدة.
LEARNED_TERMS_TABLE = os.getenv("RESPECT_AI_LEARNED_TERMS_TABLE", RESPECT_AI_LOCAL_MEMORY_TABLE).strip() or RESPECT_AI_LOCAL_MEMORY_TABLE
_LEARNED_TERMS_CACHE: Dict[str, Any] = {"ts": 0.0, "items": []}
_LEARNED_TERMS_TTL_SECONDS = int(os.getenv("RESPECT_AI_LEARNED_TERMS_CACHE_TTL", "60") or "60")


def _learned_terms_cache_key() -> str:
    return _redis_key("cache", LEARNED_TERMS_TABLE, "active")


def _invalidate_learned_terms_cache() -> None:
    _LEARNED_TERMS_CACHE["ts"] = 0.0
    _redis_delete(_learned_terms_cache_key())


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


# فلتر أضيق لذاكرة المراقبة من فلتر البلاغات.
# الهدف: لا نحفظ كلمات عامة مثل "واحد" و"فيكم" و"احط" داخل respect_ai_moderation_memory،
# لكن نبقي العبارات التي تحتوي على كلمة/جذر مسيء واضح حتى يستفيد النظام من الذاكرة بدون حذف خاطئ.
_MODERATION_MEMORY_GENERIC_PHRASE_WORDS = {
    "انا", "انت", "انتي", "انتم", "هو", "هي", "هم", "نحن", "احنا", "همه",
    "هذا", "هذه", "هذي", "هادا", "هاي", "ذا", "دي", "الي", "اللي", "الى", "إلى",
    "على", "في", "من", "عن", "مع", "عند", "عندي", "عندك", "لك", "لكم", "لنا",
    "واحد", "وحد", "احد", "حد", "اثنين", "كل", "كلهم", "كلنا", "ناس", "شخص",
    "فيكم", "فيك", "فيني", "فيهم", "عليك", "عليكم", "علينا", "عليهم",
    "احط", "حط", "حطيت", "بحط", "رح", "راح", "ابي", "ابغى", "بدي",
    "جدا", "مرة", "مره", "اليوم", "امس", "بكرا", "الان", "هنا", "هناك",
    "the", "and", "for", "with", "this", "that", "you", "are", "was", "were", "post", "tweet",
}

_MODERATION_MEMORY_STRONG_DELETE_TOKENS = {
    # عربي/عامي واضح - نحفظه ككلمة منفردة أو داخل عبارة.
    "زبي", "زب", "زبك", "زبه", "زبها", "كسمك", "كسم", "كس", "طيز", "طيزي", "طيزك", "طيزه", "طيزها", "طيزهم",
    "نيك", "منيوك", "منيوكة", "شرموط", "شرموطه", "شرموطة", "قحبة", "قحبه", "عرص", "وسخ",
    "كلب", "حمار", "خرا", "زق",
    # English obvious insults/slurs used by local/Qwen moderation.
    "fuck", "bitch", "asshole", "slut", "whore", "pussy", "dick",
}

def _is_moderation_memory_strong_delete_token(value: str) -> bool:
    n = _learned_normalized(value or "")
    spaced = n.get("spaced") or ""
    compact = n.get("compact") or ""
    if not compact:
        return False
    if compact in _MODERATION_MEMORY_STRONG_DELETE_TOKENS or spaced in _MODERATION_MEMORY_STRONG_DELETE_TOKENS:
        return True
    tokens = [t for t in spaced.split() if t]
    return any(t in _MODERATION_MEMORY_STRONG_DELETE_TOKENS for t in tokens)


def _moderation_memory_strong_delete_token_hits(value: str) -> list[str]:
    """يرجع الكلمات المسيئة الواضحة الموجودة داخل النص بعد التطبيع، لاستخدامها كذاكرة phrase منفردة."""
    n = _learned_normalized(value or "")
    spaced = n.get("spaced") or ""
    compact = n.get("compact") or ""
    tokens = [t for t in spaced.split() if t]
    hits: list[str] = []

    def add(term: str) -> None:
        clean = _safe_term_phrase(term, 80)
        if not clean:
            return
        c = _learned_normalized(clean).get("compact") or ""
        if not c:
            return
        if c not in {_learned_normalized(x).get("compact") for x in hits}:
            hits.append(clean)

    for token in tokens:
        tcompact = _learned_normalized(token).get("compact") or ""
        if not tcompact:
            continue
        if tcompact in _MODERATION_MEMORY_STRONG_DELETE_TOKENS:
            add(token)
            continue
        # صيغ الملكية الشائعة بدون فتح الباب لكلمات عامة.
        for root in ("زب", "طيز", "كسم", "كس", "نيك"):
            if tcompact.startswith(root) and 2 <= len(tcompact) <= 12:
                add(token)
                break

    for strong in _MODERATION_MEMORY_STRONG_DELETE_TOKENS:
        scompact = _learned_normalized(strong).get("compact") or ""
        # لا نضيف جذور قصيرة مثل "زب" بسبب وجودها داخل كلمة أطول؛ تحفظ فقط إذا ظهرت كتوكن مستقل أعلاه.
        if scompact and len(scompact) >= 3 and scompact in compact:
            add(strong)

    return hits[:12]


def _extract_moderation_delete_memory_phrases(text: str, result: Dict[str, Any]) -> list[str]:
    """
    استخراج مركز للعبارات التي تحفظ كـ phrase عند الحذف:
    - matchedTerm من الفلتر/الذكاء.
    - الكلمة المسيئة المفردة من النص.
    - لا يحفظ كلمات عامة مثل: واحد/فيكم/احط.
    """
    candidates: list[str] = []

    def add(value: Any) -> None:
        phrase = _safe_term_phrase(str(value or ""), 90)
        if not phrase:
            return
        if not _is_moderation_memory_learnable_delete_phrase(phrase, full_text=text):
            return
        pcompact = _learned_normalized(phrase).get("compact") or ""
        if not pcompact:
            return
        existing = {_learned_normalized(x).get("compact") for x in candidates}
        if pcompact not in existing:
            candidates.append(phrase)

    # 1) أي matchedTerm صريح يرجع من الفلتر أو Qwen.
    add(result.get("matchedTerm"))
    matched_terms = result.get("matchedTerms")
    if isinstance(matched_terms, list):
        for item in matched_terms:
            add(item)

    # 2) الكلمة المسيئة الواضحة وحدها من النص الكامل.
    for hit in _moderation_memory_strong_delete_token_hits(text):
        add(hit)

    # 3) احتياط محدود: fallback يستخرج n-grams، لكن الفلتر أعلاه لا يقبل إلا ما يحتوي سب واضح.
    for phrase in _extract_learned_terms_fallback(text):
        add(phrase)

    return candidates[:AI_MODERATION_MEMORY_MAX_LEARNED_PHRASES]

def _is_moderation_memory_generic_phrase(value: str) -> bool:
    n = _learned_normalized(value or "")
    spaced = n.get("spaced") or ""
    compact = n.get("compact") or ""
    if not compact:
        return True
    tokens = [t for t in spaced.split() if t]
    if not tokens:
        return True
    if compact in _MODERATION_MEMORY_GENERIC_PHRASE_WORDS or spaced in _MODERATION_MEMORY_GENERIC_PHRASE_WORDS:
        return True
    if all(t in _MODERATION_MEMORY_GENERIC_PHRASE_WORDS for t in tokens):
        return True
    return False

def _is_moderation_memory_learnable_delete_phrase(value: str, *, full_text: str = "") -> bool:
    phrase = _safe_term_phrase(value)
    if not _is_learnable_term(phrase):
        return False
    pn = _learned_normalized(phrase)
    pcompact = pn.get("compact") or ""
    tokens = [t for t in (pn.get("spaced") or "").split() if t]

    # لا نحفظ الكلمات العامة أو العبارات التي كلها كلمات عامة.
    if _is_moderation_memory_generic_phrase(phrase):
        return False

    # الكلمة المفردة لا تحفظ إلا إذا كانت كلمة مسيئة واضحة جدًا.
    if len(tokens) <= 1:
        return _is_moderation_memory_strong_delete_token(phrase)

    # أي عبارة مخالفة يجب أن تحتوي على كلمة مسيئة واضحة، وإلا تصبح عرضة لحذف خاطئ.
    if _is_moderation_memory_strong_delete_token(phrase):
        return True

    # احتياط: لو الجملة الأصلية فيها كلمة مسيئة واضحة، لا نحفظ عبارة لا تحتوي هي نفسها عليها.
    # هذا يمنع "واحد واحد" و"فيكم واحد" من جملة مخالفة بسبب كلمة أخرى.
    if full_text and _is_moderation_memory_strong_delete_token(full_text):
        return False

    return False


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
    """
    توافق قديم لمسار البلاغات.
    بدل جدول respect_ai_learned_terms المنفصل، نحول العبارة إلى صف phrase داخل ذاكرة المودريشن الموحدة.
    """
    phrase = _safe_term_phrase(term)
    if not _is_moderation_memory_learnable_delete_phrase(phrase):
        return {"inserted": False, "reason": "not_learnable", "term": phrase}

    n = _learned_normalized(phrase)
    compact = n.get("compact") or ""
    if not compact:
        return {"inserted": False, "reason": "empty_normalized", "term": phrase}

    payload = {
        "memory_key": _moderation_memory_key("phrase", compact),
        "memory_type": "phrase",
        "normalized_spaced": (n.get("spaced") or "")[:500],
        "normalized_compact": compact[:500],
        "sample_text": phrase[:500],
        "decision": "delete",
        "category": (category or "learned_abuse")[:80],
        "reason": (reason or "تم تعلمها من بلاغ صحيح")[:700],
        "confidence": 0.97,
        "source": "report_review",
        "model": "report_review_dictionary",
        "active": True,
        # حقول توافق اختيارية إذا كان جدولك الموحد يحتويها.
        "term": phrase[:500],
        "term_hash": _learned_hash(compact),
        "source_post_id": (source_post_id or "")[:120],
        "source_report_id": (source_report_id or "")[:120],
        "reporter_username": _display_username(reporter_username or ""),
        "reported_username": _display_username(reported_username or ""),
    }

    # لو الجدول الموحد لا يحتوي حقول التوافق القديمة، نحذفها ونحاول مرة ثانية.
    res = _upsert_moderation_memory_row(payload)
    if res.get("ok") is True:
        _invalidate_learned_terms_cache()
        return {"inserted": True, "term": phrase, "hash": payload["term_hash"], "memory_key": payload["memory_key"]}

    if str(res.get("body") or "").lower().find("column") >= 0:
        slim = dict(payload)
        for key in ("term", "term_hash", "source_post_id", "source_report_id", "reporter_username", "reported_username"):
            slim.pop(key, None)
        res = _upsert_moderation_memory_row(slim)
        if res.get("ok") is True:
            _invalidate_learned_terms_cache()
            return {"inserted": True, "term": phrase, "memory_key": slim["memory_key"], "fallbackSlim": True}

    logger.warning("Insert learned term into unified memory failed: %s", res)
    return {"inserted": False, "term": phrase, "result": res}


def _learn_abuse_terms_from_valid_report(req: RespectAIModerationRequest, result: Dict[str, Any]) -> Dict[str, Any]:
    """
    يتعلم من البلاغ المقبول في نفس الذاكرة المحلية الموحدة.
    يسجل النص كاملًا كـ exact + العبارات المخالفة كـ phrase، ثم يرجع نفس المفاتيح القديمة حتى Flutter/Admin لا يحتاجان تغييرًا.
    """
    content_type = (req.contentType or "post").strip().lower()
    post_text = (req.text if content_type == "reply" else (req.postText or req.text) or "").strip()
    if not post_text:
        return {"learned": False, "terms": [], "reason": "empty_reported_text"}

    terms = _extract_learned_terms_with_ai(post_text, req.reason or "", req.details or "", str(result.get("reason") or ""))
    source_id = req.replyId if content_type == "reply" and (req.replyId or "").strip() else (req.postId or "")
    inserted = [_insert_learned_abuse_term(
        term=term,
        category=str(result.get("category") or "learned_abuse"),
        reason=str(result.get("reason") or req.reason or "بلاغ صحيح"),
        source_post_id=source_id,
        source_report_id=req.reportId or "",
        reporter_username=req.reporterUsername or "",
        reported_username=req.reportedUsername or req.username or "",
    ) for term in terms]

    report_memory_result = dict(result)
    report_memory_result.update({
        "shouldDelete": True,
        "blocked": True,
        "category": str(result.get("category") or "report_accepted"),
        "reason": str(result.get("reason") or req.reason or "بلاغ صحيح"),
        "confidence": max(0.90, _mm_float(result.get("confidence"), 0.90)),
        "decisionSource": "report_review",
        "model": QWEN_TEXT_MODEL if QWEN_API_KEY else "report_review",
    })
    memory_result = _learn_moderation_memory_safely(
        req,
        report_memory_result,
        text_result=report_memory_result,
        source=f"report_review_{content_type}",
    )

    ok_count = sum(1 for x in inserted if x.get("inserted") is True)
    memory_ok = bool(memory_result.get("learned"))
    local_rows = memory_result.get("localMemoryRows") or memory_result.get("learnedRows") or []
    learned_terms = list(dict.fromkeys([*terms, *[str(x) for x in (memory_result.get("learnedTerms") or []) if str(x).strip()]]))
    return {
        "learned": ok_count > 0 or memory_ok,
        "terms": learned_terms,
        "inserted": inserted,
        "count": ok_count + int(memory_result.get("count") or 0),
        "contentType": content_type,
        "memoryLearnResult": memory_result,
        "localMemoryRows": local_rows,
        "learnedRows": local_rows,
        "learnedTerms": learned_terms,
        "table": RESPECT_AI_MODERATION_MEMORY_TABLE,
    }


def _load_active_learned_terms(force: bool = False) -> list[Dict[str, Any]]:
    now = time.time()
    if not force:
        redis_items = _redis_get_json(_learned_terms_cache_key())
        if isinstance(redis_items, list):
            items = [dict(x) for x in redis_items if isinstance(x, dict)]
            _LEARNED_TERMS_CACHE.update({"ts": now, "items": items})
            return items
        if (now - float(_LEARNED_TERMS_CACHE.get("ts") or 0)) < _LEARNED_TERMS_TTL_SECONDS:
            return list(_LEARNED_TERMS_CACHE.get("items") or [])

    # القراءة الجديدة: من جدول الذاكرة الموحد، صفوف phrase/keyword ذات قرار delete.
    try:
        r = requests.get(
            f"{SB_URL}/rest/v1/{RESPECT_AI_MODERATION_MEMORY_TABLE}",
            headers=_supabase_headers(use_service_role=True),
            params={
                "select": "id,sample_text,normalized_spaced,normalized_compact,category,reason,active,decision,memory_type,confidence,hits,memory_hits,updated_at",
                "active": "eq.true",
                "decision": "eq.delete",
                "memory_type": "in.(phrase,keyword)",
                "order": "updated_at.desc",
                "limit": "900",
            },
            timeout=10,
        )
        if r.status_code < 400:
            data = r.json() if r.text else []
            rows = [dict(x) for x in data if isinstance(x, dict)] if isinstance(data, list) else []
            items = []
            for row in rows:
                sample = str(row.get("sample_text") or "").strip()
                items.append({
                    **row,
                    "term": sample,
                    "source": "respect_ai_local_memory",
                })
            _LEARNED_TERMS_CACHE.update({"ts": now, "items": items})
            _redis_set_json(_learned_terms_cache_key(), items, _LEARNED_TERMS_TTL_SECONDS)
            return items
        logger.warning("Load unified learned terms failed status=%s body=%s", r.status_code, _safe_response_text(r.text, 250))
    except Exception as e:
        logger.warning("Load unified learned terms exception: %s", e)

    # توافق احتياطي: لو ما زلت تستخدم جدول learned_terms القديم عبر env.
    try:
        if LEARNED_TERMS_TABLE == RESPECT_AI_MODERATION_MEMORY_TABLE:
            _LEARNED_TERMS_CACHE.update({"ts": now, "items": []})
            return []
        r = requests.get(
            f"{SB_URL}/rest/v1/{LEARNED_TERMS_TABLE}",
            headers=_supabase_headers(use_service_role=True),
            params={"select": "id,term,normalized_spaced,normalized_compact,category,reason,active", "active": "eq.true", "order": "created_at.desc", "limit": "700"},
            timeout=10,
        )
        if r.status_code >= 400:
            logger.warning("Load legacy learned terms failed status=%s body=%s", r.status_code, _safe_response_text(r.text, 250))
            _LEARNED_TERMS_CACHE.update({"ts": now, "items": []})
            return []
        data = r.json() if r.text else []
        items = [dict(x) for x in data if isinstance(x, dict)] if isinstance(data, list) else []
        _LEARNED_TERMS_CACHE.update({"ts": now, "items": items})
        _redis_set_json(_learned_terms_cache_key(), items, _LEARNED_TERMS_TTL_SECONDS)
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
    """
    فحص سريع متوافق مع الاسم القديم، لكنه يقرأ من ذاكرة المودريشن الموحدة.
    وجوده يحافظ على بقية المسارات بدون تعديل، والقرار يخرج باسم ذاكرة Respect AI.
    """
    if not (text or "").strip():
        return None
    n = _learned_normalized(text)
    if not n["compact"]:
        return None
    for item in _load_active_learned_terms():
        term_compact = str(item.get("normalized_compact") or "").strip()
        term_spaced = str(item.get("normalized_spaced") or "").strip()
        sample = str(item.get("sample_text") or item.get("term") or term_spaced or term_compact).strip()
        if term_compact and _learned_phrase_matches_text(term_compact, term_spaced, n["compact"], n["spaced"]):
            return {
                "shouldDelete": True,
                "deleteParentReply": False,
                "category": str(item.get("category") or "learned_abuse"),
                "reason": str(item.get("reason") or "عبارة مخالفة تعلمتها ذاكرة Respect AI الموحدة"),
                "confidence": max(0.96, _mm_float(item.get("confidence"), 0.96)),
                "checks": 0,
                "learned_guard": True,
                "memoryUsed": True,
                "moderationMemoryUsed": True,
                "decisionSource": "respect_ai_moderation_memory",
                "matchedTerm": sample[:120],
                "model": "respect_ai_local_memory_v2",
            }
    return None




# ================= Respect AI Moderation Memory =================
# ذاكرة عامة موحدة لمراجعة المحتوى: تتعلم من قرارات Qwen القوية + البلاغات المقبولة + الردود والمنشورات.
# نفس جدول RESPECT_AI_LOCAL_MEMORY_TABLE يستخدم لكل مسارات التعلم حتى لا تتشتت الذاكرة.
RESPECT_AI_MODERATION_MEMORY_TABLE = os.getenv(
    "RESPECT_AI_MODERATION_MEMORY_TABLE",
    RESPECT_AI_LOCAL_MEMORY_TABLE,
).strip() or RESPECT_AI_LOCAL_MEMORY_TABLE
AI_MODERATION_MEMORY_ENABLED = os.getenv("AI_MODERATION_MEMORY_ENABLED", "true").strip().lower() not in {"0", "false", "no", "off"}
AI_MODERATION_MEMORY_CACHE_TTL_SECONDS = int(os.getenv("AI_MODERATION_MEMORY_CACHE_TTL_SECONDS", "90") or "90")
AI_MODERATION_MEMORY_MAX_ROWS = int(os.getenv("AI_MODERATION_MEMORY_MAX_ROWS", "2500") or "2500")
AI_MODERATION_MEMORY_ALLOW_MIN_CONFIDENCE = float(os.getenv("AI_MODERATION_MEMORY_ALLOW_MIN_CONFIDENCE", "0.88") or "0.88")
AI_MODERATION_MEMORY_DELETE_MIN_CONFIDENCE = float(os.getenv("AI_MODERATION_MEMORY_DELETE_MIN_CONFIDENCE", "0.93") or "0.93")
AI_MODERATION_MEMORY_REVIEW_MIN_CONFIDENCE = float(os.getenv("AI_MODERATION_MEMORY_REVIEW_MIN_CONFIDENCE", "0.78") or "0.78")
AI_MODERATION_MEMORY_MIN_HITS_FOR_PHRASE_DELETE = int(os.getenv("AI_MODERATION_MEMORY_MIN_HITS_FOR_PHRASE_DELETE", "1") or "1")
AI_MODERATION_MEMORY_MIN_HITS_FOR_SAFE_EXACT = int(os.getenv("AI_MODERATION_MEMORY_MIN_HITS_FOR_SAFE_EXACT", "1") or "1")
AI_MODERATION_MEMORY_LEARN_SAFE_MIN_CONFIDENCE = float(os.getenv("AI_MODERATION_MEMORY_LEARN_SAFE_MIN_CONFIDENCE", "0.80") or "0.80")
AI_MODERATION_MEMORY_LEARN_DELETE_MIN_CONFIDENCE = float(os.getenv("AI_MODERATION_MEMORY_LEARN_DELETE_MIN_CONFIDENCE", "0.86") or "0.86")
AI_MODERATION_MEMORY_MAX_LEARNED_PHRASES = int(os.getenv("AI_MODERATION_MEMORY_MAX_LEARNED_PHRASES", "8") or "8")
_MODERATION_MEMORY_CACHE: Dict[str, Any] = {"ts": 0.0, "items": [], "table_missing": False}


def _moderation_memory_cache_key() -> str:
    return _redis_key("cache", RESPECT_AI_MODERATION_MEMORY_TABLE, "active")


def _invalidate_moderation_memory_cache() -> None:
    _MODERATION_MEMORY_CACHE["ts"] = 0.0
    _redis_delete(_moderation_memory_cache_key())


def _mm_float(value: Any, default: float = 0.0) -> float:
    try:
        if value is None:
            return default
        return float(value)
    except Exception:
        return default


def _mm_int(value: Any, default: int = 0) -> int:
    try:
        if value is None:
            return default
        return int(float(value))
    except Exception:
        return default


def _moderation_text_has_url(text: str) -> bool:
    return bool(re.search(r"(?i)\b(?:https?://|www\.|[a-z0-9-]+\.(?:com|net|org|io|gg|co|app|dev|xyz)\b)", text or ""))


def _moderation_memory_key(memory_type: str, value: str) -> str:
    base = f"{memory_type}:{value}".strip().lower()
    return hashlib.sha256(base.encode("utf-8")).hexdigest()


def _moderation_memory_terms(text: str) -> Dict[str, Any]:
    n = _learned_normalized(text or "")
    spaced = n.get("spaced") or ""
    compact = n.get("compact") or ""
    tokens = [t for t in spaced.split() if len(t) >= 2]
    stop = {
        "هذا", "هذه", "هذي", "الي", "اللي", "على", "الى", "إلى", "في", "من", "عن", "مع", "كان", "صار",
        "انا", "انت", "انتي", "انتم", "هو", "هي", "هم", "نحن", "اليوم", "امس", "بكرا", "جدا", "مرة", "مره",
        "the", "and", "for", "with", "this", "that", "you", "are", "was", "were", "today", "post", "tweet",
    }
    tokens = [t for t in tokens if t not in stop]
    phrases: list[str] = []
    for size in (1, 2, 3, 4):
        for i in range(0, max(0, len(tokens) - size + 1)):
            phrase = " ".join(tokens[i:i + size]).strip()
            if not phrase:
                continue
            # لا نخزن جمل طويلة جدًا ولا كلمات عامة جدًا.
            compact_phrase = _learned_normalized(phrase).get("compact") or ""
            if len(compact_phrase) < 2 or len(compact_phrase) > 80:
                continue
            if phrase not in phrases:
                phrases.append(phrase)
            if len(phrases) >= 60:
                break
        if len(phrases) >= 60:
            break
    return {"spaced": spaced, "compact": compact, "tokens": tokens[:80], "phrases": phrases[:80]}


def _load_moderation_memory_rows(force: bool = False) -> list[Dict[str, Any]]:
    if not AI_MODERATION_MEMORY_ENABLED or not SB_SERVICE:
        return []
    now = time.time()
    if not force:
        redis_payload = _redis_get_json(_moderation_memory_cache_key())
        if isinstance(redis_payload, dict):
            if redis_payload.get("table_missing") is True:
                _MODERATION_MEMORY_CACHE.update({"ts": now, "items": [], "table_missing": True})
                return []
            items = [dict(x) for x in (redis_payload.get("items") or []) if isinstance(x, dict)]
            _MODERATION_MEMORY_CACHE.update({"ts": now, "items": items, "table_missing": False})
            return items
        if (now - float(_MODERATION_MEMORY_CACHE.get("ts") or 0)) < AI_MODERATION_MEMORY_CACHE_TTL_SECONDS:
            return list(_MODERATION_MEMORY_CACHE.get("items") or [])
        if _MODERATION_MEMORY_CACHE.get("table_missing") is True:
            return []
    try:
        r = requests.get(
            f"{SB_URL}/rest/v1/{RESPECT_AI_MODERATION_MEMORY_TABLE}",
            headers=_supabase_headers(use_service_role=True),
            params={
                "select": "id,memory_key,memory_type,normalized_spaced,normalized_compact,sample_text,decision,category,reason,confidence,hits,ai_hits,memory_hits,false_positive_count,false_negative_count,source,model,active,updated_at",
                "active": "eq.true",
                "order": "hits.desc,updated_at.desc",
                "limit": str(max(200, AI_MODERATION_MEMORY_MAX_ROWS)),
            },
            timeout=10,
        )
        if r.status_code == 404 or (r.status_code == 400 and "does not exist" in r.text.lower()):
            _MODERATION_MEMORY_CACHE.update({"ts": now, "items": [], "table_missing": True})
            _redis_set_json(_moderation_memory_cache_key(), {"items": [], "table_missing": True}, AI_MODERATION_MEMORY_CACHE_TTL_SECONDS)
            logger.warning("Moderation memory table is missing. Run the SQL migration for %s", RESPECT_AI_MODERATION_MEMORY_TABLE)
            return []
        if r.status_code >= 400:
            logger.warning("moderation_memory read failed status=%s body=%s", r.status_code, _safe_response_text(r.text, 350))
            _MODERATION_MEMORY_CACHE.update({"ts": now, "items": []})
            _redis_set_json(_moderation_memory_cache_key(), {"items": [], "table_missing": False}, AI_MODERATION_MEMORY_CACHE_TTL_SECONDS)
            return []
        data = r.json() if r.text else []
        items = [dict(x) for x in data if isinstance(x, dict)] if isinstance(data, list) else []
        _MODERATION_MEMORY_CACHE.update({"ts": now, "items": items, "table_missing": False})
        _redis_set_json(_moderation_memory_cache_key(), {"items": items, "table_missing": False}, AI_MODERATION_MEMORY_CACHE_TTL_SECONDS)
        return items
    except Exception as e:
        logger.warning("moderation_memory read exception: %s", e)
        return list(_MODERATION_MEMORY_CACHE.get("items") or [])


@app.get("/admin/moderation-memory")
def admin_moderation_memory(
    limit: int = 120,
    decision: str = "",
    category: str = "",
    q: str = "",
    x_app_secret: Optional[str] = Header(default=None),
):
    """
    يعرض ما تعلمته ذاكرة Respect AI من قرارات الحذف/السماح.
    استخدمه من الطرفية فقط مع X-App-Secret.
    """
    if not APP_SHARED_SECRET:
        raise HTTPException(status_code=500, detail="APP_SHARED_SECRET missing. ضع السر في Render ثم أرسله في X-App-Secret.")
    _check_secret(x_app_secret)

    safe_limit = max(1, min(int(limit or 120), 500))
    rows = _load_moderation_memory_rows(force=True)

    clean_decision = (decision or "").strip().lower()
    if clean_decision:
        rows = [r for r in rows if str(r.get("decision") or "").strip().lower() == clean_decision]

    clean_category = (category or "").strip().lower()
    if clean_category:
        rows = [r for r in rows if clean_category in str(r.get("category") or "").strip().lower()]

    clean_q = (q or "").strip().lower()
    if clean_q:
        rows = [
            r for r in rows
            if clean_q in str(r.get("sample_text") or "").lower()
            or clean_q in str(r.get("normalized_spaced") or "").lower()
            or clean_q in str(r.get("category") or "").lower()
        ]

    out: list[Dict[str, Any]] = []
    for r in rows[:safe_limit]:
        out.append({
            "memory_type": str(r.get("memory_type") or ""),
            "decision": str(r.get("decision") or ""),
            "category": str(r.get("category") or ""),
            "confidence": _mm_float(r.get("confidence"), 0.0),
            "hits": _mm_int(r.get("hits"), 0),
            "ai_hits": _mm_int(r.get("ai_hits"), 0),
            "memory_hits": _mm_int(r.get("memory_hits"), 0),
            "sample_text": str(r.get("sample_text") or ""),
            "updated_at": str(r.get("updated_at") or ""),
            "source": str(r.get("source") or ""),
            "model": str(r.get("model") or ""),
        })

    return {
        "ok": True,
        "table": RESPECT_AI_MODERATION_MEMORY_TABLE,
        "count": len(out),
        "total_cached": len(rows),
        "items": out,
    }


def _touch_moderation_memory_hit(row: Dict[str, Any]) -> None:
    if not AI_MODERATION_MEMORY_ENABLED or not SB_SERVICE:
        return
    row_id = str(row.get("id") or "").strip()
    if not row_id:
        return
    payload = {
        "memory_hits": _mm_int(row.get("memory_hits"), 0) + 1,
        "updated_at": datetime.now(timezone.utc).isoformat(),
    }
    try:
        requests.patch(
            f"{SB_URL}/rest/v1/{RESPECT_AI_MODERATION_MEMORY_TABLE}",
            headers={**_supabase_headers(use_service_role=True), "Prefer": "return=minimal"},
            params={"id": f"eq.{row_id}"},
            json=payload,
            timeout=7,
        )
    except Exception as e:
        logger.debug("moderation_memory hit update skipped: %s", e)


def _memory_row_to_moderation_result(row: Dict[str, Any], match_type: str, matched_text: str) -> Dict[str, Any]:
    decision = str(row.get("decision") or "allow").strip().lower()
    should_delete = decision in {"delete", "block", "deny", "remove"}
    confidence = max(0.0, min(1.0, _mm_float(row.get("confidence"), 0.0)))
    category = str(row.get("category") or ("moderation_memory_violation" if should_delete else "safe")).strip() or "safe"
    base_reason = str(row.get("reason") or "").strip()
    if not base_reason:
        base_reason = "قرار سريع من ذاكرة Respect AI" if not should_delete else "محتوى يطابق نمطًا مخالفًا تعلمه Respect AI سابقًا"
    return {
        "shouldDelete": should_delete,
        "deleteParentReply": False,
        "category": category,
        "reason": base_reason[:700],
        "confidence": confidence,
        "checks": 0,
        "memoryUsed": True,
        "moderationMemoryUsed": True,
        "decisionSource": "respect_ai_moderation_memory",
        "memoryDecision": decision,
        "memoryType": str(row.get("memory_type") or ""),
        "memoryMatchType": match_type,
        "matchedTerm": matched_text[:120],
        "model": "respect_ai_moderation_memory_v1",
    }


def _moderation_memory_guard(text: str, *, content_type: str = "post", has_media: bool = False) -> Optional[Dict[str, Any]]:
    raw_text = (text or "").strip()
    if not raw_text or not AI_MODERATION_MEMORY_ENABLED:
        return None
    # الروابط والصور والفيديوهات تبقى تمر على فحصها الخاص ولا نعتمد على ذاكرة النص وحدها.
    if _moderation_text_has_url(raw_text):
        return None

    terms = _moderation_memory_terms(raw_text)
    compact = str(terms.get("compact") or "")
    spaced = str(terms.get("spaced") or "")
    if len(compact) < 2:
        return None

    rows = _load_moderation_memory_rows()
    if not rows:
        return None

    exact_key = _moderation_memory_key("exact", compact)
    phrases = [str(x) for x in (terms.get("phrases") or []) if str(x).strip()]
    phrase_norms = {_learned_normalized(p).get("compact") or "": p for p in phrases}

    best: Optional[Dict[str, Any]] = None
    best_score = -1.0
    best_match_type = ""
    best_text = ""

    for row in rows:
        decision = str(row.get("decision") or "allow").strip().lower()
        memory_type = str(row.get("memory_type") or "exact").strip().lower()
        confidence = max(0.0, min(1.0, _mm_float(row.get("confidence"), 0.0)))
        hits = _mm_int(row.get("hits"), 0)
        fp = _mm_int(row.get("false_positive_count"), 0)
        fn = _mm_int(row.get("false_negative_count"), 0)
        if fp >= 2 or fn >= 3:
            continue

        matched = False
        match_type = ""
        matched_text = ""
        if memory_type == "exact" and str(row.get("memory_key") or "") == exact_key:
            matched = True
            match_type = "exact"
            matched_text = raw_text[:120]
        elif memory_type in {"phrase", "keyword"}:
            row_compact = str(row.get("normalized_compact") or "").strip()
            row_spaced = str(row.get("normalized_spaced") or "").strip()
            if row_compact and _learned_phrase_matches_text(row_compact, row_spaced, compact, spaced):
                matched = True
                match_type = memory_type
                matched_text = str(row.get("sample_text") or row_spaced or row_compact)
            elif row_compact in phrase_norms:
                matched = True
                match_type = memory_type
                matched_text = phrase_norms.get(row_compact, row_compact)
        if not matched:
            continue

        is_delete = decision in {"delete", "block", "deny", "remove"}
        is_allow = decision in {"allow", "safe", "approve"}
        threshold = AI_MODERATION_MEMORY_REVIEW_MIN_CONFIDENCE
        min_hits = 1
        if is_delete:
            threshold = AI_MODERATION_MEMORY_DELETE_MIN_CONFIDENCE
            min_hits = AI_MODERATION_MEMORY_MIN_HITS_FOR_PHRASE_DELETE if memory_type != "exact" else 1
        elif is_allow:
            # السماح من الذاكرة يكون exact فقط؛ لا نسمح من phrase حتى لا تمرر مخالفات بسبب عبارة عادية مشتركة.
            if memory_type != "exact" or has_media:
                continue
            threshold = AI_MODERATION_MEMORY_ALLOW_MIN_CONFIDENCE
            min_hits = AI_MODERATION_MEMORY_MIN_HITS_FOR_SAFE_EXACT
        else:
            continue
        if confidence < threshold or hits < min_hits:
            continue

        score = confidence + min(0.15, hits * 0.015) + (0.08 if match_type == "exact" else 0.0)
        if score > best_score:
            best = row
            best_score = score
            best_match_type = match_type
            best_text = matched_text

    if best is None:
        return None
    _touch_moderation_memory_hit(best)
    return _memory_row_to_moderation_result(best, best_match_type, best_text)


def _should_learn_moderation_memory(result: Dict[str, Any]) -> bool:
    if not AI_MODERATION_MEMORY_ENABLED:
        return False
    if result.get("moderationMemoryUsed") is True or result.get("memoryUsed") is True:
        return False
    category = str(result.get("category") or "safe").strip().lower()
    decision_source = str(result.get("decisionSource") or result.get("source") or "").strip().lower()
    confidence = max(0.0, min(1.0, _mm_float(result.get("confidence"), 0.0)))
    should_delete = bool(result.get("shouldDelete") is True or result.get("delete") is True or result.get("blocked") is True)
    if should_delete:
        return confidence >= AI_MODERATION_MEMORY_LEARN_DELETE_MIN_CONFIDENCE
    if category.startswith("safe") or category in {"empty_or_media_only", "allowed"}:
        # لا نخزن السماح الضعيف جدًا إلا إذا جاء من فحص صريح أو قاعدة آمنة معروفة.
        return confidence >= AI_MODERATION_MEMORY_LEARN_SAFE_MIN_CONFIDENCE or "qwen" in decision_source or result.get("fast_safe") is True
    return False


def _upsert_moderation_memory_row(payload: Dict[str, Any]) -> Dict[str, Any]:
    if not AI_MODERATION_MEMORY_ENABLED or not SB_SERVICE:
        return {"ok": False, "reason": "disabled_or_missing_service_role"}
    key = str(payload.get("memory_key") or "").strip()
    if not key:
        return {"ok": False, "reason": "missing_memory_key"}
    now = datetime.now(timezone.utc).isoformat()
    headers = _supabase_headers(use_service_role=True)
    try:
        existing_rows: list[Dict[str, Any]] = []
        r = requests.get(
            f"{SB_URL}/rest/v1/{RESPECT_AI_MODERATION_MEMORY_TABLE}",
            headers=headers,
            params={"select": "id,hits,ai_hits,confidence,false_positive_count,false_negative_count", "memory_key": f"eq.{key}", "limit": "1"},
            timeout=8,
        )
        if r.status_code == 404 or (r.status_code == 400 and "does not exist" in r.text.lower()):
            _MODERATION_MEMORY_CACHE.update({"table_missing": True, "ts": time.time(), "items": []})
            return {"ok": False, "reason": "table_missing"}
        if r.status_code // 100 == 2:
            data = r.json() if r.text else []
            if isinstance(data, list):
                existing_rows = [dict(x) for x in data if isinstance(x, dict)]
        elif r.status_code >= 400:
            logger.warning("moderation_memory lookup failed status=%s body=%s", r.status_code, _safe_response_text(r.text, 250))
            return {"ok": False, "status": r.status_code, "body": r.text[:250]}

        if existing_rows:
            old = existing_rows[0]
            row_id = str(old.get("id") or "")
            merged = dict(payload)
            merged.pop("id", None)
            merged["hits"] = _mm_int(old.get("hits"), 0) + 1
            merged["ai_hits"] = _mm_int(old.get("ai_hits"), 0) + 1
            merged["confidence"] = max(_mm_float(old.get("confidence"), 0.0), _mm_float(payload.get("confidence"), 0.0))
            merged["false_positive_count"] = _mm_int(old.get("false_positive_count"), 0)
            merged["false_negative_count"] = _mm_int(old.get("false_negative_count"), 0)
            merged["updated_at"] = now
            rr = requests.patch(
                f"{SB_URL}/rest/v1/{RESPECT_AI_MODERATION_MEMORY_TABLE}",
                headers={**headers, "Prefer": "return=minimal"},
                params={"id": f"eq.{row_id}"},
                json=merged,
                timeout=8,
            )
            if rr.status_code >= 400:
                logger.warning("moderation_memory patch failed status=%s body=%s", rr.status_code, _safe_response_text(rr.text, 250))
                return {"ok": False, "status": rr.status_code, "body": rr.text[:250]}
            _invalidate_moderation_memory_cache()
            return {"ok": True, "updated": True, "memory_key": key}

        new_payload = dict(payload)
        new_payload.setdefault("hits", 1)
        new_payload.setdefault("ai_hits", 1)
        new_payload.setdefault("memory_hits", 0)
        new_payload.setdefault("false_positive_count", 0)
        new_payload.setdefault("false_negative_count", 0)
        new_payload.setdefault("active", True)
        new_payload.setdefault("created_at", now)
        new_payload["updated_at"] = now
        rr = requests.post(
            f"{SB_URL}/rest/v1/{RESPECT_AI_MODERATION_MEMORY_TABLE}",
            headers={**headers, "Prefer": "return=minimal"},
            json=new_payload,
            timeout=8,
        )
        if rr.status_code >= 400:
            if rr.status_code == 404 or "does not exist" in rr.text.lower():
                _MODERATION_MEMORY_CACHE.update({"table_missing": True, "ts": time.time(), "items": []})
            logger.warning("moderation_memory insert failed status=%s body=%s", rr.status_code, _safe_response_text(rr.text, 250))
            return {"ok": False, "status": rr.status_code, "body": rr.text[:250]}
        _invalidate_moderation_memory_cache()
        return {"ok": True, "inserted": True, "memory_key": key}
    except Exception as e:
        logger.warning("moderation_memory upsert exception: %s", e)
        return {"ok": False, "error": str(e)[:250]}


def _learn_moderation_memory_from_result(
    req: RespectAIModerationRequest,
    result: Dict[str, Any],
    *,
    text_result: Optional[Dict[str, Any]] = None,
    source: str = "post_moderation",
) -> Dict[str, Any]:
    text = (req.text or req.postText or "").strip()
    if not text or not _should_learn_moderation_memory(result):
        return {"learned": False, "reason": "not_eligible"}
    if _moderation_text_has_url(text):
        return {"learned": False, "reason": "url_text_not_learned"}

    terms = _moderation_memory_terms(text)
    compact = str(terms.get("compact") or "")
    spaced = str(terms.get("spaced") or "")
    if len(compact) < 2:
        return {"learned": False, "reason": "empty_normalized_text"}

    should_delete = bool(result.get("shouldDelete") is True or result.get("delete") is True or result.get("blocked") is True)
    decision = "delete" if should_delete else "allow"
    confidence = max(0.0, min(1.0, _mm_float(result.get("confidence"), 0.0)))
    if confidence <= 0 and not should_delete:
        confidence = 0.82
    category = str(result.get("category") or ("violation" if should_delete else "safe")).strip()[:80]
    reason = str(result.get("reason") or "").strip()[:700]
    model = str(result.get("model") or (text_result or {}).get("model") or QWEN_TEXT_MODEL or "respect_ai").strip()[:120]
    now = datetime.now(timezone.utc).isoformat()
    rows: list[Dict[str, Any]] = []

    rows.append({
        "memory_key": _moderation_memory_key("exact", compact),
        "memory_type": "exact",
        "normalized_spaced": spaced[:500],
        "normalized_compact": compact[:500],
        "sample_text": text[:500],
        "decision": decision,
        "category": category,
        "reason": reason,
        "confidence": confidence,
        "source": source,
        "model": model,
        "active": True,
        "created_at": now,
        "updated_at": now,
    })

    # للمخالفات فقط نتعلم الجملة كاملة كـ exact أعلاه، ثم السبة/العبارة المخالفة وحدها كـ phrase.
    # هذا يمنع حفظ الكلمات العامة، ويضمن أن "احط زبي فيكم واحد واحد" تحفظ exact كاملة + "زبي" وحدها فورًا.
    if should_delete:
        phrases = _extract_moderation_delete_memory_phrases(text, result)

        seen = set()
        for phrase in phrases[:AI_MODERATION_MEMORY_MAX_LEARNED_PHRASES]:
            phrase = _safe_term_phrase(str(phrase))
            pn = _learned_normalized(phrase)
            pcompact = pn.get("compact") or ""
            if not pcompact or pcompact in seen:
                continue
            seen.add(pcompact)
            rows.append({
                "memory_key": _moderation_memory_key("phrase", pcompact),
                "memory_type": "phrase",
                "normalized_spaced": (pn.get("spaced") or "")[:500],
                "normalized_compact": pcompact[:500],
                "sample_text": phrase[:500],
                "decision": "delete",
                "category": category,
                "reason": reason or "عبارة مخالفة تعلمها Respect AI من قرار سابق",
                "confidence": max(confidence, AI_MODERATION_MEMORY_LEARN_DELETE_MIN_CONFIDENCE),
                "source": source,
                "model": model,
                "active": True,
                "created_at": now,
                "updated_at": now,
            })

    results = [_upsert_moderation_memory_row(row) for row in rows]
    learned_rows: list[Dict[str, Any]] = []
    for row, res in zip(rows, results):
        if res.get("ok") is True:
            learned_rows.append({
                "memoryType": str(row.get("memory_type") or ""),
                "decision": str(row.get("decision") or ""),
                "category": str(row.get("category") or ""),
                "confidence": _mm_float(row.get("confidence"), 0.0),
                "sampleText": str(row.get("sample_text") or "")[:500],
                "normalizedSpaced": str(row.get("normalized_spaced") or "")[:500],
                "normalizedCompact": str(row.get("normalized_compact") or "")[:500],
                "source": str(row.get("source") or "")[:120],
            })
    ok_count = sum(1 for x in results if x.get("ok") is True)
    return {
        "learned": ok_count > 0,
        "count": ok_count,
        "rows": len(rows),
        "results": results[:5],
        "learnedRows": learned_rows[:12],
        "localMemoryRows": learned_rows[:12],
        "learnedTerms": [r.get("sampleText") for r in learned_rows if str(r.get("sampleText") or "").strip()][:12],
    }


def _learn_moderation_memory_safely(
    req: RespectAIModerationRequest,
    result: Dict[str, Any],
    *,
    text_result: Optional[Dict[str, Any]] = None,
    source: str = "post_moderation",
) -> Dict[str, Any]:
    """
    يسجل قرار المراقبة في ذاكرة Respect AI بدون أن يعطل الحذف أو الرد.
    مهم للمشكلة التي ظهرت عندك: الحذف المحلي المبكر كان يحذف التغريدة ويرسل إشعارًا،
    لكنه لا يصل إلى مسار Qwen الذي كان يسجل الذاكرة، لذلك يبقى جدول respect_ai_moderation_memory = 0.
    """
    try:
        learn_result = _learn_moderation_memory_from_result(
            req,
            result,
            text_result=text_result or result,
            source=source,
        )
        if learn_result.get("learned") is True:
            logger.info(
                "moderation_memory learned source=%s category=%s decision=%s count=%s",
                source,
                result.get("category"),
                "delete" if (result.get("shouldDelete") is True or result.get("delete") is True or result.get("blocked") is True) else "allow",
                learn_result.get("count"),
            )
        else:
            logger.debug(
                "moderation_memory not learned source=%s reason=%s",
                source,
                learn_result.get("reason"),
            )
        return learn_result
    except Exception as learn_error:
        logger.warning("moderation_memory learn failed source=%s error=%s", source, learn_error)
        return {"learned": False, "reason": "exception", "error": str(learn_error)[:250]}

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
- "أول ما تسأل عنه المرأة يوم القيامة" أو "أول ما تُسأل عنه المرأة يوم القيامة" نص ديني/تعليمي عام؛ لا تصنفه sexual ولا religion_abuse.
- أي سؤال أو موعظة أو معلومة دينية عامة عن الصلاة أو القيامة أو المرأة أو الرجل أو الحجاب أو الأخلاق، ما دام لا يحتوي سبًا أو تحريضًا أو ازدراءً أو وصفًا جنسيًا صريحًا.
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
        "إذا كان النص دينيًا/تعليميًا عامًا مثل: أول ما تسأل عنه المرأة يوم القيامة، فالقرار الصحيح allowed=true و shouldDelete=false.",
        "لا تعتبر كلمة المرأة/النساء/القيامة/الدين مخالفة وحدها. المخالفة تكون فقط عند وجود سب أو تحريض أو ازدراء أو وصف جنسي صريح.",
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




def _collect_moderation_ai_text(data: Dict[str, Any]) -> str:
    """
    يجمع النصوص التي قد يرجعها موديل الرؤية: السبب، OCR، النص المرئي، التلخيص...
    هذا يساعدنا نمنع الحذف الخاطئ عندما يقرأ النموذج نصًا عاديًا ويصنفه sexual أو religion_abuse بالغلط.
    """
    if not isinstance(data, dict):
        return ""
    keys = (
        "reason",
        "ocrText",
        "ocr_text",
        "detectedText",
        "detected_text",
        "visibleText",
        "visible_text",
        "text",
        "caption",
        "summary",
        "description",
        "evidence",
        "visualEvidence",
        "visual_evidence",
    )
    values: list[str] = []
    for key in keys:
        value = data.get(key)
        if isinstance(value, str) and value.strip():
            values.append(value.strip())
        elif isinstance(value, (list, tuple)):
            values.extend(str(x).strip() for x in value if str(x or "").strip())
    return "\n".join(values).strip()


def _contains_any_term(value: str, terms: list[str]) -> bool:
    if not value:
        return False
    return any(term and term in value for term in terms)


def _looks_like_benign_religious_or_educational_text(value: str) -> bool:
    """
    أمثلة آمنة يجب عدم حذفها:
    - أول ما تسأل عنه المرأة يوم القيامة
    - موعظة/سؤال ديني عام عن الصلاة، الحجاب، الأخلاق، القيامة...
    الشرط: لا يوجد سب/تحريض/عري/وصف جنسي صريح.
    """
    if not value:
        return False

    normalized = _normalize_obfuscated_text_for_moderation(value)
    spaced = str(normalized.get("spaced_collapsed") or normalized.get("spaced") or "")
    compact = str(normalized.get("compact") or "")

    benign_terms = [
        "المراه", "المرأه", "المرأة", "النساء", "البنت", "البنات", "الرجل", "الرجال",
        "يوم القيامه", "القيامه", "الاخرة", "الاخره", "الجنه", "النار", "الحساب",
        "تسال عنه", "تسأل عنه", "اول ما تسال", "اول ما تسأل", "اول ما يسال",
        "الصلاه", "الصلاة", "الحجاب", "الستر", "الاخلاق", "الأخلاق",
        "الدين", "الاسلام", "الإسلام", "موعظه", "موعظة", "حديث", "اية", "آية",
        "اذكار", "أذكار", "دعاء", "استغفار", "التوبه", "التوبة",
    ]
    benign_compact_terms = [
        "اولماتسال", "اولماتسالعنه", "اولماتسألعنه", "المراهيومالقيامه",
        "المرأةيومالقيامة", "يومالقيامه", "يومالقيامة",
    ]

    has_benign_context = _contains_any_term(spaced, benign_terms) or _contains_any_term(compact, benign_compact_terms)
    if not has_benign_context:
        return False

    # لا نخفف لو النص نفسه يحتوي مخالفة واضحة محليًا.
    if _local_hard_violation_guard(value) is not None:
        return False

    explicit_bad_terms = [
        # عربي جنسي/عري/تحرش
        "عري", "عارية", "عاريه", "اباحي", "إباحي", "جنس", "جنسي", "ايحاء جنسي", "إيحاء جنسي",
        "تحرش", "اغتصاب", "صدر", "ثدي", "مؤخرة", "مؤخره", "عضو", "اعضاء حساسه", "أعضاء حساسة",
        "ملابس داخليه", "ملابس داخلية", "شفاف", "شفافة", "جسد عاري", "مفاتن",
        # عنف/تحريض/كراهية
        "اقتل", "اقتلو", "يموت", "تعذيب", "دموي", "دماء", "سلاح", "مسدس", "سكين",
        "كفر", "كافر", "سب الدين", "سب الله", "اهانه الدين", "إهانة الدين", "لعن",
        # English common vision labels
        "nude", "nudity", "naked", "porn", "sexual", "explicit", "breast", "genitals",
        "underwear", "lingerie", "weapon", "gun", "knife", "blood", "gore", "kill",
        "hate symbol", "terrorist",
    ]
    return not _contains_any_term(spaced, explicit_bad_terms) and not _contains_any_term(compact, [t.replace(" ", "") for t in explicit_bad_terms])


def _relax_contextual_text_false_positive(
    parsed: Dict[str, Any],
    result: Dict[str, Any],
    *,
    media_kind: str = "content",
) -> Dict[str, Any]:
    """
    طبقة حماية ضد الحذف المبالغ فيه من OCR داخل الصور والفيديوهات.
    لا تلغي الحذف إذا كانت الصورة/الفيديو فيه عري أو عنف أو تهديد واضح،
    لكنها تلغي الحذف إذا كان السبب مجرد نص ديني/تعليمي عادي فهمه الموديل بشكل خاطئ.
    """
    if not RESPECT_VISION_TEXT_CONTEXT_RELAXATION:
        return result
    if not isinstance(result, dict) or result.get("shouldDelete") is not True:
        return result

    category = str(result.get("category") or "").strip().lower()
    soft_false_positive_categories = {
        "sexual", "sexual_content", "harassment", "religion_abuse", "other",
        "image_violation", "unsafe_image", "video_violation", "vision_parse_error",
        "profanity", "personal_attack", "needs_context",
    }
    if category not in soft_false_positive_categories:
        # لا نلغي عري/إباحية/عنف/سلاح/كراهية مؤكدة.
        return result

    evidence = "\n".join([
        _collect_moderation_ai_text(parsed),
        str(result.get("reason") or ""),
        str(result.get("category") or ""),
    ]).strip()

    if not _looks_like_benign_religious_or_educational_text(evidence):
        return result

    relaxed = dict(result)
    relaxed.update({
        "shouldDelete": False,
        "deleteParentReply": False,
        "category": "safe_context_text",
        "reason": (
            f"تم السماح لأن النص الظاهر في {media_kind} يبدو دينيًا/تعليميًا عامًا "
            "ولا يحتوي سبًا أو تحريضًا أو عريًا أو وصفًا جنسيًا صريحًا."
        ),
        "confidence": min(float(result.get("confidence") or 0.0), 0.35),
        "relaxedFalsePositive": True,
        "originalCategory": str(result.get("category") or ""),
        "originalReason": str(result.get("reason") or "")[:500],
    })
    return relaxed


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

    parsed = _safe_json_from_ai(str(content))
    result = _normalize_moderation_result(parsed)
    return _relax_contextual_text_false_positive(parsed, result, media_kind="النص")


def moderate_with_qwen(req: RespectAIModerationRequest) -> Dict[str, Any]:
    text = (req.text or "").strip()

    # الطبقة 1: فحص محلي صارم قبل أي سياق آمن أو مراجعة Qwen.
    # هذا يمنع تمرير الكلمات الفاحشة/السب إذا ظهرت داخل جملة تبدو RP.
    hard_violation = _local_hard_violation_guard(text)
    if hard_violation is not None:
        # _simple_safe_moderation لا يملك req؛ التعلم يتم في moderate_with_qwen قبل الوصول هنا.
        return hard_violation

    fast_safe = _simple_safe_moderation(text)
    if fast_safe is not None:
        return fast_safe

    # قبل استدعاء Qwen: جرّب ذاكرة المراجعة العامة.
    # السماح من الذاكرة يكون exact فقط، والحذف يحتاج ثقة عالية؛ لذلك لا يسبب قفزات خطيرة.
    memory_result = _moderation_memory_guard(
        text,
        content_type=(req.contentType or 'post'),
        has_media=bool((req.imageUrls or []) or (req.imageUrl or '').strip() or (req.videoUrls or []) or (req.videoUrl or '').strip()),
    )
    if memory_result is not None:
        return memory_result

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
        result.setdefault("model", QWEN_TEXT_MODEL)
        result["decisionSource"] = result.get("decisionSource") or "qwen_text_moderation"
        result["memoryLearnResult"] = _learn_moderation_memory_safely(
            req,
            result,
            text_result=result,
            source="qwen_text_moderation",
        )
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



# ================= Respect AI Recommendation Taxonomy =================
# تصنيفات رسمية مغلقة نسبيًا: لا نترك Qwen أو الذاكرة يخترعون أسماء topics عشوائية.
# أي مرادف أو كلمة عربية/إنجليزية يتم تحويلها إلى واحد من هذه التصنيفات فقط.
RECOMMENDATION_ALLOWED_TOPICS = {
    "football",
    "sports",
    "basketball",
    "gaming",
    "esports",
    "programming",
    "ai",
    "technology",
    "cybersecurity",
    "cars",
    "anime",
    "movies",
    "music",
    "food",
    "travel",
    "fashion",
    "education",
    "business",
    "finance",
    "news",
    "politics",
    "religion",
    "health",
    "fitness",
    "humor",
    "memes",
    "art",
    "photography",
    "animals",
    "nature",
    "local",
    "live_streaming",
    "video",
    "shopping",
    "beauty",
    "family",
    "personal",
    "general",
}

# مرادفات أسماء التصنيفات. هذه تستخدم عندما AI يرجع topic باسم مختلف.
RECOMMENDATION_TOPIC_ALIASES = {
    # Football / sports
    "football": "football", "footbal": "football", "soccer": "football", "كرة": "football", "كوره": "football",
    "كورة": "football", "كره": "football", "كرة_قدم": "football", "كرة_القدم": "football", "كرةقدم": "football",
    "مباريات": "football", "مباراه": "football", "مباراة": "football", "اهداف": "football", "أهداف": "football",
    "goal": "football", "goals": "football", "messi": "football", "ronaldo": "football", "ميسي": "football", "رونالدو": "football",
    "sports": "sports", "sport": "sports", "رياضه": "sports", "رياضة": "sports", "رياضي": "sports",
    "basketball": "basketball", "nba": "basketball", "سلة": "basketball", "كره_السله": "basketball", "كرة_السلة": "basketball",

    # Gaming / live
    "gaming": "gaming", "game": "gaming", "games": "gaming", "gamer": "gaming", "العاب": "gaming", "ألعاب": "gaming",
    "لعبه": "gaming", "لعبة": "gaming", "قيمنق": "gaming", "قيمز": "gaming", "pubg": "gaming", "ببجي": "gaming",
    "fortnite": "gaming", "فورتنايت": "gaming", "minecraft": "gaming", "ماينكرافت": "gaming", "gta": "gaming",
    "fivem": "gaming", "فايف_ام": "gaming", "valorant": "gaming", "فالورانت": "gaming",
    "esport": "esports", "esports": "esports", "ايسبورت": "esports", "بطوله_العاب": "esports", "بطولة_العاب": "esports",
    "stream": "live_streaming", "streaming": "live_streaming", "live": "live_streaming", "بث": "live_streaming", "بثوث": "live_streaming", "لايف": "live_streaming",

    # Tech / code / AI / security
    "tech": "technology", "technology": "technology", "تقنيه": "technology", "تقنية": "technology", "تكنولوجيا": "technology",
    "phone": "technology", "mobile": "technology", "pc": "technology", "computer": "technology", "كمبيوتر": "technology", "جوال": "technology", "هاتف": "technology",
    "programming": "programming", "coding": "programming", "code": "programming", "software": "programming", "developer": "programming",
    "flutter": "programming", "dart": "programming", "python": "programming", "javascript": "programming", "typescript": "programming",
    "supabase": "programming", "firebase": "programming", "برمجه": "programming", "برمجة": "programming", "كود": "programming", "مطور": "programming",
    "ai": "ai", "artificial_intelligence": "ai", "ذكاء_اصطناعي": "ai", "الذكاء_الاصطناعي": "ai", "gpt": "ai", "chatgpt": "ai",
    "openai": "ai", "qwen": "ai", "deepseek": "ai", "gemini": "ai", "llm": "ai", "model": "ai", "نموذج": "ai",
    "security": "cybersecurity", "cyber": "cybersecurity", "cybersecurity": "cybersecurity", "امن_سيبراني": "cybersecurity",
    "أمن_سيبراني": "cybersecurity", "حماية": "cybersecurity", "اختراق": "cybersecurity", "ثغرة": "cybersecurity",

    # Lifestyle / media
    "cars": "cars", "car": "cars", "سياره": "cars", "سيارة": "cars", "سيارات": "cars", "bmw": "cars", "mercedes": "cars", "مرسيدس": "cars",
    "anime": "anime", "manga": "anime", "انمي": "anime", "أنمي": "anime", "مانجا": "anime",
    "movie": "movies", "movies": "movies", "film": "movies", "cinema": "movies", "netflix": "movies", "فيلم": "movies", "افلام": "movies", "أفلام": "movies",
    "music": "music", "song": "music", "songs": "music", "rap": "music", "اغنية": "music", "أغنية": "music", "موسيقى": "music", "راب": "music",
    "food": "food", "restaurant": "food", "recipe": "food", "اكل": "food", "أكل": "food", "مطعم": "food", "طبخ": "food", "وصفة": "food",
    "travel": "travel", "trip": "travel", "tourism": "travel", "سفر": "travel", "رحلة": "travel", "سياحة": "travel",
    "fashion": "fashion", "style": "fashion", "ملابس": "fashion", "ستايل": "fashion", "موضة": "fashion",
    "shopping": "shopping", "shop": "shopping", "buy": "shopping", "تسوق": "shopping", "شراء": "shopping", "منتج": "shopping",
    "beauty": "beauty", "makeup": "beauty", "مكياج": "beauty", "جمال": "beauty",

    # Knowledge / society
    "education": "education", "study": "education", "school": "education", "تعليم": "education", "دراسة": "education", "مدرسة": "education", "جامعة": "education",
    "business": "business", "startup": "business", "project": "business", "مشروع": "business", "تجارة": "business", "شركة": "business",
    "finance": "finance", "money": "finance", "crypto": "finance", "bitcoin": "finance", "دولار": "finance", "مال": "finance", "استثمار": "finance", "عملة": "finance",
    "news": "news", "breaking": "news", "اخبار": "news", "أخبار": "news", "خبر": "news", "عاجل": "news",
    "politics": "politics", "political": "politics", "سياسة": "politics", "سياسي": "politics", "رئيس": "politics", "انتخابات": "politics",
    "religion": "religion", "دين": "religion", "اسلام": "religion", "إسلام": "religion", "قران": "religion", "قرآن": "religion", "صلاة": "religion",
    "health": "health", "medical": "health", "doctor": "health", "صحة": "health", "طبيب": "health", "مرض": "health",
    "fitness": "fitness", "gym": "fitness", "workout": "fitness", "جيم": "fitness", "تمرين": "fitness", "رياضه_بدنيه": "fitness",
    "family": "family", "عائلة": "family", "اهل": "family", "أهل": "family", "طفل": "family",

    # Fun / creative / nature
    "humor": "humor", "funny": "humor", "lol": "humor", "ضحك": "humor", "نكتة": "humor", "هههه": "humor",
    "meme": "memes", "memes": "memes", "ميم": "memes", "ميمز": "memes",
    "art": "art", "design": "art", "رسم": "art", "فن": "art", "تصميم": "art",
    "photography": "photography", "photo": "photography", "camera": "photography", "تصوير": "photography", "صورة": "photography", "كاميرا": "photography",
    "animals": "animals", "animal": "animals", "cat": "animals", "dog": "animals", "حيوان": "animals", "قط": "animals", "كلب": "animals",
    "nature": "nature", "طبيعه": "nature", "طبيعة": "nature", "شجر": "nature", "بحر": "nature",
    "local": "local", "لبنان": "local", "سوريا": "local", "السعوديه": "local", "السعودية": "local", "محلي": "local",
    "video": "video", "فيديو": "video", "مقطع": "video",
    "personal": "personal", "شخصي": "personal", "يوميات": "personal",
    "general": "general", "عام": "general",
}

TOPIC_KEYWORD_RULES = {
    "football": ["كورة", "كوره", "كره", "كرة", "هدف", "اهداف", "أهداف", "مباراة", "مباراه", "ريال", "مدريد", "برشلونة", "برشلونه", "ميسي", "رونالدو", "نيمار", "مبابي", "هالاند", "صلاح", "الارجنتين", "الأرجنتين", "البرازيل", "دوري", "كأس", "كاس", "football", "soccer", "goal", "messi", "ronaldo", "neymar", "mbappe", "haaland", "argentina", "barcelona", "match", "league", "champions"],
    "basketball": ["basketball", "nba", "سلة", "كرة السلة", "كره السله", "باسكت"],
    "sports": ["رياضة", "رياضه", "sport", "sports", "بطولة", "بطوله", "أولمبياد", "olympic", "tennis", "تنس", "سباق"],
    "gaming": ["قيم", "قيمنق", "العاب", "ألعاب", "game", "gaming", "gta", "fivem", "فايف ام", "pubg", "ببجي", "fortnite", "minecraft", "valorant", "playstation", "بلايستيشن"],
    "esports": ["esports", "ايسبورت", "بطولة فورتنايت", "بطولة ببجي", "بطولة ألعاب", "tournament"],
    "programming": ["برمجة", "برمجه", "flutter", "dart", "python", "javascript", "typescript", "react", "node", "fastapi", "supabase", "firebase", "github", "sql", "api", "كود", "مطور"],
    "ai": ["ذكاء اصطناعي", "الذكاء الاصطناعي", "ai", "gpt", "chatgpt", "qwen", "deepseek", "gemini", "openai", "llm", "model", "نموذج"],
    "technology": ["تقنية", "تقنيه", "تكنولوجيا", "جوال", "هاتف", "كمبيوتر", "تطبيق", "android", "ios", "technology", "phone", "pc", "laptop"],
    "cybersecurity": ["امن سيبراني", "أمن سيبراني", "cyber", "security", "اختراق", "حماية", "ثغرة", "malware", "virus", "hacker"],
    "cars": ["سيارة", "سياره", "سيارات", "car", "cars", "bmw", "mercedes", "toyota", "محرك", "درفت"],
    "anime": ["انمي", "أنمي", "anime", "manga", "مانجا", "ناروتو", "ون بيس"],
    "movies": ["فيلم", "افلام", "أفلام", "movie", "movies", "cinema", "netflix", "مسلسل", "series"],
    "music": ["اغنية", "أغنية", "موسيقى", "music", "song", "rap", "راب", "البوم", "ألبوم"],
    "food": ["اكل", "أكل", "مطعم", "طبخ", "وصفة", "food", "restaurant", "recipe", "pizza", "burger"],
    "travel": ["سفر", "رحلة", "سياحة", "travel", "trip", "airport", "مطار", "فندق"],
    "fashion": ["موضة", "ملابس", "ستايل", "fashion", "style", "outfit"],
    "education": ["تعليم", "دراسة", "مدرسة", "جامعة", "امتحان", "education", "study", "school", "university"],
    "business": ["مشروع", "تجارة", "شركة", "business", "startup", "marketing"],
    "finance": ["دولار", "عملة", "مال", "استثمار", "finance", "crypto", "bitcoin", "سعر", "سوق"],
    "news": ["خبر", "اخبار", "أخبار", "عاجل", "news", "breaking"],
    "politics": ["سياسة", "سياسي", "انتخابات", "رئيس", "حكومة", "politics", "election", "president"],
    "religion": ["دين", "اسلام", "إسلام", "قرآن", "قران", "صلاة", "دعاء", "religion", "islam"],
    "health": ["صحة", "طبيب", "مرض", "دواء", "health", "medical", "doctor", "medicine"],
    "fitness": ["جيم", "تمرين", "عضلات", "fitness", "gym", "workout"],
    "humor": ["ضحك", "نكتة", "هههه", "funny", "lol", "comedy"],
    "memes": ["ميم", "ميمز", "meme", "memes"],
    "art": ["رسم", "فن", "تصميم", "art", "design", "drawing"],
    "photography": ["تصوير", "صورة", "كاميرا", "photo", "camera", "picture"],
    "animals": ["قط", "كلب", "حيوان", "animals", "cat", "dog"],
    "nature": ["طبيعة", "طبيعه", "بحر", "شجر", "nature", "sea", "mountain"],
    "shopping": ["تسوق", "شراء", "منتج", "سعر", "عرض", "shopping", "buy", "deal"],
    "beauty": ["مكياج", "جمال", "عناية", "beauty", "makeup", "skin"],
    "family": ["عائلة", "اهل", "أهل", "طفل", "family", "kids"],
    "local": ["لبنان", "سوريا", "السعودية", "السعوديه", "بيروت", "الرياض", "محلي"],
    "live_streaming": ["بث", "بثوث", "لايف", "stream", "streaming", "live"],
}

ARABIC_DIACRITICS_RE = re.compile(r"[\u0610-\u061A\u064B-\u065F\u0670\u06D6-\u06ED]")


def _normalize_topic_text(value: Any) -> str:
    text = str(value or "").strip().lower()
    if not text:
        return ""
    text = ARABIC_DIACRITICS_RE.sub("", text)
    text = text.replace("ـ", "")
    text = text.replace("أ", "ا").replace("إ", "ا").replace("آ", "ا")
    text = text.replace("ى", "ي").replace("ؤ", "و").replace("ئ", "ي")
    text = text.replace("ة", "ه")
    text = text.replace("#", " ")
    text = re.sub(r"[^a-z0-9\u0600-\u06FF]+", " ", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text


def _normalize_recommendation_topic(value: Any) -> str:
    # دالة تنظيف عامة للكلمات والمفاتيح والهاشتاقات. لا تعتبرها تصنيفًا رسميًا إلا بعد _canonical_topic_for_text.
    text = _normalize_topic_text(value)
    if not text:
        return ""
    key = text.replace(" ", "_")
    key = re.sub(r"_+", "_", key).strip("_")
    if len(key) > 80:
        key = key[:80].strip("_")
    return key


def _alias_lookup_key(value: Any) -> str:
    return _normalize_recommendation_topic(value)


_NORMALIZED_TOPIC_ALIASES = {
    _alias_lookup_key(k): v
    for k, v in RECOMMENDATION_TOPIC_ALIASES.items()
    if _alias_lookup_key(k) and v in RECOMMENDATION_ALLOWED_TOPICS
}


def _text_has_topic_signal(topic: str, text: str) -> bool:
    canonical = RECOMMENDATION_TOPIC_ALIASES.get(topic, topic)
    normalized_text = _normalize_topic_text(text)
    if not normalized_text:
        return False
    compact = normalized_text.replace(" ", "_")
    for raw_word in TOPIC_KEYWORD_RULES.get(canonical, []):
        word_text = _normalize_topic_text(raw_word)
        if not word_text:
            continue
        word_key = word_text.replace(" ", "_")
        if word_text in normalized_text or word_key in compact:
            return True
    return False


def _text_has_football_signal(text: str) -> bool:
    return _text_has_topic_signal("football", text)


def _topic_from_keyword_signal(value: Any) -> str:
    key = _normalize_recommendation_topic(value)
    if not key:
        return ""
    if key in _NORMALIZED_TOPIC_ALIASES:
        return _NORMALIZED_TOPIC_ALIASES[key]
    text = _normalize_topic_text(value)
    compact = text.replace(" ", "_")
    for topic, words in TOPIC_KEYWORD_RULES.items():
        for raw_word in words:
            word_text = _normalize_topic_text(raw_word)
            if not word_text:
                continue
            word_key = word_text.replace(" ", "_")
            if word_text == text or word_key == compact:
                return topic
    return ""


def _canonical_topic_for_text(topic: str, text: str = "") -> str:
    clean = _normalize_recommendation_topic(topic)
    if not clean:
        return ""

    mapped = _NORMALIZED_TOPIC_ALIASES.get(clean, clean)

    # sports يبقى sports للرياضات العامة، لكنه يتحول football إذا النص فيه إشارات كرة قدم واضحة.
    if mapped in {"sports", "sport"} and _text_has_football_signal(text):
        return "football"

    # إذا رجع AI اسم موديل/أداة أو كلمة مفتاحية كتصنيف، نحولها للتصنيف الرسمي.
    if mapped not in RECOMMENDATION_ALLOWED_TOPICS:
        mapped = _topic_from_keyword_signal(clean)

    if mapped in RECOMMENDATION_ALLOWED_TOPICS:
        return mapped
    return ""


def _canonical_topics_for_text(topics: list[str], text: str = "") -> list[str]:
    out: list[str] = []
    for topic in topics or []:
        clean = _canonical_topic_for_text(str(topic or ""), text)
        if clean and clean not in out:
            out.append(clean)

    # تصحيح سياقي مهم: إذا وُجد football نحذف sports من نفس المنشور حتى لا تتكرر اهتمامات كرة القدم.
    if _text_has_football_signal(text) and "football" in out:
        out = ["football", *[t for t in out if t not in {"football", "sports"}]]

    return out or ["general"]


def _fallback_post_topics(text: str, media_type: str = "text") -> list[str]:
    raw = text or ""
    topics: list[str] = []

    def add(topic: str) -> None:
        clean = _canonical_topic_for_text(topic, raw)
        if clean and clean not in topics:
            topics.append(clean)

    # الهاشتاق لا يتحول إلى topic عشوائي. فقط إذا كان الهاشتاق معروفًا ضمن التصنيفات الرسمية.
    for m in re.finditer(r"#([\w\u0600-\u06FF_]+)", raw):
        add(m.group(1))

    for topic in TOPIC_KEYWORD_RULES.keys():
        if _text_has_topic_signal(topic, raw):
            add(topic)

    mt = (media_type or "text").strip().lower()
    if mt == "video":
        add("video")
    if mt in {"image", "gif"}:
        add("photography")

    if not topics:
        add("general")
    return topics[:10]


def _extract_topics_from_ai_json(data: Dict[str, Any], fallback: list[str], text: str = "") -> tuple[list[str], str, float]:
    raw_topics = data.get("topics") or data.get("categories") or data.get("tags") or []
    if isinstance(raw_topics, str):
        try:
            raw_topics = json.loads(raw_topics)
        except Exception:
            raw_topics = [raw_topics]

    topics: list[str] = []

    def add(value: Any) -> None:
        if isinstance(value, dict):
            value = value.get("topic") or value.get("name") or value.get("tag") or value.get("id") or ""
        clean = _canonical_topic_for_text(str(value or ""), text)
        if clean and clean not in topics:
            topics.append(clean)

    if isinstance(raw_topics, list):
        for item in raw_topics:
            add(item)

    primary = _canonical_topic_for_text(
        data.get("primaryTopic") or data.get("primary_topic") or (topics[0] if topics else ""),
        text,
    )
    if primary:
        add(primary)

    if not topics:
        topics = _canonical_topics_for_text(list(fallback or ["general"]), text)
    else:
        topics = _canonical_topics_for_text(topics, text)

    if not primary or primary not in topics:
        primary = topics[0] if topics else "general"

    try:
        confidence = float(data.get("confidence") or 0.0)
    except Exception:
        confidence = 0.0
    confidence = max(0.0, min(1.0, confidence))
    return topics[:10], primary, confidence


def _topic_memory_terms(text: str) -> Dict[str, Any]:
    raw = _normalize_topic_text(text)
    hashtags = [
        _normalize_recommendation_topic(m.group(1) or "")
        for m in re.finditer(r"#([\w\u0600-\u06FF_]+)", text or "")
    ]
    hashtags = [h for h in hashtags if h]

    tokens = [
        _normalize_recommendation_topic(m.group(0) or "")
        for m in re.finditer(r"[a-z0-9_\u0600-\u06FF]{2,}", raw)
    ]
    stop = {
        "هذا", "هذه", "هذي", "الي", "اللي", "على", "الى", "الي", "في", "من", "عن", "مع", "كان", "صار",
        "انا", "انت", "انتي", "هو", "هي", "هم", "نحن", "اليوم", "امس", "بكرا", "جدا", "مره", "مرة", "عالميه", "عالمية",
        "the", "and", "for", "with", "this", "that", "you", "are", "was", "were", "today",
    }
    tokens = [t for t in tokens if t and t not in stop and len(t) >= 2]
    unique_tokens: list[str] = []
    for t in tokens:
        if t not in unique_tokens:
            unique_tokens.append(t)

    phrases: list[str] = []
    for n in (2, 3):
        for i in range(0, max(0, len(unique_tokens) - n + 1)):
            phrase = "_".join(unique_tokens[i:i + n])
            if len(phrase) >= 5 and phrase not in phrases:
                phrases.append(phrase)

    return {
        "raw": raw,
        "tokens": unique_tokens[:80],
        "token_set": set(unique_tokens),
        "hashtags": hashtags[:30],
        "hashtag_set": set(hashtags),
        "phrases": phrases[:80],
        "phrase_set": set(phrases),
    }


def _get_ai_topic_memory_rows() -> list[Dict[str, Any]]:
    if not SB_SERVICE:
        return []
    headers = _supabase_headers(use_service_role=True)
    try:
        r = requests.get(
            f"{SB_URL}/rest/v1/ai_topic_memory",
            headers=headers,
            params={
                "select": "topic,memory_type,memory_key,phrase,confidence,hits,weight,source",
                "order": "hits.desc,updated_at.desc",
                "limit": str(max(200, AI_TOPIC_MEMORY_MAX_ROWS)),
            },
            timeout=10,
        )
        if r.status_code // 100 != 2:
            logger.warning("ai_topic_memory read failed status=%s body=%s", r.status_code, _safe_response_text(r.text, 300))
            return []
        data = r.json()
        if isinstance(data, list):
            return [x for x in data if isinstance(x, dict)]
    except Exception as e:
        logger.warning("ai_topic_memory read exception: %s", e)
    return []


def _memory_key_matches_text(key: str, memory_type: str, terms: Dict[str, Any]) -> bool:
    clean_key = _normalize_recommendation_topic(key)
    if not clean_key:
        return False

    raw = str(terms.get("raw") or "")
    token_set = terms.get("token_set") or set()
    hashtag_set = terms.get("hashtag_set") or set()
    phrase_set = terms.get("phrase_set") or set()
    parts = [p for p in clean_key.split("_") if p]

    if memory_type == "hashtag":
        return clean_key in hashtag_set or clean_key in token_set

    if memory_type == "phrase":
        if clean_key in phrase_set or clean_key.replace("_", " ") in raw or clean_key in raw:
            return True
        # عبارة قصيرة مثل ميسي_سجل_هدف: نعتبرها مطابقة إذا أغلب كلماتها موجودة.
        if len(parts) >= 2:
            matched_parts = sum(1 for p in parts if p in token_set)
            return matched_parts >= max(2, int(len(parts) * 0.67))
        return False

    # keyword
    if clean_key in token_set:
        return True
    if len(parts) >= 2:
        matched_parts = sum(1 for p in parts if p in token_set)
        return matched_parts >= max(2, int(len(parts) * 0.67))
    return len(clean_key) >= 4 and clean_key.replace("_", " ") in raw


def _record_topic_memory_hits(matches: list[Dict[str, Any]]) -> None:
    # لا نمنع التصنيف لو فشل تحديث hits، هذه فقط لتحسين التعلم.
    for item in matches[:12]:
        try:
            _upsert_ai_topic_memory(
                topic=str(item.get("topic") or ""),
                memory_type=str(item.get("memory_type") or "keyword"),
                memory_key=str(item.get("memory_key") or ""),
                phrase=str(item.get("phrase") or ""),
                reason="استخدمت الذاكرة هذا المفتاح لتصنيف منشور مشابه.",
                confidence=float(item.get("confidence") or 0.7),
                source="memory",
                model="respect_topic_memory_v2",
            )
        except Exception:
            pass


def _classify_post_with_topic_memory(req: RespectAIPostClassifyRequest) -> Optional[Dict[str, Any]]:
    text = (req.text or "").strip()
    image_urls = [u.strip() for u in [*req.imageUrls, req.imageUrl] if str(u or "").strip()]
    # إذا المنشور صورة/فيديو بدون نص، الذاكرة النصية لا تكفي، نحتاج Vision/Text AI.
    if len(text) < 3 and image_urls:
        return None

    terms = _topic_memory_terms(text)
    if not terms["token_set"] and not terms["hashtag_set"] and not terms["phrase_set"]:
        return None

    rows = _get_ai_topic_memory_rows()
    if not rows:
        return None

    topic_scores: Dict[str, float] = defaultdict(float)
    topic_matches: Dict[str, list[str]] = defaultdict(list)
    topic_match_rows: Dict[str, list[Dict[str, Any]]] = defaultdict(list)

    for row in rows:
        raw_topic = _normalize_recommendation_topic(row.get("topic") or "")
        topic = _canonical_topic_for_text(raw_topic, text)
        key = _normalize_recommendation_topic(row.get("memory_key") or row.get("keyword") or row.get("phrase") or row.get("hashtag") or "")
        memory_type = str(row.get("memory_type") or "keyword").strip().lower()
        if not topic or not key or topic == "general":
            continue

        if not _memory_key_matches_text(key, memory_type, terms):
            continue

        try:
            confidence = float(row.get("confidence") or 0.55)
        except Exception:
            confidence = 0.55
        try:
            hits = int(float(row.get("hits") or 1))
        except Exception:
            hits = 1
        try:
            weight = float(row.get("weight") or 1.0)
        except Exception:
            weight = 1.0

        type_bonus = 0.0
        if memory_type == "hashtag":
            type_bonus = 0.25
        elif memory_type == "phrase":
            type_bonus = 0.18
        else:
            type_bonus = 0.08

        hit_bonus = min(0.35, math.log1p(max(1, hits)) * 0.12)
        score = max(0.12, weight) * max(0.25, min(1.0, confidence)) + type_bonus + hit_bonus

        # مفاتيح كرة القدم المشهورة مثل ميسي/رونالدو قوية جدًا للتصنيف.
        if topic == "football" and _text_has_football_signal(key):
            score += 0.18

        topic_scores[topic] += score
        if key not in topic_matches[topic]:
            topic_matches[topic].append(key)
        topic_match_rows[topic].append({
            "topic": topic,
            "memory_type": memory_type,
            "memory_key": key,
            "phrase": row.get("phrase") or text[:500],
            "confidence": confidence,
        })

    if not topic_scores:
        return None

    ranked = sorted(topic_scores.items(), key=lambda kv: kv[1], reverse=True)
    best_topic, best_score = ranked[0]
    total_score = sum(max(0.0, score) for _, score in ranked)
    match_count = len(topic_matches.get(best_topic, []))
    dominance = best_score / max(0.001, total_score)

    confidence = 0.42 + (best_score / (best_score + 1.15)) * 0.48
    confidence += min(0.10, match_count * 0.035)
    if dominance >= 0.72:
        confidence += 0.05
    confidence = max(0.0, min(0.96, confidence))

    # حماية من التطابق الضعيف جدًا: كلمة واحدة ضعيفة وغير مكررة لا تكفي.
    if match_count < 2 and best_score < 0.92:
        return None

    if confidence < AI_TOPIC_MEMORY_MIN_CONFIDENCE:
        return None

    topics = [topic for topic, _ in ranked[:5]]
    topics = _canonical_topics_for_text(topics, text)
    if _text_has_football_signal(text) and "football" in topics:
        topics = ["football", *[t for t in topics if t not in {"football", "sports"}]]
        best_topic = "football"

    _record_topic_memory_hits(topic_match_rows.get(best_topic, []))

    logger.info(
        "Respect AI topic memory hit post_id=%s topic=%s confidence=%.3f matches=%s",
        req.postId,
        best_topic,
        confidence,
        topic_matches.get(best_topic, [])[:8],
    )

    return {
        "topics": topics,
        "primaryTopic": best_topic,
        "confidence": confidence,
        "fallback": False,
        "memoryUsed": True,
        "source": "memory",
        "model": "respect_topic_memory_v2",
        "keywords": topic_matches.get(best_topic, [])[:12],
        "reason": "تم التصنيف من ذاكرة Respect AI الجانبية بناءً على تطابق كلمات/عبارات سابقة بثقة كافية، لذلك لم يتم استدعاء Qwen.",
    }


def _keywords_from_ai_json(data: Dict[str, Any], text: str) -> list[str]:
    raw_keywords = data.get("keywords") or data.get("importantKeywords") or data.get("important_keywords") or data.get("terms") or []
    if isinstance(raw_keywords, str):
        try:
            raw_keywords = json.loads(raw_keywords)
        except Exception:
            raw_keywords = re.split(r"[,،\n]+", raw_keywords)

    keywords: list[str] = []
    if isinstance(raw_keywords, list):
        for item in raw_keywords:
            if isinstance(item, dict):
                item = item.get("keyword") or item.get("term") or item.get("word") or item.get("text") or ""
            clean = _normalize_recommendation_topic(item)
            if clean and clean not in keywords and len(clean) >= 2:
                keywords.append(clean)

    terms = _topic_memory_terms(text)
    # الكلمات المفتاحية تحفظ ككلمات قصيرة فقط. العبارات تُضاف لاحقًا كـ phrase حتى لا تتكرر كـ keyword و phrase.
    for key in [*terms["hashtags"], *terms["tokens"][:18]]:
        clean = _normalize_recommendation_topic(key)
        if clean and clean not in keywords and len(clean) >= 2:
            keywords.append(clean)

    return keywords[:AI_TOPIC_MEMORY_MAX_TERMS_PER_POST]


def _reason_from_ai_json(data: Dict[str, Any]) -> str:
    reason = data.get("reason") or data.get("why") or data.get("explanation") or data.get("analysis") or ""
    if isinstance(reason, (dict, list)):
        try:
            reason = json.dumps(reason, ensure_ascii=False)
        except Exception:
            reason = str(reason)
    return str(reason or "").strip()[:700]


def _upsert_ai_topic_memory(
    *,
    topic: str,
    memory_type: str,
    memory_key: str,
    phrase: str,
    reason: str,
    confidence: float,
    source: str,
    model: str,
) -> None:
    if not SB_SERVICE:
        return
    clean_topic = _canonical_topic_for_text(topic, phrase or memory_key)
    clean_key = _normalize_recommendation_topic(memory_key)
    if not clean_topic or clean_topic == "general" or clean_topic not in RECOMMENDATION_ALLOWED_TOPICS or not clean_key or len(clean_key) < 2:
        return

    payload = {
        "p_topic": clean_topic,
        "p_memory_type": memory_type,
        "p_memory_key": clean_key,
        "p_phrase": (phrase or "")[:500],
        "p_reason": (reason or "")[:700],
        "p_confidence": max(0.0, min(1.0, float(confidence or 0.0))),
        "p_source": source or "respect_ai",
        "p_model": model or "",
    }
    headers = {**_supabase_headers(use_service_role=True), "Prefer": "return=minimal"}
    try:
        r = requests.post(f"{SB_URL}/rest/v1/rpc/respect_ai_upsert_topic_memory", headers=headers, json=payload, timeout=8)
        if r.status_code // 100 == 2:
            return
    except Exception:
        pass

    # احتياط لو لم تضف دالة RPC بعد: upsert مباشر بدون زيادة hits الذكية.
    try:
        row = {
            "topic": clean_topic,
            "memory_type": memory_type,
            "memory_key": clean_key,
            "phrase": (phrase or "")[:500],
            "reason": (reason or "")[:700],
            "confidence": max(0.0, min(1.0, float(confidence or 0.0))),
            "source": source or "respect_ai",
            "model": model or "",
            "hits": 1,
            "weight": 1.0,
            "updated_at": datetime.now(timezone.utc).isoformat(),
        }
        requests.post(
            f"{SB_URL}/rest/v1/ai_topic_memory",
            headers={**headers, "Prefer": "resolution=merge-duplicates,return=minimal"},
            params={"on_conflict": "topic,memory_type,memory_key"},
            json=row,
            timeout=8,
        )
    except Exception as e:
        logger.warning("ai_topic_memory upsert exception: %s", e)


def _learn_topic_memory_from_analysis(
    req: RespectAIPostClassifyRequest,
    *,
    topics: list[str],
    confidence: float,
    model: str,
    source: str,
    reason: str,
    keywords: list[str],
) -> None:
    if not topics or confidence < AI_TOPIC_MEMORY_LEARN_MIN_CONFIDENCE:
        return
    if source in {"local_fallback", "topic_memory", "memory"}:
        return

    text = (req.text or "").strip()
    terms = _topic_memory_terms(text)
    primary_topics = _canonical_topics_for_text([str(t) for t in topics[:3]], text)
    primary_topics = [t for t in primary_topics if t and t != "general"]
    if _text_has_football_signal(text) and "football" in primary_topics:
        primary_topics = ["football", *[t for t in primary_topics if t not in {"football", "sports"}]]
    primary_topics = primary_topics[:2]

    memory_items: list[tuple[str, str]] = []
    for h in terms["hashtags"]:
        memory_items.append(("hashtag", h))
    for kw in keywords:
        clean_kw = _normalize_recommendation_topic(kw)
        if not clean_kw:
            continue
        # إذا رجع AI عبارة مركبة، خزّنها كـ phrase لا كـ keyword.
        if "_" in clean_kw:
            memory_items.append(("phrase", clean_kw))
        else:
            memory_items.append(("keyword", clean_kw))
    for phrase in terms["phrases"][:5]:
        memory_items.append(("phrase", phrase))

    seen: set[tuple[str, str]] = set()
    limited_items: list[tuple[str, str]] = []
    for memory_type, key in memory_items:
        clean_key = _normalize_recommendation_topic(key)
        if not clean_key or len(clean_key) < 2:
            continue
        pair = (memory_type, clean_key)
        if pair in seen:
            continue
        seen.add(pair)
        limited_items.append(pair)
        if len(limited_items) >= AI_TOPIC_MEMORY_MAX_TERMS_PER_POST:
            break

    phrase_preview = text[:500]
    for topic in primary_topics:
        for memory_type, key in limited_items:
            _upsert_ai_topic_memory(
                topic=topic,
                memory_type=memory_type,
                memory_key=key,
                phrase=phrase_preview,
                reason=reason,
                confidence=confidence,
                source=source,
                model=model,
            )


def _post_topic_classification_prompt(req: RespectAIPostClassifyRequest) -> str:
    allowed = ", ".join(sorted(RECOMMENDATION_ALLOWED_TOPICS))
    return (
        "حلل هذا المنشور لتوصيات تبويب For You في تطبيق Respect. "
        "لا تراجع السلامة ولا تحذف المحتوى؛ فقط صنّف الاهتمامات. "
        "أرجع JSON فقط بدون شرح بهذا الشكل: "
        "{\"topics\":[\"football\",\"sports\"],\"primaryTopic\":\"football\",\"confidence\":0.92,\"keywords\":[\"هدف\",\"ريال\"],\"reason\":\"المنشور يتكلم عن مباراة وهدف\"}. "
        "مهم جدًا: أضف keywords قصيرة من النص/الصورة و reason يشرح لماذا اخترت التصنيف حتى تتعلم ذاكرة التطبيق لاحقًا. "
        "استخدم فقط تصنيفات إنجليزية snake_case من القائمة الرسمية، ولا تخترع أي topic جديد. "
        f"القائمة الرسمية الوحيدة: {allowed}. "
        "إذا لم تجد تصنيفًا مناسبًا اختر general فقط. "
        f"نوع الوسائط: {req.mediaType}. "
        f"الكاتب: {display_username(req.username)}. "
        f"النص:\n{(req.text or '').strip()[:3000]}"
    )


def _store_post_topics(
    post_id: str,
    topics: list[str],
    confidence: float,
    model: str,
    source: str = "respect_ai",
    *,
    primary_topic: str = "",
    reason: str = "",
    keywords: Optional[list[str]] = None,
    memory_used: bool = False,
) -> bool:
    pid = (post_id or "").strip()
    if not pid or not SB_SERVICE:
        return False
    # لا نخزن تصنيفات fallback الضعيفة حتى لا تدخل أسماء أو كلمات عشوائية في خوارزمية For You.
    source_clean = str(source or "").strip().lower()
    if confidence < POST_TOPIC_STORE_MIN_CONFIDENCE and ("fallback" in source_clean or source_clean in {"local", "interaction_fallback"}):
        return False

    cleaned = []
    for topic in topics:
        clean = _canonical_topic_for_text(str(topic or ""), "")
        if clean and clean in RECOMMENDATION_ALLOWED_TOPICS and clean not in cleaned:
            cleaned.append(clean)
    cleaned = [t for t in cleaned if t != "general" or len(cleaned) == 1]
    if not cleaned:
        return False

    primary_clean = _canonical_topic_for_text(primary_topic or cleaned[0], "")
    if primary_clean not in cleaned:
        primary_clean = cleaned[0]
    # نخلي التصنيف الرئيسي دائمًا أول صف حتى تكون القراءة والاستعلامات واضحة.
    cleaned = [primary_clean, *[t for t in cleaned if t != primary_clean]][:10]

    clean_keywords: list[str] = []
    for kw in (keywords or []):
        clean_kw = _normalize_recommendation_topic(kw)
        if clean_kw and clean_kw not in clean_keywords:
            clean_keywords.append(clean_kw)

    headers = {**_supabase_headers(use_service_role=True), "Prefer": "return=minimal"}
    try:
        requests.delete(
            f"{SB_URL}/rest/v1/post_topics",
            headers=headers,
            params={"post_id": f"eq.{pid}"},
            timeout=10,
        )
        rows = []
        for i, topic in enumerate(cleaned[:10]):
            rank = i + 1
            is_primary = topic == primary_clean and rank == 1
            rows.append({
                "post_id": pid,
                "topic": topic,
                "weight": 1.0 if is_primary else max(0.35, 0.86 - (i * 0.06)),
                "confidence": confidence,
                "source": source,
                # الأعمدة الجديدة التي توضّح primary/secondary داخل post_topics.
                "topic_role": "primary" if is_primary else "secondary",
                "is_primary": bool(is_primary),
                "topic_rank": rank,
                "model": model,
            })

        r = requests.post(f"{SB_URL}/rest/v1/post_topics", headers=headers, json=rows, timeout=10)
        # توافق مع قاعدة البيانات القديمة إذا لم تشغل SQL إضافة الأعمدة بعد.
        if r.status_code == 400 and any(word in _safe_response_text(r.text, 800).lower() for word in ["topic_role", "is_primary", "topic_rank", "model", "column"]):
            legacy_rows = [
                {
                    "post_id": row["post_id"],
                    "topic": row["topic"],
                    "weight": row["weight"],
                    "confidence": row["confidence"],
                    "source": row["source"],
                }
                for row in rows
            ]
            r = requests.post(f"{SB_URL}/rest/v1/post_topics", headers=headers, json=legacy_rows, timeout=10)
        ok = r.status_code // 100 == 2

        classification_row = {
            "post_id": pid,
            "topics": cleaned[:10],
            "primary_topic": primary_clean,
            "confidence": confidence,
            "model": model,
            "source": source,
            "reason": (reason or "")[:700],
            "keywords": clean_keywords[:30],
            "memory_used": bool(memory_used),
        }

        try:
            cr = requests.post(
                f"{SB_URL}/rest/v1/post_ai_classifications",
                headers=headers,
                json=classification_row,
                timeout=8,
            )
            if cr.status_code >= 400:
                # توافق مع الجدول القديم قبل إضافة reason/keywords/memory_used.
                old_row = {
                    "post_id": pid,
                    "topics": cleaned[:10],
                    "primary_topic": primary_clean,
                    "confidence": confidence,
                    "model": model,
                    "source": source,
                }
                requests.post(
                    f"{SB_URL}/rest/v1/post_ai_classifications",
                    headers=headers,
                    json=old_row,
                    timeout=8,
                )
        except Exception:
            pass

        if not ok:
            logger.warning("post_topics store failed status=%s body=%s", r.status_code, _safe_response_text(r.text, 500))
        return ok
    except Exception as e:
        logger.warning("post_topics store exception: %s", e)
        return False


def _classify_post_with_qwen(req: RespectAIPostClassifyRequest) -> Dict[str, Any]:
    fallback = _fallback_post_topics(req.text, req.mediaType)

    # 1) نجرّب الذاكرة الجانبية أولًا.
    # إذا كانت واثقة، لا نستدعي Qwen إطلاقًا.
    memory_result = _classify_post_with_topic_memory(req)
    if memory_result:
        return memory_result

    if not QWEN_API_KEY:
        return {
            "topics": fallback,
            "primaryTopic": fallback[0],
            "confidence": 0.20,
            "fallback": True,
            "memoryUsed": False,
            "source": "local_fallback",
            "model": "local_fallback",
            "keywords": _keywords_from_ai_json({}, req.text),
            "reason": "لم يتم ضبط QWEN_API_KEY، لذلك تم استخدام التصنيف الاحتياطي.",
        }

    image_urls = [u.strip() for u in [*req.imageUrls, req.imageUrl] if str(u or "").strip()]
    prompt = _post_topic_classification_prompt(req)
    system = "أنت مصنف اهتمامات دقيق لتطبيق اجتماعي. أعد JSON فقط. لا تكتب Markdown."

    # صور المنشورات تُحلل بنموذج Vision حتى يتعرف AI على محتوى الصورة نفسها، وليس النص فقط.
    if image_urls:
        try:
            content_parts: list[Dict[str, Any]] = [{"type": "text", "text": prompt}]
            for url in image_urls[:3]:
                content_parts.append({"type": "image_url", "image_url": {"url": url}})
            content = _chat_completion_request(
                model=QWEN_VISION_MODEL,
                api_key=QWEN_API_KEY,
                base_url=QWEN_BASE_URL,
                messages=[{"role": "system", "content": system}, {"role": "user", "content": content_parts}],
                temperature=0.05,
                max_tokens=420,
                timeout=55,
                log_label="QWEN_POST_CLASSIFY_VISION",
            )
            data = _safe_json_from_ai(str(content))
            topics, primary, confidence = _extract_topics_from_ai_json(data, fallback, req.text)
            confidence = confidence or 0.75
            return {
                "topics": topics,
                "primaryTopic": primary,
                "confidence": confidence,
                "fallback": False,
                "memoryUsed": False,
                "source": "respect_ai",
                "model": QWEN_VISION_MODEL,
                "keywords": _keywords_from_ai_json(data, req.text),
                "reason": _reason_from_ai_json(data),
            }
        except Exception as e:
            logger.warning("QWEN_POST_CLASSIFY_VISION failed: %s", e)

    try:
        content = _chat_completion_request(
            model=QWEN_TEXT_MODEL,
            api_key=QWEN_API_KEY,
            base_url=QWEN_BASE_URL,
            messages=[{"role": "system", "content": system}, {"role": "user", "content": prompt}],
            temperature=0.05,
            max_tokens=420,
            timeout=35,
            response_format={"type": "json_object"},
            log_label="QWEN_POST_CLASSIFY_TEXT",
        )
        data = _safe_json_from_ai(str(content))
        topics, primary, confidence = _extract_topics_from_ai_json(data, fallback, req.text)
        confidence = confidence or 0.70
        return {
            "topics": topics,
            "primaryTopic": primary,
            "confidence": confidence,
            "fallback": False,
            "memoryUsed": False,
            "source": "respect_ai",
            "model": QWEN_TEXT_MODEL,
            "keywords": _keywords_from_ai_json(data, req.text),
            "reason": _reason_from_ai_json(data),
        }
    except Exception as e:
        logger.warning("QWEN_POST_CLASSIFY_TEXT failed: %s", e)
        return {
            "topics": fallback,
            "primaryTopic": fallback[0],
            "confidence": 0.20,
            "fallback": True,
            "memoryUsed": False,
            "source": "local_fallback",
            "model": "local_fallback",
            "keywords": _keywords_from_ai_json({}, req.text),
            "reason": "فشل اتصال Respect AI، لذلك تم استخدام التصنيف الاحتياطي.",
            "error": str(e)[:300],
        }


@app.post("/respect-ai/classify-post", response_model=RespectAIPostClassifyResponse)
def respect_ai_classify_post(req: RespectAIPostClassifyRequest, request: FastAPIRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_secret(x_app_secret)
    _enforce_moderation_rate(_client_ip(request), limit=120)
    result = _classify_post_with_qwen(req)
    topics = _canonical_topics_for_text([
        _normalize_recommendation_topic(t)
        for t in (result.get("topics") or [])
        if _normalize_recommendation_topic(t)
    ], req.text)
    if not topics:
        topics = ["general"]
    if _text_has_football_signal(req.text) and "football" in topics:
        topics = ["football", *[t for t in topics if t not in {"football", "sports"}]]
    confidence = max(0.0, min(1.0, float(result.get("confidence") or 0.0)))
    model = str(result.get("model") or QWEN_TEXT_MODEL)
    memory_used = bool(result.get("memoryUsed"))
    source = str(result.get("source") or ("local_fallback" if result.get("fallback") else ("topic_memory" if memory_used else "respect_ai")))
    keywords = [
        _normalize_recommendation_topic(k)
        for k in (result.get("keywords") or [])
        if _normalize_recommendation_topic(k)
    ][:30]
    reason = str(result.get("reason") or "")

    primary_topic = _canonical_topic_for_text(str(result.get("primaryTopic") or topics[0]), req.text) or topics[0]
    if primary_topic not in topics:
        topics = [primary_topic, *topics]
    else:
        topics = [primary_topic, *[t for t in topics if t != primary_topic]]

    stored = _store_post_topics(
        req.postId,
        topics,
        confidence,
        model,
        source,
        primary_topic=primary_topic,
        reason=reason,
        keywords=keywords,
        memory_used=memory_used,
    )

    # 2) إذا كان التصنيف من AI الحقيقي، نعلّم الذاكرة الجانبية حتى تقل الحاجة للـ AI لاحقًا.
    _learn_topic_memory_from_analysis(
        req,
        topics=topics,
        confidence=confidence,
        model=model,
        source=source,
        reason=reason,
        keywords=keywords,
    )

    return RespectAIPostClassifyResponse(
        ok=True,
        topics=topics[:10],
        primaryTopic=primary_topic,
        confidence=confidence,
        model=model,
        stored=stored,
        fallback=bool(result.get("fallback")),
        memoryUsed=memory_used,
        source=source,
        reason=reason,
        keywords=keywords,
    )


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

    deleted_rows: list[Dict[str, Any]] = []
    owner_username = ""
    try:
        parsed = r.json() if r.text else []
        if isinstance(parsed, list):
            deleted_rows = [dict(x) for x in parsed if isinstance(x, dict)]
        elif isinstance(parsed, dict):
            deleted_rows = [dict(parsed)]
        if deleted_rows:
            owner_username = display_username(str(
                deleted_rows[0].get("username")
                or deleted_rows[0].get("user")
                or deleted_rows[0].get("author_username")
                or ""
            ))
            if owner_username == "@user":
                owner_username = ""
    except Exception as exc:
        logger.debug("Could not parse deleted post representation post_id=%s error=%s", pid, exc)

    return {
        "deleted": True,
        "deletedReplies": deleted_replies,
        "postId": pid,
        "ownerUsername": owner_username,
        "deletedRowsCount": len(deleted_rows),
        "serverDeleteMode": bool(SB_SERVICE),
    }



def _delete_supabase_reply(reply_id: str) -> Dict[str, Any]:
    rid = (reply_id or "").strip()
    if not rid:
        raise HTTPException(status_code=400, detail="replyId is empty")

    headers = {**_supabase_headers(use_service_role=True), "Prefer": "return=representation"}
    post_id = ""
    owner_username = ""
    child_ids: list[str] = []

    try:
        r0 = requests.get(
            f"{SB_URL}/rest/v1/post_replies",
            headers=_supabase_headers(use_service_role=True),
            params={"select": "id,post_id,author_username,username", "id": f"eq.{rid}", "limit": "1"},
            timeout=10,
        )
        if r0.status_code < 400:
            data = r0.json() if r0.text else []
            if isinstance(data, list) and data:
                row = dict(data[0])
                post_id = str(row.get("post_id") or "").strip()
                owner_username = _display_username(str(row.get("author_username") or row.get("username") or ""))
                if owner_username == "@user":
                    owner_username = ""
    except Exception as exc:
        logger.debug("Could not read reply before delete reply_id=%s error=%s", rid, exc)

    try:
        rc = requests.get(
            f"{SB_URL}/rest/v1/post_replies",
            headers=_supabase_headers(use_service_role=True),
            params={"select": "id", "parent_reply_id": f"eq.{rid}", "limit": "500"},
            timeout=10,
        )
        if rc.status_code < 400:
            data = rc.json() if rc.text else []
            if isinstance(data, list):
                child_ids = [str(x.get("id") or "").strip() for x in data if isinstance(x, dict) and str(x.get("id") or "").strip()]
    except Exception as exc:
        logger.debug("Could not read reply children reply_id=%s error=%s", rid, exc)

    for child_id in child_ids:
        for table in ("reply_likes", "reply_reposts", "reply_views"):
            try:
                requests.delete(f"{SB_URL}/rest/v1/{table}", headers=headers, params={"reply_id": f"eq.{child_id}"}, timeout=8)
            except Exception:
                pass

    for table in ("reply_likes", "reply_reposts", "reply_views"):
        try:
            requests.delete(f"{SB_URL}/rest/v1/{table}", headers=headers, params={"reply_id": f"eq.{rid}"}, timeout=8)
        except Exception:
            pass

    try:
        requests.delete(
            f"{SB_URL}/rest/v1/post_replies",
            headers=headers,
            params={"parent_reply_id": f"eq.{rid}"},
            timeout=12,
        )
    except Exception:
        pass

    r = requests.delete(
        f"{SB_URL}/rest/v1/post_replies",
        headers=headers,
        params={"id": f"eq.{rid}"},
        timeout=15,
    )
    logger.info("Backend delete reply reply_id=%s status=%s server_delete_mode=%s", rid, r.status_code, bool(SB_SERVICE))
    logger.debug("Backend delete reply body=%s", _safe_response_text(r.text, 800))
    if r.status_code >= 400:
        raise HTTPException(
            status_code=500,
            detail={
                "supabase_status": r.status_code,
                "supabase_body": r.text,
                "hint": "فعّل Service Role في Render حتى يستطيع السيرفر حذف الرد رغم RLS.",
            },
        )

    try:
        if post_id:
            count = requests.get(
                f"{SB_URL}/rest/v1/post_replies",
                headers=_supabase_headers(use_service_role=True),
                params={"select": "id", "post_id": f"eq.{post_id}", "limit": "10000"},
                timeout=10,
            )
            if count.status_code < 400:
                data = count.json() if count.text else []
                comments = len(data) if isinstance(data, list) else 0
                requests.patch(
                    f"{SB_URL}/rest/v1/posts",
                    headers={**_supabase_headers(use_service_role=True), "Prefer": "return=minimal"},
                    params={"id": f"eq.{post_id}"},
                    json={"comments": comments},
                    timeout=10,
                )
    except Exception as exc:
        logger.debug("Could not update post comments after reply delete reply_id=%s error=%s", rid, exc)

    return {
        "deleted": True,
        "replyId": rid,
        "postId": post_id,
        "ownerUsername": owner_username,
        "deletedChildReplies": len(child_ids),
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
                            "راجعها كجزء من مراجعة الفيديو واقرأ أي نص ظاهر OCR بدقة سياقية. "
                            "مهم جدًا: النص الديني أو التعليمي أو الوعظي العام مثل: أول ما تسأل عنه المرأة يوم القيامة، "
                            "أو أي كلام عام عن المرأة/النساء/القيامة/الصلاة/الحجاب/الأخلاق، لا يعتبر محتوى جنسيًا ولا إساءة دينية. "
                            "احذف الفيديو فقط إذا ظهرت عري/محتوى جنسي صريح/عنف دموي/سلاح تهديد/كراهية/تحريض/سب مباشر واضح. "
                            "إذا كان سبب الاشتباه مجرد OCR عادي فاسمح. أرجع JSON فقط مع ocrText إن وجد."
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
        result = _pending_video_moderation_result(
            category="video_vision_parse_pending",
            reason="تعذر قراءة نتيجة فحص لقطة من الفيديو، لذلك بقي المنشور معلقًا للمراجعة وإعادة الفحص بدل الحذف.",
            confidence=0.0,
            extra={"deleteParentReply": False},
        )
    else:
        result = _normalize_moderation_result(parsed)
        result = _relax_contextual_text_false_positive(parsed, result, media_kind="الفيديو")

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

    wait_seconds = float(os.getenv("RESPECT_VIDEO_MODERATION_SEMAPHORE_WAIT_SECONDS", "10") or "10")
    acquired = _video_moderation_semaphore.acquire(timeout=max(0.0, wait_seconds))
    if not acquired:
        logger.warning("video moderation deferred because concurrency limit is full urls=%s", len(urls))
        return _pending_video_moderation_result(
            category="video_deferred",
            reason="تم تأجيل فحص الفيديو مؤقتًا بسبب ضغط المراجعة. سيبقى المنشور تحت المراجعة وسيعاد فحصه لاحقًا بدون حذف.",
            confidence=0.0,
            checks=0,
            video_checks=[],
            extra={"deferred": True},
        )
    try:
        return _moderate_videos_with_qwen_inner(req)
    finally:
        try:
            _video_moderation_semaphore.release()
        except Exception:
            pass


def _moderate_videos_with_qwen_inner(req: RespectAIModerationRequest) -> Dict[str, Any]:
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
        return _pending_video_moderation_result(
            category="video_vision_unavailable",
            reason="QWEN_API_KEY غير موجود حاليًا، لذلك بقي الفيديو معلقًا وسيعاد فحصه لاحقًا بدل حذف المنشور.",
            confidence=0.0,
            checks=0,
            video_checks=[],
        )

    max_frames = int(os.getenv("RESPECT_AI_VIDEO_FRAMES", "6"))
    max_frames = max(3, min(max_frames, 12))

    results: list[Dict[str, Any]] = []
    for video_index, url in enumerate(urls, start=1):
        cached = _media_memory_lookup_moderation("video", url)
        if cached:
            cached["videoUrl"] = url
            cached["videoIndex"] = video_index
            cached["visionModel"] = str(cached.get("model") or "respect_ai_media_memory_v1")
            results.append(cached)
            if cached.get("shouldDelete") is True:
                return {
                    "shouldDelete": True,
                    "category": str(cached.get("category") or "video_violation"),
                    "reason": str(cached.get("reason") or "الفيديو مخالف حسب ذاكرة Respect AI"),
                    "confidence": float(cached.get("confidence") or 0.92),
                    "checks": len(results),
                    "videoChecks": results,
                    "memoryUsed": True,
                    "mediaMemoryUsed": True,
                    "moderationMemoryUsed": True,
                    "decisionSource": "respect_ai_media_memory",
                }
            continue
        try:
            frames = _extract_video_frame_data_urls(url, max_frames=max_frames)
        except Exception as e:
            # Fail-pending: فشل الفحص التقني ليس مخالفة. لا نحذف الفيديو؛ نعيد المحاولة لاحقًا.
            r = {
                "shouldDelete": False,
                "category": "video_extract_pending",
                "reason": f"تعذر فحص الفيديو رقم {video_index} مؤقتًا، وسيعاد فحصه لاحقًا بدون حذف المنشور: {e}",
                "confidence": 0.0,
                "videoUrl": url,
                "videoIndex": video_index,
                "retryable": True,
                "moderationPending": True,
                "videoModerationPending": True,
            }
            results.append(r)
            return _pending_video_moderation_result(
                category="video_extract_pending",
                reason=r["reason"],
                confidence=0.0,
                checks=len(results),
                video_checks=results,
            )

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
                        "shouldDelete": False,
                        "category": "video_vision_pending",
                        "reason": f"تعذر فحص لقطة من الفيديو رقم {video_index} عند الثانية {second} مؤقتًا، وسيعاد فحص الفيديو لاحقًا بدون حذف المنشور: {e}",
                        "confidence": 0.0,
                        "videoUrl": url,
                        "videoIndex": video_index,
                        "frameIndex": frame_index,
                        "second": second,
                        "retryable": True,
                        "moderationPending": True,
                        "videoModerationPending": True,
                    }

            # لا نرجع dataUrl حتى لا يكبر response.
            r["videoUrl"] = url
            r.pop("imageUrl", None)
            results.append(r)

            if _is_video_moderation_pending(r):
                return _pending_video_moderation_result(
                    category=str(r.get("category") or "video_pending_review"),
                    reason=str(r.get("reason") or "تعذر فحص الفيديو مؤقتًا، وسيعاد فحصه لاحقًا بدون حذف المنشور."),
                    confidence=0.0,
                    checks=len(results),
                    video_checks=results,
                )

            if r.get("shouldDelete") is True:
                r["mediaMemoryLearnResult"] = _media_memory_learn_moderation("video", url, r, source="qwen_vision_video_moderation")
                return {
                    "shouldDelete": True,
                    "category": str(r.get("category") or "video_violation"),
                    "reason": str(r.get("reason") or "الفيديو مخالف"),
                    "confidence": float(r.get("confidence") or 1.0),
                    "checks": len(results),
                    "videoChecks": results,
                    "mediaMemoryLearnResult": r.get("mediaMemoryLearnResult"),
                }

    media_memory_used = any(bool(r.get("mediaMemoryUsed") or r.get("memoryUsed")) for r in results)
    safe_video_result = {
        "shouldDelete": False,
        "category": "safe",
        "reason": "",
        "confidence": max([float(r.get("confidence") or 0.0) for r in results] or [0.0]),
        "checks": len(results),
        "videoChecks": results,
        "memoryUsed": media_memory_used,
        "mediaMemoryUsed": media_memory_used,
        "moderationMemoryUsed": media_memory_used,
    }
    learn_results = []
    for url in urls:
        learn_results.append(_media_memory_learn_moderation("video", url, safe_video_result, source="qwen_vision_video_moderation_safe"))
    safe_video_result["mediaMemoryLearnResults"] = learn_results
    return safe_video_result


def _respect_ai_image_moderation_prompt() -> str:
    return """
أنت نظام مراجعة صور وفريمات فيديو لتطبيق تواصل اجتماعي اسمه Respect App.

حلل الصورة وحدد هل يجب حذف المحتوى أم لا.
مهم جدًا: اقرأ أي نص ظاهر داخل الصورة OCR، مثل الكتابة على الشاشة أو السكرين شوت أو الملصقات، لكن افهمه بسياقه وليس كفلتر كلمات.

قاعدة مهمة جدًا:
لا تحذف بسبب كلمة مفردة أو نص ديني/تعليمي/وعظي عام. وجود كلمات مثل:
"المرأة"، "النساء"، "الرجل"، "يوم القيامة"، "الصلاة"، "الحجاب"، "الدين"، "الأخلاق"
لا يعني أن المحتوى جنسي أو إساءة دينية.
مثال يجب السماح به: "أول ما تسأل عنه المرأة يوم القيامة" أو "أول ما تُسأل عنه المرأة يوم القيامة".
هذا نص ديني/تعليمي عام، وليس sexual وليس religion_abuse.

احذف فقط إذا كان النص الظاهر أو الصورة نفسها تحتوي بوضوح على:
- عري كامل أو جزئي، ملابس داخلية/شفافة بشكل جنسي، أجزاء حساسة ظاهرة، أو محتوى جنسي/إيحائي صريح.
- عنف دموي أو إصابات صادمة أو تعذيب.
- كراهية أو رموز متطرفة أو تحريض.
- سلاح أو تهديد واضح أو محتوى خطر.
- تنمر بصري أو إهانة مباشرة لشخص.
- كلام فاحش صريح أو سب مباشر أو تحرش مكتوب على الصورة.
- محتوى غير مناسب للنشر العام بدليل بصري/نصي واضح.

لا تحذف الصور العادية مثل: سيلفي، طعام، مناظر، ألعاب، ميمز غير مؤذية، واجهات تطبيق، لقطات شاشة عادية، أو نصوص دينية/تعليمية عامة.

أرجع JSON فقط بدون markdown:
{
  "allowed": true أو false,
  "shouldDelete": true أو false,
  "category": "safe" أو "nudity" أو "sexual" أو "violence" أو "hate" أو "weapon" أو "harassment" أو "dangerous" أو "other",
  "reason": "سبب مختصر بالعربية",
  "ocrText": "النص المقروء إن وجد، وإلا اتركه فارغًا",
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
                        "text": "راجع هذه الصورة/اللقطة من محتوى في تطبيق Respect App. اقرأ أي نص ظاهر على الشاشة بسياقه. لا تحذف النصوص الدينية أو التعليمية العامة مثل: أول ما تسأل عنه المرأة يوم القيامة. احذف فقط عند وجود مخالفة واضحة صريحة. أرجع JSON فقط مع ocrText إن وجد.",
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
        result = _relax_contextual_text_false_positive(parsed, result, media_kind="الصورة")
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
        cached = _media_memory_lookup_moderation("image", url)
        if cached:
            cached["imageUrl"] = url
            cached["imageIndex"] = i
            cached["visionModel"] = str(cached.get("model") or "respect_ai_media_memory_v1")
            results.append(cached)
            if cached.get("shouldDelete") is True:
                return {
                    "shouldDelete": True,
                    "category": str(cached.get("category") or "image_violation"),
                    "reason": str(cached.get("reason") or "الصورة مخالفة حسب ذاكرة Respect AI"),
                    "confidence": float(cached.get("confidence") or 0.92),
                    "checks": len(results),
                    "imageChecks": results,
                    "memoryUsed": True,
                    "mediaMemoryUsed": True,
                    "moderationMemoryUsed": True,
                    "decisionSource": "respect_ai_media_memory",
                }
            continue
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
        r["mediaMemoryLearnResult"] = _media_memory_learn_moderation("image", url, r, source="qwen_vision_image_moderation")
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

    media_memory_used = any(bool(r.get("mediaMemoryUsed") or r.get("memoryUsed")) for r in results)
    return {
        "shouldDelete": False,
        "category": "safe",
        "reason": "",
        "confidence": max([float(r.get("confidence") or 0.0) for r in results] or [0.0]),
        "checks": len(results),
        "imageChecks": results,
        "memoryUsed": media_memory_used,
        "mediaMemoryUsed": media_memory_used,
        "moderationMemoryUsed": media_memory_used,
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
    video_pending = _is_video_moderation_pending(video_result)
    video_delete = bool(
        not video_pending
        and (
            video_result.get("shouldDelete") is True
            or video_result.get("delete") is True
            or video_result.get("blocked") is True
        )
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
        text_memory_used = bool(text_result.get("memoryUsed") or text_result.get("moderationMemoryUsed"))
        text_decision_source = str(
            text_result.get("decisionSource")
            or ("respect_ai_moderation_memory" if text_memory_used else "qwen-plus")
        )
        return {
            **text_result,
            "shouldDelete": True,
            "category": str(text_result.get("category") or "text_violation"),
            "reason": str(text_result.get("reason") or "النص مخالف"),
            "decisionSource": text_decision_source,
            "memoryUsed": text_memory_used,
            "moderationMemoryUsed": text_memory_used,
            "textModeration": text_result,
            "imageModeration": image_result,
            "videoModeration": video_result,
            "linkModeration": link_result,
            "virusTotalModeration": vt,
        }

    if image_delete:
        image_memory_used = bool(image_result.get("memoryUsed") or image_result.get("mediaMemoryUsed"))
        return {
            **image_result,
            "shouldDelete": True,
            "category": str(image_result.get("category") or "image_violation"),
            "reason": str(image_result.get("reason") or "الصورة مخالفة"),
            "decisionSource": "respect_ai_media_memory" if image_memory_used else "qwen-vl-plus-image",
            "memoryUsed": image_memory_used,
            "moderationMemoryUsed": image_memory_used,
            "mediaMemoryUsed": image_memory_used,
            "textModeration": text_result,
            "imageModeration": image_result,
            "videoModeration": video_result,
            "linkModeration": link_result,
            "virusTotalModeration": vt,
        }

    if video_pending:
        return {
            **video_result,
            "shouldDelete": False,
            "deleteParentReply": False,
            "category": str(video_result.get("category") or "video_pending_review"),
            "reason": str(video_result.get("reason") or "تعذر فحص الفيديو مؤقتًا، وسيعاد فحصه لاحقًا بدون حذف المنشور."),
            "confidence": float(video_result.get("confidence") or 0.0),
            "decisionSource": "qwen-vl-plus-video-pending",
            "moderationPending": True,
            "videoModerationPending": True,
            "retryable": True,
            "textModeration": text_result,
            "imageModeration": image_result,
            "videoModeration": video_result,
            "linkModeration": link_result,
            "virusTotalModeration": vt,
        }

    if video_delete:
        video_memory_used = bool(video_result.get("memoryUsed") or video_result.get("mediaMemoryUsed"))
        return {
            **video_result,
            "shouldDelete": True,
            "category": str(video_result.get("category") or "video_violation"),
            "reason": str(video_result.get("reason") or "الفيديو مخالف"),
            "decisionSource": "respect_ai_media_memory" if video_memory_used else "qwen-vl-plus-video",
            "memoryUsed": video_memory_used,
            "moderationMemoryUsed": video_memory_used,
            "mediaMemoryUsed": video_memory_used,
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
    content_type = (req.contentType or "post").strip().lower()
    is_reply_report = content_type == "reply" or bool((req.replyId or "").strip())
    reported_text = (req.text if is_reply_report else (req.postText or req.text) or "").strip()
    post_context = (req.postText or "").strip()
    reported = _display_username(req.reportedUsername or req.username)
    content_label = "الرد" if is_reply_report else "التغريدة"

    prompt = f"""
أنت نظام مراجعة بلاغات داخل Respect App.
مهم جدًا: لا تعتبر البلاغ صحيحًا إلا إذا الدليل واضح من نص {content_label} والبلاغ.
إذا البلاغ عن سرقة محتوى ولا يوجد نص كافٍ للمقارنة أو رابط/اسم صاحب المحتوى الأصلي، اعتبره يحتاج مراجعة بشرية ولا تحذف.
أعد JSON فقط بدون شرح خارج JSON:
{{"validReport": true/false, "action": "none|hide|delete", "category": "copyright|abuse|spam|misleading|other|insufficient_evidence", "confidence": 0.0-1.0, "reason": "سبب قصير بالعربية"}}

نوع المحتوى: {content_label}
سبب البلاغ: {report_reason}
تفاصيل البلاغ: {report_details}
نص {content_label} المبلغ عنه: {reported_text}
نص التغريدة الأصلية للسياق: {post_context if is_reply_report else ""}
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

    if QWEN_API_KEY and reported_text:
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
                log_label="REPORT_REVIEW_REPLY" if is_reply_report else "REPORT_REVIEW",
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
    delete_result: Dict[str, Any] = {"deleted": False}
    notification_result: Dict[str, Any] = {"sent": False, "reason": "not_deleted"}
    warning_result: Dict[str, Any] = {"warningCount": 0, "blocked": False}
    learn_result: Dict[str, Any] = {"learned": False, "terms": []}
    if should_hide:
        learn_result = _learn_abuse_terms_from_valid_report(req, result)

        if is_reply_report:
            try:
                delete_result = _delete_supabase_reply(req.replyId)
                update_result = delete_result
                if bool(delete_result.get("deleted")):
                    notification_result = _send_reply_moderation_deleted_push(
                        username=str(delete_result.get("ownerUsername") or reported or req.reportedUsername or req.username or ""),
                        reply_id=req.replyId,
                        post_id=str(delete_result.get("postId") or req.postId or ""),
                        reason=str(result.get("reason") or report_reason),
                        category=str(result.get("category") or "report_accepted"),
                        confidence=confidence,
                        decision_source="report_review",
                        memory_used=False,
                        matched_term="",
                        fallback_language=req.language,
                    )
            except Exception as e:
                update_result = {"deleted": False, "error": str(e)}
        else:
            if req.communityId:
                update_result = _patch_supabase_post(req.postId, {"community_hidden": True, "hidden_reason": str(result.get("reason") or "")})
            else:
                try:
                    delete_result = _delete_supabase_post(req.postId)
                    update_result = delete_result
                except Exception as e:
                    update_result = {"deleted": False, "error": str(e)}
        warning_result = _insert_user_warning(reported, str(result.get("reason") or report_reason), req.replyId if is_reply_report else req.postId, req.reportId)

    report_update_result = {"updated": False, "reason": "empty_report_id"}
    if (req.reportId or "").strip():
        report_update_result = _patch_supabase_report(req.reportId, {
            "status": "accepted" if should_hide else "rejected",
            "ai_status": "accepted" if should_hide else "rejected",
            "ai_reason": str(result.get("reason") or ""),
            "ai_confidence": confidence,
            "reviewed_at": datetime.now(timezone.utc).isoformat(),
        })

    return {
        "ok": True,
        "reportId": req.reportId,
        "postId": req.postId,
        "replyId": req.replyId,
        "contentType": "reply" if is_reply_report else "post",
        "validReport": valid,
        "shouldDelete": should_hide,
        "deleted": bool((update_result or {}).get("deleted") or (delete_result or {}).get("deleted")),
        "action": "delete" if should_hide else "none",
        "category": str(result.get("category") or "other"),
        "confidence": confidence,
        "reason": str(result.get("reason") or ""),
        "postUpdate": update_result if not is_reply_report else {"updated": False, "reason": "reply_report"},
        "replyDeleteResult": update_result if is_reply_report else {"deleted": False, "reason": "not_reply"},
        "deleteResult": update_result,
        "reportUpdate": report_update_result,
        "learnResult": learn_result,
        "memoryLearnResult": learn_result.get("memoryLearnResult", learn_result),
        "localMemoryRows": learn_result.get("localMemoryRows") or learn_result.get("learnedRows") or [],
        "learnedTerms": learn_result.get("learnedTerms") or learn_result.get("terms", []),
        "memoryLearned": bool(learn_result.get("learned")),
        "warning": warning_result,
        "notificationSent": bool(notification_result.get("sent")),
        "notificationResult": notification_result,
    }


def _patch_supabase_report(report_id: str, payload: Dict[str, Any]) -> Dict[str, Any]:
    rid = (report_id or "").strip()
    if not rid:
        return {"updated": False, "reason": "empty_report_id"}
    headers = {**_supabase_headers(use_service_role=True), "Prefer": "return=representation"}
    try:
        r = requests.patch(
            f"{SB_URL}/rest/v1/post_reports",
            headers=headers,
            params={"id": f"eq.{rid}"},
            json=payload,
            timeout=12,
        )
        if r.status_code < 400:
            return {"updated": True, "reportId": rid}
        minimal = {k: v for k, v in payload.items() if k in {"status", "ai_status"}}
        if minimal:
            r2 = requests.patch(
                f"{SB_URL}/rest/v1/post_reports",
                headers=headers,
                params={"id": f"eq.{rid}"},
                json=minimal,
                timeout=12,
            )
            if r2.status_code < 400:
                return {"updated": True, "reportId": rid, "fallback": True}
        return {"updated": False, "status": r.status_code, "body": r.text[:500]}
    except Exception as e:
        return {"updated": False, "error": str(e)}

def _run_story_moderation_job(req_data: Dict[str, Any]) -> None:
    req = RespectAIModerationRequest(**req_data)
    result = _respect_ai_moderate_story_sync(req)
    logger.info(
        "story moderation job finished story_id=%s should_delete=%s deleted=%s category=%s",
        result.get("storyId"),
        result.get("shouldDelete"),
        result.get("deleted"),
        result.get("category"),
    )


@app.post("/respect-ai/moderate-story")
def respect_ai_moderate_story(req: RespectAIModerationRequest, request: FastAPIRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_secret(x_app_secret)
    _enforce_moderation_rate(_client_ip(request))

    story_id = (req.postId or req.replyId or "").strip()
    if RESPECT_MODERATION_ASYNC:
        job_id = _submit_background_job("story_moderation", _run_story_moderation_job, _model_to_dict(req))
        return {
            "ok": True,
            "storyId": story_id,
            "queued": True,
            "moderationQueued": True,
            "jobId": job_id,
            "shouldDelete": False,
            "deleted": False,
            "category": "queued",
            "reason": "تم قبول الستوري، والمراجعة الثقيلة تعمل بالخلفية.",
            "provider": "background-moderation",
            "serverSideDelete": True,
        }

    return _respect_ai_moderate_story_sync(req)


def _respect_ai_moderate_story_sync(req: RespectAIModerationRequest) -> Dict[str, Any]:
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
        "moderationPending": bool(result.get("moderationPending") or result.get("videoModerationPending")),
        "videoModerationPending": bool(result.get("videoModerationPending")),
        "textModeration": result.get("textModeration", text_result),
        "imageModeration": result.get("imageModeration", image_result),
        "videoModeration": result.get("videoModeration", video_result),
        "linkModeration": result.get("linkModeration", link_result),
        "virusTotalModeration": result.get("virusTotalModeration", virustotal_result),
        "model": QWEN_TEXT_MODEL,
        "textModel": QWEN_TEXT_MODEL,
        "visionModel": QWEN_VISION_MODEL,
        "provider": "local-guard+moderation-memory+qwen+safe-browsing+virustotal",
        "serverSideDelete": True,
        "memoryUsed": bool(result.get("memoryUsed") or result.get("moderationMemoryUsed")),
        "moderationMemoryUsed": bool(result.get("moderationMemoryUsed")),
        "memoryDecision": str(result.get("memoryDecision") or ""),
        "matchedTerm": str(result.get("matchedTerm") or ""),
    }


@app.post("/respect-ai/precheck-post")
def respect_ai_precheck_post(req: RespectAIModerationRequest, request: FastAPIRequest, x_app_secret: Optional[str] = Header(default=None)):
    """
    فحص قبل النشر: لا يحذف أي صف من Supabase.
    إذا النص مخالف يرجع blocked=true مع السبب والعبارة المطابقة، ويتعلم الذاكرة فورًا.
    """
    _check_secret(x_app_secret)
    _enforce_moderation_rate(_client_ip(request))

    text = (req.text or req.postText or "").strip()
    if not text:
        return {
            "ok": True,
            "blocked": False,
            "shouldDelete": False,
            "prePublishBlocked": False,
            "category": "safe",
            "reason": "",
            "confidence": 0.0,
            "decisionSource": "empty_text",
            "decisionSourceKind": "local",
            "decisionSourceLabel": _moderation_delete_source_label("local", req.language),
            "localMemoryRows": [],
            "learnedTerms": [],
        }

    learned_result = _learned_abuse_violation_guard(text)
    if learned_result is not None and learned_result.get("shouldDelete") is True:
        result = dict(learned_result)
        result.setdefault("decisionSource", "respect_ai_moderation_memory")
        result.setdefault("model", "respect_ai_local_memory_v2")
    else:
        result = moderate_with_qwen(req)

    should_delete = bool(
        result.get("shouldDelete") is True
        or result.get("delete") is True
        or result.get("blocked") is True
    )
    reason = str(result.get("reason") or ("محتوى مخالف لإرشادات المجتمع" if should_delete else ""))
    category = str(result.get("category") or ("violation" if should_delete else "safe"))
    confidence = float(result.get("confidence") or (0.99 if should_delete else 0.0))
    memory_used = bool(result.get("memoryUsed") or result.get("moderationMemoryUsed"))
    decision_source = str(
        result.get("decisionSource")
        or ("respect_ai_moderation_memory" if memory_used else "pre_publish_moderation")
    )
    source_kind = _moderation_delete_source_kind(decision_source, memory_used=memory_used)
    source_label = _moderation_delete_source_label(source_kind, req.language)

    memory_learn_result: Dict[str, Any] = dict(result.get("memoryLearnResult") or {})
    if should_delete and memory_learn_result.get("learned") is not True:
        result_for_memory = dict(result)
        result_for_memory.setdefault("shouldDelete", True)
        result_for_memory.setdefault("category", category)
        result_for_memory.setdefault("reason", reason)
        result_for_memory.setdefault("confidence", confidence)
        result_for_memory.setdefault("decisionSource", decision_source)
        result_for_memory.setdefault("model", str(result.get("model") or QWEN_TEXT_MODEL or "pre_publish_moderation"))
        memory_learn_result = _learn_moderation_memory_safely(
            req,
            result_for_memory,
            text_result=result_for_memory,
            source=f"{decision_source}_pre_publish",
        )
    if not memory_learn_result:
        memory_learn_result = {"learned": False, "reason": "not_eligible"}

    return {
        "ok": True,
        "blocked": should_delete,
        "shouldDelete": should_delete,
        "prePublishBlocked": should_delete,
        "deleted": False,
        "serverSideDelete": False,
        "memoryLearned": bool(memory_learn_result.get("learned")),
        "memoryLearnResult": memory_learn_result,
        "localMemoryRows": memory_learn_result.get("localMemoryRows") or memory_learn_result.get("learnedRows") or [],
        "learnedTerms": memory_learn_result.get("learnedTerms") or [],
        "reason": reason,
        "category": category,
        "confidence": confidence,
        "decisionSource": decision_source,
        "decisionSourceKind": source_kind,
        "decisionSourceLabel": source_label,
        "memoryUsed": memory_used,
        "moderationMemoryUsed": bool(result.get("moderationMemoryUsed") or memory_used),
        "memoryDecision": str(result.get("memoryDecision") or ""),
        "matchedTerm": str(result.get("matchedTerm") or ""),
        "matchedTerms": result.get("matchedTerms") or [],
        "model": str(result.get("model") or QWEN_TEXT_MODEL),
        "provider": "local-guard+moderation-memory+qwen-pre-publish",
    }


def _run_post_moderation_job(req_data: Dict[str, Any]) -> None:
    req = RespectAIModerationRequest(**req_data)
    result = _respect_ai_moderate_post_sync(req)
    logger.info(
        "post moderation job finished post_id=%s should_delete=%s deleted=%s category=%s",
        result.get("postId"),
        result.get("shouldDelete"),
        result.get("deleted"),
        result.get("category"),
    )


@app.post("/respect-ai/moderate-post")
def respect_ai_moderate_post(req: RespectAIModerationRequest, request: FastAPIRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_secret(x_app_secret)
    _enforce_moderation_rate(_client_ip(request))

    # إذا الذاكرة/الفلتر المحلي وجد مخالفة مؤكدة، نحذف فوريًا حتى لا ينتظر المستخدم الوظيفة الخلفية.
    learned_result = _learned_abuse_violation_guard(req.text or req.postText or "")
    if learned_result is not None and learned_result.get("shouldDelete") is True:
        return _respect_ai_moderate_post_sync(req)

    if RESPECT_MODERATION_ASYNC:
        job_id = _submit_background_job("post_moderation", _run_post_moderation_job, _model_to_dict(req))
        return {
            "ok": True,
            "postId": req.postId,
            "replyId": req.replyId,
            "contentType": (req.contentType or "post"),
            "queued": True,
            "moderationQueued": True,
            "jobId": job_id,
            "shouldDelete": False,
            "deleted": False,
            "category": "queued",
            "reason": "تم قبول المحتوى، والمراجعة الثقيلة تعمل بالخلفية.",
            "provider": "background-moderation",
            "serverSideDelete": True,
        }

    return _respect_ai_moderate_post_sync(req)


def _respect_ai_moderate_post_sync(req: RespectAIModerationRequest) -> Dict[str, Any]:
    content_type = (req.contentType or "post").strip().lower()
    is_reply_content = content_type == "reply" or bool((req.replyId or "").strip())
    target_id = (req.replyId if is_reply_content else req.postId) or ""

    # طبقة تعلم البلاغات: تفحص القاموس المتعلم قبل Qwen، حتى يكون الحذف فوريًا ومتسقًا.
    learned_result = _learned_abuse_violation_guard(req.text or req.postText or "")
    if learned_result is not None and learned_result.get("shouldDelete") is True:
        delete_result: Dict[str, Any] = {"deleted": False}
        if target_id.strip():
            delete_result = _delete_supabase_reply(req.replyId) if is_reply_content else _delete_supabase_post(req.postId)

        reason = str(learned_result.get("reason") or "عبارة مخالفة متعلمة من بلاغ صحيح سابق")
        category = str(learned_result.get("category") or "learned_abuse")
        confidence = float(learned_result.get("confidence") or 0.99)
        decision_source = "respect_ai_moderation_memory"
        owner_username = str(req.username or delete_result.get("ownerUsername") or "").strip()
        notification_result: Dict[str, Any] = {"sent": False, "reason": "not_deleted"}
        memory_learn_result: Dict[str, Any] = {"learned": False, "reason": "not_deleted"}
        if bool(delete_result.get("deleted")):
            if is_reply_content:
                notification_result = _send_reply_moderation_deleted_push(
                    username=owner_username,
                    reply_id=req.replyId,
                    post_id=str(delete_result.get("postId") or req.postId or ""),
                    reason=reason,
                    category=category,
                    confidence=confidence,
                    decision_source=decision_source,
                    memory_used=True,
                    matched_term=str(learned_result.get("matchedTerm") or ""),
                    fallback_language=req.language,
                )
            else:
                notification_result = _send_post_moderation_deleted_push(
                    username=owner_username,
                    post_id=req.postId,
                    reason=reason,
                    category=category,
                    confidence=confidence,
                    decision_source=decision_source,
                    memory_used=True,
                    matched_term=str(learned_result.get("matchedTerm") or ""),
                    fallback_language=req.language,
                )
            learned_for_memory = dict(learned_result)
            learned_for_memory.setdefault("shouldDelete", True)
            learned_for_memory.setdefault("category", category)
            learned_for_memory.setdefault("reason", reason)
            learned_for_memory.setdefault("confidence", confidence)
            learned_for_memory.setdefault("decisionSource", decision_source)
            learned_for_memory.setdefault("model", "respect_ai_local_memory_v2")
            memory_learn_result = _learn_moderation_memory_safely(
                req,
                learned_for_memory,
                text_result=learned_for_memory,
                source="respect_ai_local_memory_delete",
            )

        return {
            "ok": True,
            "postId": req.postId,
            "replyId": req.replyId,
            "contentType": "reply" if is_reply_content else "post",
            "shouldDelete": True,
            "deleted": bool(delete_result.get("deleted")),
            "deleteResult": delete_result,
            "replyDeleteResult": delete_result if is_reply_content else {"deleted": False, "reason": "not_reply"},
            "notificationSent": bool(notification_result.get("sent")),
            "notificationResult": notification_result,
            "memoryLearned": bool(memory_learn_result.get("learned")),
            "memoryLearnResult": memory_learn_result,
            "localMemoryRows": memory_learn_result.get("localMemoryRows") or memory_learn_result.get("learnedRows") or [],
            "learnedTerms": memory_learn_result.get("learnedTerms") or [],
            "reason": reason,
            "category": category,
            "confidence": confidence,
            "decisionSource": decision_source,
            "decisionSourceKind": "memory",
            "decisionSourceLabel": "ذاكرة Respect AI",
            "memoryUsed": True,
            "moderationMemoryUsed": True,
            "textModeration": learned_result,
            "imageModeration": {"shouldDelete": False, "category": "skipped", "reason": "تم الحذف من طبقة التعلم النصية"},
            "videoModeration": {"shouldDelete": False, "category": "skipped", "reason": "تم الحذف من طبقة التعلم النصية"},
            "linkModeration": {"shouldDelete": False, "category": "skipped", "reason": "تم الحذف من طبقة التعلم النصية"},
            "virusTotalModeration": {"shouldDelete": False, "category": "skipped", "reason": "تم الحذف من طبقة التعلم النصية"},
            "learnedMatch": True,
            "matchedTerm": str(learned_result.get("matchedTerm") or ""),
            "model": "respect_ai_local_memory_v2",
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
    video_retry_result: Dict[str, Any] = {"scheduled": False, "reason": "not_pending"}
    if _is_video_moderation_pending(video_result):
        video_retry_result = _schedule_pending_video_moderation_retry(req, video_result)
        video_result = {**video_result, "retrySchedule": video_retry_result}
    else:
        _clear_pending_video_moderation_retry(req)
    result = _combine_text_image_video_moderation(text_result, image_result, video_result, link_result, virustotal_result)

    should_delete = bool(
        result.get("shouldDelete") is True
        or result.get("delete") is True
        or result.get("blocked") is True
    )

    delete_result: Dict[str, Any] = {"deleted": False}
    if should_delete:
        delete_result = _delete_supabase_reply(req.replyId) if is_reply_content else _delete_supabase_post(req.postId)

    reason = str(result.get("reason") or "")
    category = str(result.get("category") or "safe")
    confidence = float(result.get("confidence") or 0.0)
    memory_used = bool(result.get("memoryUsed") or result.get("moderationMemoryUsed"))
    decision_source = str(
        result.get("decisionSource")
        or ("respect_ai_moderation_memory" if memory_used else "combined")
    )
    source_kind = _moderation_delete_source_kind(decision_source, memory_used=memory_used)
    source_label = _moderation_delete_source_label(source_kind, req.language)
    notification_result: Dict[str, Any] = {"sent": False, "reason": "not_deleted"}

    memory_learn_result: Dict[str, Any] = dict(result.get("memoryLearnResult") or {})
    if not memory_learn_result:
        memory_learn_result = dict((result.get("textModeration") or {}).get("memoryLearnResult") or {})
    if not memory_learn_result:
        memory_learn_result = {"learned": False, "reason": "not_eligible"}

    if bool(delete_result.get("deleted")):
        owner_username = str(req.username or delete_result.get("ownerUsername") or "").strip()
        if is_reply_content:
            notification_result = _send_reply_moderation_deleted_push(
                username=owner_username,
                reply_id=req.replyId,
                post_id=str(delete_result.get("postId") or req.postId or ""),
                reason=reason,
                category=category,
                confidence=confidence,
                decision_source=decision_source,
                memory_used=memory_used,
                matched_term=str(result.get("matchedTerm") or ""),
                fallback_language=req.language,
            )
        else:
            notification_result = _send_post_moderation_deleted_push(
                username=owner_username,
                post_id=req.postId,
                reason=reason,
                category=category,
                confidence=confidence,
                decision_source=decision_source,
                memory_used=memory_used,
                matched_term=str(result.get("matchedTerm") or ""),
                fallback_language=req.language,
            )

        # ضمان أخير: أي حذف ناجح لازم يحاول تسجيل الذاكرة.
        # إذا كان الحذف جاء من local_hard_filter، فغالبًا تم التعلم داخل moderate_with_qwen.
        # إذا لم يحدث، نسجله هنا حتى لا يبقى العداد 0.
        if memory_learn_result.get("learned") is not True:
            result_for_memory = dict(result)
            result_for_memory.setdefault("shouldDelete", should_delete)
            result_for_memory.setdefault("category", category)
            result_for_memory.setdefault("reason", reason)
            result_for_memory.setdefault("confidence", confidence)
            result_for_memory.setdefault("decisionSource", decision_source)
            result_for_memory.setdefault("model", str(result.get("model") or QWEN_TEXT_MODEL or "post_moderation"))
            memory_learn_result = _learn_moderation_memory_safely(
                req,
                result_for_memory,
                text_result=result.get("textModeration") if isinstance(result.get("textModeration"), dict) else result_for_memory,
                source=f"{decision_source}_delete",
            )

    return {
        "ok": True,
        "postId": req.postId,
        "replyId": req.replyId,
        "contentType": "reply" if is_reply_content else "post",
        "shouldDelete": should_delete,
        "deleted": bool(delete_result.get("deleted")),
        "deleteResult": delete_result,
        "replyDeleteResult": delete_result if is_reply_content else {"deleted": False, "reason": "not_reply"},
        "notificationSent": bool(notification_result.get("sent")),
        "notificationResult": notification_result,
        "memoryLearned": bool(memory_learn_result.get("learned")),
        "memoryLearnResult": memory_learn_result,
        "localMemoryRows": memory_learn_result.get("localMemoryRows") or memory_learn_result.get("learnedRows") or [],
        "learnedTerms": memory_learn_result.get("learnedTerms") or [],
        "reason": reason,
        "category": category,
        "confidence": confidence,
        "decisionSource": decision_source,
        "decisionSourceKind": source_kind,
        "decisionSourceLabel": source_label,
        "textModeration": result.get("textModeration", text_result),
        "imageModeration": result.get("imageModeration", image_result),
        "videoModeration": result.get("videoModeration", video_result),
        "linkModeration": result.get("linkModeration", link_result),
        "virusTotalModeration": result.get("virusTotalModeration", virustotal_result),
        "model": QWEN_TEXT_MODEL,
        "textModel": QWEN_TEXT_MODEL,
        "visionModel": QWEN_VISION_MODEL,
        "provider": "local-guard+moderation-memory+qwen+safe-browsing+virustotal",
        "serverSideDelete": True,
        "moderationPending": bool(result.get("moderationPending") or result.get("videoModerationPending")),
        "videoModerationPending": bool(result.get("videoModerationPending")),
        "videoRetryResult": video_retry_result,
        "memoryUsed": memory_used,
        "moderationMemoryUsed": memory_used,
        "memoryDecision": str(result.get("memoryDecision") or ""),
        "matchedTerm": str(result.get("matchedTerm") or ""),
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


def _repo_owner_name() -> tuple[str, str]:
    owner = RESPECT_REPO_OWNER.strip()
    name = RESPECT_REPO_NAME.strip()
    if owner and name:
        return owner, name.replace(".git", "")
    raw = RESPECT_REPO_URL.strip()
    # يدعم https://github.com/owner/repo.git أو git@github.com:owner/repo.git
    match = re.search(r"github\.com[:/]+([^/]+)/([^/]+?)(?:\.git)?/?$", raw)
    if not match:
        raise HTTPException(status_code=500, detail="RESPECT_REPO_URL غير صالح. ضع رابط GitHub صحيح في متغيرات Render.")
    return match.group(1), match.group(2).replace(".git", "")


def _github_headers(require_token: bool = False) -> Dict[str, str]:
    if require_token and not GITHUB_TOKEN:
        raise HTTPException(status_code=500, detail="GITHUB_TOKEN missing. ضعه في Render حتى يستطيع السيرفر إنشاء Pull Request.")
    headers = {
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "Respect-App-AI-Fixer",
    }
    if GITHUB_TOKEN:
        headers["Authorization"] = f"Bearer {GITHUB_TOKEN}"
    return headers


def _github_request(method: str, path: str, *, params: Optional[Dict[str, Any]] = None, payload: Optional[Dict[str, Any]] = None, require_token: bool = False) -> Any:
    url = f"{GITHUB_API_BASE}{path}"
    try:
        response = requests.request(
            method.upper(),
            url,
            headers=_github_headers(require_token=require_token),
            params=params,
            json=payload,
            timeout=35,
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"GitHub request failed: {e}")
    if response.status_code >= 400:
        raise HTTPException(status_code=500, detail=f"GitHub error {response.status_code}: {_safe_response_text(response.text, 1200)}")
    if not response.text.strip():
        return {}
    try:
        return response.json()
    except Exception:
        return response.text


def _github_default_branch(owner: str, repo: str) -> str:
    if GITHUB_DEFAULT_BRANCH.strip():
        return GITHUB_DEFAULT_BRANCH.strip()
    data = _github_request("GET", f"/repos/{owner}/{repo}")
    branch = str((data or {}).get("default_branch") or "main").strip()
    return branch or "main"


def _github_repo_tree(owner: str, repo: str, branch: str) -> list[Dict[str, Any]]:
    data = _github_request("GET", f"/repos/{owner}/{repo}/git/trees/{branch}", params={"recursive": "1"})
    tree = data.get("tree") if isinstance(data, dict) else None
    if not isinstance(tree, list):
        raise HTTPException(status_code=500, detail="تعذر قراءة شجرة ملفات GitHub")
    allowed = (".dart", ".py", ".yaml", ".yml", ".json", ".sql", ".ts", ".tsx", ".js", ".md")
    blocked_parts = {"build", ".dart_tool", ".git", "node_modules", "ios/Pods", "android/.gradle", "coverage"}
    files: list[Dict[str, Any]] = []
    for item in tree:
        if not isinstance(item, dict) or item.get("type") != "blob":
            continue
        path = str(item.get("path") or "")
        if not path or not path.lower().endswith(allowed):
            continue
        if any(part in path for part in blocked_parts):
            continue
        size = int(item.get("size") or 0)
        if size > 650_000:
            continue
        files.append({"path": path, "size": size, "sha": item.get("sha")})
    return files


def _github_file_content(owner: str, repo: str, path: str, branch: str) -> Dict[str, Any]:
    data = _github_request("GET", f"/repos/{owner}/{repo}/contents/{path}", params={"ref": branch})
    if not isinstance(data, dict):
        raise HTTPException(status_code=500, detail=f"تعذر قراءة الملف {path}")
    raw = str(data.get("content") or "")
    encoding = str(data.get("encoding") or "")
    text = ""
    if encoding == "base64" and raw:
        try:
            text = base64.b64decode(raw.replace("\n", "")).decode("utf-8", errors="replace")
        except Exception:
            text = ""
    return {"path": path, "sha": data.get("sha"), "content": text, "size": data.get("size") or len(text)}


def _feedback_supabase_insert(row: Dict[str, Any]) -> Dict[str, Any]:
    if not SB_URL or not (SB_SERVICE or SB_ANON):
        return {"ok": False, "reason": "Supabase env missing"}
    try:
        response = requests.post(
            f"{SB_URL}/rest/v1/{APP_AI_FEEDBACK_TABLE}",
            headers={**_supabase_headers(use_service_role=True), "Prefer": "return=representation"},
            json=row,
            timeout=15,
        )
        if response.status_code >= 400:
            return {"ok": False, "status": response.status_code, "body": _safe_response_text(response.text, 900)}
        data = response.json() if response.text.strip() else []
        return {"ok": True, "rows": data}
    except Exception as e:
        return {"ok": False, "reason": str(e)}


def _feedback_supabase_patch(report_id: str, payload: Dict[str, Any]) -> Dict[str, Any]:
    if not SB_URL or not (SB_SERVICE or SB_ANON):
        return {"ok": False, "reason": "Supabase env missing"}
    try:
        response = requests.patch(
            f"{SB_URL}/rest/v1/{APP_AI_FEEDBACK_TABLE}",
            headers={**_supabase_headers(use_service_role=True), "Prefer": "return=representation"},
            params={"id": f"eq.{report_id}"},
            json=payload,
            timeout=15,
        )
        if response.status_code >= 400:
            return {"ok": False, "status": response.status_code, "body": _safe_response_text(response.text, 900)}
        data = response.json() if response.text.strip() else []
        return {"ok": True, "rows": data}
    except Exception as e:
        return {"ok": False, "reason": str(e)}



def _feedback_supabase_get(report_id: str) -> Optional[Dict[str, Any]]:
    if not SB_URL or not (SB_SERVICE or SB_ANON):
        return None
    try:
        response = requests.get(
            f"{SB_URL}/rest/v1/{APP_AI_FEEDBACK_TABLE}",
            headers=_supabase_headers(use_service_role=True),
            params={"select": "*", "id": f"eq.{report_id}", "limit": "1"},
            timeout=15,
        )
        if response.status_code >= 400:
            return None
        rows = response.json()
        if isinstance(rows, list) and rows:
            return Dict[str, Any](rows[0]) if False else dict(rows[0])
    except Exception:
        return None
    return None


def _feedback_supabase_list(status: str = "all", limit: int = 120) -> Dict[str, Any]:
    if not SB_URL or not (SB_SERVICE or SB_ANON):
        return {"ok": False, "items": [], "reason": "Supabase env missing"}
    safe_limit = max(1, min(int(limit or 120), 300))
    params: Dict[str, str] = {
        "select": "*",
        "order": "created_at.desc",
        "limit": str(safe_limit),
    }
    clean_status = str(status or "all").strip().lower()
    if clean_status and clean_status != "all":
        params["status"] = f"eq.{clean_status}"
    try:
        response = requests.get(
            f"{SB_URL}/rest/v1/{APP_AI_FEEDBACK_TABLE}",
            headers=_supabase_headers(use_service_role=True),
            params=params,
            timeout=18,
        )
        if response.status_code >= 400:
            return {"ok": False, "items": [], "status": response.status_code, "body": _safe_response_text(response.text, 900)}
        rows = response.json() if response.text.strip() else []
        if not isinstance(rows, list):
            rows = []
        return {"ok": True, "items": rows, "count": len(rows)}
    except Exception as e:
        return {"ok": False, "items": [], "reason": str(e)}


def _feedback_supabase_delete(report_id: str) -> Dict[str, Any]:
    if not SB_URL or not (SB_SERVICE or SB_ANON):
        return {"ok": False, "reason": "Supabase env missing"}
    try:
        response = requests.delete(
            f"{SB_URL}/rest/v1/{APP_AI_FEEDBACK_TABLE}",
            headers={**_supabase_headers(use_service_role=True), "Prefer": "return=representation"},
            params={"id": f"eq.{report_id}"},
            timeout=15,
        )
        if response.status_code >= 400:
            return {"ok": False, "status": response.status_code, "body": _safe_response_text(response.text, 900)}
        rows = response.json() if response.text.strip() else []
        return {"ok": True, "rows": rows}
    except Exception as e:
        return {"ok": False, "reason": str(e)}


def _notify_app_feedback_resolved(report: Dict[str, Any], admin_username: str, admin_note: str = "") -> Dict[str, Any]:
    username = _display_username(str(report.get("username") or ""))
    report_id = str(report.get("id") or "").strip()
    title = "تم حل البلاغ"
    body = "تم حل المشكلة في البلاغ الذي قدمته، شكرًا لتعاونكم."
    report_title = str(report.get("title") or "").strip()
    if report_title:
        body = f"تم حل المشكلة في البلاغ: {report_title}. شكرًا لتعاونكم."
    if admin_note.strip():
        body = f"{body}\n{admin_note.strip()[:220]}"

    result: Dict[str, Any] = {"sent": False, "username": username, "reason": ""}
    if not username or username == "@user":
        result["reason"] = "missing_username"
        return result
    try:
        target = get_user_push_target(username, fallback_language="ar")
        if not target:
            result["reason"] = "receiver_has_no_fcm_token"
            return result
        language = target.get("language", "ar")
        sent = send_fcm_v1(
            target["token"],
            "app_feedback_resolved",
            title,
            body,
            _localized_data(
                {
                    "type": "app_feedback_resolved",
                    "reportId": report_id,
                    "report_id": report_id,
                    "title": title,
                    "body": body,
                    "text": body,
                    "adminUsername": _display_username(admin_username),
                },
                language,
                title,
                body,
            ),
        )
        result.update(sent if isinstance(sent, dict) else {"raw": sent})
        result["sent"] = True
        return result
    except Exception as e:
        result["reason"] = str(e)
        logger.warning("app feedback resolved push failed report_id=%s user=%s err=%s", report_id, username, e)
        return result




def _exception_detail_text(exc: Exception, limit: int = 1200) -> str:
    """يرجع نص آمن وقصير للخطأ بدون كشف مفاتيح أو توكنات."""
    try:
        detail = getattr(exc, "detail", None)
        if isinstance(detail, (dict, list)):
            raw = json.dumps(detail, ensure_ascii=False)
        elif detail is not None:
            raw = str(detail)
        else:
            raw = str(exc)
    except Exception:
        raw = str(exc)
    return _safe_response_text(raw, limit)


def _ai_provider_status_from_exception(exc: Exception) -> int:
    """يستخرج status الحقيقي من أخطاء مزودي الذكاء مثل OpenRouter/Qwen."""
    if isinstance(exc, HTTPException):
        try:
            if int(exc.status_code) in {408, 409, 425, 429, 500, 502, 503, 504}:
                return int(exc.status_code)
        except Exception:
            pass

        detail = getattr(exc, "detail", None)
        if isinstance(detail, dict):
            for key, value in detail.items():
                low_key = str(key).lower()
                if low_key.endswith("_status") or low_key in {"status", "provider_status", "hf_status"}:
                    try:
                        status = int(value)
                        if status > 0:
                            return status
                    except Exception:
                        pass
            try:
                raw = json.dumps(detail, ensure_ascii=False).lower()
            except Exception:
                raw = str(detail).lower()
        else:
            raw = str(detail or exc).lower()
    else:
        raw = str(exc).lower()

    # احتياطي للنصوص القادمة من OpenRouter أو مزودات OpenAI-compatible.
    if "429" in raw or "rate limit" in raw or "too many requests" in raw or "quota" in raw:
        return 429
    if "timeout" in raw or "timed out" in raw:
        return 504
    if "temporarily unavailable" in raw or "overloaded" in raw or "service unavailable" in raw:
        return 503
    return 0


def _is_retryable_ai_exception(exc: Exception) -> bool:
    if isinstance(exc, (
        requests.exceptions.Timeout,
        requests.exceptions.ConnectionError,
        requests.exceptions.ChunkedEncodingError,
    )):
        return True
    return _ai_provider_status_from_exception(exc) in {408, 409, 425, 429, 500, 502, 503, 504}


def _feedback_ai_busy_response(
    *,
    report_id: str,
    phase: str,
    exc: Exception,
    db_insert: Dict[str, Any],
    analysis: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    """
    عند ضغط نماذج OpenRouter/Qwen لا نفشل البلاغ.
    نحفظ البلاغ في Supabase بحالة قابلة لإعادة المحاولة ونرجع 200 للتطبيق.
    """
    provider_status = _ai_provider_status_from_exception(exc) or 503
    now = datetime.now(timezone.utc).isoformat()
    phase_ar = "تحليل البلاغ" if phase == "analysis" else "تجهيز التصحيح"
    status = "queued_ai_busy" if phase == "analysis" else "analyzed_waiting_ai_retry"
    summary = (
        "تم حفظ البلاغ بنجاح، لكن نموذج الذكاء الاصطناعي مشغول الآن. "
        "لن يضيع البلاغ، جرّب إعادة التحليل لاحقًا من لوحة الإدارة."
    )
    result = {
        "summary": summary,
        "retryable": True,
        "phase": phase,
        "phaseLabel": phase_ar,
        "providerStatus": provider_status,
        "error": _exception_detail_text(exc),
        "models": {"patcher": AI_FIX_MODEL_1, "reviewer": AI_FIX_MODEL_2, "finalReviewer": AI_FIX_MODEL_3, "chain": AI_FIX_MODEL_CHAIN},
        "hint": "إذا فشلت كل الموديلات المجانية بسبب 429/402/503 فزِد AI_FIX_EXTRA_MODELS أو اشحن OpenRouter credits.",
    }
    patch_payload: Dict[str, Any] = {
        "status": status,
        "result": result,
        "updated_at": now,
    }
    if isinstance(analysis, dict):
        patch_payload["analysis"] = analysis
    database_patch = _feedback_supabase_patch(report_id, patch_payload)
    logger.warning(
        "AI feedback saved without failing request report_id=%s phase=%s provider_status=%s error=%s",
        report_id,
        phase,
        provider_status,
        _exception_detail_text(exc, 500),
    )
    return {
        "ok": True,
        "id": report_id,
        "reportId": report_id,
        "status": status,
        "summary": summary,
        "retryable": True,
        "phase": phase,
        "providerStatus": provider_status,
        "analysis": analysis or {},
        "result": result,
        "changedFiles": [],
        "review2": {},
        "review3": {},
        "databaseSaved": bool(db_insert.get("ok")),
        "databasePatch": database_patch,
        "models": result.get("models") or {},
        "model": AI_FIX_MODEL_1,
    }


def _ai_fix_is_admin(username: str) -> bool:
    clean = normalize_username(username).lower()
    return bool(clean and clean in AI_FIX_ADMIN_USERNAMES)


def _extract_json_object(raw: str) -> Dict[str, Any]:
    text = (raw or "").strip()
    if not text:
        raise HTTPException(status_code=500, detail="Qwen returned empty JSON")
    try:
        data = json.loads(text)
        if isinstance(data, dict):
            return data
    except Exception:
        pass
    match = re.search(r"\{.*\}", text, flags=re.S)
    if match:
        try:
            data = json.loads(match.group(0))
            if isinstance(data, dict):
                return data
        except Exception:
            pass
    raise HTTPException(status_code=500, detail=f"Qwen JSON parse failed: {_safe_response_text(text, 900)}")


def _split_ai_model_env(value: str) -> list[str]:
    """يقسم قائمة موديلات من Render مفصولة بفواصل أو أسطر، مع إزالة التكرار."""
    models: list[str] = []
    raw = str(value or "").replace("\n", ",").replace(";", ",")
    for item in raw.split(","):
        model = item.strip()
        if not model or model.startswith("#"):
            continue
        if model not in models:
            models.append(model)
    return models


def _ai_fix_base_model_chain() -> list[str]:
    """
    قائمة عامة يستخدمها AI Fixer عند فشل أي نموذج.
    ابدأ بالأساسيات ثم أضف AI_FIX_EXTRA_MODELS من Render.
    """
    chain: list[str] = []
    for item in [AI_FIX_MODEL_1, AI_FIX_MODEL_2, AI_FIX_MODEL_3, *_split_ai_model_env(AI_FIX_EXTRA_MODELS)]:
        item = str(item or "").strip()
        if item and item not in chain:
            chain.append(item)
    return chain


AI_FIX_MODEL_CHAIN = _ai_fix_base_model_chain()


def _ai_fix_chain_for(primary_model: str) -> list[str]:
    """
    يجعل النموذج المطلوب أول واحد، ثم يجرب بقية الموديلات بالترتيب.
    AI_FIX_MAX_MODEL_ATTEMPTS يمنع الدوران الطويل جدًا داخل Render.
    """
    primary = str(primary_model or "").strip()
    chain: list[str] = []
    if primary:
        chain.append(primary)
    for model in AI_FIX_MODEL_CHAIN:
        if model and model not in chain:
            chain.append(model)
    max_attempts = max(1, AI_FIX_MAX_MODEL_ATTEMPTS)
    return chain[:max_attempts]


def _model_label(log_label: str, model: str, index: int) -> str:
    safe = re.sub(r"[^A-Za-z0-9]+", "_", str(model or "model")).strip("_").upper()[:60]
    return f"{log_label}_TRY_{index}_{safe}"


def _ai_json_failure_detail(errors: list[Dict[str, Any]]) -> Dict[str, Any]:
    return {
        "message": "كل موديلات AI Fixer فشلت أو كانت مشغولة.",
        "errors": errors[-12:],
        "modelsTried": [str(e.get("model") or "") for e in errors if e.get("model")],
        "retryable": True,
        "hint": "زِد AI_FIX_EXTRA_MODELS أو اشحن OpenRouter credits. الموديلات المجانية تتعرض للضغط وتملك حدودًا يومية/دقيقة.",
    }


def _ai_fixer_json(
    messages: list[Dict[str, str]],
    *,
    model: str,
    max_tokens: int = 2500,
    temperature: float = 0.1,
    log_label: str = "AI_FIXER",
) -> Dict[str, Any]:
    """
    يستدعي OpenRouter بسلسلة موديلات fallback.
    إذا فشل نموذج بسبب 429/402/503/timeout أو رجّع JSON غير صالح، ينتقل للنموذج التالي.
    إذا لم تضبط OPENROUTER_API_KEY يستخدم Qwen كاحتياطي قديم.
    """
    if OPENROUTER_API_KEY:
        errors: list[Dict[str, Any]] = []
        chain = _ai_fix_chain_for(model)
        logger.info("AI Fixer %s model chain=%s", log_label, chain)

        for index, candidate_model in enumerate(chain, start=1):
            candidate_model = str(candidate_model or "").strip()
            if not candidate_model:
                continue

            # المحاولة الأولى: JSON mode. بعض الموديلات لا تدعمه، لذلك عند 400/422 نجرب بدونه.
            try:
                raw = _chat_completion_request(
                    model=candidate_model,
                    api_key=OPENROUTER_API_KEY,
                    base_url=OPENROUTER_BASE_URL,
                    messages=messages,
                    temperature=temperature,
                    max_tokens=max_tokens,
                    timeout=QWEN_CODER_TIMEOUT_SECONDS,
                    response_format={"type": "json_object"},
                    log_label=_model_label(log_label, candidate_model, index),
                )
                data = _extract_json_object(raw)
                data.setdefault("model", candidate_model)
                data.setdefault("_modelUsed", candidate_model)
                data.setdefault("_modelsTried", chain[:index])
                return data
            except Exception as exc:
                status = _ai_provider_status_from_exception(exc)
                errors.append({
                    "model": candidate_model,
                    "status": status or getattr(exc, "status_code", 0),
                    "error": _exception_detail_text(exc, 700),
                    "jsonMode": True,
                })

                # لو المشكلة ضغط/رصيد/مزود غير متاح لا نعيد نفس النموذج، ننتقل مباشرة.
                if status in {402, 408, 409, 425, 429, 500, 502, 503, 504}:
                    logger.warning(
                        "AI Fixer model skipped log_label=%s model=%s status=%s error=%s",
                        log_label,
                        candidate_model,
                        status,
                        _exception_detail_text(exc, 350),
                    )
                    continue

            # المحاولة الثانية لنفس النموذج بدون response_format.
            # تفيد مع موديلات مجانية لا تدعم JSON mode لكنها تستطيع إرجاع JSON نصيًا.
            try:
                raw = _chat_completion_request(
                    model=candidate_model,
                    api_key=OPENROUTER_API_KEY,
                    base_url=OPENROUTER_BASE_URL,
                    messages=messages,
                    temperature=temperature,
                    max_tokens=max_tokens,
                    timeout=QWEN_CODER_TIMEOUT_SECONDS,
                    response_format=None,
                    log_label=f"{_model_label(log_label, candidate_model, index)}_NO_JSON_MODE",
                )
                data = _extract_json_object(raw)
                data.setdefault("model", candidate_model)
                data.setdefault("_modelUsed", candidate_model)
                data.setdefault("_modelsTried", chain[:index])
                return data
            except Exception as exc:
                status = _ai_provider_status_from_exception(exc)
                errors.append({
                    "model": candidate_model,
                    "status": status or getattr(exc, "status_code", 0),
                    "error": _exception_detail_text(exc, 700),
                    "jsonMode": False,
                })
                logger.warning(
                    "AI Fixer model failed log_label=%s model=%s status=%s error=%s",
                    log_label,
                    candidate_model,
                    status or getattr(exc, "status_code", 0),
                    _exception_detail_text(exc, 350),
                )
                continue

        raise HTTPException(status_code=503, detail=_ai_json_failure_detail(errors))

    if not QWEN_API_KEY:
        raise HTTPException(status_code=500, detail="OPENROUTER_API_KEY missing. ضع مفتاح OpenRouter في Render لتشغيل نماذج التصحيح المجانية.")

    try:
        raw = _chat_completion_request(
            model=QWEN_CODER_MODEL,
            api_key=QWEN_API_KEY,
            base_url=QWEN_BASE_URL,
            messages=messages,
            temperature=temperature,
            max_tokens=max_tokens,
            timeout=QWEN_CODER_TIMEOUT_SECONDS,
            response_format={"type": "json_object"},
            log_label=log_label,
        )
    except HTTPException:
        raw = _chat_completion_request(
            model=QWEN_CODER_MODEL,
            api_key=QWEN_API_KEY,
            base_url=QWEN_BASE_URL,
            messages=messages,
            temperature=temperature,
            max_tokens=max_tokens,
            timeout=QWEN_CODER_TIMEOUT_SECONDS,
            log_label=f"{log_label}_FALLBACK",
        )
    data = _extract_json_object(raw)
    data.setdefault("model", QWEN_CODER_MODEL)
    data.setdefault("_modelUsed", QWEN_CODER_MODEL)
    data.setdefault("_modelsTried", [QWEN_CODER_MODEL])
    return data


def _qwen_coder_json(messages: list[Dict[str, str]], *, max_tokens: int = 2500, temperature: float = 0.1) -> Dict[str, Any]:
    # الاسم قديم للتوافق؛ الآن يستخدم سلسلة موديلات OpenRouter بدل موديل واحد.
    return _ai_fixer_json(
        messages,
        model=AI_FIX_MODEL_1,
        max_tokens=max_tokens,
        temperature=temperature,
        log_label="AI_FIX_MODEL_1_ANALYZE",
    )

def _score_candidate_file(path: str, title: str, note: str, screen: str) -> int:
    low_path = path.lower()
    text = f"{title} {note} {screen}".lower()
    score = 0
    keywords = {
        "settings": ["اعدادات", "الإعدادات", "settings", "ملاحظ", "بلاغ", "feedback"],
        "profile": ["profile", "بروفايل", "الملف الشخصي", "حسابي", "تعديل"],
        "feed": ["feed", "فيد", "الرئيسية", "منشور", "تغريدة", "هاشتاق"],
        "chat": ["chat", "message", "رسائل", "دردشة"],
        "login": ["login", "auth", "تسجيل", "دخول", "كلمة المرور"],
        "admin": ["admin", "ادمن", "إدارة", "بلاغات"],
        "supabase": ["supabase", "database", "قاعدة", "مجتمعات", "ديون"],
        "server": ["server", "backend", "render", "ai", "qwen", "push", "otp"],
        "notification": ["notification", "اشعار", "إشعار", "push"],
        "live": ["live", "بث"],
        "call": ["call", "مكالمة", "اتصال"],
    }
    for key, words in keywords.items():
        if key in low_path and any(w.lower() in text for w in words):
            score += 10
    filename = low_path.rsplit("/", 1)[-1]
    for token in re.findall(r"[a-zA-Z_]{4,}|[\u0600-\u06FF]{3,}", text):
        t = token.lower().strip("_-")
        if t and t in filename:
            score += 3
    # ملفات مركزية مهمة في مشروعك.
    if low_path.endswith("supabase_service.dart"):
        score += 4
    if low_path.endswith("settings_screen.dart"):
        score += 4
    if low_path.endswith("server.py") or "server" in low_path:
        score += 3
    return score


def _select_candidate_files(files: list[Dict[str, Any]], title: str, note: str, screen: str, limit: int) -> list[str]:
    scored = []
    for f in files:
        path = str(f.get("path") or "")
        if not path:
            continue
        score = _score_candidate_file(path, title, note, screen)
        if score > 0:
            scored.append((score, int(f.get("size") or 0), path))
    scored.sort(key=lambda x: (-x[0], x[1], x[2]))
    selected = [p for _, _, p in scored[:limit]]
    for must in ["lib/screens/settings_screen.dart", "lib/services/supabase_service.dart", "server.py", "main.py", "app.py"]:
        if len(selected) >= limit:
            break
        if any(str(f.get("path") or "") == must for f in files) and must not in selected:
            selected.append(must)
    if not selected:
        selected = [str(f.get("path")) for f in files[:limit] if f.get("path")]
    return selected[:limit]


def _file_context(files: list[Dict[str, Any]], max_chars_per_file: int = AI_FIX_MAX_FILE_CHARS) -> str:
    parts: list[str] = []
    for f in files:
        path = str(f.get("path") or "")
        content = str(f.get("content") or "")
        if len(content) > max_chars_per_file:
            content = content[:max_chars_per_file] + "\n/* ... TRUNCATED_FOR_AI_CONTEXT ... */"
        parts.append(f"\n===== FILE: {path} =====\n{content}")
    return "\n".join(parts)


def _analysis_suspected_paths(analysis: Dict[str, Any]) -> list[str]:
    paths: list[str] = []
    for key in ["filesToModify", "suspectedFiles", "files", "candidateFiles"]:
        value = analysis.get(key)
        if isinstance(value, list):
            for item in value:
                if isinstance(item, dict):
                    path = str(item.get("path") or item.get("file") or "").strip()
                else:
                    path = str(item or "").strip()
                if path and path not in paths:
                    paths.append(path)
    return paths[:AI_FIX_MAX_FILES]



def _feedback_media_payload(req: AppAIFeedbackSubmitRequest) -> Dict[str, Any]:
    attachments: list[Dict[str, str]] = []

    def add(url: Any, media_type: str = "", name: str = "") -> None:
        clean_url = str(url or "").strip()
        if not clean_url or not (clean_url.startswith("http://") or clean_url.startswith("https://")):
            return
        clean_type = str(media_type or "").strip().lower()
        if clean_type not in {"image", "video"}:
            low_url = clean_url.lower().split("?", 1)[0]
            if low_url.endswith((".mp4", ".mov", ".m4v", ".webm", ".mkv")):
                clean_type = "video"
            elif low_url.endswith((".jpg", ".jpeg", ".png", ".webp", ".gif")):
                clean_type = "image"
            else:
                clean_type = "file"
        item = {"url": clean_url, "type": clean_type, "name": str(name or "").strip()[:160]}
        if not any(existing.get("url") == clean_url for existing in attachments):
            attachments.append(item)

    add(req.mediaUrl, req.mediaType, req.mediaName)
    for raw in req.mediaAttachments or []:
        if not isinstance(raw, dict):
            continue
        add(raw.get("url") or raw.get("mediaUrl"), raw.get("type") or raw.get("mediaType"), raw.get("name") or raw.get("mediaName"))
    for url in req.imageUrls or []:
        add(url, "image", "")
    for url in req.videoUrls or []:
        add(url, "video", "")
    for url in req.mediaUrls or []:
        add(url, "", "")

    attachments = attachments[:4]
    image_urls = [item["url"] for item in attachments if item.get("type") == "image"]
    video_urls = [item["url"] for item in attachments if item.get("type") == "video"]
    return {
        "attachments": attachments,
        "imageUrls": image_urls,
        "videoUrls": video_urls,
        "count": len(attachments),
        "hasMedia": bool(attachments),
    }


def _visual_feedback_prompt() -> str:
    return (
        "أنت مساعد بصري لنظام صيانة تطبيق Flutter اسمه Respect App. "
        "المستخدم أرفق صورة أو لقطات من فيديو لتوضيح مشكلة في التطبيق. "
        "حلل ما يظهر في الشاشة: النصوص، الأزرار، الأخطاء، الصفحة، السلوك المتوقع، وأي مؤشر يساعد المبرمج. "
        "لا تحكم على المحتوى كمنشور اجتماعي، بل ركز على تشخيص عطل واجهة/تطبيق. "
        "أرجع JSON فقط بالمفاتيح: summary, observedScreen, visibleTexts, suspectedUiProblem, developerNotes, confidence."
    )


def _analyze_feedback_image_url(image_url: str, label: str) -> Dict[str, Any]:
    if not QWEN_API_KEY:
        return {"ok": False, "type": "image", "url": image_url, "error": "QWEN_API_KEY missing; vision skipped"}
    content = _chat_completion_request(
        model=QWEN_VISION_MODEL,
        api_key=QWEN_API_KEY,
        base_url=QWEN_BASE_URL,
        messages=[
            {"role": "system", "content": _visual_feedback_prompt()},
            {
                "role": "user",
                "content": [
                    {"type": "image_url", "image_url": {"url": image_url}},
                    {"type": "text", "text": f"حلل هذا المرفق البصري الخاص ببلاغ مشكلة داخل التطبيق. الوصف: {label}. أرجع JSON فقط."},
                ],
            },
        ],
        temperature=0.0,
        max_tokens=650,
        timeout=45,
        response_format=None,
        log_label="AI_FEEDBACK_VISION_IMAGE",
    )
    parsed = _safe_json_from_ai(str(content))
    return {"ok": True, "type": "image", "url": image_url, "model": QWEN_VISION_MODEL, "analysis": parsed or {"summary": str(content)[:1200]}}


def _analyze_feedback_video_url(video_url: str, label: str) -> Dict[str, Any]:
    if not QWEN_API_KEY:
        return {"ok": False, "type": "video", "url": video_url, "error": "QWEN_API_KEY missing; vision skipped"}
    frames = _extract_video_frame_data_urls(video_url, max_frames=4)
    content_blocks: list[Dict[str, Any]] = []
    for frame in frames[:4]:
        data_url = str(frame.get("dataUrl") or "")
        if data_url:
            content_blocks.append({"type": "image_url", "image_url": {"url": data_url}})
    content_blocks.append({"type": "text", "text": f"هذه لقطات من فيديو بلاغ مشكلة داخل التطبيق. الوصف: {label}. حلل ما يظهر في اللقطات واكتب JSON فقط."})
    content = _chat_completion_request(
        model=QWEN_VISION_MODEL,
        api_key=QWEN_API_KEY,
        base_url=QWEN_BASE_URL,
        messages=[
            {"role": "system", "content": _visual_feedback_prompt()},
            {"role": "user", "content": content_blocks},
        ],
        temperature=0.0,
        max_tokens=850,
        timeout=75,
        response_format=None,
        log_label="AI_FEEDBACK_VISION_VIDEO",
    )
    parsed = _safe_json_from_ai(str(content))
    return {
        "ok": True,
        "type": "video",
        "url": video_url,
        "model": QWEN_VISION_MODEL,
        "framesAnalyzed": len(frames[:4]),
        "analysis": parsed or {"summary": str(content)[:1400]},
    }


def _analyze_feedback_visual_evidence(req: AppAIFeedbackSubmitRequest) -> Dict[str, Any]:
    media = _feedback_media_payload(req)
    if not media.get("hasMedia"):
        return {"ok": True, "hasMedia": False, "items": []}
    items: list[Dict[str, Any]] = []
    for item in media.get("attachments", [])[:3]:
        url = str(item.get("url") or "")
        media_type = str(item.get("type") or "")
        label = str(item.get("name") or req.title or req.screen or "بلاغ مشكلة")
        try:
            if media_type == "image":
                items.append(_analyze_feedback_image_url(url, label))
            elif media_type == "video":
                items.append(_analyze_feedback_video_url(url, label))
            else:
                items.append({"ok": False, "type": media_type or "file", "url": url, "error": "نوع المرفق غير مدعوم بصريًا"})
        except Exception as e:
            items.append({"ok": False, "type": media_type, "url": url, "error": _safe_response_text(str(e), 500)})
    return {"ok": True, "hasMedia": True, "media": media, "items": items}


def _analyze_feedback_with_qwen(req: AppAIFeedbackSubmitRequest, report_id: str) -> Dict[str, Any]:
    owner, repo = _repo_owner_name()
    branch = _github_default_branch(owner, repo)
    tree = _github_repo_tree(owner, repo, branch)
    media_payload = _feedback_media_payload(req)
    visual_evidence = _analyze_feedback_visual_evidence(req)
    candidate_paths = _select_candidate_files(tree, req.title, req.note, req.screen, AI_FIX_MAX_FILES)
    fetched: list[Dict[str, Any]] = []
    for path in candidate_paths:
        try:
            fetched.append(_github_file_content(owner, repo, path, branch))
        except Exception as e:
            logger.warning("AI feedback fetch candidate failed path=%s err=%s", path, e)
    file_list = "\n".join(f"- {f.get('path')} ({f.get('size', 0)} bytes)" for f in tree[:280])
    messages = [
        {
            "role": "system",
            "content": (
                "أنت Qwen3-Coder داخل نظام صيانة Respect App. حلل بلاغ المستخدم على مشروع Flutter/FastAPI/Supabase. "
                "لا تعدل الآن. فقط حدد الملفات المحتملة وسبب المشكلة وخطة تصحيح آمنة. "
                "أعد JSON فقط بالمفاتيح: summary, problem, confidence, suspectedFiles, filesToModify, proposedFix, risk, testPlan, status. "
                "filesToModify يجب أن تكون قائمة عناصر {path, reason}. status يجب أن تكون analyzed."
            ),
        },
        {
            "role": "user",
            "content": (
                f"REPORT_ID: {report_id}\n"
                f"المستخدم: {req.username}\nالاسم: {req.name}\nالعنوان: {req.title}\nالصفحة: {req.screen}\nنسخة التطبيق: {req.appVersion}\n"
                f"نص البلاغ:\n{req.note}\n\n"
                f"مرفقات البلاغ من التطبيق:\n{json.dumps(media_payload, ensure_ascii=False)[:5000]}\n\n"
                f"تحليل المرفقات البصرية إن وجد:\n{json.dumps(visual_evidence, ensure_ascii=False)[:7000]}\n\n"
                f"قائمة ملفات المشروع المختصرة:\n{file_list[:18000]}\n\n"
                f"محتوى ملفات مرشحة:\n{_file_context(fetched)}"
            ),
        },
    ]
    analysis = _qwen_coder_json(messages, max_tokens=2600, temperature=0.05)
    analysis.setdefault("status", "analyzed")
    analysis.setdefault("candidateFiles", candidate_paths)
    analysis.setdefault("media", media_payload)
    analysis.setdefault("visualEvidence", visual_evidence)
    analysis.setdefault("repo", {"owner": owner, "name": repo, "branch": branch})
    return analysis



def _safe_patch_path(path: str) -> str:
    clean = str(path or "").strip().replace("\\", "/")
    if clean.startswith("a/") or clean.startswith("b/"):
        clean = clean[2:]
    clean = clean.lstrip("/")
    if not clean or clean == "/dev/null":
        return ""
    if clean.startswith("../") or "/../" in clean or clean.endswith("/.."):
        return ""
    if clean.startswith(".git/") or "/.git/" in clean:
        return ""
    return clean


def _extract_unified_diff(value: Any) -> str:
    if isinstance(value, dict):
        for key in ("unifiedDiff", "diff", "patch", "candidatePatch"):
            raw = value.get(key)
            if isinstance(raw, str) and raw.strip():
                return _extract_unified_diff(raw)
        return ""
    text = str(value or "").strip()
    if text.startswith("```"):
        text = re.sub(r"^```(?:diff|patch|text)?\s*", "", text, flags=re.I).strip()
        text = re.sub(r"\s*```$", "", text).strip()
    pos = text.find("diff --git ")
    if pos > 0:
        text = text[pos:]
    return text.strip()


def _paths_from_unified_diff(diff_text: str) -> list[str]:
    paths: list[str] = []
    for line in str(diff_text or "").splitlines():
        path = ""
        match = re.match(r"^diff --git\s+a/(.*?)\s+b/(.*?)\s*$", line)
        if match:
            path = match.group(2)
        elif line.startswith("+++ "):
            raw = line[4:].strip().split("\t", 1)[0]
            if raw.startswith("b/"):
                path = raw[2:]
            elif raw != "/dev/null":
                path = raw
        safe = _safe_patch_path(path)
        if safe and safe not in paths:
            paths.append(safe)
    return paths[:AI_FIX_MAX_FILES]


def _validate_patch_scope(diff_text: str, allowed_paths: set[str]) -> list[str]:
    if not diff_text.strip():
        raise HTTPException(status_code=500, detail="النموذج لم يرجع unified diff صالح")
    if len(diff_text) > AI_FIX_MAX_PATCH_CHARS:
        raise HTTPException(status_code=500, detail="التصحيح أكبر من الحد المسموح. قلل عدد الملفات أو حجم التعديل.")
    if "diff --git" not in diff_text and "@@" not in diff_text:
        raise HTTPException(status_code=500, detail="التصحيح ليس بصيغة unified diff")
    paths = _paths_from_unified_diff(diff_text)
    if not paths:
        raise HTTPException(status_code=500, detail="لم نستطع معرفة الملفات المعدلة من diff")
    blocked = [p for p in paths if p not in allowed_paths]
    if blocked:
        raise HTTPException(status_code=500, detail=f"التصحيح حاول تعديل ملفات خارج النطاق: {', '.join(blocked[:6])}")
    return paths


def _run_git_apply(workdir: str, patch_path: str, *, check_only: bool) -> Dict[str, Any]:
    command = ["git", "apply"]
    if check_only:
        command.append("--check")
    command.append(patch_path)
    try:
        proc = subprocess.run(command, cwd=workdir, capture_output=True, text=True, timeout=45)
    except FileNotFoundError:
        return {"ok": False, "error": "git غير موجود على السيرفر. ثبّت git أو استخدم Render runtime يحتوي git."}
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "انتهى وقت فحص patch"}
    output = (proc.stdout or "") + ("\n" if proc.stdout and proc.stderr else "") + (proc.stderr or "")
    return {"ok": proc.returncode == 0, "returnCode": proc.returncode, "output": _safe_response_text(output, 2000)}


def _apply_patch_to_fetched_files(diff_text: str, fetched: list[Dict[str, Any]]) -> Dict[str, Any]:
    allowed_paths = {_safe_patch_path(str(f.get("path") or "")) for f in fetched if _safe_patch_path(str(f.get("path") or ""))}
    changed_paths = _validate_patch_scope(diff_text, allowed_paths)

    with tempfile.TemporaryDirectory(prefix="respect_ai_patch_") as tmp:
        for f in fetched:
            path = _safe_patch_path(str(f.get("path") or ""))
            if not path:
                continue
            abs_path = os.path.join(tmp, path)
            os.makedirs(os.path.dirname(abs_path), exist_ok=True)
            with open(abs_path, "w", encoding="utf-8", newline="") as out:
                out.write(str(f.get("content") or ""))

        patch_path = os.path.join(tmp, "respect_ai_fix.patch")
        with open(patch_path, "w", encoding="utf-8", newline="") as out:
            out.write(diff_text)
            if not diff_text.endswith("\n"):
                out.write("\n")

        check = _run_git_apply(tmp, patch_path, check_only=True)
        if not check.get("ok"):
            return {"ok": False, "changedFiles": changed_paths, "error": check.get("output") or check.get("error") or "git apply --check failed"}

        applied = _run_git_apply(tmp, patch_path, check_only=False)
        if not applied.get("ok"):
            return {"ok": False, "changedFiles": changed_paths, "error": applied.get("output") or applied.get("error") or "git apply failed"}

        files: list[Dict[str, Any]] = []
        for path in changed_paths:
            abs_path = os.path.join(tmp, path)
            if not os.path.exists(abs_path):
                return {"ok": False, "changedFiles": changed_paths, "error": f"الملف الناتج غير موجود بعد تطبيق patch: {path}"}
            with open(abs_path, "r", encoding="utf-8", errors="replace") as src:
                content = src.read()
            if len(content.strip()) < 5:
                return {"ok": False, "changedFiles": changed_paths, "error": f"الملف الناتج فارغ أو غير صالح: {path}"}
            files.append({"path": path, "content": content, "reason": "Respect AI unified diff patch"})

    return {"ok": True, "changedFiles": changed_paths, "files": files, "error": ""}


def _generate_patch_with_model_1(report: Dict[str, Any], analysis: Dict[str, Any], fetched: list[Dict[str, Any]], validation_error: str = "") -> Dict[str, Any]:
    retry_note = ""
    if validation_error:
        retry_note = f"\n\nمحاولة سابقة فشلت عند git apply --check بسبب:\n{validation_error}\nأعد unifiedDiff مصحح فقط."

    messages = [
        {
            "role": "system",
            "content": (
                "أنت Qwen3-Coder داخل نظام Respect App AI Fixer. مهمتك إنتاج تصحيح صغير بصيغة unified diff فقط. "
                "لا ترجع محتوى الملف كاملًا أبدًا. لا تعدل ملفات غير موجودة في السياق. "
                "أعد JSON فقط بالمفاتيح: status, summary, changedFiles, unifiedDiff, testPlan, risk. "
                "status يجب أن يكون patch_ready. unifiedDiff يجب أن يبدأ غالبًا بـ diff --git وأن يحتوي @@. "
                "غيّر أقل عدد ممكن من الأسطر حول مكان المشكلة فقط. حافظ على Dart syntax و Python syntax."
            ),
        },
        {
            "role": "user",
            "content": (
                f"البلاغ الأصلي:\nالعنوان: {report.get('title','')}\nالصفحة: {report.get('screen','')}\nالنص: {report.get('note','')}\n\n"
                f"تحليل الملفات:\n{json.dumps(analysis, ensure_ascii=False)[:14000]}\n\n"
                f"محتوى الملفات المرشحة للتعديل فقط:\n{_file_context(fetched, max_chars_per_file=max(AI_FIX_MAX_FILE_CHARS, 24000))}"
                f"{retry_note}"
            ),
        },
    ]
    result = _ai_fixer_json(messages, model=AI_FIX_MODEL_1, max_tokens=14000, temperature=0.03, log_label="AI_FIX_MODEL_1_PATCH")
    result["unifiedDiff"] = _extract_unified_diff(result)
    result.setdefault("status", "patch_ready")
    result["model"] = str(result.get("_modelUsed") or result.get("model") or AI_FIX_MODEL_1)
    return result


def _review_patch_with_model_2(report: Dict[str, Any], analysis: Dict[str, Any], patch_result: Dict[str, Any], validation: Dict[str, Any]) -> Dict[str, Any]:
    messages = [
        {
            "role": "system",
            "content": (
                "أنت DeepSeek Reviewer. راجع patch لمشروع Flutter/FastAPI. لا تعدّل الكود. "
                "افحص syntax والمنطق والتأثير الجانبي وهل patch محدود حول المشكلة. "
                "أعد JSON فقط: {approved:boolean, decision, summary, syntaxIssues:list, logicIssues:list, securityIssues:list, suggestions:list, status}. "
                "approved لا يكون true إلا إذا كان patch آمنًا وصحيحًا ولا يحتوي أخطاء syntax واضحة."
            ),
        },
        {
            "role": "user",
            "content": (
                f"البلاغ:\n{report.get('title','')}\n{report.get('note','')}\n\n"
                f"التحليل:\n{json.dumps(analysis, ensure_ascii=False)[:9000]}\n\n"
                f"نتيجة فحص git apply:\n{json.dumps(validation, ensure_ascii=False)[:3000]}\n\n"
                f"PATCH:\n{str(patch_result.get('unifiedDiff') or '')[:AI_FIX_MAX_PATCH_CHARS]}"
            ),
        },
    ]
    review = _ai_fixer_json(messages, model=AI_FIX_MODEL_2, max_tokens=3200, temperature=0.02, log_label="AI_FIX_MODEL_2_REVIEW")
    approved = bool(review.get("approved")) and str(review.get("decision", "approved")).lower() not in {"reject", "rejected", "needs_fix", "failed"}
    review["approved"] = approved
    review.setdefault("status", "reviewed")
    review["model"] = str(review.get("_modelUsed") or review.get("model") or AI_FIX_MODEL_2)
    return review


def _review_reviewer_with_model_3(report: Dict[str, Any], analysis: Dict[str, Any], patch_result: Dict[str, Any], validation: Dict[str, Any], review_2: Dict[str, Any]) -> Dict[str, Any]:
    messages = [
        {
            "role": "system",
            "content": (
                "أنت Kimi Final Reviewer. راجع patch وراجع قرار DeepSeek. "
                "أعطِ قرارًا نهائيًا قبل وصوله للأدمن. لا تعدل الكود ولا ترجع ملف كامل. "
                "أعد JSON فقط: {approved:boolean, finalDecision, summary, reviewer2Correct:boolean, remainingRisks:list, adminNote, status}. "
                "approved true يعني يمكن عرض زر موافقة الأدمن. approved false يعني يحتاج إصلاح AI قبل الأدمن."
            ),
        },
        {
            "role": "user",
            "content": (
                f"البلاغ:\n{report.get('title','')}\n{report.get('note','')}\n\n"
                f"التحليل:\n{json.dumps(analysis, ensure_ascii=False)[:8000]}\n\n"
                f"فحص patch المحلي:\n{json.dumps(validation, ensure_ascii=False)[:3000]}\n\n"
                f"مراجعة DeepSeek:\n{json.dumps(review_2, ensure_ascii=False)[:6000]}\n\n"
                f"PATCH:\n{str(patch_result.get('unifiedDiff') or '')[:AI_FIX_MAX_PATCH_CHARS]}"
            ),
        },
    ]
    review = _ai_fixer_json(messages, model=AI_FIX_MODEL_3, max_tokens=3200, temperature=0.02, log_label="AI_FIX_MODEL_3_FINAL_REVIEW")
    approved = bool(review.get("approved")) and str(review.get("finalDecision", "approved")).lower() not in {"reject", "rejected", "needs_fix", "failed"}
    review["approved"] = approved
    review.setdefault("status", "final_reviewed")
    review["model"] = str(review.get("_modelUsed") or review.get("model") or AI_FIX_MODEL_3)
    return review


def _build_report_payload_for_fix(report: Dict[str, Any], analysis: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "id": str(report.get("id") or report.get("reportId") or ""),
        "title": str(report.get("title") or "بلاغ مشكلة في Respect App"),
        "screen": str(report.get("screen") or ""),
        "note": str(report.get("note") or ""),
        "username": str(report.get("username") or ""),
        "analysis": analysis,
    }

def _generate_fix_with_qwen(report: Dict[str, Any]) -> Dict[str, Any]:
    """
    الاسم بقي للتوافق، لكن التنفيذ صار Triple AI Patch Review:
    Qwen3-Coder Free -> DeepSeek Free -> Kimi Free -> موافقة الأدمن.
    النموذج الأول يرجع unified diff فقط، ثم السيرفر يفحصه محليًا بـ git apply --check،
    وبعد موافقة النموذجين الثاني والثالث فقط يظهر للأدمن.
    """
    owner, repo = _repo_owner_name()
    branch = _github_default_branch(owner, repo)
    analysis = report.get("analysis") if isinstance(report.get("analysis"), dict) else {}
    paths = _analysis_suspected_paths(analysis)
    if not paths:
        paths = list(analysis.get("candidateFiles") or [])[:AI_FIX_MAX_FILES] if isinstance(analysis.get("candidateFiles"), list) else []
    if not paths:
        raise HTTPException(status_code=400, detail="لا توجد ملفات محددة للتصحيح في التحليل")

    fetched: list[Dict[str, Any]] = []
    for path in paths[:AI_FIX_MAX_FILES]:
        fetched.append(_github_file_content(owner, repo, path, branch))

    report_payload = _build_report_payload_for_fix(report, analysis)

    patch_result = _generate_patch_with_model_1(report_payload, analysis, fetched)
    diff_text = _extract_unified_diff(patch_result)
    validation = _apply_patch_to_fetched_files(diff_text, fetched)

    # محاولة إصلاح واحدة فقط لو فشل patch محليًا. هذا يحافظ على السيرفر خفيف ويمنع loop طويل.
    if not validation.get("ok"):
        patch_result = _generate_patch_with_model_1(report_payload, analysis, fetched, validation_error=str(validation.get("error") or ""))
        diff_text = _extract_unified_diff(patch_result)
        validation = _apply_patch_to_fetched_files(diff_text, fetched)

    if not validation.get("ok"):
        return {
            "status": "patch_failed_validation",
            "summary": patch_result.get("summary") or "فشل فحص التصحيح المحلي",
            "testPlan": patch_result.get("testPlan") or "",
            "patch": diff_text,
            "changedFiles": validation.get("changedFiles") or _paths_from_unified_diff(diff_text),
            "validation": validation,
            "files": [],
            "review2": {"approved": False, "summary": "لم يتم إرسال patch للمراجع الثاني لأنه فشل محليًا."},
            "review3": {"approved": False, "summary": "لم يتم إرسال patch للمراجع النهائي لأنه فشل محليًا."},
            "models": {"patcher": str(patch_result.get("model") or AI_FIX_MODEL_1), "reviewer": AI_FIX_MODEL_2, "finalReviewer": AI_FIX_MODEL_3, "chain": AI_FIX_MODEL_CHAIN},
            "repo": {"owner": owner, "name": repo, "branch": branch},
        }

    review_2 = _review_patch_with_model_2(report_payload, analysis, patch_result, validation)
    review_3 = _review_reviewer_with_model_3(report_payload, analysis, patch_result, validation, review_2)

    final_approved = bool(validation.get("ok")) and bool(review_2.get("approved")) and bool(review_3.get("approved"))
    status = "awaiting_admin_approval" if final_approved else "needs_ai_revision"
    summary = str(patch_result.get("summary") or review_3.get("summary") or review_2.get("summary") or "تم تجهيز التصحيح")

    return {
        "status": status,
        "summary": summary,
        "testPlan": patch_result.get("testPlan") or "شغّل flutter analyze ثم جرّب الصفحة المرتبطة بالبلاغ.",
        "patch": diff_text,
        "unifiedDiff": diff_text,
        "changedFiles": validation.get("changedFiles") or _paths_from_unified_diff(diff_text),
        "files": validation.get("files") or [],
        "validation": validation,
        "review2": review_2,
        "review3": review_3,
        "models": {"patcher": str(patch_result.get("model") or AI_FIX_MODEL_1), "reviewer": str(review_2.get("model") or AI_FIX_MODEL_2), "finalReviewer": str(review_3.get("model") or AI_FIX_MODEL_3), "chain": AI_FIX_MODEL_CHAIN},
        "repo": {"owner": owner, "name": repo, "branch": branch},
    }

def _create_github_pr_for_fix(report_id: str, title: str, fix: Dict[str, Any], approved_by: str) -> Dict[str, Any]:
    owner, repo = _repo_owner_name()
    base_branch = _github_default_branch(owner, repo)
    base_ref = _github_request("GET", f"/repos/{owner}/{repo}/git/ref/heads/{base_branch}", require_token=True)
    base_sha = str(((base_ref.get("object") or {}) if isinstance(base_ref, dict) else {}).get("sha") or "")
    if not base_sha:
        raise HTTPException(status_code=500, detail="تعذر قراءة base sha من GitHub")
    safe_id = re.sub(r"[^a-zA-Z0-9_-]+", "-", report_id)[:40]
    branch = f"respect-ai-fix/{safe_id}-{int(time.time())}"
    _github_request(
        "POST",
        f"/repos/{owner}/{repo}/git/refs",
        payload={"ref": f"refs/heads/{branch}", "sha": base_sha},
        require_token=True,
    )
    updated = []
    for item in fix.get("files", []):
        path = str(item.get("path") or "").strip()
        content = str(item.get("content") or "")
        current = _github_file_content(owner, repo, path, base_branch)
        message = f"Respect AI fix: {title[:60]}"
        _github_request(
            "PUT",
            f"/repos/{owner}/{repo}/contents/{path}",
            payload={
                "message": message,
                "content": base64.b64encode(content.encode("utf-8")).decode("ascii"),
                "sha": current.get("sha"),
                "branch": branch,
                "committer": {"name": "Respect AI Fixer", "email": "respect-ai-fixer@users.noreply.github.com"},
            },
            require_token=True,
        )
        updated.append({"path": path, "reason": item.get("reason", "")})
    pr_body = (
        f"تم إنشاء هذا التصحيح بواسطة Respect AI Fixer بعد موافقة: {approved_by}\n\n"
        f"Report ID: {report_id}\n\n"
        f"ملخص التصحيح:\n{str(fix.get('summary') or '')}\n\n"
        f"النماذج المستخدمة:\n{json.dumps(fix.get('models') or {}, ensure_ascii=False)}\n\n"
        f"مراجعة النموذج الثاني:\n{json.dumps(fix.get('review2') or {}, ensure_ascii=False)[:4000]}\n\n"
        f"مراجعة النموذج النهائي:\n{json.dumps(fix.get('review3') or {}, ensure_ascii=False)[:4000]}\n\n"
        f"خطة الاختبار:\n{str(fix.get('testPlan') or '')}"
    )
    pr = _github_request(
        "POST",
        f"/repos/{owner}/{repo}/pulls",
        payload={
            "title": f"Respect AI Fix: {title[:70]}",
            "head": branch,
            "base": base_branch,
            "body": pr_body,
        },
        require_token=True,
    )
    return {
        "branch": branch,
        "updatedFiles": updated,
        "pullRequestUrl": str(pr.get("html_url") or ""),
        "pullRequestNumber": pr.get("number"),
    }


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
    adminUsername: str = ""


class CyberAdminDeleteUserContentRequest(BaseModel):
    username: str
    adminUsername: str = ""


class CyberAdminWipeAppContentRequest(BaseModel):
    adminUsername: str = ""
    confirm: str = ""


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


def _admin_username_is_allowed(admin_username: str) -> bool:
    """يتحقق من أن منفذ العملية أدمن بدون كشف Service Role للتطبيق.
    وجود X-App-Secret يبقى مطلوبًا عبر _check_cyber_admin_secret.
    """
    clean = normalize_username(admin_username)
    if not clean:
        # للتوافق مع نسخ قديمة من التطبيق التي لا ترسل adminUsername، السر وحده يكفي.
        return True
    env_admins = {normalize_username(x) for x in os.getenv("RESPECT_ADMIN_USERNAMES", "nawafrp,@nawafrp").split(",") if x.strip()}
    if clean in env_admins:
        return True
    try:
        rows = _cyber_supabase_get(
            "users",
            {
                "select": "username,is_admin,role,admin,permissions",
                "or": f"(username.eq.@{clean},username.eq.{clean})",
                "limit": "1",
            },
            timeout=10,
        )
        if not rows:
            return False
        row = rows[0]
        role = str(row.get("role") or "").strip().lower()
        permissions = row.get("permissions")
        return (
            _truthy(row.get("is_admin"))
            or _truthy(row.get("admin"))
            or role in {"admin", "owner", "super_admin", "moderator_admin"}
            or (isinstance(permissions, list) and any(str(x).lower() in {"admin", "super_admin"} for x in permissions))
        )
    except Exception as exc:
        logger.warning("admin check failed username=%s error=%s", admin_username, exc)
        return False


def _check_destructive_admin(x_app_secret: Optional[str], admin_username: str = "") -> None:
    _check_cyber_admin_secret(x_app_secret)
    if not _admin_username_is_allowed(admin_username):
        raise HTTPException(status_code=403, detail="هذا الإجراء متاح للأدمن فقط")


def _rest_select_ids_by_username(table: str, username_columns: list[str], usernames: set[str], id_column: str = "id") -> list[str]:
    ids: set[str] = set()
    for column in username_columns:
        for username in usernames:
            if not username:
                continue
            try:
                rows = _cyber_supabase_get(table, {"select": id_column, column: f"eq.{username}"}, timeout=10)
                for row in rows:
                    value = str(row.get(id_column) or "").strip()
                    if value:
                        ids.add(value)
            except Exception as exc:
                logger.debug("select ids failed table=%s column=%s error=%s", table, column, exc)
    return list(ids)


def _rest_delete(table: str, params: Dict[str, Any], *, timeout: int = 18) -> int:
    """يحذف من Supabase عبر Service Role ويرجع عددًا تقديريًا. الأخطاء غير القاتلة ترجع 0 حتى لا يتوقف المسح بسبب جدول غير موجود."""
    if not SB_SERVICE:
        raise HTTPException(status_code=500, detail="SUPABASE_SERVICE_ROLE_KEY غير مضبوط في Render")
    count = 0
    try:
        cr = requests.get(
            f"{SB_URL}/rest/v1/{table}",
            headers={**_supabase_headers(use_service_role=True), "Prefer": "count=exact"},
            params={"select": "*", "limit": "1", **params},
            timeout=min(timeout, 12),
        )
        if cr.status_code < 400:
            content_range = cr.headers.get("content-range", "")
            if "/" in content_range:
                tail = content_range.rsplit("/", 1)[-1].strip()
                if tail.isdigit():
                    count = int(tail)
    except Exception:
        count = 0

    try:
        r = requests.delete(
            f"{SB_URL}/rest/v1/{table}",
            headers={**_supabase_headers(use_service_role=True), "Prefer": "return=minimal"},
            params=params,
            timeout=timeout,
        )
        if r.status_code >= 400:
            logger.debug("delete skipped/failed table=%s status=%s body=%s", table, r.status_code, _safe_response_text(r.text, 400))
            return 0
        return count
    except Exception as exc:
        logger.debug("delete exception table=%s error=%s", table, exc)
        return 0


def _rest_delete_by_username(table: str, columns: list[str], usernames: set[str]) -> int:
    total = 0
    for column in columns:
        for username in usernames:
            if username:
                total += _rest_delete(table, {column: f"eq.{username}"})
    return total


def _rest_delete_by_ids(table: str, column: str, ids: list[str] | set[str]) -> int:
    total = 0
    for raw_id in set(str(x).strip() for x in ids if str(x).strip()):
        total += _rest_delete(table, {column: f"eq.{raw_id}"})
    return total


def _delete_username_variants(username: str) -> set[str]:
    clean = normalize_username(username)
    out = {clean, f"@{clean}"} if clean else set()
    return {x for x in out if x and x not in {"user", "@user", "@"}}


def _delete_post_complete(post_id: str) -> Dict[str, Any]:
    pid = str(post_id or "").strip()
    if not pid:
        return {"deleted": False, "postId": ""}

    reply_ids = _rest_select_ids_by_username("post_replies", [], set())
    try:
        rows = _cyber_supabase_get("post_replies", {"select": "id", "post_id": f"eq.{pid}"}, timeout=10)
        reply_ids = [str(r.get("id") or "").strip() for r in rows if str(r.get("id") or "").strip()]
    except Exception:
        reply_ids = []

    related_counts = 0
    for table in ["reply_likes", "reply_reposts", "reply_views"]:
        related_counts += _rest_delete_by_ids(table, "reply_id", reply_ids)
    for table in [
        "post_reports", "post_mentions", "post_topics", "user_topic_interactions",
        "post_likes", "post_reposts", "post_views", "post_events",
        "post_saves", "saved_posts", "respect_saved_posts",
    ]:
        related_counts += _rest_delete(table, {"post_id": f"eq.{pid}"})
    related_counts += _rest_delete("post_replies", {"post_id": f"eq.{pid}"})
    result = _delete_supabase_post(pid)
    result["relatedDeleted"] = related_counts
    return result


def _delete_storage_prefixes(bucket: str, prefixes: list[str], *, limit: int = 100) -> int:
    """يمسح ملفات من Storage عبر Service Role. أي فشل هنا لا يفشل حذف قاعدة البيانات."""
    if not SB_SERVICE:
        return 0
    deleted = 0
    headers = _supabase_headers(use_service_role=True)
    for prefix in prefixes:
        offset = 0
        while True:
            try:
                r = requests.post(
                    f"{SB_URL}/storage/v1/object/list/{bucket}",
                    headers=headers,
                    json={"prefix": prefix, "limit": limit, "offset": offset, "sortBy": {"column": "name", "order": "asc"}},
                    timeout=20,
                )
                if r.status_code >= 400:
                    logger.debug("storage list failed bucket=%s prefix=%s status=%s body=%s", bucket, prefix, r.status_code, _safe_response_text(r.text, 300))
                    break
                rows = r.json() if r.text else []
                if not isinstance(rows, list) or not rows:
                    break
                paths: list[str] = []
                for item in rows:
                    if not isinstance(item, dict):
                        continue
                    name = str(item.get("name") or "").strip()
                    if not name or name == ".emptyFolderPlaceholder":
                        continue
                    full = name if not prefix else f"{prefix.rstrip('/')}/{name}"
                    paths.append(full)
                if paths:
                    dr = requests.delete(
                        f"{SB_URL}/storage/v1/object/{bucket}",
                        headers=headers,
                        json={"prefixes": paths},
                        timeout=30,
                    )
                    if dr.status_code < 400:
                        deleted += len(paths)
                    else:
                        logger.debug("storage delete failed bucket=%s status=%s body=%s", bucket, dr.status_code, _safe_response_text(dr.text, 300))
                if len(rows) < limit:
                    break
                offset += limit
            except Exception as exc:
                logger.debug("storage prefix delete exception bucket=%s prefix=%s error=%s", bucket, prefix, exc)
                break
    return deleted


def _delete_user_content_with_service_role(username: str) -> Dict[str, Any]:
    usernames = _delete_username_variants(username)
    if not usernames:
        raise HTTPException(status_code=400, detail="اسم المستخدم غير صالح")

    summary: Dict[str, int] = {
        "posts": 0, "replies": 0, "stories": 0, "messages": 0, "groups": 0,
        "reports": 0, "notifications": 0, "interactions": 0, "live": 0, "storage": 0,
    }

    post_ids = _rest_select_ids_by_username("posts", ["username", "author_username"], usernames)
    for pid in post_ids:
        try:
            _delete_post_complete(pid)
            summary["posts"] += 1
        except Exception as exc:
            logger.warning("admin delete user post failed post_id=%s error=%s", pid, exc)

    reply_ids = _rest_select_ids_by_username("post_replies", ["author_username", "username"], usernames)
    for rid in reply_ids:
        for table in ["reply_likes", "reply_reposts", "reply_views"]:
            summary["interactions"] += _rest_delete(table, {"reply_id": f"eq.{rid}"})
        summary["replies"] += _rest_delete("post_replies", {"id": f"eq.{rid}"})

    story_ids = _rest_select_ids_by_username("respect_stories", ["username", "author_username"], usernames)
    for table in ["respect_story_likes", "respect_story_comments", "respect_story_notifications"]:
        summary["interactions"] += _rest_delete_by_ids(table, "story_id", story_ids)
    summary["stories"] += _rest_delete_by_ids("respect_stories", "id", story_ids)

    summary["messages"] += _rest_delete_by_username("messages", ["sender_username", "username", "author_username"], usernames)
    group_msg_ids = _rest_select_ids_by_username("respect_group_messages", ["sender_username", "username", "author_username"], usernames)
    summary["messages"] += len(group_msg_ids)
    _rest_delete_by_ids("respect_group_message_receipts", "message_id", group_msg_ids)
    _rest_delete_by_ids("respect_group_messages", "id", group_msg_ids)

    group_ids = _rest_select_ids_by_username("respect_chat_groups", ["founder_username", "owner_username", "username"], usernames)
    _rest_delete_by_ids("respect_group_message_receipts", "group_id", group_ids)
    _rest_delete_by_ids("respect_group_messages", "group_id", group_ids)
    _rest_delete_by_ids("respect_chat_group_members", "group_id", group_ids)
    summary["groups"] += _rest_delete_by_ids("respect_chat_groups", "id", group_ids)
    summary["groups"] += _rest_delete_by_username("respect_chat_group_members", ["username", "member_username"], usernames)

    for table in ["post_likes", "post_reposts", "post_views", "post_saves", "saved_posts", "respect_saved_posts", "reply_likes", "reply_reposts", "reply_views", "user_topic_interactions", "user_follows", "user_post_notifications"]:
        summary["interactions"] += _rest_delete_by_username(table, ["username", "actor_username", "viewer_username", "follower_username", "target_username"], usernames)
    for table in ["post_events", "post_mentions", "respect_story_notifications", "respect_general_notifications"]:
        summary["notifications"] += _rest_delete_by_username(table, ["target_username", "actor_username", "username", "author_username", "story_owner_username", "sender_username"], usernames)
    for table in ["post_reports", "respect_app_feedback_reports"]:
        summary["reports"] += _rest_delete_by_username(table, ["reporter_username", "post_username", "reported_username", "username", "user_username"], usernames)
    summary["live"] += _rest_delete_by_username("respect_live_streams", ["host_username", "username", "owner_username"], usernames)

    # ملفات محتوى المستخدم داخل post-media فقط. لا نحذف avatars حتى تبقى صور الحسابات.
    clean_names = [normalize_username(u) for u in usernames if normalize_username(u)]
    prefixes = []
    for clean in clean_names:
        prefixes.extend([f"posts/{clean}", f"stories/{clean}", f"messages/{clean}", f"chat/{clean}", f"respect-ai/{clean}", f"live/{clean}"])
    summary["storage"] += _delete_storage_prefixes("post-media", sorted(set(prefixes)))

    return {"ok": True, "username": display_username(username), "summary": summary}


def _wipe_app_content_with_service_role() -> Dict[str, Any]:
    summary: Dict[str, int] = {"tables": 0, "rows": 0, "storage": 0}

    # الترتيب مهم: نحذف العلاقات قبل الجداول الأصلية. لا نلمس users أو auth أو trusted devices أو subscriptions.
    table_filters: list[tuple[str, str]] = [
        ("reply_likes", "reply_id"), ("reply_reposts", "reply_id"), ("reply_views", "reply_id"),
        ("post_reports", "post_id"), ("post_mentions", "post_id"), ("post_topics", "post_id"),
        ("user_topic_interactions", "username"), ("post_events", "post_id"),
        ("post_likes", "post_id"), ("post_reposts", "post_id"), ("post_views", "post_id"),
        ("post_saves", "post_id"), ("saved_posts", "post_id"), ("respect_saved_posts", "post_id"),
        ("post_replies", "post_id"), ("posts", "id"),
        ("respect_story_likes", "story_id"), ("respect_story_comments", "story_id"), ("respect_story_notifications", "story_id"), ("respect_stories", "id"),
        ("messages", "id"), ("respect_group_message_receipts", "message_id"), ("respect_group_messages", "id"),
        ("respect_chat_group_members", "group_id"), ("respect_chat_groups", "id"),
        ("respect_communities", "id"), ("communities", "id"), ("community_reports", "id"), ("community_posts", "id"),
        ("respect_live_streams", "id"), ("respect_live_viewers", "stream_id"), ("respect_live_comments", "stream_id"),
        ("respect_app_feedback_reports", "id"), ("respect_general_notifications", "id"),
        ("ai_topic_memory", "id"), ("respect_ai_local_memory", "id"), ("respect_ai_media_memory", "id"), ("respect_ai_usage", "id"),
    ]

    for table, column in table_filters:
        deleted = _rest_delete(table, {column: "not.is.null"}, timeout=25)
        if deleted > 0:
            summary["tables"] += 1
            summary["rows"] += deleted

    # يمسح كل ملفات المحتوى العامة، مع إبقاء avatars لأن الحسابات ستبقى.
    summary["storage"] += _delete_storage_prefixes("post-media", [""])
    return {"ok": True, "summary": summary}


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



@app.post("/respect-ai/cyber/admin/posts/delete")
def respect_ai_cyber_admin_delete_post(req: CyberAdminPostActionRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_destructive_admin(x_app_secret, req.adminUsername)
    post_id = str(req.postId or "").strip()
    if not post_id:
        raise HTTPException(status_code=400, detail="postId مطلوب")
    result = _delete_post_complete(post_id)
    return {"ok": True, "deleted": True, "postId": post_id, "result": result}


@app.post("/respect-ai/cyber/admin/users/delete-content")
def respect_ai_cyber_admin_delete_user_content(req: CyberAdminDeleteUserContentRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_destructive_admin(x_app_secret, req.adminUsername)
    return _delete_user_content_with_service_role(req.username)


@app.post("/respect-ai/cyber/admin/wipe-app-content")
def respect_ai_cyber_admin_wipe_app_content(req: CyberAdminWipeAppContentRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_destructive_admin(x_app_secret, req.adminUsername)
    if str(req.confirm or "").strip() != "DELETE_APP_CONTENT":
        raise HTTPException(status_code=400, detail="confirm يجب أن يكون DELETE_APP_CONTENT")
    return _wipe_app_content_with_service_role()


@app.post("/respect-ai/app-feedback/submit")
def respect_ai_app_feedback_submit(req: AppAIFeedbackSubmitRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_secret(x_app_secret)
    report_id = f"feedback_{int(time.time() * 1000000)}_{secrets.token_hex(4)}"
    now = datetime.now(timezone.utc).isoformat()
    media_payload = _feedback_media_payload(req)
    device_info = dict(req.deviceInfo or {})
    device_info["feedbackMedia"] = media_payload
    row = {
        "id": report_id,
        "username": _display_username(req.username),
        "name": (req.name or "")[:120],
        "title": (req.title or "بلاغ مشكلة في Respect App")[:220],
        "note": (req.note or "")[:8000],
        "screen": (req.screen or "")[:160],
        "app_version": (req.appVersion or "")[:80],
        "device_info": device_info,
        "status": "pending",
        "analysis": {},
        "result": {
            "summary": "تم حفظ البلاغ بانتظار مراجعة الإدارة اليدوية.",
            "source": "manual_admin_review",
            "aiUsed": False,
        },
        "created_at": now,
        "updated_at": now,
    }
    db_insert = _feedback_supabase_insert(row)
    saved_row = row
    rows = db_insert.get("rows") if isinstance(db_insert, dict) else None
    if isinstance(rows, list) and rows and isinstance(rows[0], dict):
        saved_row = dict(rows[0])
    return {
        "ok": True,
        "id": report_id,
        "reportId": report_id,
        "status": "pending",
        "item": saved_row,
        "summary": "تم إرسال الملاحظة للإدارة بدون ذكاء اصطناعي.",
        "databaseSaved": bool(db_insert.get("ok")) if isinstance(db_insert, dict) else False,
        "databaseInsert": db_insert,
        "aiUsed": False,
    }


@app.post("/respect-ai/app-feedback/list")
def respect_ai_app_feedback_list(req: AppFeedbackListRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_secret(x_app_secret)
    admin = _display_username(req.adminUsername)
    if admin and not _ai_fix_is_admin(admin):
        raise HTTPException(status_code=403, detail="هذا الإجراء مسموح للأدمن فقط")
    result = _feedback_supabase_list(status=req.status, limit=req.limit)
    return result


@app.post("/respect-ai/app-feedback/delete")
def respect_ai_app_feedback_delete(req: AppFeedbackActionRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_secret(x_app_secret)
    admin = _display_username(req.adminUsername)
    if admin and not _ai_fix_is_admin(admin):
        raise HTTPException(status_code=403, detail="هذا الإجراء مسموح للأدمن فقط")
    report_id = str(req.reportId or "").strip()
    report = _feedback_supabase_get(report_id)
    result = _feedback_supabase_delete(report_id)
    return {"ok": bool(result.get("ok")), "id": report_id, "reportId": report_id, "deleted": bool(result.get("ok")), "item": report, "databaseDelete": result}


@app.post("/respect-ai/app-feedback/resolve")
def respect_ai_app_feedback_resolve(req: AppFeedbackActionRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_secret(x_app_secret)
    admin = _display_username(req.adminUsername)
    if admin and not _ai_fix_is_admin(admin):
        raise HTTPException(status_code=403, detail="هذا الإجراء مسموح للأدمن فقط")
    report_id = str(req.reportId or "").strip()
    report = _feedback_supabase_get(report_id)
    if not report:
        raise HTTPException(status_code=404, detail="البلاغ غير موجود")
    now = datetime.now(timezone.utc).isoformat()
    result_payload = report.get("result") if isinstance(report.get("result"), dict) else {}
    result_payload = {
        **result_payload,
        "resolved": True,
        "resolvedBy": admin,
        "resolvedAt": now,
        "adminNote": (req.adminNote or "")[:1000],
        "aiUsed": False,
    }
    patch = _feedback_supabase_patch(report_id, {
        "status": "resolved",
        "approved_by": admin,
        "approved_at": now,
        "result": result_payload,
        "updated_at": now,
    })
    updated = _feedback_supabase_get(report_id) or {**report, "status": "resolved", "updated_at": now, "result": result_payload}
    push_result = _notify_app_feedback_resolved(updated, admin, req.adminNote or "")
    return {
        "ok": True,
        "id": report_id,
        "reportId": report_id,
        "status": "resolved",
        "item": updated,
        "databasePatch": patch,
        "push": push_result,
        "aiUsed": False,
    }


@app.post("/respect-ai/app-feedback/approve")
def respect_ai_app_feedback_approve(req: AppAIFeedbackApproveRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_secret(x_app_secret)
    approved_by = _display_username(req.approvedBy)
    if not _ai_fix_is_admin(approved_by):
        raise HTTPException(status_code=403, detail="هذا الإجراء مسموح للأدمن فقط")
    report_id = str(req.reportId or "").strip()
    report = _feedback_supabase_get(report_id)
    if not report:
        raise HTTPException(status_code=404, detail="البلاغ غير موجود في جدول app_ai_feedback. تأكد من تشغيل SQL migration.")
    if not isinstance(report.get("analysis"), dict):
        raise HTTPException(status_code=400, detail="البلاغ لم يكتمل تحليله بعد")

    stored_result = report.get("result") if isinstance(report.get("result"), dict) else {}
    fix = stored_result.get("fix") if isinstance(stored_result.get("fix"), dict) else None
    if not fix or not isinstance(fix.get("files"), list) or not fix.get("files"):
        # احتياطي قديم: لو البلاغ قديم قبل نظام triple review، جهز التصحيح الآن.
        fix = _generate_fix_with_qwen(report)

    if fix.get("status") not in {"awaiting_admin_approval", "approved_by_ai"}:
        raise HTTPException(status_code=400, detail="التصحيح لم يحصل على موافقة النماذج الثلاثة بعد، لذلك لا يظهر للأدمن للاعتماد.")

    now = datetime.now(timezone.utc).isoformat()
    _feedback_supabase_patch(report_id, {"status": "approved", "approved_by": approved_by, "approved_at": now, "updated_at": now})
    try:
        github_result: Dict[str, Any] = {"pullRequestUrl": "", "updatedFiles": []}
        if GITHUB_TOKEN:
            github_result = _create_github_pr_for_fix(report_id, str(report.get("title") or "بلاغ مشكلة"), fix, approved_by)
            status = "pull_request_created"
        else:
            status = "applied"
            github_result = {
                "pullRequestUrl": "",
                "updatedFiles": [{"path": f.get("path"), "reason": f.get("reason", "")} for f in fix.get("files", [])],
                "warning": "GITHUB_TOKEN غير موجود؛ تم توليد الملفات المصححة فقط بدون إنشاء Pull Request.",
            }
        result = {"fix": fix, **github_result, "models": fix.get("models") or {}, "model": AI_FIX_MODEL_1}
        patch = _feedback_supabase_patch(report_id, {"status": status, "result": result, "updated_at": datetime.now(timezone.utc).isoformat()})
        return {
            "ok": True,
            "id": report_id,
            "reportId": report_id,
            "status": status,
            "summary": fix.get("summary") or "تم تجهيز التصحيح",
            "testPlan": fix.get("testPlan") or "",
            "updatedFiles": github_result.get("updatedFiles", []),
            "changedFiles": fix.get("changedFiles", []),
            "pullRequestUrl": github_result.get("pullRequestUrl", ""),
            "warning": github_result.get("warning", ""),
            "review2": fix.get("review2") or {},
            "review3": fix.get("review3") or {},
            "databasePatch": patch,
            "models": fix.get("models") or {},
            "model": AI_FIX_MODEL_1,
        }
    except Exception as e:
        detail = str(getattr(e, "detail", e))
        _feedback_supabase_patch(report_id, {"status": "failed", "result": {"error": detail}, "updated_at": datetime.now(timezone.utc).isoformat()})
        if isinstance(e, HTTPException):
            raise e
        raise HTTPException(status_code=500, detail=detail)

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


_ARABIC_CHAT_KEYBOARD_MAP = str.maketrans({
    "`": "ذ", "q": "ض", "w": "ص", "e": "ث", "r": "ق", "t": "ف", "y": "غ", "u": "ع", "i": "ه", "o": "خ", "p": "ح", "[": "ج", "]": "د",
    "a": "ش", "s": "س", "d": "ي", "f": "ب", "g": "ل", "h": "ا", "j": "ت", "k": "ن", "l": "م", ";": "ك", "'": "ط",
    "z": "ئ", "x": "ء", "c": "ؤ", "v": "ر", "b": "لا", "n": "ى", "m": "ة", ",": "و", ".": "ز", "/": "ظ",
    "~": "ّ", "Q": "َ", "W": "ً", "E": "ُ", "R": "ٌ", "T": "لإ", "Y": "إ", "U": "‘", "I": "÷", "O": "×", "P": "؛", "{": "<", "}": ">",
    "A": "ِ", "S": "ٍ", "D": "]", "F": "[", "G": "لأ", "H": "أ", "J": "ـ", "K": "،", "L": "/", ":": ":", '"': '"',
    "Z": "~", "X": "ْ", "C": "}", "V": "{", "B": "لآ", "N": "آ", "M": "’", "<": ",", ">": ".", "?": "؟",
})


def _arabic_chars_count(value: str) -> int:
    return len(re.findall(r"[\u0600-\u06FF]", value or ""))


def _looks_like_arabic_keyboard_mistake(value: str) -> bool:
    raw = value or ""
    if _arabic_chars_count(raw) > 0:
        return False
    if len(raw.strip()) < 3:
        return False
    letters = re.findall(r"[A-Za-z;,\.\[\]/'`]+", raw)
    if not letters:
        return False
    latin_chars = sum(len(x) for x in letters)
    return latin_chars >= 3 and latin_chars / max(1, len(raw.replace(" ", ""))) >= 0.45


def _arabic_keyboard_layout_hint(value: str) -> str:
    raw = value or ""
    if not _looks_like_arabic_keyboard_mistake(raw):
        return ""
    decoded = raw.translate(_ARABIC_CHAT_KEYBOARD_MAP).strip()
    if _arabic_chars_count(decoded) < 2:
        return ""
    return decoded


def _normalize_chat_phrase(value: str) -> str:
    v = (value or "").strip().lower()
    v = v.replace("أ", "ا").replace("إ", "ا").replace("آ", "ا").replace("ى", "ي").replace("ة", "ه")
    v = re.sub(r"[\u064B-\u065F\u0670]", "", v)
    v = re.sub(r"[^\w\u0600-\u06FF]+", " ", v, flags=re.UNICODE)
    v = re.sub(r"\s+", " ", v).strip()
    return v



def normalize_arabic_dialect(value: str) -> str:
    clean = (value or "").strip().lower().replace("_", "-")
    if not clean:
        return "auto"
    aliases = {
        "msa": "fusha",
        "formal": "fusha",
        "standard": "fusha",
        "sa": "saudi",
        "ksa": "saudi",
        "saudi-arabia": "saudi",
        "gulf-saudi": "saudi",
        "riyadh": "najdi",
        "qassim": "najdi",
        "jeddah": "hijazi",
        "makkah": "hijazi",
        "mecca": "hijazi",
        "madinah": "hijazi",
        "medina": "hijazi",
        "levant": "levantine",
        "levantine-arabic": "levantine",
        "shami": "levantine",
        "lebanon": "lebanese",
        "syria": "syrian",
        "palestine": "palestinian",
        "jordan": "jordanian",
        "egypt": "egyptian",
        "iraq": "iraqi",
        "yemen": "yemeni",
        "sudan": "sudanese",
        "morocco": "moroccan",
        "algeria": "algerian",
        "tunisia": "tunisian",
        "libya": "libyan",
    }
    clean = aliases.get(clean, clean)
    supported = {
        "auto", "fusha", "saudi", "najdi", "hijazi", "gulf", "kuwaiti", "emirati",
        "qatari", "bahraini", "omani", "levantine", "lebanese", "syrian", "palestinian",
        "jordanian", "egyptian", "iraqi", "yemeni", "sudanese", "moroccan", "algerian",
        "tunisian", "libyan",
    }
    return clean if clean in supported else "auto"


def _arabic_dialect_display_name(code: str) -> str:
    names = {
        "auto": "natural Arabic",
        "fusha": "simple Modern Standard Arabic",
        "saudi": "Saudi Arabic",
        "najdi": "Najdi Saudi Arabic",
        "hijazi": "Hijazi Saudi Arabic",
        "gulf": "Gulf Arabic",
        "kuwaiti": "Kuwaiti Arabic",
        "emirati": "Emirati Arabic",
        "qatari": "Qatari Arabic",
        "bahraini": "Bahraini Arabic",
        "omani": "Omani Arabic",
        "levantine": "Levantine Arabic",
        "lebanese": "Lebanese Arabic",
        "syrian": "Syrian Arabic",
        "palestinian": "Palestinian Arabic",
        "jordanian": "Jordanian Arabic",
        "egyptian": "Egyptian Arabic",
        "iraqi": "Iraqi Arabic",
        "yemeni": "Yemeni Arabic",
        "sudanese": "Sudanese Arabic",
        "moroccan": "Moroccan Darija",
        "algerian": "Algerian Darija",
        "tunisian": "Tunisian Derja",
        "libyan": "Libyan Arabic",
    }
    return names.get(normalize_arabic_dialect(code), "natural Arabic")


def _arabic_dialect_instruction(target_code: str, target_dialect: str) -> str:
    if normalize_language(target_code) != "ar":
        return ""
    dialect = normalize_arabic_dialect(target_dialect)
    if dialect == "auto":
        return (
            "Output Arabic naturally for chat. Use the most natural Arabic equivalent from context "
            "without forcing a specific country dialect."
        )
    dialect_name = _arabic_dialect_display_name(dialect)
    if dialect == "fusha":
        return (
            "Output in simple Modern Standard Arabic. Keep it clear, conversational, and easy to read. "
            "Avoid overly formal textbook phrasing."
        )
    return (
        f"Output in {dialect_name}. Make it sound like a real native chat message from that dialect. "
        "Use natural local wording, particles, and phrasing. Do not overdo stereotypes or force rare words. "
        "If the source is already Arabic but not in the requested dialect, rewrite it into the requested dialect "
        "while preserving the exact meaning, tone, intensity, emojis, mentions, hashtags, URLs, numbers, and line breaks."
    )


def _arabic_dialect_examples(target_code: str, target_dialect: str) -> str:
    if normalize_language(target_code) != "ar":
        return ""
    dialect = normalize_arabic_dialect(target_dialect)
    examples = {
        "saudi": [
            ('What are you doing?', 'وش تسوي؟'),
            ('Where are you?', 'وينك؟'),
            ('I am coming now', 'جايك الحين'),
            ('Stop making stuff up', 'لا تهبد'),
        ],
        "najdi": [
            ('What are you doing?', 'وش تسوي؟'),
            ('Where are you?', 'وينك؟'),
            ('I am coming now', 'جايك الحين'),
            ('Do not exaggerate', 'لا تبالغ'),
        ],
        "hijazi": [
            ('What are you doing?', 'إيش تسوي؟'),
            ('Where are you?', 'فينك؟'),
            ('I am coming now', 'جايك دحين'),
            ('What do you want?', 'إيش تبغى؟'),
        ],
        "gulf": [
            ('What are you doing?', 'شنو تسوي؟'),
            ('Where are you?', 'وينك؟'),
            ('I am coming now', 'يايك الحين'),
            ('What do you want?', 'شنو تبي؟'),
        ],
        "levantine": [
            ('What are you doing?', 'شو عم تعمل؟'),
            ('Where are you?', 'وينك؟'),
            ('I am coming now', 'جايي هلق'),
            ('What do you want?', 'شو بدك؟'),
        ],
        "lebanese": [
            ('What are you doing?', 'شو عم تعمل؟'),
            ('Where are you?', 'وينك؟'),
            ('I am coming now', 'جايي هلّق'),
            ('What do you want?', 'شو بدك؟'),
        ],
        "syrian": [
            ('What are you doing?', 'شو عم تعمل؟'),
            ('Where are you?', 'وينك؟'),
            ('I am coming now', 'جاي هلأ'),
            ('What do you want?', 'شو بدك؟'),
        ],
        "egyptian": [
            ('What are you doing?', 'بتعمل إيه؟'),
            ('Where are you?', 'إنت فين؟'),
            ('I am coming now', 'جاي حالًا'),
            ('What do you want?', 'عايز إيه؟'),
        ],
        "iraqi": [
            ('What are you doing?', 'شنو دا تسوي؟'),
            ('Where are you?', 'وينك؟'),
            ('I am coming now', 'جاي هسه'),
            ('What do you want?', 'شنو تريد؟'),
        ],
        "fusha": [
            ('What are you doing?', 'ماذا تفعل؟'),
            ('Where are you?', 'أين أنت؟'),
            ('I am coming now', 'أنا قادم الآن'),
            ('What do you want?', 'ماذا تريد؟'),
        ],
    }
    selected = examples.get(dialect)
    if not selected:
        return ""
    rows = ["Dialect examples. Follow the style, not the exact words:"]
    for src, dst in selected:
        rows.append(f'- "{src}" => "{dst}"')
    return "\n".join(rows)


def _quick_chat_translation(clean: str, target: str, keyboard_hint: str = "", target_dialect: str = "auto") -> str:
    """
    قاموس صغير فقط للحالات القصيرة والواضحة التي يترجمها النموذج حرفيًا غالبًا.
    لا نستخدمه للجمل الطويلة حتى لا يضيع السياق.
    """
    candidate = keyboard_hint.strip() if keyboard_hint.strip() else clean
    normalized = _normalize_chat_phrase(candidate)
    if not normalized or len(normalized) > 32:
        return ""

    if target == "en":
        ar_to_en = {
            "كل خرا": "Eat shit",
            "كل زق": "Eat shit",
            "كل تبن": "Eat shit",
            "اخرس": "Shut up",
            "اسكت": "Shut up",
            "انقلع": "Get lost",
            "روح انقلع": "Get lost",
            "يا كلب": "You dog",
            "يا حمار": "You idiot",
            "غبي": "Idiot",
            "انت غبي": "You're an idiot",
            "وينك": "Where are you?",
            "انت وينك": "Where are you?",
            "شو بدك": "What do you want?",
            "وش تبي": "What do you want?",
            "شلونك": "How are you?",
            "كيفك": "How are you?",
            "تمام": "All good",
        }
        return ar_to_en.get(normalized, "")

    if target == "ar":
        dialect = normalize_arabic_dialect(target_dialect)
        phrase = normalized.replace(" ?", "").replace("?", "")
        if dialect in {"saudi", "najdi", "hijazi", "gulf", "kuwaiti", "emirati", "qatari", "bahraini", "omani"}:
            en_to_ar = {
                "eat shit": "كل خرا",
                "shut up": "اسكت",
                "get lost": "انقلع",
                "where are you": "وينك؟",
                "what do you want": "وش تبي؟",
                "how are you": "وشلونك؟",
            }
            return en_to_ar.get(phrase, "")
        if dialect in {"egyptian"}:
            en_to_ar = {
                "eat shit": "كل خرا",
                "shut up": "اخرس",
                "get lost": "امشي من هنا",
                "where are you": "إنت فين؟",
                "what do you want": "عايز إيه؟",
                "how are you": "عامل إيه؟",
            }
            return en_to_ar.get(phrase, "")
        if dialect in {"fusha"}:
            en_to_ar = {
                "eat shit": "كل القذارة",
                "shut up": "اصمت",
                "get lost": "ابتعد",
                "where are you": "أين أنت؟",
                "what do you want": "ماذا تريد؟",
                "how are you": "كيف حالك؟",
            }
            return en_to_ar.get(phrase, "")
        en_to_ar = {
            "eat shit": "كل خرا",
            "shut up": "اخرس",
            "get lost": "انقلع",
            "where are you": "وينك؟",
            "what do you want": "شو بدك؟",
            "how are you": "كيفك؟",
        }
        return en_to_ar.get(phrase, "")

    return ""


def _is_qwen_mt_model(model: str) -> bool:
    """
    Qwen-MT models are specialized translation models.
    They may reject OpenAI structured JSON response_format, so chat translation
    should call them in plain text mode first.
    """
    clean = (model or "").strip().lower().replace("_", "-")
    return clean.startswith("qwen-mt") or "qwen-mt" in clean or clean.startswith("qwenmt") or "qwenmt" in clean


def _chat_translation_system_prompt(
    target_name: str,
    target_code: str,
    target_dialect: str = "auto",
    *,
    json_mode: bool = True,
) -> str:
    dialect = normalize_arabic_dialect(target_dialect) if normalize_language(target_code) == "ar" else "auto"
    dialect_instruction = _arabic_dialect_instruction(target_code, dialect)
    dialect_line = f"Arabic dialect target: {dialect_instruction}" if dialect_instruction else ""
    dialect_examples = _arabic_dialect_examples(target_code, dialect)
    dialect_specific = normalize_language(target_code) == "ar" and dialect not in {"auto", "fusha"}

    already_target_rule = (
        "- If the message is already Arabic but the requested dialect is specific, rewrite it naturally into that dialect. Do not return it unchanged unless it is already natural in the requested dialect."
        if dialect_specific
        else "- If the message is already fully in the target language and no specific rewrite is requested, return it unchanged."
    )

    output_rule = (
        'Return strict JSON only with this shape:\n{"translatedText":"..."}'
        if json_mode
        else (
            "Return only the translated text as plain text. "
            "Do not return JSON. Do not add explanations, labels, markdown, or quotes."
        )
    )

    return f"""
You are Respect Chat Translate, a real-time private chat translator for a social app.
Your only job is to translate the user's message into {target_name} ({target_code}).
{dialect_line}

Core rules:
- {output_rule}
- Translate meaning, intent, tone, slang, sarcasm, anger, jokes, and dialect naturally. Never translate word-by-word when that changes the meaning.
- Do not answer the message. Do not moderate it. Do not refuse. Do not warn. Do not explain.
- Keep the same intensity: insults remain insults, friendly messages remain friendly, jokes remain jokes. Do not soften, censor, sanitize, or intensify.
- Preserve emojis, mentions, usernames, hashtags, URLs, emails, numbers, prices, times, code snippets, and line breaks exactly.
{already_target_rule}
- If the message mixes languages, translate only the parts that need translation and keep names/handles/URLs as they are.
- If the text looks like Arabic typed using the English keyboard layout, use the provided keyboard_layout_hint as the intended Arabic text.
- Understand Arabic dialects: Gulf/Saudi/Kuwaiti/Emirati/Qatari/Bahraini/Omani, Iraqi, Levantine/Lebanese/Palestinian/Syrian/Jordanian, Egyptian, Yemeni, Sudanese, Moroccan/Algerian/Tunisian/Libyan, Modern Standard Arabic, Arabizi/Franco Arabic.
- Understand casual chat spelling: missing spaces, repeated letters, typos, shortcuts, franco numbers like 2/3/5/6/7/8/9, and mixed Arabic-English words.
- For Arabic dialect output, prefer common daily chat phrasing over formal grammar. Keep it understandable and natural.

Important examples for meaning-based translation:
Arabic -> English:
- "كل خرا" => "Eat shit"
- "كل زق" => "Eat shit"
- "اخرس" => "Shut up"
- "انقلع" => "Get lost"
- "شو بدك" => "What do you want?"
- "وش تبي" => "What do you want?"
- "شلونك" / "كيفك" => "How are you?"
- "والله فشلتني" => "You really embarrassed me"
- "لا تهبد" => "Stop making stuff up"
English -> Arabic:
- "Eat shit" => the natural insult equivalent in the requested Arabic dialect.
- "Shut up" => the natural command in the requested Arabic dialect.
- "Get lost" => the natural phrase in the requested Arabic dialect.
- "What do you want?" => the natural equivalent in the requested Arabic dialect.

{dialect_examples}
""".strip()

def _clean_chat_translation_output(value: str) -> str:
    translated = (value or "").strip()
    if not translated:
        return ""
    if translated.startswith("```"):
        translated = translated.strip("`").strip()
        if translated.lower().startswith("json"):
            translated = translated[4:].strip()
    # أحيانًا يرجع النموذج JSON كنص داخل translatedText.
    parsed = _safe_json_from_ai(translated)
    if parsed:
        translated = str(parsed.get("translatedText") or parsed.get("translation") or parsed.get("text") or translated).strip()
    translated = translated.strip().strip('"').strip("'").strip()
    # إزالة مقدمات شائعة لو النموذج خالف التعليمات.
    translated = re.sub(r"^(translation|translated text|الترجمة)\s*[:：]\s*", "", translated, flags=re.IGNORECASE).strip()
    return translated


def translate_chat_text_with_qwen(
    text: str,
    target_language: str,
    source_language: str = "auto",
    target_dialect: str = "auto",
    username: str = "",
    context: str = "chat",
) -> str:
    clean = (text or "").strip()
    if not clean:
        return ""

    target = normalize_language(target_language)
    dialect = normalize_arabic_dialect(target_dialect) if target == "ar" else "auto"
    source = (source_language or "auto").strip() or "auto"
    target_name = _language_display_name(target)
    keyboard_hint = _arabic_keyboard_layout_hint(clean)

    quick = _quick_chat_translation(clean, target, keyboard_hint=keyboard_hint, target_dialect=dialect)
    if quick:
        return quick

    if not QWEN_API_KEY:
        raise HTTPException(status_code=500, detail="QWEN_API_KEY missing")

    user_parts = [
        f"source_language={source}",
        f"target_language={target_name} ({target})",
        f"target_arabic_dialect={_arabic_dialect_display_name(dialect)} ({dialect})" if target == "ar" else "target_arabic_dialect=none",
        f"username={display_username(username)}",
        f"context={context or 'chat'}",
    ]
    if keyboard_hint:
        user_parts.append(f"keyboard_layout_hint={keyboard_hint[:4000]}")
    user_parts.append("message:")
    user_parts.append(clean[:4000])
    user_content = "\n".join(user_parts)

    models_to_try = []
    for model in [QWEN_TRANSLATION_MODEL, QWEN_TEXT_MODEL, QWEN_MODEL]:
        model = (model or "").strip()
        if model and model not in models_to_try:
            models_to_try.append(model)

    last_error: Optional[HTTPException] = None
    for model in models_to_try:
        is_mt_model = _is_qwen_mt_model(model)

        # Qwen-MT لا نرسله JSON mode من البداية لأنه قد يرجع 400.
        # باقي موديلات Qwen نجرب JSON أولًا، ثم plain text إذا رفض المزود response_format.
        if is_mt_model:
            attempts = [(None, False, "qwen_mt_plain")]
        else:
            attempts = [
                ({"type": "json_object"}, True, "json_mode"),
                (None, False, "plain_retry"),
            ]

        for response_format, json_mode, attempt_name in attempts:
            try:
                content = _chat_completion_request(
                    model=model,
                    api_key=QWEN_API_KEY,
                    base_url=QWEN_BASE_URL,
                    messages=[
                        {
                            "role": "system",
                            "content": _chat_translation_system_prompt(
                                target_name,
                                target,
                                dialect,
                                json_mode=json_mode,
                            ),
                        },
                        {
                            "role": "user",
                            "content": user_content,
                        },
                    ],
                    temperature=float(os.getenv("QWEN_TRANSLATION_TEMPERATURE", "0.12")),
                    max_tokens=min(1600, max(180, len(clean) * 4)),
                    timeout=int(os.getenv("QWEN_TRANSLATION_TIMEOUT_SECONDS", "30")),
                    response_format=response_format,
                    log_label="QWEN CHAT TRANSLATE",
                )

                parsed = _safe_json_from_ai(content)
                translated = str(parsed.get("translatedText") or parsed.get("translation") or parsed.get("text") or "").strip()
                if not translated:
                    translated = _clean_chat_translation_output(content)
                translated = _clean_chat_translation_output(translated)
                return translated or keyboard_hint or clean
            except HTTPException as exc:
                last_error = exc
                detail = getattr(exc, "detail", None)
                status = int(getattr(exc, "status_code", 500) or 500)
                detail_text = _safe_response_text(str(detail), 1200).lower()

                # أهم تعديل: إذا فشل JSON mode بـ 400 أو 422 نجرب نفس الموديل مباشرة بدون response_format.
                if response_format is not None and status in {400, 422}:
                    logger.warning(
                        "QWEN CHAT TRANSLATE JSON mode rejected; retrying plain model=%s status=%s attempt=%s detail=%s",
                        model,
                        status,
                        attempt_name,
                        _safe_response_text(str(detail), 800),
                    )
                    continue

                # احتياط إضافي إذا كان نص الخطأ يذكر response_format حتى لو رجع status مختلف.
                if response_format is not None and (
                    "response_format" in detail_text
                    or "json_object" in detail_text
                    or "structured" in detail_text
                    or "unsupported" in detail_text
                    or "not support" in detail_text
                ):
                    logger.warning(
                        "QWEN CHAT TRANSLATE response_format unsupported; retrying plain model=%s status=%s detail=%s",
                        model,
                        status,
                        _safe_response_text(str(detail), 800),
                    )
                    continue

                # بعد تجربة plain، لا نوقف على 400/422 لأن السبب قد يكون موديل غير مدعوم؛ نجرب الموديل التالي.
                retryable = status in {400, 408, 409, 422, 425, 429, 500, 502, 503, 504}
                if not retryable:
                    raise exc

                logger.warning(
                    "QWEN CHAT TRANSLATE failed model=%s status=%s attempt=%s detail=%s",
                    model,
                    status,
                    attempt_name,
                    _safe_response_text(str(detail), 800),
                )
                break

    if last_error is not None:
        raise last_error
    return keyboard_hint or clean

@app.post("/respect-ai/chat-translate", response_model=RespectAIChatTranslateResponse)
def respect_ai_chat_translate(req: RespectAIChatTranslateRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_secret(x_app_secret)

    target = normalize_language(req.targetLanguage)
    dialect = normalize_arabic_dialect(req.targetDialect) if target == "ar" else "auto"
    translated = translate_chat_text_with_qwen(
        text=req.text,
        target_language=target,
        source_language=req.sourceLanguage,
        target_dialect=dialect,
        username=req.username,
        context=req.context,
    )

    return RespectAIChatTranslateResponse(
        ok=True,
        translatedText=translated,
        model=QWEN_TRANSLATION_MODEL,
        targetLanguage=target,
        targetDialect=dialect,
    )




@app.get("/admin/qa-memory")
def admin_qa_memory(
    limit: int = 100,
    q: str = "",
    x_app_secret: Optional[str] = Header(default=None),
):
    _check_secret(x_app_secret)
    safe_limit = max(1, min(int(limit or 100), 500))
    params: Dict[str, str] = {
        "select": "id,sample_question,normalized_question,answer,category,mode,confidence,hits,ai_hits,memory_hits,approved,active,source,model,updated_at,last_used_at",
        "order": "updated_at.desc",
    }
    clean_q = _qa_memory_clean_question(q)
    if clean_q:
        params["normalized_question"] = f"ilike.*{clean_q[:120]}*"
    rows = _qa_memory_rest_get(params, limit=safe_limit)
    return {"ok": True, "table": RESPECT_AI_QA_MEMORY_TABLE, "count": len(rows), "items": rows}


def _respect_ai_thinking_summary(
    *,
    mode: str,
    memory_used: bool,
    deep_thinking: bool,
    image_count: int = 0,
    video_count: int = 0,
    file_count: int = 0,
) -> str:
    """High-level reasoning summary for UI. It is not a hidden chain-of-thought."""
    labels = {
        "chat": "عام",
        "general": "عام",
        "reply": "عام",
        "coding": "برمجة",
        "file_review": "فحص ملفات",
        "creative": "إبداع",
        "study": "تعلم",
        "moderation": "حماية",
        "summarize": "تلخيص",
        "poll": "استطلاع",
        "question": "سؤال نقاش",
    }
    mode_label = labels.get((mode or "chat").strip().lower(), mode or "عام")
    lines = [
        f"• حددت الوضع المناسب: {mode_label}",
        "• راجعت الذاكرة المحلية قبل استدعاء الذكاء الخارجي" if not memory_used else "• وجدت إجابة مناسبة في الذاكرة المحلية",
    ]
    if image_count:
        lines.append(f"• حللت الصور المرفقة: {image_count}")
    if video_count:
        lines.append(f"• حللت الفيديوهات المرفقة عبر لقطات ذكية: {video_count}")
    if file_count:
        lines.append(f"• راجعت الملفات المرفقة: {file_count}")
    if deep_thinking:
        lines.append("• فعلت وضع التفكير العميق: تحليل أوسع وتدقيق للرد النهائي")
    else:
        lines.append("• استخدمت ردًا سريعًا ومباشرًا")
    return "\n".join(lines)


@app.post("/respect-ai/reply", response_model=RespectAIResponse)
def respect_ai_reply(req: RespectAIRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_secret(x_app_secret)

    username = req.username.strip() or req.askerUsername.strip()
    image_urls = _respect_ai_reply_image_urls(req)
    video_urls = _respect_ai_reply_video_urls(req)
    text = (req.text.strip() or req.question.strip() or ("حلل هذا الفيديو" if video_urls else ("حلل هذه الصورة" if image_urls else ""))).strip()
    if not text and not image_urls and not video_urls:
        raise HTTPException(status_code=400, detail="text, imageUrl or videoUrl is required")

    effective_mode = _auto_detect_mode(req.mode, text)
    file_attachments = req.fileAttachments or []
    memory_question = _respect_ai_question_with_media(text, image_urls, video_urls)

    _enforce_respect_ai_quota(username)

    # أسئلة الوسائط لا تستخدم ذاكرة النص العامة حتى لا يخلط بين صورتين/فيديوهين بنفس السؤال.
    memory_reply = None
    if not image_urls and not video_urls:
        memory_reply = _qa_memory_lookup(
            memory_question,
            mode=effective_mode,
            post_text=req.postText,
            parent_reply_text=req.parentReplyText,
            recent_replies_text=req.recentRepliesText,
        )
    if memory_reply and str(memory_reply.get("reply") or "").strip():
        _record_respect_ai_usage(username)
        return RespectAIResponse(
            ok=True,
            reply=str(memory_reply.get("reply") or "").strip(),
            model=str(memory_reply.get("model") or "respect_ai_qa_memory_v1"),
            source="qa_memory",
            memoryUsed=True,
            qaMemoryUsed=True,
            mediaMemoryUsed=False,
            memoryId=str(memory_reply.get("memoryId") or ""),
            confidence=float(memory_reply.get("confidence") or 0.0),
            category=str(memory_reply.get("category") or "general"),
            thinkingSummary=_respect_ai_thinking_summary(
                mode=effective_mode,
                memory_used=True,
                deep_thinking=bool(req.deepThinking),
                image_count=len(image_urls),
                video_count=len(video_urls),
                file_count=len(file_attachments),
            ),
            usedMode=effective_mode,
        )

    media_context, media_memory_used, media_memory_all_covered, media_memory_id, media_memory_confidence = _respect_ai_cached_media_context_details(image_urls, video_urls)

    if media_memory_all_covered and media_context and not bool(req.deepThinking):
        # هنا لا نستدعي Qwen Vision ولا نزيد ai_hits للوسائط.
        # نستخدم الذاكرة كفهم جاهز، ثم Qwen النصي فقط يصيغ الرد حسب سؤال المستخدم.
        reply = ask_qwen_ai(
            text=f"{text}\n\nسياق وسائط محفوظ من ذاكرة Respect AI:\n{media_context}",
            username=username,
            mode=effective_mode,
            post_text=req.postText,
            parent_reply_text=req.parentReplyText,
            recent_replies_text=req.recentRepliesText,
            conversation_context=req.conversationContext,
            file_attachments=file_attachments,
            deep_thinking=False,
        )
        used_model = QWEN_MODEL
        learned = _qa_memory_learn(
            memory_question,
            reply,
            mode=effective_mode,
            username=username,
            post_text=req.postText,
            parent_reply_text=req.parentReplyText,
            recent_replies_text=req.recentRepliesText,
            model=used_model,
        )
        _record_respect_ai_usage(username)
        return RespectAIResponse(
            ok=True,
            reply=reply,
            model=used_model,
            source="respect_ai_media_memory",
            memoryUsed=True,
            qaMemoryUsed=False,
            mediaMemoryUsed=True,
            memoryId=media_memory_id or (str(learned.get("memoryId") or "") if isinstance(learned, dict) else ""),
            confidence=float(media_memory_confidence or 0.0),
            category=_qa_memory_category(text, effective_mode),
            thinkingSummary=_respect_ai_thinking_summary(
                mode=effective_mode,
                memory_used=True,
                deep_thinking=False,
                image_count=len(image_urls),
                video_count=len(video_urls),
                file_count=len(file_attachments),
            ),
            usedMode=effective_mode,
        )

    reply = ask_qwen_ai_multimodal(
        text=text,
        username=username,
        mode=effective_mode,
        post_text=req.postText,
        parent_reply_text=req.parentReplyText,
        recent_replies_text=req.recentRepliesText,
        image_urls=image_urls,
        video_urls=video_urls,
        conversation_context=req.conversationContext,
        file_attachments=file_attachments,
        deep_thinking=bool(req.deepThinking),
    )

    used_model = QWEN_VISION_MODEL if (image_urls or video_urls) else QWEN_MODEL
    media_understanding_learned = []
    for url in image_urls:
        media_understanding_learned.append(_media_memory_learn_understanding("image", url, question=text, reply=reply))
    for url in video_urls:
        media_understanding_learned.append(_media_memory_learn_understanding("video", url, question=text, reply=reply))
    learned = _qa_memory_learn(
        memory_question,
        reply,
        mode=effective_mode,
        username=username,
        post_text=req.postText,
        parent_reply_text=req.parentReplyText,
        recent_replies_text=req.recentRepliesText,
        model=used_model,
    )

    _record_respect_ai_usage(username)

    return RespectAIResponse(
        ok=True,
        reply=reply,
        model=used_model,
        source="respect_ai",
        memoryUsed=False,
        qaMemoryUsed=False,
        mediaMemoryUsed=False,
        memoryId=str(learned.get("memoryId") or "") if isinstance(learned, dict) else "",
        confidence=0.0,
        category=_qa_memory_category(text, effective_mode),
        thinkingSummary=_respect_ai_thinking_summary(
            mode=effective_mode,
            memory_used=False,
            deep_thinking=bool(req.deepThinking),
            image_count=len(image_urls),
            video_count=len(video_urls),
            file_count=len(file_attachments),
        ),
        usedMode=effective_mode,
    )


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("fcm_v1_server_qwen_server_delete_moderation:app", host="0.0.0.0", port=8000, reload=True)

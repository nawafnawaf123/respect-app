import base64
import json
import logging
import os
import re
import smtplib
import hashlib
import hmac
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

# ================= Auth OTP Email =================
SMTP_HOST = os.getenv("SMTP_HOST", "").strip()
SMTP_PORT = int(os.getenv("SMTP_PORT", "587"))
SMTP_USERNAME = os.getenv("SMTP_USERNAME", "").strip()
SMTP_PASSWORD = os.getenv("SMTP_PASSWORD", "").strip()
SMTP_FROM = os.getenv("SMTP_FROM", SMTP_USERNAME or "Respect App <no-reply@respect-app.local>").strip()
OTP_TTL_MINUTES = int(os.getenv("OTP_TTL_MINUTES", "10"))
TRUSTED_DEVICE_DAYS = int(os.getenv("TRUSTED_DEVICE_DAYS", "90"))

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
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


_moderation_rate: Dict[str, list[float]] = defaultdict(list)


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


def _load_service_account_info() -> Dict[str, Any]:
    if SA_JSON:
        try:
            return json.loads(SA_JSON)
        except json.JSONDecodeError as e:
            raise HTTPException(status_code=500, detail=f"Invalid FIREBASE_SA_JSON: {e}")

    if not SA_FILE:
        raise HTTPException(
            status_code=500,
            detail="Missing Firebase service account. Set FIREBASE_SERVICE_ACCOUNT_JSON or FIREBASE_SERVICE_ACCOUNT_FILE.",
        )

    if not os.path.exists(SA_FILE):
        raise HTTPException(status_code=500, detail="Firebase service account file not found")

    try:
        with open(SA_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Cannot read Firebase service account file: {e}")


def get_access_token() -> str:
    try:
        creds = service_account.Credentials.from_service_account_info(
            _load_service_account_info(),
            scopes=SCOPES,
        )
        creds.refresh(Request())
        return creds.token
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

    url = f"{SB_URL}/rest/v1/users"
    headers = {
        "apikey": SB_ANON,
        "Authorization": f"Bearer {SB_ANON}",
    }
    params = {
        "select": "username,fcm_token",
        "or": f"(username.eq.{clean},username.eq.{display})",
        "limit": "1",
    }

    response = requests.get(url, headers=headers, params=params, timeout=15)
    if response.status_code >= 400:
        raise HTTPException(status_code=500, detail=f"Supabase error: {response.text}")

    rows = response.json()
    if not rows:
        return None

    token = rows[0].get("fcm_token")
    return str(token).strip() if token else None


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


def send_fcm_v1(token: str, msg_type: str, title: str, body: str, data: Dict[str, Any]) -> Dict[str, Any]:
    token = token.strip()
    if not token:
        raise HTTPException(status_code=400, detail="Missing FCM token")

    access_token = get_access_token()
    url = f"https://fcm.googleapis.com/v1/projects/{PROJECT_ID}/messages:send"

    clean_data = _string_data(data, msg_type, title, body)

    if msg_type == "call":
        # مهم جدًا:
        # المكالمات Data Only Push حتى تصل إلى IncomingCallFirebaseMessagingService
        # ولا يعرضها Firebase كإشعار عادي فقط.
        payload = {
            "message": {
                "token": token,
                "data": clean_data,
                "android": {
                    "priority": "HIGH",
                    "ttl": "45s",
                },
            }
        }
    else:
        payload = {
            "message": {
                "token": token,
                "notification": {
                    "title": title,
                    "body": body,
                },
                "data": clean_data,
                "android": {
                    "priority": "HIGH",
                    "notification": {
                        "channel_id": "respect_messages_channel",
                        "sound": "default",
                    },
                },
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

    return {"ok": True, "firebase": response.json(), "sent_as": "data_only_call" if msg_type == "call" else "notification_message"}


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
        "server_delete_enabled": bool(SB_SERVICE),
        "link_guard_enabled": bool(GSB_TOKEN),
        "virustotal_enabled": bool(VIRUSTOTAL_API_KEY),
        "qwen_model": QWEN_MODEL,
        "qwen_text_model": QWEN_TEXT_MODEL,
        "qwen_vision_model": QWEN_VISION_MODEL,
        "qwen_base_url": QWEN_BASE_URL,
        "moderation_endpoint": "/respect-ai/moderate",
        "story_moderation_endpoint": "/respect-ai/moderate-story",
    }


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


def _send_otp_email(email: str, code: str, purpose: str) -> str:
    subject = "رمز تحقق Respect App"
    action = "إنشاء الحساب" if purpose == "signup" else "تسجيل الدخول"
    body = f"""مرحبًا،

رمز التحقق الخاص بك في Respect App هو:

{code}

الغرض: {action}
صلاحية الرمز: {OTP_TTL_MINUTES} دقائق.

إذا لم تطلب هذا الرمز، تجاهل هذه الرسالة.
"""
    if not SMTP_HOST or not SMTP_USERNAME or not SMTP_PASSWORD:
        logger.warning("OTP email SMTP is not configured. OTP for %s (%s): %s", email, purpose, code)
        return "log_only"

    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = SMTP_FROM
    msg["To"] = email
    msg.set_content(body)

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

    # لو كان المستخدم موجودًا في Auth من محاولة قديمة، لا نرسل إيميل جديد ولا نكسر إنشاء الحساب.
    # بعدها Flutter سيحاول signInWithPassword بنفس كلمة المرور.
    if r.status_code in (400, 409, 422) and (
        "already" in body_lower
        or "registered" in body_lower
        or "exists" in body_lower
        or "duplicate" in body_lower
        or "user_already_exists" in body_lower
    ):
        return {"ok": True, "created": False, "alreadyExists": True}

    raise HTTPException(
        status_code=400,
        detail=f"تعذر إنشاء مستخدم Auth بدون رسالة Supabase: {r.status_code} {body_text}",
    )


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


@app.post("/send_message_push")
def send_message_push(req: MessagePushRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_secret(x_app_secret)
    title = req.senderName.strip() or display_username(req.senderUsername)
    body = req.text.strip() or "أرسل لك رسالة"

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
            "senderName": req.senderName,
            "text": req.text,
            "peerUsername": display_username(req.senderUsername),
            "peerName": title,
        },
    )


@app.post("/send_call_push")
def send_call_push(req: CallPushRequest, x_app_secret: Optional[str] = Header(default=None)):
    _check_secret(x_app_secret)
    title = "مكالمة فيديو واردة" if req.video else "مكالمة صوتية واردة"
    body = req.callerName.strip() or display_username(req.callerUsername)

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
            "callerName": req.callerName,
            "caller_name": req.callerName,
            "callerAvatarPath": req.callerAvatar,
            "caller_avatar": req.callerAvatar,
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


def _local_obvious_violation(text: str) -> Optional[Dict[str, Any]]:
    """
    فلتر احتياطي عند تعطل Qwen. لا يحذف إلا المخالف الواضح جدًا.
    """
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
    if should_hide:
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

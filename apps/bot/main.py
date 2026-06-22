import hashlib
import hmac
import json
import os
from decimal import Decimal, InvalidOperation
from typing import Any
from uuid import uuid4

import httpx
from fastapi import FastAPI, Header, HTTPException, Request
from game_logic import is_winning_selection
from pydantic import BaseModel
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    telegram_bot_token: str = ""
    telegram_webhook_secret: str = ""
    supabase_url: str = ""
    supabase_service_role_key: str = ""
    nowpayments_api_key: str = ""
    nowpayments_ipn_secret: str = ""
    public_base_url: str = ""
    crm_base_url: str = ""


settings = Settings()
app = FastAPI(title="Demo Dice Bot")


class TelegramMessage(BaseModel):
    message_id: int
    chat: dict[str, Any]
    from_user: dict[str, Any] | None = None
    text: str | None = None


class TelegramUpdate(BaseModel):
    update_id: int
    message: dict[str, Any] | None = None
    callback_query: dict[str, Any] | None = None


def require_runtime_settings() -> None:
    missing = [
        key
        for key, value in {
            "TELEGRAM_BOT_TOKEN": settings.telegram_bot_token,
            "TELEGRAM_WEBHOOK_SECRET": settings.telegram_webhook_secret,
            "SUPABASE_URL": settings.supabase_url,
            "SUPABASE_SERVICE_ROLE_KEY": settings.supabase_service_role_key,
        }.items()
        if not value
    ]
    if missing:
        raise HTTPException(status_code=500, detail=f"Missing runtime settings: {', '.join(missing)}")


def parse_amount(raw: str) -> str:
    try:
        amount = Decimal(raw)
    except InvalidOperation as exc:
        raise ValueError("금액 형식이 올바르지 않습니다.") from exc
    if amount <= 0:
        raise ValueError("금액은 0보다 커야 합니다.")
    return str(amount.quantize(Decimal("0.000001")))


def classify_selection(selection: str) -> str:
    if selection in {"odd", "even", "홀", "짝"}:
        return "odd_even"
    if selection in {"under", "over", "언더", "오버"}:
        return "under_over"
    if selection in {"1", "2", "3", "4", "5", "6"}:
        return "exact_number"
    raise ValueError("선택지는 odd/even, under/over, 1~6 중 하나여야 합니다.")


def normalize_selection(selection: str) -> str:
    aliases = {"홀": "odd", "짝": "even", "언더": "under", "오버": "over"}
    return aliases.get(selection.lower(), selection.lower())


def supabase_headers() -> dict[str, str]:
    return {
        "apikey": settings.supabase_service_role_key,
        "authorization": f"Bearer {settings.supabase_service_role_key}",
        "content-type": "application/json",
    }


async def call_rpc(name: str, payload: dict[str, Any]) -> Any:
    require_runtime_settings()
    async with httpx.AsyncClient(timeout=20) as client:
        response = await client.post(
            f"{settings.supabase_url.rstrip('/')}/rest/v1/rpc/{name}",
            headers=supabase_headers(),
            json=payload,
        )
    if response.status_code >= 400:
        raise HTTPException(status_code=502, detail=response.text)
    if not response.content:
        return None
    return response.json()


async def telegram_api(method: str, payload: dict[str, Any]) -> dict[str, Any]:
    require_runtime_settings()
    async with httpx.AsyncClient(timeout=20) as client:
        response = await client.post(
            f"https://api.telegram.org/bot{settings.telegram_bot_token}/{method}",
            json=payload,
        )
    data = response.json()
    if not data.get("ok"):
        raise HTTPException(status_code=502, detail=data)
    return data["result"]


async def send_message(chat_id: int, text: str) -> None:
    await telegram_api("sendMessage", {"chat_id": chat_id, "text": text})


async def ensure_user(message: dict[str, Any]) -> dict[str, Any]:
    user = message.get("from") or {}
    return await call_rpc(
        "upsert_player",
        {
            "p_telegram_id": user.get("id"),
            "p_username": user.get("username"),
            "p_first_name": user.get("first_name"),
        },
    )


async def handle_start(chat_id: int, message: dict[str, Any]) -> None:
    await ensure_user(message)
    await send_message(
        chat_id,
        "🎲 데모 주사위 봇입니다.\n"
        "/balance - 잔액 확인\n"
        "/bet odd 10 - 홀짝/언더오버/숫자 배팅\n"
        "/deposit 50 - NOWPayments 입금 생성\n"
        "/withdraw 10 WALLET_ADDRESS - 출금 요청",
    )


async def handle_balance(chat_id: int, message: dict[str, Any]) -> None:
    user = await ensure_user(message)
    await send_message(chat_id, f"현재 잔액: {user['balance']}")


async def handle_bet(chat_id: int, message: dict[str, Any], parts: list[str]) -> None:
    if len(parts) != 3:
        await send_message(chat_id, "사용법: /bet odd 10 또는 /bet 6 10")
        return
    selection = normalize_selection(parts[1])
    amount = parse_amount(parts[2])
    game_type = classify_selection(selection)
    user = await ensure_user(message)
    bet = await call_rpc(
        "place_bet",
        {
            "p_user_id": user["id"],
            "p_game_type": game_type,
            "p_selection": selection,
            "p_stake": amount,
            "p_client_nonce": str(uuid4()),
        },
    )
    dice_message = await telegram_api("sendDice", {"chat_id": chat_id, "emoji": "🎲"})
    dice_value = dice_message["dice"]["value"]
    settlement = await call_rpc(
        "settle_bet",
        {
            "p_bet_id": bet["id"],
            "p_dice_message_id": dice_message["message_id"],
            "p_dice_value": dice_value,
        },
    )
    result = "승리" if is_winning_selection(game_type, selection, dice_value) else "패배"
    await send_message(
        chat_id,
        f"결과: {dice_value}\n{result}\n지급액: {settlement['payout']}\n잔액: {settlement['balance']}",
    )


async def handle_deposit(chat_id: int, message: dict[str, Any], parts: list[str]) -> None:
    if len(parts) != 2:
        await send_message(chat_id, "사용법: /deposit 50")
        return
    if not settings.nowpayments_api_key:
        await send_message(chat_id, "입금 API 키가 아직 설정되지 않았습니다.")
        return
    amount = parse_amount(parts[1])
    user = await ensure_user(message)
    payload = {
        "price_amount": amount,
        "price_currency": "usd",
        "pay_currency": "usdttrc20",
        "order_id": f"user:{user['id']}:{uuid4()}",
        "order_description": "Demo dice balance top-up",
    }
    if settings.public_base_url:
        payload["ipn_callback_url"] = f"{settings.public_base_url.rstrip('/')}/payments/nowpayments/ipn"
    async with httpx.AsyncClient(timeout=20) as client:
        response = await client.post(
            "https://api.nowpayments.io/v1/payment",
            headers={"x-api-key": settings.nowpayments_api_key, "content-type": "application/json"},
            json=payload,
        )
    if response.status_code >= 400:
        raise HTTPException(status_code=502, detail=response.text)
    payment = response.json()
    await call_rpc(
        "create_deposit_request",
        {
            "p_user_id": user["id"],
            "p_amount": amount,
            "p_provider": "nowpayments",
            "p_provider_payment_id": str(payment.get("payment_id")),
            "p_payload": payment,
        },
    )
    await send_message(
        chat_id,
        "입금 요청이 생성되었습니다.\n"
        f"결제 ID: {payment.get('payment_id')}\n"
        f"입금 주소: {payment.get('pay_address')}\n"
        f"결제 금액: {payment.get('pay_amount')} {payment.get('pay_currency')}",
    )


async def handle_withdraw(chat_id: int, message: dict[str, Any], parts: list[str]) -> None:
    if len(parts) < 3:
        await send_message(chat_id, "사용법: /withdraw 10 WALLET_ADDRESS")
        return
    amount = parse_amount(parts[1])
    address = " ".join(parts[2:]).strip()
    user = await ensure_user(message)
    withdrawal = await call_rpc(
        "request_withdrawal",
        {"p_user_id": user["id"], "p_amount": amount, "p_destination": address},
    )
    await send_message(chat_id, f"출금 요청 완료: {withdrawal['id']}\n상태: {withdrawal['status']}")


async def process_message(message: dict[str, Any]) -> None:
    chat_id = message["chat"]["id"]
    text = (message.get("text") or "").strip()
    parts = text.split()
    if not parts:
        return
    try:
        command = parts[0].split("@", 1)[0].lower()
        if command == "/start":
            await handle_start(chat_id, message)
        elif command == "/balance":
            await handle_balance(chat_id, message)
        elif command == "/bet":
            await handle_bet(chat_id, message, parts)
        elif command == "/deposit":
            await handle_deposit(chat_id, message, parts)
        elif command == "/withdraw":
            await handle_withdraw(chat_id, message, parts)
        else:
            await send_message(chat_id, "알 수 없는 명령입니다. /start 를 입력해 주세요.")
    except ValueError as exc:
        await send_message(chat_id, str(exc))


def verify_nowpayments_signature(body: bytes, signature: str | None) -> None:
    if not settings.nowpayments_ipn_secret:
        raise HTTPException(status_code=500, detail="NOWPayments IPN secret is not configured")
    if not signature:
        raise HTTPException(status_code=401, detail="Missing IPN signature")
    parsed = json.loads(body)
    canonical = json.dumps(parsed, sort_keys=True, separators=(",", ":")).encode()
    expected = hmac.new(settings.nowpayments_ipn_secret.encode(), canonical, hashlib.sha512).hexdigest()
    if not hmac.compare_digest(expected, signature):
        raise HTTPException(status_code=401, detail="Invalid IPN signature")


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/telegram/webhook/{secret}")
async def telegram_webhook(secret: str, update: TelegramUpdate) -> dict[str, bool]:
    if secret != settings.telegram_webhook_secret:
        raise HTTPException(status_code=404, detail="Not found")
    if update.message:
        receipt = await call_rpc("record_telegram_update", {"p_update_id": update.update_id})
        if receipt:
            await process_message(update.message)
    return {"ok": True}


@app.post("/payments/nowpayments/ipn")
async def nowpayments_ipn(request: Request, x_nowpayments_sig: str | None = Header(default=None)) -> dict[str, bool]:
    body = await request.body()
    verify_nowpayments_signature(body, x_nowpayments_sig)
    payload = json.loads(body)
    await call_rpc(
        "credit_deposit_from_nowpayments",
        {
            "p_payment_id": str(payload.get("payment_id")),
            "p_status": payload.get("payment_status"),
            "p_actual_amount": payload.get("actually_paid") or payload.get("pay_amount") or 0,
            "p_payload": payload,
        },
    )
    return {"ok": True}


if os.getenv("RUN_LOCAL_BOT") == "1":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=int(os.getenv("PORT", "8000")))
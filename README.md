# Telegram Dice Betting Bot

Python Telegram dice betting bot with Supabase Postgres ledger/RPCs, NOWPayments integration, Render hosting, and a Vercel-hosted admin CRM.

## Structure

```text
.
├── apps/
│   ├── bot/      # Python Telegram webhook bot
│   └── crm/      # Next.js admin CRM
├── packages/
│   ├── db/       # DB notes/shared SQL references
│   └── shared/   # Shared TypeScript constants
├── supabase/
│   └── migrations/
├── docs/
├── render.yaml
└── vercel.json
```

## Core guarantees

- All balance mutations happen through Supabase RPCs using row locks.
- Every monetary mutation writes `ledger_transactions` with before/after balances.
- Telegram update, bet settlement, and NOWPayments credit flows use idempotency keys.
- Sensitive RPCs are revoked from `anon` and `authenticated`.
- CRM uses server route handlers for service-role access; service-role keys are never exposed to the browser bundle.

## Required environment variables

### Bot / Render

- `TELEGRAM_BOT_TOKEN`
- `TELEGRAM_WEBHOOK_SECRET`
- `SUPABASE_URL`
- `SUPABASE_SERVICE_ROLE_KEY`
- `NOWPAYMENTS_API_KEY`
- `NOWPAYMENTS_IPN_SECRET`
- `CRM_BASE_URL`
- `PUBLIC_BASE_URL`

### CRM / Vercel

- `NEXT_PUBLIC_SUPABASE_URL`
- `NEXT_PUBLIC_SUPABASE_ANON_KEY`
- `SUPABASE_SERVICE_ROLE_KEY`
- `NOWPAYMENTS_API_KEY`
- `NOWPAYMENTS_IPN_SECRET`

## Local bot run

```bash
cd apps/bot
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
uvicorn main:app --reload --port 8000
```

Set the Telegram webhook after deployment:

```bash
curl "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/setWebhook" \
  -d "url=https://YOUR_RENDER_URL/telegram/webhook/$TELEGRAM_WEBHOOK_SECRET"
```

## Local CRM run

```bash
cd apps/crm
npm install
npm run dev
```

## Supabase setup

Apply the migration in `supabase/migrations/001_initial_schema.sql`, then create a Supabase Auth user for the first admin and insert its Auth UUID into `admin_accounts`.

## Safety note

This project processes betting and payment flows. Before production use, confirm legal compliance, Telegram/NOWPayments policy compatibility, KYC/AML requirements, and jurisdictional restrictions.

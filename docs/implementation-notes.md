# Implementation Notes

## Deployment responsibilities

- Render hosts `apps/bot` as a FastAPI webhook receiver.
- Vercel hosts `apps/crm`.
- Supabase stores all durable state and performs balance-changing operations through RPCs.

## Idempotency model

- Telegram updates are tracked in `telegram_update_receipts`.
- Stake deduction uses `place_bet:<user_id>:<client_nonce>`.
- Settlement uses `settle_bet:<bet_id>:<dice_message_id>`.
- NOWPayments credits use `nowpayments:<payment_id>:<status>`.

## Admin CRM security model

- Browser authenticates with Supabase Auth using anon key.
- Browser sends Supabase access token to `/api/admin/*`.
- Server route verifies the token against Supabase Auth and confirms `admin_accounts.is_active`.
- Mutations are executed with service-role key only on the server.

## Production checklist

- Rotate all keys before launch.
- Verify `REVOKE EXECUTE` statements after every migration.
- Confirm `SUPABASE_SERVICE_ROLE_KEY` is not present in client bundles.
- Configure Telegram webhook to the Render URL and secret path.
- Configure NOWPayments IPN URL to `/payments/nowpayments/ipn`.
- Run smoke tests for duplicated Telegram updates and duplicated IPN callbacks.

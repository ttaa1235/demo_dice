# Database Package

The canonical schema and RPC implementation lives in `supabase/migrations/001_initial_schema.sql`.

Design constraints:

- Use `numeric(20,6)` for all balances and amounts.
- Use `SELECT ... FOR UPDATE` in every balance-mutating RPC.
- Write immutable ledger rows for all balance changes.
- Keep sensitive RPCs `SECURITY DEFINER` and revoke execution from `anon` and `authenticated`.

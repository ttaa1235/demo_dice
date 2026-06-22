create extension if not exists pgcrypto;

create table if not exists public.players (
  id uuid primary key default gen_random_uuid(),
  telegram_id bigint not null unique,
  username text,
  first_name text,
  balance numeric(20,6) not null default 0 check (balance >= 0),
  status text not null default 'active' check (status in ('active', 'blocked')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.telegram_update_receipts (
  update_id bigint primary key,
  created_at timestamptz not null default now()
);

create table if not exists public.ledger_transactions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.players(id),
  direction text not null check (direction in ('credit', 'debit')),
  amount numeric(20,6) not null check (amount > 0),
  balance_before numeric(20,6) not null,
  balance_after numeric(20,6) not null,
  reason text not null,
  idempotency_key text not null unique,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.bets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.players(id),
  game_type text not null check (game_type in ('odd_even', 'under_over', 'exact_number')),
  selection text not null,
  stake numeric(20,6) not null check (stake > 0),
  multiplier numeric(12,6) not null,
  status text not null default 'placed' check (status in ('placed', 'settled')),
  dice_message_id bigint,
  dice_value int check (dice_value between 1 and 6),
  payout numeric(20,6) not null default 0,
  client_nonce text not null,
  created_at timestamptz not null default now(),
  settled_at timestamptz,
  unique (user_id, client_nonce),
  unique (dice_message_id)
);

create table if not exists public.deposit_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.players(id),
  provider text not null,
  provider_payment_id text unique,
  amount numeric(20,6) not null check (amount > 0),
  status text not null default 'waiting' check (status in ('waiting', 'confirmed', 'failed')),
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.withdrawal_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.players(id),
  amount numeric(20,6) not null check (amount > 0),
  destination text not null,
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.admin_accounts (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid not null unique,
  email text,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.game_settings (
  key text primary key,
  value jsonb not null,
  updated_at timestamptz not null default now()
);

insert into public.game_settings(key, value)
values
  ('betting', '{"min_stake":1,"max_stake":1000}'::jsonb),
  ('payments', '{"min_deposit":1,"min_withdrawal":1}'::jsonb)
on conflict (key) do nothing;

alter table public.players enable row level security;
alter table public.telegram_update_receipts enable row level security;
alter table public.ledger_transactions enable row level security;
alter table public.bets enable row level security;
alter table public.deposit_requests enable row level security;
alter table public.withdrawal_requests enable row level security;
alter table public.admin_accounts enable row level security;
alter table public.game_settings enable row level security;

create or replace function public.record_telegram_update(p_update_id bigint)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.telegram_update_receipts(update_id)
  values (p_update_id)
  on conflict do nothing;

  return found;
end;
$$;

create or replace function public.upsert_player(p_telegram_id bigint, p_username text, p_first_name text)
returns public.players
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player public.players;
begin
  if p_telegram_id is null then
    raise exception 'telegram id is required';
  end if;

  insert into public.players(telegram_id, username, first_name)
  values (p_telegram_id, p_username, p_first_name)
  on conflict (telegram_id) do update
    set username = excluded.username,
        first_name = excluded.first_name,
        updated_at = now()
  returning * into v_player;

  if v_player.status <> 'active' then
    raise exception 'player is blocked';
  end if;

  return v_player;
end;
$$;

create or replace function public.bet_multiplier(p_game_type text)
returns numeric
language sql
immutable
as $$
  select case
    when p_game_type in ('odd_even', 'under_over') then 1.95
    when p_game_type = 'exact_number' then 5.70
    else null
  end
$$;

create or replace function public.is_winning_bet(p_game_type text, p_selection text, p_dice_value int)
returns boolean
language sql
immutable
as $$
  select case
    when p_game_type = 'odd_even' then (p_dice_value % 2 = 1 and p_selection = 'odd') or (p_dice_value % 2 = 0 and p_selection = 'even')
    when p_game_type = 'under_over' then (p_dice_value <= 3 and p_selection = 'under') or (p_dice_value >= 4 and p_selection = 'over')
    when p_game_type = 'exact_number' then p_selection = p_dice_value::text
    else false
  end
$$;

create or replace function public.write_ledger(
  p_user_id uuid,
  p_direction text,
  p_amount numeric,
  p_balance_before numeric,
  p_balance_after numeric,
  p_reason text,
  p_idempotency_key text,
  p_metadata jsonb default '{}'::jsonb
)
returns public.ledger_transactions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.ledger_transactions;
begin
  insert into public.ledger_transactions(
    user_id, direction, amount, balance_before, balance_after, reason, idempotency_key, metadata
  )
  values (
    p_user_id, p_direction, p_amount, p_balance_before, p_balance_after, p_reason, p_idempotency_key, coalesce(p_metadata, '{}'::jsonb)
  )
  on conflict (idempotency_key) do update
    set idempotency_key = excluded.idempotency_key
  returning * into v_row;

  return v_row;
end;
$$;

create or replace function public.place_bet(
  p_user_id uuid,
  p_game_type text,
  p_selection text,
  p_stake numeric,
  p_client_nonce text
)
returns public.bets
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player public.players;
  v_multiplier numeric;
  v_bet public.bets;
  v_balance_after numeric;
  v_inserted boolean;
begin
  select * into v_player from public.players where id = p_user_id for update;
  if not found or v_player.status <> 'active' then
    raise exception 'player not available';
  end if;
  if p_stake <= 0 or v_player.balance < p_stake then
    raise exception 'insufficient balance';
  end if;

  v_multiplier := public.bet_multiplier(p_game_type);
  if v_multiplier is null then
    raise exception 'invalid game type';
  end if;

  insert into public.bets(user_id, game_type, selection, stake, multiplier, client_nonce)
  values (p_user_id, p_game_type, p_selection, p_stake, v_multiplier, p_client_nonce)
  on conflict (user_id, client_nonce) do nothing
  returning * into v_bet;

  v_inserted := found;
  if not v_inserted then
    select * into v_bet from public.bets where user_id = p_user_id and client_nonce = p_client_nonce;
    return v_bet;
  end if;

  if v_bet.status = 'placed' then
    v_balance_after := v_player.balance - p_stake;
    update public.players set balance = v_balance_after, updated_at = now() where id = p_user_id;
    perform public.write_ledger(
      p_user_id,
      'debit',
      p_stake,
      v_player.balance,
      v_balance_after,
      'bet_stake',
      'place_bet:' || p_user_id || ':' || p_client_nonce,
      jsonb_build_object('bet_id', v_bet.id)
    );
  end if;

  return v_bet;
end;
$$;

create or replace function public.settle_bet(p_bet_id uuid, p_dice_message_id bigint, p_dice_value int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_bet public.bets;
  v_player public.players;
  v_is_win boolean;
  v_payout numeric := 0;
  v_before numeric;
  v_after numeric;
begin
  select * into v_bet from public.bets where id = p_bet_id for update;
  if not found then
    raise exception 'bet not found';
  end if;

  select * into v_player from public.players where id = v_bet.user_id for update;

  if v_bet.status = 'settled' then
    return jsonb_build_object('payout', v_bet.payout, 'balance', v_player.balance);
  end if;

  v_is_win := public.is_winning_bet(v_bet.game_type, v_bet.selection, p_dice_value);
  if v_is_win then
    v_payout := round(v_bet.stake * v_bet.multiplier, 6);
    v_before := v_player.balance;
    v_after := v_before + v_payout;
    update public.players set balance = v_after, updated_at = now() where id = v_player.id;
    perform public.write_ledger(
      v_player.id,
      'credit',
      v_payout,
      v_before,
      v_after,
      'bet_payout',
      'settle_bet:' || p_bet_id || ':' || p_dice_message_id,
      jsonb_build_object('bet_id', p_bet_id, 'dice_value', p_dice_value)
    );
  else
    v_after := v_player.balance;
  end if;

  update public.bets
  set status = 'settled',
      dice_message_id = p_dice_message_id,
      dice_value = p_dice_value,
      payout = v_payout,
      settled_at = now()
  where id = p_bet_id
  returning * into v_bet;

  return jsonb_build_object('payout', v_payout, 'balance', v_after);
end;
$$;

create or replace function public.create_deposit_request(
  p_user_id uuid,
  p_amount numeric,
  p_provider text,
  p_provider_payment_id text,
  p_payload jsonb default '{}'::jsonb
)
returns public.deposit_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.deposit_requests;
begin
  insert into public.deposit_requests(user_id, amount, provider, provider_payment_id, payload)
  values (p_user_id, p_amount, p_provider, p_provider_payment_id, coalesce(p_payload, '{}'::jsonb))
  on conflict (provider_payment_id) do update
    set payload = excluded.payload,
        updated_at = now()
  returning * into v_row;
  return v_row;
end;
$$;

create or replace function public.credit_deposit_from_nowpayments(
  p_payment_id text,
  p_status text,
  p_actual_amount numeric,
  p_payload jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_deposit public.deposit_requests;
  v_player public.players;
  v_before numeric;
  v_after numeric;
begin
  select * into v_deposit
  from public.deposit_requests
  where provider = 'nowpayments' and provider_payment_id = p_payment_id
  for update;

  if not found then
    raise exception 'deposit request not found';
  end if;

  update public.deposit_requests
  set payload = coalesce(p_payload, '{}'::jsonb),
      updated_at = now()
  where id = v_deposit.id;

  if p_status not in ('confirmed', 'finished') then
    return jsonb_build_object('credited', false, 'status', p_status);
  end if;

  if v_deposit.status = 'confirmed' then
    select * into v_player from public.players where id = v_deposit.user_id;
    return jsonb_build_object('credited', false, 'balance', v_player.balance);
  end if;

  select * into v_player from public.players where id = v_deposit.user_id for update;
  v_before := v_player.balance;
  v_after := v_before + greatest(p_actual_amount, v_deposit.amount);

  update public.players set balance = v_after, updated_at = now() where id = v_player.id;
  update public.deposit_requests set status = 'confirmed', updated_at = now() where id = v_deposit.id;
  perform public.write_ledger(
    v_player.id,
    'credit',
    greatest(p_actual_amount, v_deposit.amount),
    v_before,
    v_after,
    'deposit_nowpayments',
    'nowpayments:' || p_payment_id || ':confirmed',
    jsonb_build_object('deposit_id', v_deposit.id)
  );

  return jsonb_build_object('credited', true, 'balance', v_after);
end;
$$;

create or replace function public.request_withdrawal(p_user_id uuid, p_amount numeric, p_destination text)
returns public.withdrawal_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player public.players;
  v_row public.withdrawal_requests;
  v_after numeric;
begin
  select * into v_player from public.players where id = p_user_id for update;
  if not found or v_player.status <> 'active' then
    raise exception 'player not available';
  end if;
  if p_amount <= 0 or v_player.balance < p_amount then
    raise exception 'insufficient balance';
  end if;

  insert into public.withdrawal_requests(user_id, amount, destination)
  values (p_user_id, p_amount, p_destination)
  returning * into v_row;

  v_after := v_player.balance - p_amount;
  update public.players set balance = v_after, updated_at = now() where id = p_user_id;
  perform public.write_ledger(
    p_user_id,
    'debit',
    p_amount,
    v_player.balance,
    v_after,
    'withdrawal_hold',
    'withdrawal_hold:' || v_row.id,
    jsonb_build_object('withdrawal_id', v_row.id)
  );

  return v_row;
end;
$$;

create or replace function public.approve_withdrawal(p_withdrawal_id uuid)
returns public.withdrawal_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.withdrawal_requests;
begin
  select * into v_row from public.withdrawal_requests where id = p_withdrawal_id for update;
  if not found then
    raise exception 'withdrawal not found';
  end if;
  if v_row.status <> 'pending' then
    return v_row;
  end if;
  update public.withdrawal_requests
  set status = 'approved', updated_at = now()
  where id = p_withdrawal_id
  returning * into v_row;
  return v_row;
end;
$$;

create or replace function public.reject_withdrawal(p_withdrawal_id uuid)
returns public.withdrawal_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.withdrawal_requests;
  v_player public.players;
  v_after numeric;
begin
  select * into v_row from public.withdrawal_requests where id = p_withdrawal_id for update;
  if not found then
    raise exception 'withdrawal not found';
  end if;
  if v_row.status <> 'pending' then
    return v_row;
  end if;

  select * into v_player from public.players where id = v_row.user_id for update;
  v_after := v_player.balance + v_row.amount;
  update public.players set balance = v_after, updated_at = now() where id = v_player.id;
  update public.withdrawal_requests
  set status = 'rejected', updated_at = now()
  where id = p_withdrawal_id
  returning * into v_row;
  perform public.write_ledger(
    v_player.id,
    'credit',
    v_row.amount,
    v_player.balance,
    v_after,
    'withdrawal_refund',
    'withdrawal_refund:' || v_row.id,
    jsonb_build_object('withdrawal_id', v_row.id)
  );

  return v_row;
end;
$$;

create or replace function public.admin_adjust_balance(
  p_user_id uuid,
  p_direction text,
  p_amount numeric,
  p_reason text,
  p_idempotency_key text
)
returns public.players
language plpgsql
security definer
set search_path = public
as $$
declare
  v_player public.players;
  v_after numeric;
begin
  if p_amount <= 0 then
    raise exception 'amount must be positive';
  end if;
  if p_direction not in ('credit', 'debit') then
    raise exception 'invalid direction';
  end if;

  select * into v_player from public.players where id = p_user_id for update;
  if not found then
    raise exception 'player not found';
  end if;

  if p_direction = 'debit' and v_player.balance < p_amount then
    raise exception 'insufficient balance';
  end if;

  v_after := case
    when p_direction = 'credit' then v_player.balance + p_amount
    else v_player.balance - p_amount
  end;

  update public.players
  set balance = v_after,
      updated_at = now()
  where id = p_user_id
  returning * into v_player;

  perform public.write_ledger(
    p_user_id,
    p_direction,
    p_amount,
    case when p_direction = 'credit' then v_after - p_amount else v_after + p_amount end,
    v_after,
    coalesce(nullif(p_reason, ''), 'admin_adjustment'),
    p_idempotency_key,
    jsonb_build_object('source', 'admin')
  );

  return v_player;
end;
$$;

create or replace function public.admin_update_game_settings(p_key text, p_value jsonb)
returns public.game_settings
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.game_settings;
begin
  insert into public.game_settings(key, value, updated_at)
  values (p_key, p_value, now())
  on conflict (key) do update
    set value = excluded.value,
        updated_at = now()
  returning * into v_row;

  return v_row;
end;
$$;

revoke all on all tables in schema public from anon, authenticated;
revoke execute on all functions in schema public from anon, authenticated;
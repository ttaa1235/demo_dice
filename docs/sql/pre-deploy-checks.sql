select table_name
from information_schema.tables
where table_schema = 'public'
order by table_name;

select routine_name, security_type
from information_schema.routines
where routine_schema = 'public'
order by routine_name;

select n.nspname as schema_name, p.proname as function_name, r.rolname as grantee, has_function_privilege(r.rolname, p.oid, 'execute') as can_execute
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
cross join pg_roles r
where n.nspname = 'public'
  and p.proname in (
    'place_bet',
    'settle_bet',
    'credit_deposit_from_nowpayments',
    'request_withdrawal',
    'approve_withdrawal',
    'reject_withdrawal',
    'admin_adjust_balance',
    'admin_update_game_settings'
  )
  and r.rolname in ('anon', 'authenticated')
order by p.proname, r.rolname;

select schemaname, tablename, rowsecurity
from pg_tables
where schemaname = 'public'
order by tablename;

create or replace function public.bet_multiplier(p_game_type text)
returns numeric
language sql
immutable
set search_path = public
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
set search_path = public
as $$
  select case
    when p_game_type = 'odd_even' then (p_dice_value % 2 = 1 and p_selection = 'odd') or (p_dice_value % 2 = 0 and p_selection = 'even')
    when p_game_type = 'under_over' then (p_dice_value <= 3 and p_selection = 'under') or (p_dice_value >= 4 and p_selection = 'over')
    when p_game_type = 'exact_number' then p_selection = p_dice_value::text
    else false
  end
$$;

revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on all functions in schema public to service_role;
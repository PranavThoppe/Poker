-- Credit Classic Poker wins in the same transaction that commits the room's
-- authoritative transition to ended. The client cannot choose the winner.

alter table public.profiles
  add column if not exists lifetime_wins integer not null default 0;

create table if not exists public.game_win_credits (
  game_id uuid not null,
  player_id text not null references public.profiles(id),
  credited_at timestamptz not null default now(),
  primary key (game_id, player_id)
);

create or replace function public.commit_game_transition(
  p_room_id uuid,
  p_actor_device_id text,
  p_action_id uuid,
  p_expected_version bigint,
  p_public_state jsonb,
  p_private_state jsonb,
  p_deadline_at timestamptz,
  p_response jsonb,
  p_security_update jsonb default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_room public.game_rooms%rowtype;
  v_receipt jsonb;
  v_receipts jsonb;
  v_response jsonb;
  v_winner_count integer;
  v_winner_id text;
  v_credited_player_id text;
begin
  select * into v_room from public.game_rooms where id = p_room_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', jsonb_build_object('code', 'room_not_found'));
  end if;

  select value into v_receipt
  from jsonb_array_elements(v_room.recent_command_receipts) value
  where value ->> 'action_id' = p_action_id::text
    and value ->> 'actor_device_id' = p_actor_device_id
  limit 1;
  if v_receipt is not null then
    return coalesce(v_receipt -> 'response', jsonb_build_object('ok', false, 'error', jsonb_build_object('code', 'receipt_corrupt')));
  end if;

  if v_room.server_version <> p_expected_version then
    return jsonb_build_object('ok', false, 'error', jsonb_build_object(
      'code', 'stale_state', 'server_version', v_room.server_version,
      'hand_id', v_room.public_state ->> 'handID'
    ));
  end if;

  -- Only credit the first transition to ended, and only from an engine-produced
  -- Classic Poker state with at least two humans and one completed hand.
  if not coalesce((v_room.public_state -> 'phase') ? 'ended', false)
     and coalesce((p_public_state -> 'phase') ? 'ended', false)
     and p_public_state ->> 'gameMode' = 'classicPoker'
     and coalesce((p_public_state ->> 'completedHandCount')::integer, 0) >= 1
     and (
       select count(*)
       from jsonb_array_elements(coalesce(p_public_state -> 'players', '[]'::jsonb)) player
       where coalesce((player ->> 'isBot')::boolean, false) = false
     ) >= 2 then
    select count(*) filter (where result ->> 'isWinner' = 'true'),
           max(result ->> 'id') filter (where result ->> 'isWinner' = 'true')
      into v_winner_count, v_winner_id
      from jsonb_array_elements(coalesce(p_public_state -> 'endStats', '[]'::jsonb)) result;

    if v_winner_count = 1 and v_winner_id is not null then
      insert into public.game_win_credits (game_id, player_id)
      select p_room_id, v_winner_id
      where exists (select 1 from public.profiles where id = v_winner_id)
      on conflict (game_id, player_id) do nothing
      returning player_id into v_credited_player_id;

      if found then
        update public.profiles
           set lifetime_wins = lifetime_wins + 1
         where id = v_credited_player_id;
      end if;
    end if;
  end if;

  v_response := p_response || jsonb_build_object('ok', true, 'serverVersion', v_room.server_version + 1);
  v_receipts := coalesce(v_room.recent_command_receipts, '[]'::jsonb) ||
    jsonb_build_array(jsonb_build_object('action_id', p_action_id, 'actor_device_id', p_actor_device_id,
                                         'response', v_response, 'at', clock_timestamp()));
  select coalesce(jsonb_agg(value order by ordinal), '[]'::jsonb) into v_receipts
  from jsonb_array_elements(v_receipts) with ordinality e(value, ordinal)
  where ordinal > greatest(jsonb_array_length(v_receipts) - 100, 0);

  update public.game_rooms
     set public_state = p_public_state,
         private_state = p_private_state,
         deadline_at = p_deadline_at,
         server_version = v_room.server_version + 1,
         recent_command_receipts = v_receipts,
         security_summary = coalesce(p_security_update, security_summary),
         updated_at = clock_timestamp()
   where id = p_room_id;
  return v_response;
end;
$$;

revoke all on function public.commit_game_transition(uuid, text, uuid, bigint, jsonb, jsonb, timestamptz, jsonb, jsonb) from public, anon, authenticated;

-- The Edge Function is now the sole win-credit authority. Prevent clients from
-- incrementing arbitrary player counters through the legacy RPC or ledger.
do $$
begin
  if to_regprocedure('public.credit_game_win(uuid,text)') is not null then
    execute 'revoke all on function public.credit_game_win(uuid, text) from public, anon, authenticated';
  end if;
end;
$$;

alter table public.game_win_credits enable row level security;
revoke all on table public.game_win_credits from public, anon, authenticated;

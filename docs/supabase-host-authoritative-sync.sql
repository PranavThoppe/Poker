-- Host-authoritative Classic Poker synchronization.
-- Run once in the Supabase SQL editor after the existing game_rooms migration.

create table if not exists public.game_intents (
  request_id uuid primary key,
  room_id text not null,
  player_id text not null,
  intent_type text not null,
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'pending'
    check (status in ('pending', 'claimed', 'processed', 'rejected', 'superseded')),
  rejection_reason text,
  created_at timestamptz not null default now(),
  claimed_at timestamptz,
  claimed_by text,
  resolved_at timestamptz
);

create index if not exists game_intents_room_status_created_idx
  on public.game_intents (room_id, status, created_at);

-- A later Ready request replaces the player's earlier pending Ready request. This is
-- intentionally an explicit desired value rather than a toggle, so retries are safe.
create or replace function public.enqueue_game_intent(
  p_request_id uuid, p_room_id text, p_player_id text, p_intent_type text, p_payload text
) returns uuid language plpgsql security definer set search_path = public as $$
begin
  if p_intent_type = 'setReady' then
    update game_intents
       set status = 'superseded', resolved_at = now(), rejection_reason = 'superseded'
     where room_id = p_room_id and player_id = p_player_id and intent_type = 'setReady'
       and status = 'pending';
  end if;
  insert into game_intents(request_id, room_id, player_id, intent_type, payload)
  values (p_request_id, p_room_id, p_player_id, p_intent_type, p_payload::jsonb)
  on conflict (request_id) do nothing;
  return p_request_id;
end;
$$;

-- Claimed requests are retriable after 30 seconds, so killing/relaunching a host cannot
-- strand a guest request forever. The host ID check prevents another guest from claiming.
create or replace function public.claim_game_intents(p_room_id text, p_host_id text)
returns table(request_id uuid, room_id text, player_id text, intent_type text, payload text, created_at timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from game_rooms where id::text = p_room_id and host_id = p_host_id) then
    return;
  end if;
  return query
  with candidates as (
    select gi.request_id from game_intents gi
    where gi.room_id = p_room_id
      and (gi.status = 'pending' or (gi.status = 'claimed' and gi.claimed_at < now() - interval '30 seconds'))
    order by gi.created_at
    for update skip locked
  ), claimed as (
    update game_intents gi set status = 'claimed', claimed_by = p_host_id, claimed_at = now()
    from candidates c where gi.request_id = c.request_id
    returning gi.request_id, gi.room_id, gi.player_id, gi.intent_type, gi.payload::text as payload, gi.created_at
  ) select * from claimed;
end;
$$;

create or replace function public.resolve_game_intent(p_request_id uuid, p_accepted boolean, p_reason text default null)
returns void language sql security definer set search_path = public as $$
  update game_intents
     set status = case when p_accepted then 'processed' else 'rejected' end,
         rejection_reason = p_reason, resolved_at = now()
   where request_id = p_request_id and status = 'claimed';
$$;

-- Returns false rather than overwriting a snapshot whose version has moved on.  The
-- caller supplies the version it read/last published; inserts use expected version 0.
create or replace function public.replace_game_room_state(
  p_room_id text, p_host_id text, p_expected_version integer, p_game_mode text,
  p_phase text, p_public_state jsonb, p_updated_at timestamptz
) returns boolean language plpgsql security definer set search_path = public as $$
declare current_version integer;
declare current_host text;
begin
  select coalesce((public_state->>'stateVersion')::integer, 0), host_id into current_version, current_host
    from game_rooms where id::text = p_room_id for update;
  if found then
    if current_host <> p_host_id or current_version <> p_expected_version then return false; end if;
    update game_rooms set public_state = p_public_state, game_mode = p_game_mode,
      phase = p_phase, host_id = p_host_id, updated_at = p_updated_at where id::text = p_room_id;
  else
    if p_expected_version <> 0 then return false; end if;
    insert into game_rooms(id, host_id, game_mode, phase, public_state, updated_at)
      values (p_room_id::uuid, p_host_id, p_game_mode, p_phase, p_public_state, p_updated_at);
  end if;
  return true;
end;
$$;

grant execute on function public.enqueue_game_intent(uuid,text,text,text,text) to anon, authenticated;
grant execute on function public.claim_game_intents(text,text) to anon, authenticated;
grant execute on function public.resolve_game_intent(uuid,boolean,text) to anon, authenticated;
grant execute on function public.replace_game_room_state(text,text,integer,text,text,jsonb,timestamptz) to anon, authenticated;

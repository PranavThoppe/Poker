-- Server-authoritative Classic Poker runtime.  This deliberately extends the
-- existing room record: private cards and command receipts must never be
-- exposed through PostgREST to the iMessage extension.
alter table public.game_rooms
  add column if not exists server_version bigint not null default 0,
  add column if not exists private_state jsonb,
  add column if not exists deadline_at timestamptz,
  add column if not exists recent_command_receipts jsonb not null default '[]'::jsonb,
  add column if not exists security_summary jsonb not null default
    '{"total":0,"high":0,"last_seen_at":null}'::jsonb,
  add column if not exists recent_security_events jsonb not null default '[]'::jsonb;

alter table public.game_rooms enable row level security;
alter table public.player_hole_cards enable row level security;
revoke all on table public.game_rooms, public.player_hole_cards from anon, authenticated;

-- The Edge Function is the only caller.  A duplicate action ID returns its
-- original response before checking the expected version, making HTTP retries
-- safe.  Pin the search path so a caller cannot shadow JSON/array functions.
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
begin
  select * into v_room from public.game_rooms where id = p_room_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'error', jsonb_build_object('code', 'room_not_found'));
  end if;

  select value into v_receipt
  from jsonb_array_elements(v_room.recent_command_receipts) value
  where value ->> 'action_id' = p_action_id::text
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

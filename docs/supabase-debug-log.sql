-- Debug event log for Classic Poker multiplayer rooms.
-- Run in the Supabase SQL editor (Dashboard → SQL → New query).

-- 1. Add rolling JSON array column (one row per game room).
ALTER TABLE game_rooms
ADD COLUMN IF NOT EXISTS debug_log jsonb NOT NULL DEFAULT '[]'::jsonb;

-- 2. Atomically append one event and keep the newest 1,000 entries.
--    Uses SECURITY DEFINER so clients can append without a read-modify-write race.
CREATE OR REPLACE FUNCTION append_debug_event(p_room_id uuid, p_event jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  merged jsonb;
  trimmed jsonb;
BEGIN
  SELECT COALESCE(debug_log, '[]'::jsonb) || jsonb_build_array(p_event)
  INTO merged
  FROM game_rooms
  WHERE id = p_room_id;

  IF merged IS NULL THEN
    RETURN;
  END IF;

  IF jsonb_array_length(merged) > 1000 THEN
    SELECT COALESCE(jsonb_agg(elem ORDER BY ord), '[]'::jsonb)
    INTO trimmed
    FROM (
      SELECT elem, ord
      FROM jsonb_array_elements(merged) WITH ORDINALITY AS t(elem, ord)
      ORDER BY ord DESC
      LIMIT 1000
    ) last_events;

    merged := trimmed;
  END IF;

  UPDATE game_rooms
  SET debug_log = merged
  WHERE id = p_room_id;
END;
$$;

GRANT EXECUTE ON FUNCTION append_debug_event(uuid, jsonb) TO anon, authenticated;

-- 3. Optional: inspect a room's log in the dashboard.
-- SELECT id, jsonb_array_length(debug_log) AS event_count, debug_log
-- FROM game_rooms
-- WHERE id = '<game-uuid>';

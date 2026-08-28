-- Lifetime game-win tracking for Classic Poker.
-- Run in the Supabase SQL editor (Dashboard → SQL → New query).

-- 1. Lifetime counter on the existing profiles row.
ALTER TABLE profiles
ADD COLUMN IF NOT EXISTS lifetime_wins INT NOT NULL DEFAULT 0;

-- 2. Idempotency ledger (one credit per game + player). Prevents duplicate
--    increments from replays or re-opening an ended session.
CREATE TABLE IF NOT EXISTS game_win_credits (
  game_id UUID NOT NULL,
  player_id TEXT NOT NULL REFERENCES profiles(id),
  credited_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (game_id, player_id)
);

-- 3. Atomically insert the ledger row and bump counters. SECURITY DEFINER avoids
--    a client-side read-modify-write race on profiles.lifetime_wins.
CREATE OR REPLACE FUNCTION credit_game_win(
  p_game_id uuid,
  p_player_id text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  inserted int;
BEGIN
  INSERT INTO game_win_credits (game_id, player_id)
  VALUES (p_game_id, p_player_id)
  ON CONFLICT (game_id, player_id) DO NOTHING;

  GET DIAGNOSTICS inserted = ROW_COUNT;
  IF inserted = 0 THEN
    RETURN;
  END IF;

  UPDATE profiles
  SET lifetime_wins = lifetime_wins + 1
  WHERE id = p_player_id;

  IF NOT FOUND THEN
    DELETE FROM game_win_credits
    WHERE game_id = p_game_id AND player_id = p_player_id;
    RAISE EXCEPTION 'profile % not found', p_player_id;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION credit_game_win(uuid, text) TO anon, authenticated;

ALTER TABLE game_win_credits ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS game_win_credits_select ON game_win_credits;
CREATE POLICY game_win_credits_select ON game_win_credits
  FOR SELECT TO anon, authenticated USING (true);

DROP POLICY IF EXISTS game_win_credits_insert ON game_win_credits;
CREATE POLICY game_win_credits_insert ON game_win_credits
  FOR INSERT TO anon, authenticated WITH CHECK (true);

GRANT SELECT, INSERT ON game_win_credits TO anon, authenticated;

-- If an earlier version of this script was applied, run these cleanup statements:
-- DROP TABLE IF EXISTS group_wins;
-- ALTER TABLE game_win_credits DROP COLUMN IF EXISTS group_id;

-- Optional: inspect credits for a player.
-- SELECT * FROM game_win_credits WHERE player_id = '<device-id>';
-- SELECT id, display_name, lifetime_wins FROM profiles WHERE id = '<device-id>';

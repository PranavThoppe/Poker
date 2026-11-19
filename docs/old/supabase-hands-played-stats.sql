-- Lifetime hands-played tracking. Run after the profiles table exists.
-- A hand counts after it reaches its hand summary, for each player dealt into it.

ALTER TABLE profiles
ADD COLUMN IF NOT EXISTS lifetime_hands_played INT NOT NULL DEFAULT 0;

-- One credit per dealt hand and player makes retrying a network request safe.
CREATE TABLE IF NOT EXISTS hand_played_credits (
  hand_id UUID NOT NULL,
  player_id TEXT NOT NULL REFERENCES profiles(id),
  game_mode TEXT NOT NULL,
  credited_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (hand_id, player_id)
);

-- Safe when re-running after an earlier version of this migration.
ALTER TABLE hand_played_credits
ADD COLUMN IF NOT EXISTS game_mode TEXT;
UPDATE hand_played_credits
SET game_mode = 'classicPoker'
WHERE game_mode IS NULL;
ALTER TABLE hand_played_credits
ALTER COLUMN game_mode SET NOT NULL;

CREATE OR REPLACE FUNCTION credit_hand_played(
  p_hand_id uuid,
  p_player_id text,
  p_game_mode text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  inserted int;
BEGIN
  INSERT INTO hand_played_credits (hand_id, player_id, game_mode)
  VALUES (p_hand_id, p_player_id, p_game_mode)
  ON CONFLICT (hand_id, player_id) DO NOTHING;

  GET DIAGNOSTICS inserted = ROW_COUNT;
  IF inserted = 0 THEN RETURN; END IF;

  UPDATE profiles
  SET lifetime_hands_played = lifetime_hands_played + 1
  WHERE id = p_player_id;

  IF NOT FOUND THEN
    DELETE FROM hand_played_credits
    WHERE hand_id = p_hand_id AND player_id = p_player_id;
    RAISE EXCEPTION 'profile % not found', p_player_id;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION credit_hand_played(uuid, text, text) TO anon, authenticated;

ALTER TABLE hand_played_credits ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS hand_played_credits_select ON hand_played_credits;
CREATE POLICY hand_played_credits_select ON hand_played_credits
  FOR SELECT TO anon, authenticated USING (true);
DROP POLICY IF EXISTS hand_played_credits_insert ON hand_played_credits;
CREATE POLICY hand_played_credits_insert ON hand_played_credits
  FOR INSERT TO anon, authenticated WITH CHECK (true);
GRANT SELECT, INSERT ON hand_played_credits TO anon, authenticated;

-- Scope private hole cards to a specific hand so eliminated players and stale rows
-- cannot surface the previous deal. Run in the Supabase SQL editor before testing
-- the updated client.

ALTER TABLE player_hole_cards
ADD COLUMN IF NOT EXISTS hand_id UUID;

-- Backfill is not required: the host deletes all room rows before each new deal.
-- New writes always include hand_id; fetches ignore rows with a NULL or mismatched hand_id.

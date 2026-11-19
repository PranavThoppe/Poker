-- Read-friendly Supabase views: keep profile IDs as the source of truth while
-- exposing the current profile display name next to every direct reference.
--
-- Run in Dashboard -> SQL Editor. This creates views only; it does not alter,
-- copy, or delete rows in the underlying tables.
--
-- Assumes the app's current table names:
--   profiles, game_rooms, player_hole_cards, game_intents, game_win_credits
-- If your Dashboard uses profile_hole_cards or intents instead, replace those
-- names below only after confirming they are the tables used by the deployed app.

create or replace view public.game_rooms_with_host_name
with (security_invoker = true) as
select
  gr.*,
  p.display_name as host_display_name
from public.game_rooms gr
left join public.profiles p on p.id = gr.host_id;

create or replace view public.player_hole_cards_with_profile_name
with (security_invoker = true) as
select
  phc.*,
  p.display_name as player_display_name
from public.player_hole_cards phc
left join public.profiles p on p.id = phc.player_id;

create or replace view public.game_intents_with_profile_name
with (security_invoker = true) as
select
  gi.*,
  p.display_name as player_display_name
from public.game_intents gi
left join public.profiles p on p.id = gi.player_id;

create or replace view public.game_win_credits_with_profile_name
with (security_invoker = true) as
select
  gwc.*,
  p.display_name as player_display_name
from public.game_win_credits gwc
left join public.profiles p on p.id = gwc.player_id;

-- If `security_invoker` is unavailable on your Postgres/Supabase version,
-- omit that option, then review RLS and permissions before exposing a view to
-- the app. For Dashboard inspection, leave access restricted to admins.

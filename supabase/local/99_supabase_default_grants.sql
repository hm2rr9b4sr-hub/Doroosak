-- LOCAL TESTING ONLY. Mirrors Supabase's default table grants so that
-- Row Level Security (not missing grants) is what limits each role in tests.
grant usage on schema public to anon, authenticated, service_role;
grant select, insert, update, delete on all tables in schema public to anon, authenticated, service_role;
grant usage, select on all sequences in schema public to anon, authenticated, service_role;

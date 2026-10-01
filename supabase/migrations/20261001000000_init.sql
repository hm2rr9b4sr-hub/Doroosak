-- Doroosak | دروسك — initial schema
--
-- Rules that hold across this file:
--   * Every instant is timestamptz (stored as UTC).
--   * Availability rules are LOCAL wall time + an IANA zone; they are turned
--     into instants only by get_available_slots(), per date, by Postgres's
--     IANA database. No fixed offsets anywhere.
--   * Money is integer minor units (cents) + ISO currency.
--   * Business-critical state (bookings, payments, ledger) is written only by
--     server functions; clients have no direct write access to it.
--   * The parent (guardian) is the account holder; a student is a child
--     profile that belongs to one or more guardians.

create extension if not exists btree_gist;

-- ───────────────────────── Enums ─────────────────────────
create type app_role       as enum ('guardian', 'teacher', 'admin', 'student');
create type teacher_status as enum ('pending', 'approved', 'rejected', 'suspended');
create type booking_status as enum ('held', 'pending_payment', 'confirmed', 'completed',
                                    'cancelled_by_guardian', 'cancelled_by_teacher',
                                    'no_show_student', 'no_show_teacher', 'expired', 'refunded');
create type request_status as enum ('submitted', 'in_review', 'matched', 'closed');
create type payment_status as enum ('requires_action', 'processing', 'succeeded', 'failed',
                                    'refunded', 'partially_refunded');

-- ───────────────────────── Settings ─────────────────────────
-- Every policy number lives here, editable by admin, never in code.
create table app_settings (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now()
);

insert into app_settings (key, value) values
  ('min_notice_minutes',       '720'),    -- 12 h before a lesson
  ('booking_horizon_days',     '28'),
  ('buffer_minutes',           '10'),     -- gap after each lesson for the teacher
  ('slot_step_minutes',        '30'),     -- slots start every 30 min inside a block
  ('hold_minutes',             '10'),     -- how long a slot is held during checkout
  ('lesson_lengths',           '[30, 60]'),
  ('cancel_full_refund_hours', '24'),
  ('join_early_minutes',       '10');

create function setting_int(p_key text) returns int
language sql stable set search_path = public as $$
  select (value #>> '{}')::int from app_settings where key = p_key
$$;

-- ───────────────────────── Timezones ─────────────────────────
create function is_valid_tz(tz text) returns boolean
language sql stable set search_path = public as $$
  select exists (select 1 from pg_timezone_names where name = tz)
$$;

-- ───────────────────────── Identity ─────────────────────────
-- One profile per signed-in adult (guardian, teacher, admin).
create table profiles (
  id           uuid primary key references auth.users on delete cascade,
  full_name    text not null,
  full_name_ar text,
  avatar_path  text,
  locale       text not null default 'ar' check (locale in ('ar', 'en')),
  timezone     text not null check (is_valid_tz(timezone)),   -- e.g. 'America/New_York'
  country_code text,
  created_at   timestamptz not null default now()
);

create table user_roles (
  user_id uuid references profiles on delete cascade,
  role    app_role not null,
  primary key (user_id, role)
);

-- A learner. Children have no login; a teen may later get one (user_id).
create table students (
  id           uuid primary key default gen_random_uuid(),
  display_name text not null,
  birth_year   int check (birth_year between 1990 and 2100),
  grade_level  text,
  timezone     text not null check (is_valid_tz(timezone)),
  user_id      uuid unique references auth.users on delete set null,
  created_at   timestamptz not null default now()
);

create table guardian_students (
  guardian_id  uuid references profiles on delete cascade,
  student_id   uuid references students on delete cascade,
  relationship text not null default 'parent',
  is_primary   boolean not null default true,
  created_at   timestamptz not null default now(),
  primary key (guardian_id, student_id)
);

create table teachers (
  id               uuid primary key references profiles on delete cascade,
  status           teacher_status not null default 'pending',
  bio_ar           text,
  bio_en           text,
  years_experience int check (years_experience >= 0),
  timezone         text not null default 'Asia/Aden' check (is_valid_tz(timezone)),
  rating_avg       numeric(3, 2),
  rating_count     int not null default 0,
  approved_at      timestamptz,
  approved_by      uuid references profiles
);

-- ───────────────────────── Catalog ─────────────────────────
create table subjects (
  id         uuid primary key default gen_random_uuid(),
  slug       text unique not null,
  name_ar    text not null,
  name_en    text not null,
  is_core    boolean not null default false,
  is_active  boolean not null default true,
  sort_order int not null default 0
);

insert into subjects (slug, name_ar, name_en, is_core, sort_order) values
  ('quran',           'القرآن الكريم',      'Quran',           true, 1),
  ('islamic-studies', 'التربية الإسلامية',  'Islamic Studies', true, 2),
  ('arabic',          'اللغة العربية',      'Arabic',          true, 3),
  ('english',         'اللغة الإنجليزية',   'English',         true, 4);

create table teacher_subjects (
  teacher_id uuid references teachers on delete cascade,
  subject_id uuid references subjects,
  levels     text[] not null default '{}',
  primary key (teacher_id, subject_id)
);

create table subject_requests (
  id                 uuid primary key default gen_random_uuid(),
  student_id         uuid not null references students on delete cascade,
  requested_by       uuid not null references profiles,
  subject_text       text not null,
  subject_id         uuid references subjects,
  grade_level        text,
  description        text not null,
  status             request_status not null default 'submitted',
  matched_teacher_id uuid references teachers,
  handled_by         uuid references profiles,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

-- ───────────────────────── Availability ─────────────────────────
-- Weekly blocks in the TEACHER'S wall time. weekday: 0 = Sunday … 6 = Saturday,
-- counted in the teacher's zone. A block crossing midnight is saved as two rules.
create table availability_rules (
  id          uuid primary key default gen_random_uuid(),
  teacher_id  uuid not null references teachers on delete cascade,
  weekday     smallint not null check (weekday between 0 and 6),
  start_local time not null,
  end_local   time not null,
  timezone    text not null check (is_valid_tz(timezone)),
  valid_from  date not null default current_date,
  valid_until date,
  check (end_local > start_local),
  check (valid_until is null or valid_until >= valid_from)
);
create index on availability_rules (teacher_id, weekday);

create table availability_exceptions (
  id         uuid primary key default gen_random_uuid(),
  teacher_id uuid not null references teachers on delete cascade,
  kind       text not null check (kind in ('blocked', 'extra')),
  starts_at  timestamptz not null,
  ends_at    timestamptz not null,
  reason     text,
  check (ends_at > starts_at)
);
create index on availability_exceptions (teacher_id, starts_at);

-- ───────────────────────── Pricing ─────────────────────────
create table price_list (
  id               uuid primary key default gen_random_uuid(),
  subject_id       uuid references subjects,     -- null = any subject
  teacher_id       uuid references teachers,     -- null = platform default
  duration_minutes int  not null check (duration_minutes > 0),
  currency         text not null default 'USD',
  student_price    int  not null check (student_price > 0),          -- cents
  platform_fee_bps int  not null check (platform_fee_bps between 0 and 10000),
  valid_from       timestamptz not null default now(),
  valid_until      timestamptz,
  is_active        boolean not null default true
);

-- ───────────────────────── Bookings ─────────────────────────
create table bookings (
  id              uuid primary key default gen_random_uuid(),
  student_id      uuid not null references students,
  booked_by       uuid not null references profiles,   -- the guardian who booked and pays
  teacher_id      uuid not null references teachers,
  subject_id      uuid not null references subjects,
  starts_at       timestamptz not null,
  ends_at         timestamptz not null,
  -- The interval the teacher is unavailable for: the lesson plus the buffer after it.
  blocked_range   tstzrange not null,
  status          booking_status not null default 'held',
  hold_expires_at timestamptz,
  -- Snapshots, so later edits never rewrite history.
  teacher_tz      text not null,
  student_tz      text not null,
  price_list_id   uuid references price_list,
  currency        text not null,
  amount_total    int  not null,
  platform_fee    int  not null,
  teacher_earning int  not null,
  cancel_reason   text,
  created_at      timestamptz not null default now(),
  check (ends_at > starts_at),
  check (lower(blocked_range) = starts_at and upper(blocked_range) >= ends_at),
  check (amount_total = platform_fee + teacher_earning)
);

-- THE double-booking guarantee. Enforced by Postgres itself: two active
-- bookings can never overlap for the same teacher (lesson + buffer) or for the
-- same student, however many devices press "Book" in the same second.
alter table bookings add constraint no_teacher_overlap
  exclude using gist (teacher_id with =, blocked_range with &&)
  where (status in ('held', 'pending_payment', 'confirmed'));

alter table bookings add constraint no_student_overlap
  exclude using gist (student_id with =, tstzrange(starts_at, ends_at) with &&)
  where (status in ('held', 'pending_payment', 'confirmed'));

create index on bookings (student_id, starts_at);
create index on bookings (teacher_id, starts_at);
create index on bookings (status, hold_expires_at);

-- ───────────────────────── Lessons ─────────────────────────
create table lessons (
  id                uuid primary key default gen_random_uuid(),
  booking_id        uuid unique not null references bookings on delete cascade,
  room_name         text unique not null,
  media_provider    text not null default 'livekit',
  teacher_joined_at timestamptz,
  student_joined_at timestamptz,
  started_at        timestamptz,
  ended_at          timestamptz,
  content_state     jsonb not null default '{}'   -- last synced Quran page/ayah, whiteboard ref
);

create table lesson_messages (
  id         bigint generated always as identity primary key,
  lesson_id  uuid not null references lessons on delete cascade,
  sender_id  uuid not null references auth.users,
  body       text not null check (length(body) between 1 and 4000),
  created_at timestamptz not null default now()
);

create table lesson_materials (
  id           uuid primary key default gen_random_uuid(),
  lesson_id    uuid references lessons on delete cascade,
  teacher_id   uuid not null references teachers,
  title        text not null,
  storage_path text,
  url          text,
  created_at   timestamptz not null default now(),
  check (storage_path is not null or url is not null)
);

-- ───────────────────────── Payments & ledger ─────────────────────────
create table payments (
  id             uuid primary key default gen_random_uuid(),
  booking_id     uuid references bookings,
  payer_id       uuid not null references profiles,
  provider       text not null default 'stripe',
  provider_ref   text unique,
  amount         int  not null check (amount > 0),
  currency       text not null,
  status         payment_status not null,
  raw_last_event jsonb,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create table ledger_accounts (
  id       uuid primary key default gen_random_uuid(),
  kind     text not null check (kind in ('provider_clearing', 'guardian_payable', 'platform_revenue',
                                         'teacher_payable', 'payout_clearing', 'credit_liability',
                                         'processing_fees', 'refunds')),
  owner_id uuid references profiles,   -- the teacher, for teacher_payable
  currency text not null,
  unique nulls not distinct (kind, owner_id, currency)
);

create table ledger_entries (
  id           bigint generated always as identity primary key,
  txn_id       uuid not null,            -- groups the balanced legs of one money movement
  account_id   uuid not null references ledger_accounts,
  amount       int  not null,            -- +debit / −credit, cents
  booking_id   uuid references bookings,
  payment_id   uuid references payments,
  kind         text not null,            -- 'charge' | 'fee' | 'earning' | 'refund' | 'payout'
  available_at timestamptz,              -- when a teacher earning becomes payable
  created_at   timestamptz not null default now()
);
create index on ledger_entries (txn_id);
create index on ledger_entries (account_id);

-- Each transaction's legs must sum to zero; checked at commit.
create function assert_ledger_balanced() returns trigger
language plpgsql set search_path = public as $$
begin
  if (select coalesce(sum(amount), 0) from ledger_entries where txn_id = new.txn_id) <> 0 then
    raise exception 'ledger transaction % is not balanced', new.txn_id using errcode = '23514';
  end if;
  return null;
end $$;

create constraint trigger ledger_balanced
  after insert or update on ledger_entries
  deferrable initially deferred
  for each row execute function assert_ledger_balanced();

-- Teacher payouts. At launch: manual remittance forwarded by a trusted person
-- in the US; the admin records each transfer here. A payout partner can
-- replace the method later with no ledger change.
create table payouts (
  id          uuid primary key default gen_random_uuid(),
  teacher_id  uuid not null references teachers,
  amount      int  not null check (amount > 0),
  currency    text not null default 'USD',
  method      text not null default 'manual_remittance',
  reference   text,
  paid_at     timestamptz not null,
  recorded_by uuid not null references profiles,
  created_at  timestamptz not null default now()
);

create table webhook_events (
  provider    text not null,
  event_id    text not null,
  received_at timestamptz not null default now(),
  primary key (provider, event_id)
);

create table reviews (
  booking_id uuid primary key references bookings,
  student_id uuid not null references students,
  teacher_id uuid not null references teachers,
  rating     smallint not null check (rating between 1 and 5),
  comment    text,
  created_at timestamptz not null default now()
);

-- ───────────────────────── Access helpers ─────────────────────────
create function is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from user_roles where user_id = auth.uid() and role = 'admin')
$$;

create function is_guardian_of(p_student uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from guardian_students where guardian_id = auth.uid() and student_id = p_student)
      or exists (select 1 from students where id = p_student and user_id = auth.uid())
$$;

create function teacher_has_student(p_student uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from bookings where teacher_id = auth.uid() and student_id = p_student)
$$;

create function is_lesson_participant(p_lesson uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from lessons l join bookings b on b.id = l.booking_id
    where l.id = p_lesson and (b.teacher_id = auth.uid() or is_guardian_of(b.student_id))
  )
$$;

-- Teachers can edit their profile but never approve themselves or set their rating.
create function protect_teacher_fields() returns trigger
language plpgsql set search_path = public as $$
begin
  if auth.uid() is not null and not is_admin()
     and (new.status is distinct from old.status
          or new.rating_avg is distinct from old.rating_avg
          or new.rating_count is distinct from old.rating_count
          or new.approved_at is distinct from old.approved_at
          or new.approved_by is distinct from old.approved_by) then
    raise exception 'only an admin can change status or rating' using errcode = '42501';
  end if;
  return new;
end $$;

create trigger teachers_protect before update on teachers
  for each row execute function protect_teacher_fields();

-- ───────────────────────── Slots ─────────────────────────
-- Core expansion, with no notice/horizon rules applied. Not callable by clients.
-- For each date as the TEACHER sees it, each rule on that weekday becomes a real
-- interval via `(date + local time) AT TIME ZONE rule_zone`, which applies the
-- IANA offset valid on that exact date. Slots are then stepped in real time.
create function compute_slots(
  p_teacher uuid, p_from timestamptz, p_to timestamptz, p_minutes int
) returns table (starts_at timestamptz, ends_at timestamptz)
language sql stable security definer set search_path = public as $$
  with t as (
    select id, timezone from teachers where id = p_teacher
  ),
  days as (
    select d::date as local_date
    from t, generate_series((p_from at time zone t.timezone)::date - 1,
                            (p_to   at time zone t.timezone)::date + 1,
                            interval '1 day') d
  ),
  -- DST edge (zones with daylight saving only; Asia/Aden has none):
  -- a wall time inside the spring-forward gap does not exist; Postgres moves it
  -- forward by the skipped hour. If that leaves a block ending before it starts,
  -- the block keeps its wall-clock length from the shifted start, so the week's
  -- lesson is moved, never lost. A fall-back (repeated) wall time resolves to
  -- one instant, so the lesson is never doubled.
  blocks as (
    select x.s as b_start,
           case when x.e <= x.s then x.s + (r.end_local - r.start_local) else x.e end as b_end
    from days dy
    join availability_rules r
      on r.teacher_id = p_teacher
     and r.weekday = extract(dow from dy.local_date)
     and dy.local_date >= r.valid_from
     and (r.valid_until is null or dy.local_date <= r.valid_until)
    cross join lateral (
      select ((dy.local_date + r.start_local) at time zone r.timezone) as s,
             ((dy.local_date + r.end_local)   at time zone r.timezone) as e
    ) x
    union all
    select e.starts_at, e.ends_at
    from availability_exceptions e
    where e.teacher_id = p_teacher and e.kind = 'extra'
  ),
  candidates as (
    select s as starts_at, s + make_interval(mins => p_minutes) as ends_at
    from blocks b,
         generate_series(b.b_start,
                         b.b_end - make_interval(mins => p_minutes),
                         make_interval(mins => setting_int('slot_step_minutes'))) s
  )
  select distinct c.starts_at, c.ends_at
  from candidates c
  where c.starts_at >= p_from
    and c.ends_at   <= p_to
    and not exists (
      select 1 from availability_exceptions e
      where e.teacher_id = p_teacher and e.kind = 'blocked'
        and tstzrange(e.starts_at, e.ends_at) && tstzrange(c.starts_at, c.ends_at))
    and not exists (
      select 1 from bookings bk
      where bk.teacher_id = p_teacher
        and bk.status in ('held', 'pending_payment', 'confirmed')
        and bk.blocked_range && tstzrange(c.starts_at, c.ends_at + make_interval(mins => setting_int('buffer_minutes'))))
  order by 1
$$;

revoke execute on function compute_slots(uuid, timestamptz, timestamptz, int) from public;

-- What clients call. Returns UTC instants only; each app formats them in its own zone.
create function get_available_slots(
  p_teacher uuid, p_from timestamptz, p_to timestamptz, p_minutes int default 30
) returns table (starts_at timestamptz, ends_at timestamptz)
language sql stable security definer set search_path = public as $$
  select s.starts_at, s.ends_at
  from teachers t,
       compute_slots(
         p_teacher,
         greatest(p_from, now() + make_interval(mins => setting_int('min_notice_minutes'))),
         least(p_to, now() + make_interval(days => setting_int('booking_horizon_days'))),
         p_minutes) s
  where t.id = p_teacher and t.status = 'approved'
$$;

-- ───────────────────────── Pricing ─────────────────────────
create function price_booking(p_teacher uuid, p_subject uuid, p_minutes int)
returns table (price_list_id uuid, currency text, amount_total int, platform_fee int, teacher_earning int)
language sql stable security definer set search_path = public as $$
  select p.id, p.currency, p.student_price,
         round(p.student_price * p.platform_fee_bps / 10000.0)::int,
         p.student_price - round(p.student_price * p.platform_fee_bps / 10000.0)::int
  from price_list p
  where p.is_active
    and p.duration_minutes = p_minutes
    and (p.teacher_id = p_teacher or p.teacher_id is null)
    and (p.subject_id = p_subject or p.subject_id is null)
    and p.valid_from <= now()
    and (p.valid_until is null or p.valid_until > now())
  order by (p.teacher_id is not null) desc, (p.subject_id is not null) desc, p.valid_from desc
  limit 1
$$;

-- ───────────────────────── Booking a slot ─────────────────────────
-- Places a short hold while the guardian pays. Re-checks everything server
-- side; the exclusion constraints make the final decision when two requests race.
create function create_booking_hold(
  p_student uuid, p_teacher uuid, p_subject uuid, p_starts_at timestamptz, p_minutes int
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_uid     uuid := auth.uid();
  v_ends    timestamptz := p_starts_at + make_interval(mins => p_minutes);
  v_teacher teachers%rowtype;
  v_student students%rowtype;
  v_price   record;
  v_id      uuid;
begin
  if v_uid is null or not is_guardian_of(p_student) then
    raise exception 'not allowed to book for this student' using errcode = '42501';
  end if;

  if not coalesce((select value from app_settings where key = 'lesson_lengths') @> to_jsonb(p_minutes), false) then
    raise exception 'lesson length % is not offered', p_minutes using errcode = '22023';
  end if;

  select * into v_teacher from teachers where id = p_teacher and status = 'approved';
  if not found then
    raise exception 'teacher is not available' using errcode = 'P0002';
  end if;

  if not exists (select 1 from teacher_subjects where teacher_id = p_teacher and subject_id = p_subject) then
    raise exception 'teacher does not teach this subject' using errcode = '22023';
  end if;

  -- Serialize holds per teacher so a racing second request waits, then sees the
  -- first one's booking and gets a clean 'slot_taken' (instead of a deadlock
  -- abort). The exclusion constraints remain the final guarantee.
  perform pg_advisory_xact_lock(hashtextextended(p_teacher::text, 0));

  if not exists (select 1 from get_available_slots(p_teacher, p_starts_at, v_ends, p_minutes) s
                 where s.starts_at = p_starts_at) then
    raise exception 'slot_taken' using errcode = 'DR001', hint = 'The time is no longer available.';
  end if;

  select * into v_price from price_booking(p_teacher, p_subject, p_minutes);
  if not found then
    raise exception 'no price configured' using errcode = 'P0002';
  end if;

  select * into v_student from students where id = p_student;

  begin
    insert into bookings (student_id, booked_by, teacher_id, subject_id, starts_at, ends_at,
                          blocked_range, status, hold_expires_at, teacher_tz, student_tz,
                          price_list_id, currency, amount_total, platform_fee, teacher_earning)
    values (p_student, v_uid, p_teacher, p_subject, p_starts_at, v_ends,
            tstzrange(p_starts_at, v_ends + make_interval(mins => setting_int('buffer_minutes'))),
            'held', now() + make_interval(mins => setting_int('hold_minutes')),
            v_teacher.timezone, v_student.timezone,
            v_price.price_list_id, v_price.currency, v_price.amount_total,
            v_price.platform_fee, v_price.teacher_earning)
    returning id into v_id;
  exception when exclusion_violation or deadlock_detected then
    raise exception 'slot_taken' using errcode = 'DR001', hint = 'Someone booked this time a moment ago.';
  end;

  return v_id;
end $$;

-- Frees slots whose checkout was never completed. Scheduled every minute.
create function expire_holds() returns int
language sql security definer set search_path = public as $$
  with x as (
    update bookings set status = 'expired'
    where status in ('held', 'pending_payment') and hold_expires_at < now()
    returning 1
  )
  select count(*)::int from x
$$;
revoke execute on function expire_holds() from public;

-- A guardian adds a child under their own account.
create function add_child(p_name text, p_birth_year int, p_grade text, p_timezone text)
returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if auth.uid() is null then
    raise exception 'sign in first' using errcode = '42501';
  end if;
  insert into students (display_name, birth_year, grade_level, timezone)
  values (p_name, p_birth_year, p_grade, p_timezone) returning id into v_id;
  insert into guardian_students (guardian_id, student_id) values (auth.uid(), v_id);
  insert into user_roles (user_id, role) values (auth.uid(), 'guardian') on conflict do nothing;
  return v_id;
end $$;

-- ───────────────────────── Row Level Security ─────────────────────────
alter table app_settings            enable row level security;
alter table profiles                enable row level security;
alter table user_roles              enable row level security;
alter table students                enable row level security;
alter table guardian_students       enable row level security;
alter table teachers                enable row level security;
alter table subjects                enable row level security;
alter table teacher_subjects        enable row level security;
alter table subject_requests        enable row level security;
alter table availability_rules      enable row level security;
alter table availability_exceptions enable row level security;
alter table price_list              enable row level security;
alter table bookings                enable row level security;
alter table lessons                 enable row level security;
alter table lesson_messages         enable row level security;
alter table lesson_materials        enable row level security;
alter table payments                enable row level security;
alter table ledger_accounts         enable row level security;
alter table ledger_entries          enable row level security;
alter table payouts                 enable row level security;
alter table webhook_events          enable row level security;
alter table reviews                 enable row level security;

create policy settings_read  on app_settings for select using (true);
create policy settings_admin on app_settings for all using (is_admin()) with check (is_admin());

create policy profiles_self   on profiles for select using (id = auth.uid() or is_admin());
create policy profiles_insert on profiles for insert with check (id = auth.uid());
create policy profiles_update on profiles for update using (id = auth.uid()) with check (id = auth.uid());
-- Teachers' public names are visible to everyone browsing teachers.
create policy profiles_teachers_public on profiles for select
  using (exists (select 1 from teachers t where t.id = profiles.id and t.status = 'approved'));

create policy roles_self on user_roles for select using (user_id = auth.uid() or is_admin());
create policy roles_admin on user_roles for all using (is_admin()) with check (is_admin());

create policy students_read on students for select
  using (is_guardian_of(id) or teacher_has_student(id) or is_admin());
create policy students_update on students for update
  using (is_guardian_of(id)) with check (is_guardian_of(id));

create policy guardian_links_read on guardian_students for select
  using (guardian_id = auth.uid() or is_admin());

create policy teachers_read on teachers for select
  using (status = 'approved' or id = auth.uid() or is_admin());
create policy teachers_apply on teachers for insert
  with check (id = auth.uid() and status = 'pending');
create policy teachers_update on teachers for update
  using (id = auth.uid() or is_admin()) with check (id = auth.uid() or is_admin());

create policy subjects_read  on subjects for select using (is_active or is_admin());
create policy subjects_admin on subjects for all using (is_admin()) with check (is_admin());

create policy teacher_subjects_read on teacher_subjects for select using (true);
create policy teacher_subjects_own  on teacher_subjects for all
  using (teacher_id = auth.uid() or is_admin()) with check (teacher_id = auth.uid() or is_admin());

create policy requests_read on subject_requests for select
  using (is_guardian_of(student_id) or matched_teacher_id = auth.uid() or is_admin());
create policy requests_create on subject_requests for insert
  with check (is_guardian_of(student_id) and requested_by = auth.uid() and status = 'submitted');
create policy requests_admin on subject_requests for update using (is_admin()) with check (is_admin());

create policy rules_own on availability_rules for all
  using (teacher_id = auth.uid() or is_admin()) with check (teacher_id = auth.uid() or is_admin());
create policy exceptions_own on availability_exceptions for all
  using (teacher_id = auth.uid() or is_admin()) with check (teacher_id = auth.uid() or is_admin());

create policy prices_read  on price_list for select using (is_active or is_admin());
create policy prices_admin on price_list for all using (is_admin()) with check (is_admin());

-- Bookings: read-only for people; all writes go through server functions.
create policy bookings_read on bookings for select
  using (is_guardian_of(student_id) or teacher_id = auth.uid() or is_admin());

create policy lessons_read on lessons for select using (is_lesson_participant(id) or is_admin());

create policy messages_read on lesson_messages for select
  using (is_lesson_participant(lesson_id) or is_admin());
create policy messages_send on lesson_messages for insert
  with check (sender_id = auth.uid() and is_lesson_participant(lesson_id));

create policy materials_read on lesson_materials for select
  using (teacher_id = auth.uid() or (lesson_id is not null and is_lesson_participant(lesson_id)) or is_admin());
create policy materials_own on lesson_materials for all
  using (teacher_id = auth.uid()) with check (teacher_id = auth.uid());

create policy payments_read on payments for select using (payer_id = auth.uid() or is_admin());

create policy ledger_accounts_admin on ledger_accounts for select using (is_admin());
create policy ledger_entries_admin  on ledger_entries  for select using (is_admin());

create policy payouts_read  on payouts for select using (teacher_id = auth.uid() or is_admin());
create policy payouts_admin on payouts for insert with check (is_admin() and recorded_by = auth.uid());

create policy reviews_read on reviews for select
  using (is_guardian_of(student_id) or teacher_id = auth.uid() or is_admin());
create policy reviews_write on reviews for insert
  with check (is_guardian_of(student_id)
              and exists (select 1 from bookings b where b.id = booking_id and b.status = 'completed'
                          and b.student_id = reviews.student_id and b.teacher_id = reviews.teacher_id));

-- ───────────────────────── Scheduled jobs (Supabase only) ─────────────────────────
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.schedule('expire-booking-holds', '* * * * *', 'select public.expire_holds()');
  end if;
end $$;

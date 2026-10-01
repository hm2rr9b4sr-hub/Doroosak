"""Shared fixtures for database tests.

Creates a throwaway database, applies the Supabase shim, every migration in
order, then Supabase's default grants. Tests run against real Postgres.

Connection settings come from the usual PG* environment variables
(defaults: host /tmp, user postgres).
"""
import json
import os
import pathlib
import uuid

import psycopg2
import psycopg2.extras
import pytest

ROOT = pathlib.Path(__file__).resolve().parents[1]
PGHOST = os.environ.get("PGHOST", "/tmp")
PGUSER = os.environ.get("PGUSER", "postgres")
PGPORT = os.environ.get("PGPORT", "5432")
PGPASSWORD = os.environ.get("PGPASSWORD")

psycopg2.extras.register_uuid()


def connect(dbname, autocommit=True):
    conn = psycopg2.connect(host=PGHOST, user=PGUSER, port=PGPORT, password=PGPASSWORD, dbname=dbname)
    conn.autocommit = autocommit
    return conn


@pytest.fixture(scope="session")
def dbname():
    name = f"doroosak_test_{uuid.uuid4().hex[:8]}"
    admin = connect("postgres")
    admin.cursor().execute(f'create database "{name}"')
    conn = connect(name)
    cur = conn.cursor()
    files = [ROOT / "local" / "00_supabase_shim.sql"]
    files += sorted((ROOT / "migrations").glob("*.sql"))
    files += [ROOT / "local" / "99_supabase_default_grants.sql"]
    for f in files:
        cur.execute(f.read_text())
    conn.close()
    yield name
    admin.cursor().execute(f'drop database "{name}" with (force)')
    admin.close()


@pytest.fixture()
def db(dbname):
    """A superuser connection (bypasses RLS) for arranging test data."""
    conn = connect(dbname)
    yield conn
    conn.close()


def as_user(conn, user_id):
    """Switch a connection to act as a signed-in Supabase user (RLS applies)."""
    cur = conn.cursor()
    cur.execute("reset role")
    cur.execute("select set_config('request.jwt.claims', %s, false)",
                (json.dumps({"sub": str(user_id), "role": "authenticated"}),))
    cur.execute("set role authenticated")
    return cur


# ───────────── Test data builders ─────────────

def make_user(cur, name, tz="America/New_York", roles=()):
    uid = uuid.uuid4()
    cur.execute("insert into auth.users (id, email) values (%s, %s)", (uid, f"{uid.hex[:6]}@test"))
    cur.execute("insert into profiles (id, full_name, timezone) values (%s, %s, %s)", (uid, name, tz))
    for r in roles:
        cur.execute("insert into user_roles (user_id, role) values (%s, %s)", (uid, r))
    return uid


def make_teacher(cur, name="Teacher", tz="Asia/Aden", subject="quran", price=2000, fee_bps=2000):
    uid = make_user(cur, name, tz, roles=("teacher",))
    cur.execute("insert into teachers (id, status, timezone) values (%s, 'approved', %s)", (uid, tz))
    cur.execute("insert into teacher_subjects (teacher_id, subject_id) "
                "select %s, id from subjects where slug = %s", (uid, subject))
    cur.execute("insert into price_list (teacher_id, duration_minutes, student_price, platform_fee_bps, valid_from) "
                "values (%s, 30, %s, %s, now() - interval '1 day'), (%s, 60, %s, %s, now() - interval '1 day')",
                (uid, price, fee_bps, uid, price * 2, fee_bps))
    return uid


def add_rule(cur, teacher, weekday, start, end, tz="Asia/Aden", valid_from="2020-01-01"):
    cur.execute("insert into availability_rules (teacher_id, weekday, start_local, end_local, timezone, valid_from) "
                "values (%s, %s, %s, %s, %s, %s)", (teacher, weekday, start, end, tz, valid_from))


def make_family(cur, parent_name="Parent", child_name="Child", tz="America/New_York"):
    parent = make_user(cur, parent_name, tz, roles=("guardian",))
    child = uuid.uuid4()
    cur.execute("insert into students (id, display_name, timezone) values (%s, %s, %s)", (child, child_name, tz))
    cur.execute("insert into guardian_students (guardian_id, student_id) values (%s, %s)", (parent, child))
    return parent, child


def subject_id(cur, slug="quran"):
    cur.execute("select id from subjects where slug = %s", (slug,))
    return cur.fetchone()[0]

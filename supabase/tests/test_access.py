"""Row Level Security and booking-function rules, tested as real signed-in users."""
from datetime import time

import psycopg2
import pytest

from conftest import add_rule, as_user, make_family, make_teacher, subject_id


@pytest.fixture()
def setup(db):
    cur = db.cursor()
    teacher = make_teacher(cur, price=2000, fee_bps=2000)
    for wd in range(7):
        add_rule(cur, teacher, wd, time(9, 0), time(22, 0))
    fam_a = make_family(cur, "Fatima", "Yusuf")
    fam_b = make_family(cur, "Nabil", "Layla")
    subj = subject_id(cur)
    cur.execute("select starts_at from get_available_slots(%s, now(), now() + interval '28 days', 30) limit 1",
                (teacher,))
    start = cur.fetchone()[0]
    return cur, teacher, fam_a, fam_b, subj, start


def test_parent_sees_only_own_children(db, setup):
    _, _, (pa, ca), (pb, cb), _, _ = setup
    cur = as_user(db, pa)
    cur.execute("select id from students")
    assert [r[0] for r in cur.fetchall()] == [ca]


def test_parent_cannot_book_for_someone_elses_child(db, setup):
    _, teacher, (pa, ca), (pb, cb), subj, start = setup
    cur = as_user(db, pa)
    with pytest.raises(psycopg2.errors.InsufficientPrivilege):
        cur.execute("select create_booking_hold(%s, %s, %s, %s, 30)", (cb, teacher, subj, start))


def test_parent_cannot_write_bookings_directly(db, setup):
    _, teacher, (pa, ca), _, subj, start = setup
    cur = as_user(db, pa)
    with pytest.raises(psycopg2.errors.InsufficientPrivilege):
        cur.execute("""insert into bookings (student_id, booked_by, teacher_id, subject_id, starts_at, ends_at,
                       blocked_range, teacher_tz, student_tz, currency, amount_total, platform_fee, teacher_earning)
                       values (%s, %s, %s, %s, %s, %s + interval '30 min', tstzrange(%s, %s + interval '40 min'),
                       'Asia/Aden', 'America/New_York', 'USD', 1, 0, 1)""",
                    (ca, pa, teacher, subj, start, start, start, start))


def test_booking_is_priced_by_server_and_hidden_from_other_parents(db, setup):
    _, teacher, (pa, ca), (pb, cb), subj, start = setup
    cur = as_user(db, pa)
    cur.execute("select create_booking_hold(%s, %s, %s, %s, 30)", (ca, teacher, subj, start))
    booking = cur.fetchone()[0]
    cur.execute("select amount_total, platform_fee, teacher_earning, student_tz, teacher_tz "
                "from bookings where id = %s", (booking,))
    assert cur.fetchone() == (2000, 400, 1600, "America/New_York", "Asia/Aden")

    cur = as_user(db, pb)
    cur.execute("select count(*) from bookings where id = %s", (booking,))
    assert cur.fetchone()[0] == 0

    cur = as_user(db, teacher)
    cur.execute("select count(*) from bookings where id = %s", (booking,))
    assert cur.fetchone()[0] == 1


def test_slot_inside_notice_period_is_rejected(db, setup):
    _, teacher, (pa, ca), _, subj, _ = setup
    cur = as_user(db, pa)
    with pytest.raises(psycopg2.Error) as e:
        cur.execute("select create_booking_hold(%s, %s, %s, date_trunc('hour', now()) + interval '2 hours', 30)",
                    (ca, teacher, subj))
    assert e.value.pgcode == "DR001"


def test_teacher_cannot_approve_themselves(db):
    cur = db.cursor()
    teacher = make_teacher(cur)
    cur.execute("update teachers set status = 'pending' where id = %s", (teacher,))
    cur = as_user(db, teacher)
    with pytest.raises(psycopg2.errors.InsufficientPrivilege):
        cur.execute("update teachers set status = 'approved' where id = %s", (teacher,))


def test_pending_teacher_is_hidden_and_unbookable(db, setup):
    cur, teacher, (pa, ca), _, subj, start = setup
    cur.execute("update teachers set status = 'pending' where id = %s", (teacher,))
    c = as_user(db, pa)
    c.execute("select count(*) from teachers where id = %s", (teacher,))
    assert c.fetchone()[0] == 0
    c.execute("select count(*) from get_available_slots(%s, now(), now() + interval '28 days', 30)", (teacher,))
    assert c.fetchone()[0] == 0


def test_add_child_links_to_parent(db):
    from conftest import make_user
    cur = db.cursor()
    parent = make_user(cur, "Sara")
    c = as_user(db, parent)
    c.execute("select add_child('Omar', 2018, 'Grade 2', 'America/Los_Angeles')")
    child = c.fetchone()[0]
    c.execute("select display_name from students")
    assert c.fetchall() == [("Omar",)]
    c.execute("select count(*) from guardian_students where student_id = %s", (child,))
    assert c.fetchone()[0] == 1


def test_ledger_must_balance(db):
    cur = db.cursor()
    cur.execute("insert into ledger_accounts (kind, currency) values ('provider_clearing','USD'), "
                "('platform_revenue','USD') returning id")
    a, b = [r[0] for r in cur.fetchall()]
    db.autocommit = False
    cur.execute("insert into ledger_entries (txn_id, account_id, amount, kind) "
                "values (gen_random_uuid(), %s, 2000, 'charge')", (a,))
    with pytest.raises(psycopg2.errors.CheckViolation):
        db.commit()
    db.rollback()
    cur.execute("insert into ledger_entries (txn_id, account_id, amount, kind) values "
                "('00000000-0000-0000-0000-000000000001', %s, 2000, 'charge'), "
                "('00000000-0000-0000-0000-000000000001', %s, -2000, 'charge')", (a, b))
    db.commit()
    db.autocommit = True

"""Double-booking must be impossible, enforced by the database.

These tests use separate real connections that race each other. They never
rely on the app checking first.
"""
import threading
from datetime import datetime, time, timedelta, timezone

import psycopg2
import pytest

from conftest import add_rule, as_user, connect, make_family, make_teacher, subject_id

UTC = timezone.utc
RUNS = 100


def next_slot(cur, teacher, minutes=30, offset=0):
    cur.execute("select starts_at from get_available_slots(%s, now(), now() + interval '28 days', %s) "
                "offset %s limit 1", (teacher, minutes, offset))
    row = cur.fetchone()
    assert row, "no available slot to test with"
    return row[0]


def race(dbname, jobs):
    """Run each job on its own connection, released at the same instant.
    Returns a list of 'ok' / error-code strings."""
    barrier = threading.Barrier(len(jobs))
    results = [None] * len(jobs)

    def run(i, job):
        conn = connect(dbname, autocommit=False)
        try:
            cur = conn.cursor()
            job.setup(cur)
            barrier.wait()
            job.go(cur)
            conn.commit()
            results[i] = "ok"
        except psycopg2.Error as e:
            conn.rollback()
            results[i] = e.pgcode
        finally:
            conn.close()

    threads = [threading.Thread(target=run, args=(i, j)) for i, j in enumerate(jobs)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    return results


class RawInsert:
    """Writes the booking row directly, skipping every app-level check.
    Proves the constraint alone is enough."""
    def __init__(self, student, parent, teacher, subj, start, minutes=30):
        self.args = (student, parent, teacher, subj, start, minutes)

    def setup(self, cur):
        pass

    def go(self, cur):
        student, parent, teacher, subj, start, minutes = self.args
        end = start + timedelta(minutes=minutes)
        cur.execute("""
            insert into bookings (student_id, booked_by, teacher_id, subject_id, starts_at, ends_at,
                                  blocked_range, status, teacher_tz, student_tz, currency,
                                  amount_total, platform_fee, teacher_earning)
            values (%s, %s, %s, %s, %s, %s, tstzrange(%s, %s), 'held', 'Asia/Aden',
                    'America/New_York', 'USD', 2000, 400, 1600)
        """, (student, parent, teacher, subj, start, end, start, end + timedelta(minutes=10)))


class HoldAsParent:
    """The real path a phone takes: create_booking_hold() as the signed-in parent."""
    def __init__(self, parent, student, teacher, subj, start, minutes=30):
        self.parent = parent
        self.args = (student, teacher, subj, start, minutes)

    def setup(self, cur):
        as_user(cur.connection, self.parent)

    def go(self, cur):
        cur.execute("select create_booking_hold(%s, %s, %s, %s, %s)", self.args)


@pytest.fixture()
def world(db):
    cur = db.cursor()
    teacher = make_teacher(cur)
    for wd in range(7):
        add_rule(cur, teacher, wd, time(9, 0), time(22, 0))
    families = [make_family(cur, f"Parent {i}", f"Child {i}") for i in range(2)]
    return cur, teacher, families, subject_id(cur)


def active_bookings(cur, teacher, start):
    cur.execute("select count(*) from bookings where teacher_id = %s and starts_at = %s "
                "and status in ('held','pending_payment','confirmed')", (teacher, start))
    return cur.fetchone()[0]


# When two raw inserts collide, Postgres rejects the loser either through the
# exclusion constraint (23P01) or, if both were already waiting on each other,
# through deadlock detection (40P01). Either way it is never two rows.
REJECTED = {"23P01", "40P01"}


def exactly_one_wins(results):
    return results.count("ok") == 1 and all(r in REJECTED for r in results if r != "ok")


def test_same_slot_raw_inserts_race(dbname, world):
    """Two connections insert the same teacher slot at the same moment, 100 times.
    Every time: exactly one commits, the other is rejected by the database."""
    cur, teacher, ((p1, c1), (p2, c2)), subj = world
    for i in range(RUNS):
        start = datetime(2027, 1, 4, 9, 0, tzinfo=UTC) + timedelta(hours=i)
        results = race(dbname, [RawInsert(c1, p1, teacher, subj, start),
                                RawInsert(c2, p2, teacher, subj, start)])
        assert exactly_one_wins(results), f"run {i}: {results}"
        assert active_bookings(cur, teacher, start) == 1


def test_many_parents_same_slot_raw(dbname, db):
    """Eight connections race for one slot, 50 times: still exactly one."""
    cur = db.cursor()
    teacher = make_teacher(cur)
    subj = subject_id(cur)
    fams = [make_family(cur, f"P{i}", f"C{i}") for i in range(8)]
    for i in range(50):
        start = datetime(2027, 2, 1, 9, 0, tzinfo=UTC) + timedelta(hours=i)
        results = race(dbname, [RawInsert(c, p, teacher, subj, start) for p, c in fams])
        assert exactly_one_wins(results), f"run {i}: {results}"
        assert active_bookings(cur, teacher, start) == 1


def test_same_slot_two_parents_via_app_function(dbname, world):
    """Two parents press Book on the same slot in the same instant through the
    real booking function, 100 times. Exactly one hold is created each time;
    the loser gets the friendly 'slot_taken' error (DR001)."""
    cur, teacher, ((p1, c1), (p2, c2)), subj = world
    for i in range(RUNS):
        start = next_slot(cur, teacher)
        results = race(dbname, [HoldAsParent(p1, c1, teacher, subj, start),
                                HoldAsParent(p2, c2, teacher, subj, start)])
        assert sorted(results) == ["DR001", "ok"], f"run {i}: {results}"
        assert active_bookings(cur, teacher, start) == 1
        cur.execute("update bookings set status = 'expired' where teacher_id = %s", (teacher,))


def test_many_parents_same_slot_via_app_function(dbname, db):
    """Eight parents press Book on one slot at once, 50 times: one hold,
    seven clean 'slot_taken' answers, never a raw database error."""
    cur = db.cursor()
    teacher = make_teacher(cur)
    for wd in range(7):
        add_rule(cur, teacher, wd, time(9, 0), time(22, 0))
    subj = subject_id(cur)
    fams = [make_family(cur, f"P{i}", f"C{i}") for i in range(8)]
    for i in range(50):
        start = next_slot(cur, teacher)
        results = race(dbname, [HoldAsParent(p, c, teacher, subj, start) for p, c in fams])
        assert results.count("ok") == 1 and results.count("DR001") == 7, f"run {i}: {results}"
        assert active_bookings(cur, teacher, start) == 1
        cur.execute("update bookings set status = 'expired' where teacher_id = %s", (teacher,))


def test_overlapping_but_different_slots_race(dbname, world):
    """9:00–9:30 and 9:15–9:45 overlap; they also can't both commit."""
    cur, teacher, ((p1, c1), (p2, c2)), subj = world
    for i in range(RUNS):
        a = datetime(2027, 3, 1, 9, 0, tzinfo=UTC) + timedelta(hours=i)
        b = a + timedelta(minutes=15)
        results = race(dbname, [RawInsert(c1, p1, teacher, subj, a),
                                RawInsert(c2, p2, teacher, subj, b)])
        assert exactly_one_wins(results), f"run {i}: {results}"


def test_buffer_after_lesson_is_enforced(db, world):
    """A lesson ending 9:30 blocks the teacher until 9:40 (10-min buffer)."""
    cur, teacher, ((p1, c1), (p2, c2)), subj = world
    a = datetime(2027, 6, 1, 9, 0, tzinfo=UTC)
    RawInsert(c1, p1, teacher, subj, a).go(cur)
    with pytest.raises(psycopg2.errors.ExclusionViolation):
        RawInsert(c2, p2, teacher, subj, a + timedelta(minutes=30)).go(cur)   # 9:30, inside buffer
    RawInsert(c2, p2, teacher, subj, a + timedelta(minutes=40)).go(cur)       # 9:40, allowed


def test_back_to_back_without_overlap_both_succeed(dbname, world):
    """Control: two non-overlapping slots racing must BOTH succeed."""
    cur, teacher, ((p1, c1), (p2, c2)), subj = world
    a = datetime(2027, 9, 1, 9, 0, tzinfo=UTC)
    results = race(dbname, [RawInsert(c1, p1, teacher, subj, a),
                            RawInsert(c2, p2, teacher, subj, a + timedelta(minutes=40))])
    assert results == ["ok", "ok"]


def test_same_child_cannot_be_in_two_lessons(db):
    """A child can't be booked with two different teachers at the same time."""
    cur = db.cursor()
    t1, t2 = make_teacher(cur, "T1"), make_teacher(cur, "T2")
    parent, child = make_family(cur)
    subj = subject_id(cur)
    a = datetime(2027, 6, 2, 9, 0, tzinfo=UTC)
    RawInsert(child, parent, t1, subj, a).go(cur)
    with pytest.raises(psycopg2.errors.ExclusionViolation):
        RawInsert(child, parent, t2, subj, a).go(cur)


def test_expired_hold_frees_the_slot(db, world):
    cur, teacher, ((p1, c1), (p2, c2)), subj = world
    start = next_slot(cur, teacher)
    as_user(db, p1).execute("select create_booking_hold(%s, %s, %s, %s, 30)", (c1, teacher, subj, start))
    cur.execute("reset role")
    cur.execute("update bookings set hold_expires_at = now() - interval '1 second' where teacher_id = %s", (teacher,))
    cur.execute("select expire_holds()")
    assert cur.fetchone()[0] == 1
    as_user(db, p2).execute("select create_booking_hold(%s, %s, %s, %s, 30)", (c2, teacher, subj, start))
    cur.execute("reset role")
    assert active_bookings(cur, teacher, start) == 1

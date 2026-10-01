"""Timezone correctness, checked against the IANA database itself.

No test here encodes "before / after November". Each case stores only the
inputs a real booking has — teacher_timezone, student_timezone, lesson_time,
date — and the expected answer is computed by an independent IANA
implementation (Python's zoneinfo). Postgres must agree with it everywhere.
"""
from datetime import date, datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo

import pytest

from conftest import add_rule, make_teacher

UTC = timezone.utc

TEACHER_ZONES = [
    "Asia/Aden",         # launch market: no DST
    "Europe/London",     # future countries: zones WITH daylight saving, to prove rules
    "America/New_York",  #   expand correctly when the teacher's own clock changes
]

STUDENT_ZONES = [
    "America/New_York", "America/Chicago", "America/Denver", "America/Phoenix",
    "America/Los_Angeles", "America/Anchorage", "Pacific/Honolulu",
    "Europe/London", "Asia/Riyadh",
]

LESSON_TIMES = [time(0, 30), time(6, 0), time(12, 30), time(17, 45), time(23, 0)]

WINDOW_START = datetime(2026, 10, 1, tzinfo=UTC)
WINDOW_END = datetime(2028, 10, 1, tzinfo=UTC)   # 24 months, 4 DST changes each side
LESSON_MIN = 30


def dow(d: date) -> int:
    """Postgres weekday numbering: Sunday = 0 … Saturday = 6."""
    return (d.weekday() + 1) % 7


def is_clean_local_time(local: datetime, tz: ZoneInfo) -> bool:
    """False for wall times that don't exist (spring-forward gap) or happen
    twice (fall-back overlap) in that zone. Those are covered separately."""
    a = local.replace(tzinfo=tz, fold=0)
    b = local.replace(tzinfo=tz, fold=1)
    if a.utcoffset() != b.utcoffset():
        return False
    return a.astimezone(UTC).astimezone(tz).replace(tzinfo=None) == local


def oracle_slots(teacher_tz, start_local, end_local, weekday):
    """Expected slots for one weekly rule, computed with zoneinfo only."""
    tz = ZoneInfo(teacher_tz)
    out = []
    d = WINDOW_START.astimezone(tz).date() - timedelta(days=1)
    last = WINDOW_END.astimezone(tz).date() + timedelta(days=1)
    while d <= last:
        if dow(d) == weekday:
            b_start = datetime.combine(d, start_local).replace(tzinfo=tz).astimezone(UTC)
            b_end = datetime.combine(d, end_local).replace(tzinfo=tz).astimezone(UTC)
            s = b_start
            while s + timedelta(minutes=LESSON_MIN) <= b_end:
                if s >= WINDOW_START and s + timedelta(minutes=LESSON_MIN) <= WINDOW_END:
                    out.append(s)
                s += timedelta(minutes=30)
        d += timedelta(days=1)
    return out


@pytest.mark.parametrize("teacher_tz", TEACHER_ZONES)
@pytest.mark.parametrize("lesson_time", LESSON_TIMES, ids=lambda t: t.strftime("%H%M"))
def test_rule_expansion_matches_iana(db, teacher_tz, lesson_time):
    cur = db.cursor()
    teacher = make_teacher(cur, tz=teacher_tz)
    weekday = 6  # Saturday in the teacher's zone
    end = (datetime.combine(date(2000, 1, 1), lesson_time) + timedelta(minutes=LESSON_MIN)).time()
    if end <= lesson_time:      # a block crossing midnight is stored as two rules; keep this one simple
        end = time(23, 59, 59)
    add_rule(cur, teacher, weekday, lesson_time, end, tz=teacher_tz)

    cur.execute("select starts_at from compute_slots(%s, %s, %s, %s)",
                (teacher, WINDOW_START, WINDOW_END, LESSON_MIN))
    got = [r[0] for r in cur.fetchall()]

    tz = ZoneInfo(teacher_tz)
    expected = oracle_slots(teacher_tz, lesson_time, end, weekday)
    # Compare only dates where the wall time is unambiguous; DST edge
    # behaviour has its own test below.
    clean = lambda s: is_clean_local_time(s.astimezone(tz).replace(tzinfo=None), tz)
    got_clean = [s for s in got if clean(s)]
    exp_clean = [s for s in expected if clean(s)]

    assert len(exp_clean) > 90, "expected ~104 Saturdays in 24 months"
    assert got_clean == exp_clean


@pytest.mark.parametrize("student_tz", STUDENT_ZONES)
def test_student_sees_correct_local_time(db, student_tz):
    """Every slot, shown in the student's zone by Postgres, matches zoneinfo,
    and converting back gives the exact original instant (round trip)."""
    cur = db.cursor()
    teacher = make_teacher(cur)
    for wd in range(7):
        add_rule(cur, teacher, wd, time(12, 0), time(14, 0))

    cur.execute("""
        select starts_at, (starts_at at time zone %s)
        from compute_slots(%s, %s, %s, %s)
    """, (student_tz, teacher, WINDOW_START, WINDOW_END, LESSON_MIN))
    rows = cur.fetchall()
    assert len(rows) > 2500

    tz = ZoneInfo(student_tz)
    for utc_instant, pg_local in rows:
        py_local = utc_instant.astimezone(tz).replace(tzinfo=None)
        assert pg_local == py_local, f"{utc_instant} in {student_tz}"
        back = py_local.replace(tzinfo=tz, fold=0)
        if is_clean_local_time(py_local, tz):
            assert back.astimezone(UTC) == utc_instant


def test_spec_example_aden_to_new_york(db):
    """The example from the product spec, as documentation. Inputs only;
    the expected values below are produced by zoneinfo, not typed in."""
    cur = db.cursor()
    teacher = make_teacher(cur)
    add_rule(cur, teacher, 6, time(12, 30), time(13, 0))   # Saturdays 12:30 in Aden

    ny = ZoneInfo("America/New_York")
    aden = ZoneInfo("Asia/Aden")
    for d in (date(2026, 10, 24), date(2026, 11, 7)):
        start = datetime.combine(d, time(0, 0), aden).astimezone(UTC)
        cur.execute("select starts_at, (starts_at at time zone 'America/New_York')::time "
                    "from compute_slots(%s, %s, %s, 30)", (teacher, start, start + timedelta(days=1)))
        (utc_instant, ny_time), = cur.fetchall()
        expected = datetime.combine(d, time(12, 30), aden).astimezone(ny).time()
        assert ny_time == expected
        print(f"{d}: 12:30 Aden -> {ny_time.strftime('%I:%M %p')} New York")


def test_dst_gap_and_overlap_policy(db):
    """Teacher in a DST zone with a rule inside the spring-forward gap
    (01:30 on the last Sunday of March in London) and the fall-back overlap.
    Policy: the slot still exists exactly once per week; it is never dropped
    or doubled. (Asia/Aden has no DST, so launch teachers never hit this.)"""
    cur = db.cursor()
    teacher = make_teacher(cur, tz="Europe/London")
    add_rule(cur, teacher, 0, time(1, 30), time(2, 0), tz="Europe/London")  # Sundays 01:30
    cur.execute("select starts_at from compute_slots(%s, %s, %s, 30)",
                (teacher, datetime(2027, 3, 1, tzinfo=UTC), datetime(2027, 11, 30, tzinfo=UTC)))
    got = [r[0] for r in cur.fetchall()]
    london = ZoneInfo("Europe/London")
    sundays = {s.astimezone(london).date() for s in got}
    assert len(got) == len(sundays), "a Sunday got two slots"
    expected_sundays = {d for d in (date(2027, 3, 1) + timedelta(days=i) for i in range(275)) if dow(d) == 0}
    assert sundays == expected_sundays, "a Sunday lost its slot"
    # On the spring-forward Sunday, 01:30 doesn't exist: the lesson moves
    # forward by the skipped hour to 02:30 local, exactly like calendar apps.
    gap_day = [s.astimezone(london) for s in got if s.astimezone(london).date() == date(2027, 3, 28)]
    assert [s.time() for s in gap_day] == [time(2, 30)]
    # On the fall-back Sunday, 01:30 happens twice: still one lesson.
    overlap_day = [s for s in got if s.astimezone(london).date() == date(2027, 10, 31)]
    assert len(overlap_day) == 1

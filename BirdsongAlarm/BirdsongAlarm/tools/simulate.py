#!/usr/bin/env python3
"""Simulate years of daily use of the Birdsong alarm engine.

This is a model, not the real app: the Swift scheduling logic is re-written
here in Python and driven by a simulated iPhone (system alarms, app being
suspended or killed, time-zone travel, weekly re-signing) and a simulated
owner. It checks, morning by morning, whether an alarm rang at the right
local time with the right bird.

    python3 tools/simulate.py                # 1,000 days, both engines, 3 owner types
    python3 tools/simulate.py --days 3650 --seeds 20

Engines:
    old  the first design: a queue of 7 one-time alarms, plus silent audio to stay awake
    new  the current Swift code: weekly-repeating, self-healing alarms; the app
         never keeps itself awake, so everything depends on the system alarm
"""
import argparse
import hashlib
import random
from collections import Counter
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

UTC = timezone.utc
HOME_TZ = "America/Chicago"
TRIP_ZONES = ["America/Denver", "America/Los_Angeles", "America/New_York", "Europe/London"]
START = date(2026, 10, 12)
N_BIRDS = 20
LEAD = timedelta(seconds=60)
LATE = timedelta(hours=3)
KEEPALIVE_WINDOW = timedelta(hours=12)

# How the simulated phone misbehaves (assumptions, per event or per day).
P_SCHEDULE_FAILS = 0.01       # one AlarmKit schedule call is refused
P_CRASH_MID_ARM = 0.003       # app dies between cancelling and re-adding alarms
P_KILL_SUSPENDED = 0.35       # iOS evicts a suspended app overnight
P_KILL_KEEPALIVE = 0.04       # iOS kills the app even though it plays silent audio
P_REBOOT = 0.01
P_FORCE_QUIT = 0.04           # owner swipes the app away
P_INTENT_LAUNCHES = 0.97      # Stop on the lock screen manages to wake a dead app
P_STILL_ALERTING = 0.2        # alarm still marked "ringing" when the stop handler runs
P_TRIP_STARTS = 0.011
P_TIME_CHANGE = 0.01
P_DISABLE = 0.004
P_RESIGN_ON_TIME = 0.85
ALARM_TIMES = [(5, 30), (6, 0), (6, 30), (7, 0), (7, 45), (8, 15)]

PERSONAS = {
    # how the owner reacts each morning, and how often they open the app otherwise
    "Engaged (opens the app most days)":
        dict(meet=0.60, early=0.10, evening=0.50, midday=0.30, after_resign=0.9),
    "Mixed (mostly taps Stop)":
        dict(meet=0.25, early=0.05, evening=0.15, midday=0.15, after_resign=0.7),
    "Sleeper (taps Stop, almost never opens the app)":
        dict(meet=0.02, early=0.00, evening=0.02, midday=0.03, after_resign=0.5),
}


# ---------------------------------------------------------------- shuffle deck
MASK = (1 << 64) - 1


def _next(state):
    state[0] = (state[0] + 0x9E3779B97F4A7C15) & MASK
    z = state[0]
    z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) & MASK
    z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) & MASK
    return z ^ (z >> 31)


_ORDERS = {}


def deck_order(count, rnd):
    """Python port of ShuffleDeck.order (see Sources/Models/ShuffleDeck.swift)."""
    seed = lambda r: [(r * 0x9E3779B97F4A7C15 + 0xB5AD4ECEDA1CE2A9) & MASK]
    known = _ORDERS.setdefault(count, [])
    if not known:
        cur, st, i = list(range(count)), seed(0), count - 1
        while i > 0:
            j = _next(st) % (i + 1)
            cur[i], cur[j] = cur[j], cur[i]
            i -= 1
        known.append(cur)
    gap = min(count, max(2, count // 2))
    while len(known) <= rnd:
        prev, st = known[-1], seed(len(known))
        last = {b: p for p, b in enumerate(prev)}
        remaining, new = list(range(count)), []
        for p in range(count):
            eligible = [b for b in remaining if (count - last[b]) + p >= gap]
            pick = eligible[_next(st) % len(eligible)]
            new.append(pick)
            remaining.remove(pick)
        known.append(new)
    return known[rnd]


def day_number(d):
    return (d - date(2026, 1, 1)).days


def deck_bird(d):
    n = max(day_number(d), 0)
    return deck_order(N_BIRDS, n // N_BIRDS)[n % N_BIRDS]


# ---------------------------------------------------------------- the phone
class World:
    def __init__(self, seed, persona, engine_cls):
        self.erng = random.Random(seed ^ 0x5EED)     # engine-side luck: refused calls, crashes, ids
        self.p = persona
        self.tz = ZoneInfo(HOME_TZ)
        self.now = None
        self.alarms = {}          # id -> dict(kind, at, bird, created, alerting)
        self.defaults = {}        # survives the app being killed
        self.proc = "dead"        # dead | suspended | alive (silent audio keeps it running)
        self.crashed = False
        self.sig_ok = True
        self.alive_since = None
        self.alive_hours = 0.0
        self.stats = Counter()
        self.heard = []           # (day index, bird) for on-time rings
        self.engine = engine_cls(self)

    # --- helpers
    def at(self, d, h, m, s=0):
        return datetime(d.year, d.month, d.day, h, m, s, tzinfo=self.tz).astimezone(UTC)

    def local(self, instant=None):
        return (instant or self.now).astimezone(self.tz)

    # --- AlarmKit, as the engine sees it
    def ak_schedule(self, alarm_id, kind, at, bird):
        if self.erng.random() < P_SCHEDULE_FAILS:
            self.stats["schedule calls refused"] += 1
            return False
        self.alarms[alarm_id] = dict(kind=kind, at=at, bird=bird, created=self.now, alerting=False)
        return True

    def ak_cancel(self, alarm_id):
        self.alarms.pop(alarm_id, None)

    def crash(self):
        self.crashed = True
        self.stats["crashes mid-update"] += 1

    # --- app process
    def set_proc(self, state):
        if self.proc == "alive" and state != "alive" and self.alive_since:
            self.alive_hours += (self.now - self.alive_since).total_seconds() / 3600
            self.alive_since = None
        if state == "alive" and self.proc != "alive":
            self.alive_since = self.now
        self.proc = state

    def ensure_running(self):
        if not self.sig_ok:
            return False
        if self.proc == "dead":
            self.set_proc("suspended")
            self.engine.memory_reset()
            self.engine.on_launch()
        return True

    def settle(self, from_foreground=False):
        """Decide what state the app is left in after an event."""
        if self.crashed:
            self.crashed = False
            self.set_proc("dead")
        elif self.proc == "dead":
            return
        elif self.engine.keepalive_wanted() and (from_foreground or self.proc == "alive"):
            self.set_proc("alive")      # silent audio can only be started from the foreground
        else:
            self.set_proc("suspended")

    # --- owner actions
    def open_app(self):
        if not self.ensure_running():
            self.stats["could not open app (signature expired)"] += 1
            return False
        self.engine.on_foreground()
        card = self.engine.card
        if card:
            bird, fire = card
            if self.now - fire > LATE + timedelta(minutes=1):
                self.stats["stale bird card shown"] += 1
            if bird != deck_bird(self.local(fire).date()):
                self.stats["wrong bird on card"] += 1
        return True

    def tap_stop(self, alarm_id, r_still, r_launch):
        """Stop on the lock screen. Runs a short handler inside the app."""
        still = r_still < P_STILL_ALERTING
        alarm = self.alarms.get(alarm_id)
        if alarm and not still:
            self.finish_ring(alarm_id)
        if self.sig_ok and (self.proc != "dead" or r_launch < P_INTENT_LAUNCHES):
            self.ensure_running()
            self.engine.on_stop_intent(alarm_id)
            if still:
                self.finish_ring(alarm_id)
                self.engine.retry()
        elif still:
            self.finish_ring(alarm_id)
        self.settle()

    def finish_ring(self, alarm_id):
        alarm = self.alarms.get(alarm_id)
        if not alarm:
            return
        alarm["alerting"] = False
        if alarm["kind"] == "fixed":
            del self.alarms[alarm_id]       # one-time alarms are used up

    # --- system: which alarm rings next today
    def next_ring(self, d, after, day_end):
        best = None
        for alarm_id, a in self.alarms.items():
            if a["kind"] == "fixed":
                t = a["at"]
            else:
                wd, h, m = a["at"]
                if d.weekday() != wd:
                    continue
                t = self.at(d, h, m)
                if a["created"] >= t:
                    continue
            if after < t < day_end and (best is None or t < best[0]):
                best = (t, alarm_id)
        return best


# ---------------------------------------------------------------- old engine
class OldEngine:
    """Queue of 7 one-time alarms, rebuilt from scratch on every dismissal."""
    name = "old"

    def __init__(self, world):
        self.w = world
        self.memory_reset()

    def memory_reset(self):
        self.active = None
        self.card = None

    @property
    def d(self):
        return self.w.defaults

    def keepalive_wanted(self):
        return bool(self.d.get("enabled") and self.d.get("leadin", True))

    def on_launch(self):
        if not self.d.get("enabled"):
            return
        if not self.d.get("plan"):
            self.arm()
        else:
            self.check_due()

    def on_foreground(self):
        if not self.d.get("enabled"):
            return
        self.check_due()
        upcoming = sum(1 for e in self.d.get("plan", []) if e["fire"] > self.w.now)
        if self.card is None and upcoming <= 3:
            self.arm()
        else:
            keep = {e["id"] for e in self.d.get("plan", [])}
            for alarm_id in list(self.w.alarms):
                if alarm_id not in keep:
                    self.w.ak_cancel(alarm_id)

    def on_stop_intent(self, alarm_id):
        self.d["stopped"] = alarm_id

    def retry(self):
        pass

    def on_dismiss(self):
        entry = self.active
        if entry:
            self.w.ak_cancel(entry["id"])
        self.card = None
        self.active = None
        if self.d.get("enabled"):
            self.arm(after=max(self.w.now, entry["fire"] + timedelta(seconds=60)) if entry else None)

    def tick(self):
        self.check_due()

    def check_due(self):
        if not self.d.get("enabled"):
            return
        lead = LEAD if self.d.get("leadin", True) else timedelta(0)
        due = [e for e in self.d.get("plan", []) if self.w.now >= e["fire"] - lead]
        if not due:
            return
        due = due[-1]
        if self.active and due["id"] == self.active["id"]:
            return
        if self.w.now - due["fire"] <= LATE:
            self.active = due
            self.card = (due["bird"], due["fire"])
        elif self.card is None:
            self.arm()

    def arm(self, after=None):
        w = self.w
        after = after or w.now
        h, m = self.d["time"]
        plan, day = [], w.local(after).date()
        while len(plan) < 7:
            fire = w.at(day, h, m)
            if fire > after:
                plan.append(dict(id="F%016x" % w.erng.getrandbits(64), fire=fire, bird=deck_bird(day)))
            day += timedelta(days=1)
        self.d["plan"] = plan
        keep = {e["id"] for e in plan}
        for alarm_id in list(w.alarms):
            if alarm_id not in keep:
                w.ak_cancel(alarm_id)
        if w.erng.random() < P_CRASH_MID_ARM:
            w.crash()
            return
        for e in plan:
            w.ak_schedule(e["id"], "fixed", e["fire"], e["bird"])

    def set_time(self, h, m):
        self.d["time"] = (h, m)
        if self.d.get("enabled"):
            self.arm()

    def set_enabled(self, on):
        self.d["enabled"] = on
        if on:
            self.arm()
        else:
            for alarm_id in list(self.w.alarms):
                self.w.ak_cancel(alarm_id)
            self.d["plan"] = []


# ---------------------------------------------------------------- new engine
class NewEngine:
    """Seven weekly-repeating alarms, one per weekday, kept correct by a
    reconcile step that runs at every opportunity and only changes what differs."""
    name = "new"

    def __init__(self, world):
        self.w = world
        self.memory_reset()

    def memory_reset(self):
        self.active_key = None
        self.card = None
        self.need = False

    @property
    def d(self):
        return self.w.defaults

    def fire_on(self, day):
        h, m = self.d["time"]
        return self.w.at(day, h, m)

    def key(self, fire):
        h, m = self.d["time"]
        return "%d|%d:%d" % (day_number(self.w.local(fire).date()), h, m)

    @staticmethod
    def alarm_id(weekday, h, m, bird):
        return "W" + hashlib.md5(("%d|%d|%d|%d" % (weekday, h, m, bird)).encode()).hexdigest()[:16]

    def next_fire(self):
        today = self.w.local().date()
        for off in range(0, 3):
            fire = self.fire_on(today + timedelta(days=off))
            if fire > self.w.now:
                return fire

    def keepalive_wanted(self):
        return False        # the app never keeps itself or the phone awake

    def desired(self):
        """weekday -> (alarm id, bird) for that weekday's next ring."""
        w, out, deferred = self.w, {}, set()
        h, m = self.d["time"]
        today = w.local().date()
        for off in range(0, 8):
            day = today + timedelta(days=off)
            wd = day.weekday()
            if wd in out or wd in deferred:
                continue
            fire = self.fire_on(day)
            if fire <= w.now:
                just_rang = (w.now - fire < timedelta(minutes=15)
                             and self.key(fire) not in (self.d.get("handled"), self.d.get("stopped")))
                if not just_rang:
                    continue            # otherwise: leave an alarm that has only just rung alone
            if self.key(fire) == self.d.get("handled"):
                deferred.add(wd)        # dismissed early: no alarm for this weekday until it has passed
                continue
            bird = deck_bird(day)
            out[wd] = (self.alarm_id(wd, h, m, bird), bird)
        return out, bool(deferred)

    def reconcile(self):
        w = self.w
        if not self.d.get("enabled"):
            return
        if any(a["alerting"] for a in w.alarms.values()):
            self.need = True            # never touch alarms while one is ringing
            return
        want, deferred = self.desired()
        ids = {alarm_id for alarm_id, _ in want.values()}
        self.need = deferred
        # Add what is missing first, then remove what is stale. If the app dies
        # half-way, the phone is left with an extra alarm rather than a missing one.
        h, m = self.d["time"]
        for wd, (alarm_id, bird) in want.items():
            if alarm_id in w.alarms:
                continue
            for _attempt in range(3):
                if w.ak_schedule(alarm_id, "weekly", (wd, h, m), bird):
                    break
            else:
                self.need = True
        if w.erng.random() < P_CRASH_MID_ARM:
            w.crash()
            return
        for alarm_id in list(w.alarms):
            if alarm_id not in ids:
                w.ak_cancel(alarm_id)

    def retry(self):
        self.reconcile()

    def on_launch(self):
        self.reconcile()
        self.check_due()

    def on_foreground(self):
        self.check_due()
        self.reconcile()

    def current_fire(self, lead=timedelta(0)):
        today = self.w.local().date()
        for day in (today, today - timedelta(days=1)):
            fire = self.fire_on(day)
            if fire - lead <= self.w.now <= fire + LATE:
                return fire
        return None

    def on_stop_intent(self, alarm_id):
        fire = self.current_fire()
        if fire:
            self.d["stopped"] = self.key(fire)
        self.reconcile()

    def on_dismiss(self):
        w = self.w
        if self.active_key:
            self.d["handled"] = self.active_key
            for alarm_id, a in list(w.alarms.items()):
                if a["alerting"]:
                    w.finish_ring(alarm_id)
            bird, fire = self.card
            if fire > w.now:            # dismissed during the lead-in: silence today's alarm
                h, m = self.d["time"]
                w.ak_cancel(self.alarm_id(w.local(fire).weekday(), h, m, bird))
        self.card = None
        self.active_key = None
        self.reconcile()

    def tick(self):
        self.check_due()
        if self.need:
            self.reconcile()

    def check_due(self):
        if not self.d.get("enabled"):
            self.card = self.active_key = None
            return
        lead = timedelta(0)
        fire = self.current_fire(lead)
        if fire is None:
            self.card = self.active_key = None      # the card expires with its morning
            return
        k = self.key(fire)
        if k == self.d.get("handled") or k == self.active_key:
            return
        self.active_key = k
        self.card = (deck_bird(self.w.local(fire).date()), fire)

    def set_time(self, h, m):
        self.d["time"] = (h, m)
        self.card = self.active_key = None
        self.reconcile()

    def set_enabled(self, on):
        self.d["enabled"] = on
        if on:
            self.reconcile()
        else:
            for alarm_id in list(self.w.alarms):
                self.w.ak_cancel(alarm_id)


# ---------------------------------------------------------------- one run
def run(engine_cls, persona, days, seed, expiry_silences=False):
    w = World(seed, persona, engine_cls)
    eng, st = w.engine, w.stats
    trips = random.Random(seed + 7)
    w.defaults.update(time=(7, 0), leadin=True, enabled=False)

    # Evening before day 0: install, open, switch the alarm on.
    w.now = w.at(START - timedelta(days=1), 21, 0)
    w.ensure_running()
    eng.on_foreground()
    eng.set_enabled(True)
    w.settle(from_foreground=True)

    last_sign, resign_day = -1, 6
    trip_end, disabled_until = None, None

    for i in range(days):
        day = START + timedelta(days=i)
        # Today's luck is drawn up front, so both engines live through the same 1,000 days.
        luck = random.Random(seed * 100003 + i)
        u = {name: luck.random() for name in ("reboot", "kill", "midday", "trip", "resign", "after_resign",
                                             "force_quit", "disable", "time_change", "evening")}
        per_ring = [[luck.random() for _ in range(4)] for _ in range(8)]
        ring_no = 0
        if i >= last_sign + 8:
            w.sig_ok = False
            st["days with expired signature"] += 1

        # 03:00  the phone does what phones do overnight
        w.now = w.at(day, 3, 0)
        if u["reboot"] < P_REBOOT or (w.proc == "alive" and u["kill"] < P_KILL_KEEPALIVE) \
                or (w.proc == "suspended" and u["kill"] < P_KILL_SUSPENDED):
            w.set_proc("dead")

        enabled = bool(w.defaults.get("enabled"))
        eh, em = w.defaults["time"]
        expected_at = w.at(day, eh, em)
        day_end = w.at(day, 14, 59)
        rings, early_dismissed, lead_in = [], False, False
        cursor = w.at(day, 0, 0)

        # Morning: walk through every alarm the system rings today, in order.
        handled_expected_tick = False
        while True:
            nxt = w.next_ring(day, cursor, day_end)
            moment = nxt[0] if nxt else None
            if enabled and not handled_expected_tick and (moment is None or expected_at <= moment):
                moment, nxt_is_expected = expected_at, True
            else:
                nxt_is_expected = False
            if moment is None:
                break
            if moment == expected_at:
                handled_expected_tick = True

            r_early, r_meet, r_still, r_launch = per_ring[min(ring_no, 7)]
            ring_no += 1

            # one minute before: the lead-in, if the app is still alive
            if w.proc == "alive" and w.sig_ok:
                w.now = moment - LEAD
                eng.tick()
                if eng.card and moment == expected_at:
                    lead_in = True
                    if r_early < persona["early"]:
                        w.now = moment - timedelta(seconds=30)
                        w.open_app()
                        eng.on_dismiss()
                        w.settle(from_foreground=True)
                        early_dismissed = True
                w.settle()

            # the moment itself: does a system alarm actually ring?
            ringing = w.next_ring(day, moment - timedelta(seconds=1), moment + timedelta(seconds=1))
            cursor = moment
            if ringing and not (expiry_silences and not w.sig_ok):
                t, alarm_id = ringing
                w.now = t
                a = w.alarms[alarm_id]
                a["alerting"] = True
                lt = w.local(t)
                rings.append(((lt.hour, lt.minute), a["bird"]))
                if w.proc == "alive" and w.sig_ok:
                    eng.tick()
                w.now = t + timedelta(seconds=20)
                if r_meet < persona["meet"] and w.sig_ok:
                    w.finish_ring(alarm_id)             # "Meet the bird" stops the alarm and opens the app
                    if w.open_app():
                        if eng.card:
                            eng.on_dismiss()
                        else:
                            st["opened from alarm but no bird card"] += 1
                        w.settle(from_foreground=True)
                else:
                    w.tap_stop(alarm_id, r_still, r_launch)
            elif ringing:
                w.finish_ring(ringing[1])
            elif nxt_is_expected and w.proc == "alive" and w.sig_ok:
                w.now = moment
                eng.tick()

        if w.proc == "alive":
            w.now = max(w.now, expected_at) + timedelta(minutes=2)
            eng.tick()
            w.settle()

        # Score the morning.
        on_time = [r for r in rings if r[0] == (eh, em)]
        st["rings at the wrong local time"] += len(rings) - len(on_time)
        if enabled and not early_dismissed:
            st["mornings an alarm was expected"] += 1
            if not on_time:
                st["MISSED alarms"] += 1
                if rings:
                    st["  missed because: rang at the wrong hour after travel"] += 1
                elif any(e["fire"] == expected_at for e in w.defaults.get("plan", [])):
                    st["  missed because: alarm lost during an update"] += 1
                elif not w.sig_ok and expiry_silences:
                    st["  missed because: signature expired"] += 1
                else:
                    st["  missed because: queue ran dry"] += 1
            else:
                w.heard.append((i, on_time[0][1]))
                if len(on_time) > 1:
                    st["double rings"] += 1
                if on_time[0][1] != deck_bird(day):
                    st["wrong bird sang"] += 1
                if lead_in:
                    st["mornings with the soft lead-in"] += 1
        else:
            st["rings when none was wanted"] += len(on_time)

        # 12:30  maybe opens the app at lunch
        w.now = w.at(day, 12, 30)
        if u["midday"] < persona["midday"] and w.open_app():
            if eng.card:
                eng.on_dismiss()
            w.settle(from_foreground=True)

        # 15:00  travel changes the phone's time zone; the app is not told
        w.now = w.at(day, 15, 0)
        if trip_end is None and u["trip"] < P_TRIP_STARTS:
            w.tz = ZoneInfo(trips.choice(TRIP_ZONES))
            trip_end = i + trips.randint(2, 6)
            st["trips to another time zone"] += 1
        elif trip_end is not None and i >= trip_end:
            w.tz = ZoneInfo(HOME_TZ)
            trip_end = None

        # 18:00  weekly re-sign; the owner sometimes swipes the app away
        w.now = w.at(day, 18, 0)
        if i >= resign_day:
            w.sig_ok = True
            w.set_proc("dead")
            last_sign = i
            resign_day = i + 7 + (0 if u["resign"] < P_RESIGN_ON_TIME else trips.randint(2, 4))
            if u["after_resign"] < persona["after_resign"] and w.open_app():
                w.settle(from_foreground=True)
        elif u["force_quit"] < P_FORCE_QUIT:
            w.set_proc("dead")

        # 20:00  settings changes
        w.now = w.at(day, 20, 0)
        if disabled_until is not None and i >= disabled_until:
            if w.open_app():
                eng.set_enabled(True)
                w.settle(from_foreground=True)
                disabled_until = None
        elif u["disable"] < P_DISABLE and w.defaults.get("enabled") and w.open_app():
            eng.set_enabled(False)
            w.settle(from_foreground=True)
            disabled_until = i + trips.randint(1, 3)
        elif u["time_change"] < P_TIME_CHANGE and w.open_app():
            eng.set_time(*trips.choice(ALARM_TIMES))
            w.settle(from_foreground=True)
            st["alarm time changes"] += 1

        # 22:30  maybe opens the app before bed
        w.now = w.at(day, 22, 30)
        if u["evening"] < persona["evening"] and w.open_app():
            w.settle(from_foreground=True)

    w.now = w.at(START + timedelta(days=days), 0, 0)
    w.set_proc("dead")
    st["hours per day the app kept itself awake"] = round(w.alive_hours / days, 1)
    last, gaps = {}, []
    for idx, bird in w.heard:
        if bird in last:
            gaps.append(idx - last[bird])
        last[bird] = idx
    st["shortest gap between the same bird (days)"] = min(gaps) if gaps else 0
    return st


ROWS = ["mornings an alarm was expected", "MISSED alarms",
        "  missed because: queue ran dry", "  missed because: rang at the wrong hour after travel",
        "  missed because: alarm lost during an update", "  missed because: signature expired",
        "rings at the wrong local time",
        "wrong bird sang", "double rings", "rings when none was wanted",
        "stale bird card shown", "wrong bird on card", "opened from alarm but no bird card",
        "hours per day the app kept itself awake",
        "shortest gap between the same bird (days)"]
CONTEXT = ["trips to another time zone", "alarm time changes", "days with expired signature",
           "schedule calls refused", "crashes mid-update"]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--days", type=int, default=1000)
    parser.add_argument("--seeds", type=int, default=1, help="repeat with different random seeds and average")
    parser.add_argument("--seed", type=int, default=2026)
    parser.add_argument("--stop-never-wakes-app", action="store_true",
                        help="pessimistic: tapping Stop never manages to run the app's handler when the app is dead")
    parser.add_argument("--expiry-silences", action="store_true",
                        help="pessimistic: assume alarms do not ring while the signature is expired")
    args = parser.parse_args()
    if args.stop_never_wakes_app:
        global P_INTENT_LAUNCHES
        P_INTENT_LAUNCHES = 0.0

    for label, persona in PERSONAS.items():
        print(f"\n=== {label}: {args.days} days" + (f", average of {args.seeds} runs" if args.seeds > 1 else "") + " ===")
        results = {}
        for engine in (OldEngine, NewEngine):
            total = Counter()
            for k in range(args.seeds):
                for key, value in run(engine, persona, args.days, args.seed + k, args.expiry_silences).items():
                    if key.startswith("shortest"):
                        total[key] = value if key not in total else min(total[key], value)
                    else:
                        total[key] += value
            results[engine.name] = {key: (v if key.startswith("shortest") else round(v / args.seeds, 1))
                                    for key, v in total.items()}
        print(f"{'':46}{'old':>9}{'new':>9}")
        for row in ROWS:
            print(f"{row:46}{results['old'].get(row, 0):>9}{results['new'].get(row, 0):>9}")
        print("  what happened to the phone: " + ", ".join(
            f"{results['new'].get(c, 0):g} {c}" for c in CONTEXT))


if __name__ == "__main__":
    main()

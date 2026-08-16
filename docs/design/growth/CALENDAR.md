# The update calendar

Written for round 6's growth half against a brief that no longer exists
(`GROWTH-TODO.md`, deleted once it was spent — the record is
`../../dev/HANDOFF_v6.md` §G1). The ops half; the code half (weekend double
cash, milestone codes) shipped as PRs in that round.

---

## Why this is strategy rather than housekeeping

Roblox changed how it judges games this year. The evaluation window went from
**7 days to 28**, explicitly to stop rewarding games that "win attention with
exciting thumbnails but don't deliver long-term value."

So the question stopped being *is this fun tonight* and became *did this hold
people for four weeks*. That makes the update calendar the actual growth
strategy, not a nice-to-have on the end of one.

---

## The cadence

**Something small every week. Something big every month or season.**

And then the constraint that matters more than the cadence:

> **A fortnightly update that actually ships beats a weekly one that keeps
> slipping.**

A live-ops calendar is a **staffing commitment**, not a feature. Be honest about
what the team can hold before writing dates down, because a missed beat is worse
than a slower one — players read a skipped week as abandonment, and the 28-day
window means they are right to.

Reference points for the large beat: seasonal events that run six to eight weeks
rather than a weekend.

---

## What is already built and needs no calendar at all

**Weekend double cash.** `Config.Sessions.WeekendMultiplier`, live as of this
round. It fires on Saturday and Sunday UTC, stacks multiplicatively with the
boost for ×4, and needs no scheduling, no content and no one to remember
anything. It is the cheapest recurring beat available and it is already running.

Everything below is the work on top of that.

---

## Codes: milestone, not dated

This is the one strong opinion in the document.

**A dated code rewards whoever already happens to be playing.** It is a gift to
the people least at risk of leaving.

**A milestone code rewards pushing the number.** "10K likes" or "50K visits"
unlocks a code, so claiming it is something players do *to each other* — they
have a reason to bring somebody, which is the same reason the friend bonus
exists. The code becomes a shared goal instead of a handout.

### Payload: cash **and** a timed boost

Cash alone gets claimed and the game gets closed. A timed boost is what makes
someone actually play *right now*, because the clock is running. Ship both in
every code.

### Suggested milestones

| Trigger | Payload |
| --- | --- |
| 1K visits | small cash + 10 min boost |
| 10K visits | cash + boost |
| 50K visits | cash + boost |
| 1K likes | cash + boost |
| 10K likes | cash + longer boost |
| Each seasonal launch | cash + boost, retired when the season ends |

Milestone codes never expire once unlocked. That is the point — a player who
arrives in month three can still claim the 1K code, and it reads as history
rather than as a thing they missed.

---

## The rule that governs everything on the calendar

Whatever pulls someone back has to **drop them into something fun within about
ten minutes.**

Pulling someone back into a grind is worse than not pulling them back at all: it
spends the re-engagement and confirms the reason they left. A daily reward that
lands a player in front of a forty-minute wall has done net harm.

This is the test to apply to every proposed beat before it goes on the calendar.

---

## A quarter, as an illustration

Not a commitment — a shape.

| Week | Beat |
| --- | --- |
| 1 | Season opens: new bat tier + arena reskin |
| 2 | QoL, whatever landed |
| 3 | Milestone code if a threshold was crossed |
| 4 | Small content: a variant, a utility |
| 5 | QoL |
| 6 | Mid-season event, weekend-scoped |
| 7 | QoL |
| 8 | Season closes, next one opens |

Weekend double cash runs underneath all of it, every weekend, with nobody doing
anything.

---

## What to watch

In the Creator Dashboard, in this order:

1. **Play-through rate** — is the icon working (see `STORE_PAGE.md` §4)
2. **Sessions per user per day** — is the return hook working; 1.5+ is healthy,
   below 1.2 is a structural re-engagement problem
3. **Day 1 / Day 2–7 / Day 8–28 retention buckets** — the thing actually being
   ranked

None of these are readable until the analytics from this round have been live
long enough to aggregate, and Roblox's own charts lag by roughly a day. Do not
try to read a beat's effect the morning after it ships.

# Growth backlog

`IDEAS.md` is a depth backlog: it answers *what should the game contain*. It is
well-sourced and most of it is right, but it starts at the moment a player is
already standing on a plot. This document covers the four questions before and
around that one:

1. Why does a stranger click?
2. Why are they still here at minute ten?
3. Why do they open the game again tomorrow?
4. Why do they bring somebody?

It is a **companion** to `IDEAS.md`, not a replacement. Where it re-prioritises
an item from that document it names the item and gives the reason; it does not
restate the item's content.

Sources are Roblox's own newsroom and DevForum announcements (primary,
marked **[R]**), and third-party analyst and aggregator write-ups (marked
**[3P]** — useful, directional, and *not* Roblox's own numbers). Everything
about this repo was read out of the source at the line cited, and the price
curve was re-run through `tools/verify.py` rather than remembered.

Difficulty follows `IDEAS.md`: **S** = a few hours · **M** = about a day ·
**L** = multi-day. Some items here are not code at all and are marked **[art]**
or **[ops]**.

Standing constraint for this document: **no monetization.** That is a decision,
not an oversight, and §2 accounts for what it costs rather than arguing with it.

---

## The seven findings that should change the plan

**1. Roblox now scores a 28-day window, so discovery is a retention function.**
In June 2026 the Recommended For You algorithm was rewritten: the evaluation
window went from 7 days to 28, explicitly because "short-term engagement is
overvalued, [and] the system could disproportionately favor games that win
attention with exciting thumbnails but don't deliver long-term value for
players." **[R]** Retention is no longer a thing you fix after you get traffic.
It is the thing that decides whether you get traffic.

**2. Playtime credit is capped at 60 minutes per user per day, and this game is
an 88-minute build.** Roblox's `7 Day Playtime Per User` signal counts a
"maximum of 60 minutes per user, per experience, per day." **[R]** The verifier
prints the curve: full build at **87.7 min**, and the 60-minute mark falls at
`upgrader5` (60.6 min). Droppers 9 and 10 and upgrader 6 — **27 minutes, 31% of
the entire build** — are worth exactly zero to the algorithm for a player who
does it in one sitting. This makes `IDEAS.md` P0 #2 the single highest-value
change in the repo, and it is a `Config.lua` edit.

**3. The return hooks are already written and every one of them is switched
off.** `Config.Prototypes` at `Config.lua:549` has `Offline = false` and
`Sessions = false`, behind which sit `SessionService.lua` (806 lines),
`SessionUI.lua` (632 lines), a tuned `Config.Offline` and a tuned
`Config.Sessions`. `7 Day Play Days Per User` is a named ranking signal
**[R]** and this is the code that produces it. Nothing else on this list has a
better effort-to-outcome ratio than a Studio pass followed by flipping two
booleans — with the caveat from `HANDOFF_v3.md` §4 that *none of the prototype
code has ever run in Roblox*, and that the shipped swing animation was broken
in two different ways that only Studio could reveal.

**4. Co-play is a named signal and this game has no social surface whatsoever.**
`7 Day Intentional Co-Play Days Per User` counts "users intentionally playing
with friends […] through join, invite, or private server rather than through a
matchmaking." **[R]** Grepped against `src/`: no `SocialService`, no
`GetFriendsAsync`, no invite prompt, no friend bonus, no shared objective. Six
plots ring an arena and the game never once asks you to bring somebody. This is
the largest unbuilt growth surface in the project.

**5. The store page is 100% of acquisition and 0% of the repo.** The icon
decides the click before any feature does, and it renders at roughly 150 px in
the feed **[3P]**. There is no icon strategy, no thumbnail set, no positioning
line, and no trailer anywhere in this project. Third-party reporting also has
Roblox replacing qualified play-through rate with **play-through rate plus
first-play bounce** **[3P, unconfirmed]** — if that holds, an icon that
over-promises is punished twice: once on the bounce, once on the retention
buckets behind it.

**6. 80% of sessions are mobile and the UI is authored in fixed pixels.** Mobile
went 74% → 80% of Roblox sessions over Q1 2026; desktop is 17%, console 3%, and
56% of users are under 16 **[3P]**. This client builds fixed-size cards —
`UDim2.fromOffset(470, 330)` at `SessionUI.lua:190`, `UDim2.fromOffset(430, 250)`
at `HUD.lua:349` — with no `UIScale` anywhere, and `HUD.lua:493` sets
`IgnoreGuiInset = false` with no safe-area handling. There is no `TouchEnabled`
branch in `src/client/` at all. Four out of five first impressions currently
land on the worst-looking version of the game.

**7. There is no analytics of any kind.** No `AnalyticsService`, no funnel
events, no instrumentation. Every number in this document is a benchmark rather
than a measurement, and it stays that way until this is fixed. This is the one
item on the list that makes every other item cheaper, because it converts
argument into evidence.

---

## 1. How discovery actually works in 2026

### The named signals

These are Roblox's own, quoted from the Recommended For You announcement **[R]**:

| Signal | Roblox's definition |
| --- | --- |
| Qualified play-through rate | "The number of engaging plays divided by the number of impressions from Recommended For You." |
| 7 Day Playtime Per User | "Total playing time per user in your experience within the last 7 days (**maximum of 60 minutes per user, per experience, per day**)." |
| 7 Day Play Days Per User | "Total unique days users engage with your experience over the last 7 days." |
| 7 Day Spend Days Per User | "Total unique days users spend Robux in your experience over the last 7 days." |
| 7 Day Robux Spent Per User | "Total Robux spent per user in your experience over the last 7 days." |
| 7 Day Intentional Co-Play Days Per User | "Frequency of users intentionally playing with friends over the last 7 days (**through join, invite, or private server** rather than through a matchmaking)." |

**Roblox explicitly refuses to rank them:** "There is no one signal that is most
important. All of these signals work together to convey how players engage with
a game and whether they enjoy coming back to play more." **[R]** Anyone selling
you a weighted breakdown of this list is inventing it. Treat all six as live.

### What changed in June 2026

- The window went **7 days → 28 days**, bucketed **Day 1 / Day 2–7 / Day 8–28**,
  measured across playtime, play days, qualified play sessions and intentional
  co-play. **[R]**
- Stated motive: stop rewarding "games that win attention with exciting
  thumbnails but don't deliver long-term value." **[R]**
- Roblox says testing showed the new algorithm "did a significantly better job
  surfacing games that retain players over time," without publishing the
  lift. **[R]**
- A follow-up post says more signals are under test across "the first few
  minutes of a session, to daily, weekly and monthly," and is deliberately
  non-specific about what they are. **[R]** Nothing should be planned against it
  yet.
- Platform scale for context: **132 million DAU**, Q1 2026. **[R]**

### The third-party read

These are analyst figures, not Roblox's, and they are directionally consistent
with the primary sources rather than derived from them. Useful for setting
targets; not useful for winning arguments. **[3P]**

- **Sessions per user per day: 1.5+ is healthy, below 1.2 signals a structural
  re-engagement problem.**
- **Core loop under 15 minutes. Over 30 minutes is an algorithmic
  disadvantage.**
- The 24-hour return window is weighted most heavily, with a secondary signal at
  72 hours.
- The line worth writing on the wall: *"A 45-minute session followed by no
  return looks worse under this model than two 12-minute sessions in the same
  day."*
- Retention gates the value of *any* traffic: a game at 30% D1 gets roughly
  **3× the algorithmic benefit from the same marketing** as one at 10% D1.

Retention benchmarks for this genre, carried over from `IDEAS.md`: tycoon D1
30% good / 45% excellent, D7 15% / 25%. One third-party report puts average D7
at ~38% for prestige tycoons specifically, and claims top-tycoon CCU peaks above
100K with typical playthroughs of six to twenty hours of active time **[3P,
low confidence]**. Tycoons are consistently reported as the **second-largest
share of concurrent players on Roblox after obbies** **[3P]** — the genre is not
the problem.

---

## 2. Scoring this game against that list

| Signal | Where we stand | Fix |
| --- | --- | --- |
| Qualified play-through rate | **Unscored.** No icon strategy, no positioning, nothing to click. | §3 |
| 7 Day Playtime Per User | **Actively hostile to the cap.** 87.7-minute build against a 60-minute daily credit. | §4, `IDEAS.md` P0 #2 |
| 7 Day Play Days Per User | **Zero by construction.** No offline earnings, no daily loop, no exit hook — all written, all off. | §4, `IDEAS.md` P1 #8 / #10 |
| 7 Day Spend Days Per User | **Permanently zero.** Forfeited by decision. | — |
| 7 Day Robux Spent Per User | **Permanently zero.** Forfeited by decision. | — |
| 7 Day Intentional Co-Play Days | **Zero.** No social surface exists. | §5 |

### The honest accounting on monetization

**Two of the six published signals are spend-based.** Choosing not to monetize
means one third of the named list is scored at zero, permanently, and no amount
of engagement work moves it. For scale, the genre norms we are declining are a
2–5% payer conversion rate at an ARPPU of 100–300 Robux **[3P]**.

There are two real consequences, and they should be said out loud once:

1. **The other four signals have to be exceptional, not adequate.** Parity on
   playtime and play days does not make up a third of the list.
2. **Paid acquisition is off the table by construction** (see §3), because with
   no revenue there is no ROAS at any CPI.

There is one genuine upside and it is not nothing: aggressive monetization is
one of the most-cited reasons players quit tycoons — "geared towards pushing
players to spend Robux," "pressure players into spending to compete" **[3P]** —
and one third-party analysis of tycoon quality uses *fewer than five gamepasses*
as a health marker. Not monetizing removes an entire class of churn and an
entire class of design compromise. It is a defensible position. It is just not
a free one.

---

## 3. Acquisition

The funnel is **impression → click → first 30 seconds → 10 minutes → day 2**.
`IDEAS.md` P1 #9 owns the third step and owns it well. Steps one and two are
unowned by anything in this repo.

### 3.1 The positioning sentence · S [art]

Do this before the icon, because the icon is downstream of it.

"Tycoon" is not a pitch, it is a genre, and "tycoon + brainrot" is the most
cloned combination on the platform right now. The reference point is Steal a
Brainrot, whose entire hook is **one word — *steal*** — and whose virality came
from **visible loss**: clips of kids losing things, which feed themselves
because the spectacle is legible without context **[3P]**.

This game already owns a sentence nobody else is saying:

> **Your factory gets raided, and you defend it with a bat.**

The arena, the wave system, the boss every fifth wave and geographic PvP are all
built and shipping today. That is a different sentence from "tycoon," and it is
the one the icon, the thumbnails, the title, the description and the first thirty
seconds should all be saying — **and they must agree with each other**, because
first-play bounce is measured now. A conveyor belt is not the pitch. The raid is.

### 3.2 Icon · S [art] — the highest-leverage single asset in the project

- **512×512, 1:1.** Design at 1024×1024 and downsample so edges and text stay
  sharp. PNG, under 2 MB. **[3P]**
- **It renders at roughly 150 px in the feed.** One subject, high contrast,
  minimal or no text — anything smaller than a face is mud at that size. **[3P]**
- **Show the sentence.** A Tung guy mid-swing at a raider reads at 150 px. A
  factory does not.
- **A player decides in a fraction of a second**, which is why a strong icon can
  outweigh a month of features **[3P]**.

### 3.3 Thumbnails · S [art]

1920×1080. Three slots, each selling a different thing rather than three angles
on the same thing:

1. **The fantasy** — the full factory running, the number large and legible.
2. **The verb** — the bat connecting with a raider, mid-swing.
3. **The thing nobody else has** — the arena raid with several players in it.

### 3.4 The A/B loop · S [ops]

There is no icon A/B tool. The method is: ship one, watch play-through rate in
the Creator Dashboard, change **one element at a time** (subject, background,
expression, text), ship again **[3P]**. This is worth running as a standing
weekly job for the first month, and it is worth *nothing* until §7 exists — you
cannot read a CTR change against a game whose retention is also moving.

### 3.5 UGC avatar items as a free top-of-funnel · M [art]

The Marketplace is a real discovery channel and it costs an upload rather than a
budget: 14M+ unique UGC items listed in 2025 against 28B Robux of transaction
volume, an estimated 120,000 active sellers as of early 2026, and — the useful
part — **emotes and animations are the fastest-growing category at +180% YoY
and the least saturated**, where hair and accessories are picked over. **[3P]**

A "tung tung tung" emote, or a bat accessory, is on-theme, cheap, and puts the
game's name in a surface players browse voluntarily.

**Flag the risk honestly:** Tung Tung Tung Sahur is a character created by
TikTok user @noxaasht in February 2025, not by us. The meme is still live on
Roblox in 2026 — the music IDs are still circulating and Steal a Brainrot hit
nearly 24 million players in a single day off the same trend **[3P]** — so the
tailwind is real. But shipping *Marketplace items* off somebody else's character
is a materially different risk posture from shipping a game that references it,
and it is a takedown surface. Worth doing with an original silhouette rather
than a copy.

### 3.6 Paid ads: don't · [ops]

- Blended global gaming CPI rose **30% YoY to $0.56**; tier-one installs run
  ~$4.22 iOS / ~$2.97 Android. **[3P]**
- The 2026 consensus has moved off chasing low CPI and onto balancing it against
  LTV for ROAS. **[3P]**
- **With no monetization, LTV in Robux is zero, so ROAS is zero at any CPI.**
  Paid traffic into this game is pure cost with no payback mechanism.

The corollary is the useful part: **the algorithm is the ad budget.** A 30% D1
game extracts ~3× the algorithmic benefit from the same traffic as a 10% D1 game
**[3P]**, so every hour spent on §4 is an hour spent on acquisition. Sponsoring a
game that isn't retaining is buying a bounce.

---

## 4. Retention and the return hook

### 4.1 Re-cut the session, don't just shorten the game · S

`IDEAS.md` P0 #2 says retune to 30–60 minutes against a genre benchmark. Right
answer, incomplete reason. The reason is the **60-minute daily credit cap**, and
it changes the target from "shorter" to a specific shape:

- **One satisfying arc that completes inside ~50 minutes**, leaving headroom
  under the cap.
- **A visible next thing at the point where the arc closes**, so the session
  ends on appetite rather than exhaustion.
- Third-party guidance wants the *core loop* under 15 minutes with the whole
  experience made of repeatable short loops rather than one long one **[3P]** —
  which is what rebirth is for, and is an argument for pulling the first rebirth
  much closer than its current **+10 minutes after the full build (~98 min)**.

The verifier already models and prints this and will fail the build on a
mid-game wall over 15 minutes, so the whole change is a `Config.lua` edit plus
`python3 tools/verify.py`. Current curve for reference:

```
  dropper8      7.1m  =====================              @  53.4m
  upgrader5     7.2m  =====================              @  60.6m   <- credit cap
  dropper9      8.1m  ========================           @  68.7m
  upgrader6     8.5m  =========================          @  77.2m
  dropper10    10.5m  ===============================    @  87.7m
```

### 4.2 Turn on what is already written · S

`Config.Prototypes` — `Offline = false`, `Sessions = false`. Behind them:

- **Offline earnings** (`Config.Offline`): 25% rate, 8h cap, cap extensions at
  12/16/24h as purchases. This is the strongest single return hook in the genre
  and the welcome-back panel is half its value — see `IDEAS.md` P1 #8, which has
  the safety rules (`os.time()` never `tick()`, CPS derived server-side) and
  should be read before the flag is flipped.
- **Daily streak, playtime ladder, boost cooldown, weekend 2×**
  (`Config.Sessions`): directly produces `Play Days Per User`. See `IDEAS.md`
  P0 #3, P0 #4, P1 #10.

**Promote all of these to P0.** `IDEAS.md` files offline earnings and daily
rewards under P1; against a named ranking signal, with the code already written,
that is too low.

**Carry the caveat.** `HANDOFF_v3.md` §4: none of this has run in Roblox, and
the last feature that "was derived and reviewed" was broken twice in ways only
Studio could reveal. Budget a Studio pass, not a flag flip.

### 4.3 The exit hook · S

The gap the prototypes *don't* cover. Right now nothing is running while you're
away, nothing is waiting when you get back, and nothing expires.

The specific third-party guidance is sharper than "add a daily reward": place a
**visible state change at the exit point** — a timer or counter showing what
will be different when you return — and note that "daily rewards and quest
boards only work if they pull players back to genuinely satisfying loops under
10 minutes" **[3P]**. A popup on quit is not this. A vault visibly filling, with
a number that will be larger tomorrow, is.

### 4.4 Weekly-reset leaderboard · S

Buried inside `IDEAS.md` P2 #17. The growth-relevant half is the reset: **an
all-time board is unwinnable for anyone who joins after week one**, which makes
it a retention feature for exactly the players who need it least. Rank current
income/sec, reset weekly, keep the all-time board as a trophy case.

---

## 5. Virality and co-play

This is the section with the most headroom, because `Intentional Co-Play Days`
is a named signal **[R]** and almost nobody in this genre builds for it.

### 5.1 Friend bonus · S

`IDEAS.md` P2 #17 has it as a bullet: +10% per friend in server, capped +30%,
with the claim that players with one in-game friend show 3× higher D30 retention
and co-play sessions run 1.9× longer. **Promote it out of the P2 grab-bag.** It
is a named ranking signal, it is the cheapest virality lever available, and it
requires `GetFriendsAsync` plus an income multiplier.

### 5.2 Invite prompt and the Friend Referral System · S

Roblox shipped a **Friend Referral System** that lets creators reward inviting
friends into an experience with bonus currency or items **[3P]**. Nothing in
this repo uses it. Pair it with `SocialService:PromptGameInvite` at the moment
the bonus becomes legible — i.e. the first time a player sees "+10% (1 friend)"
and there is a visible number attached to bringing one more.

The signal counts join/invite/private-server specifically, **not matchmaking**,
so an invite button is not decoration — it is the literal thing being measured.

### 5.3 The server-wide boss · M

This is the co-play verb the game is one step away from having, and it is
already in the README roadmap ("a shared arena objective"). Everything it needs
exists: the arena, `NPCService` wave logic, boss scaling every 5th wave,
geographic PvP zoning.

Why it matters more than another dropper tier: a tycoon is structurally
**parallel play** — six people in six boxes, each watching their own number.
Nothing in the loop requires or rewards another human being. A boss everyone
fights at once, in the arena that already exists, converts a lobby into a
session people invite each other to.

### 5.4 Design for the shareable moment · M

Steal a Brainrot's clip economy runs on **visible loss** — the spectacle is
legible to someone with no context **[3P]**. This game has raids that chip your
bank and PvP in the arena, but nothing at stake that a spectator can *read*.

Ideas in ascending order of risk:

- **Legible stakes on a raid.** A raider reaching the vault should visibly take
  something, not silently decrement a number.
- **Boss kill credit**, named and announced server-wide.
- **A high-stakes arena wager.** The highest-virality, highest-risk option, and
  the one that needs `IDEAS.md`'s session-locked persistence gap closed first —
  that is still the number one known defect in the repo.

---

## 6. Live ops

The 28-day window is what makes the calendar the strategy rather than a nicety:
a game is now judged on whether it held people for weeks. **[R]**

- **A live-ops calendar is a forward schedule of weekly events, seasonal
  content, limited-time items and updates.** One cited case study reports an
  always-on live-ops system lifting D1 retention 30% and DAU 300% **[3P, single
  case, treat as illustrative]**.
- **The working cadence** is a weekly small beat plus a monthly or seasonal
  large one, with QoL shipped between them as it lands **[3P]**. The comparison
  points are Fischfest running most of a summer and Dress to Impress's seasonal
  updates running six to eight weeks.
- **Codes: milestone, not dated.** `IDEAS.md` P2 #17 has the reasoning and it is
  correct — a dated code rewards whoever is already playing, a milestone code
  rewards pushing the counter. Payload should be cash **plus a timed boost**,
  because the boost is what forces a session rather than a check-in.
- **Weekend 2×** (`Config.Sessions.WeekendMultiplier`, written, off) is the
  cheapest recurring beat available and needs no calendar at all.

The honest constraint: a live-ops calendar is a **staffing commitment**, not a
feature. If the team cannot hold a weekly beat, a fortnightly one that actually
lands beats a weekly one that slips.

---

## 7. Mobile · M

Four out of five sessions **[3P]**. This is an acquisition defect: it is the
version of the game most people's first impression is of.

What is actually broken:

- **No `UIScale` anywhere.** `SessionUI.lua:190` builds a 470×330 card;
  `HUD.lua:349` builds 430×250. On a phone viewport those are most of the
  screen, and on a small one they overflow it.
- **`IgnoreGuiInset = false` at `HUD.lua:493` with no safe-area handling.**
  Notches and home indicators will eat UI.
- **No `TouchEnabled` branch in `src/client/` at all.** The only touch-aware
  thing in the client is the utility chip at `UpgradeUI.lua:328`.

What is *not* broken, and should not be "fixed": combat. Bats are plain Roblox
`Tool`s, so the built-in mobile fire button drives `Tool.Activated` for free —
`CombatClient.lua:204` documents this deliberately. Leave it alone.

The fix is a `UIScale` driven off viewport size, offsets converted to scale on
the containers, and a pass on a phone-shaped viewport in Studio. Also worth
re-reading `IDEAS.md`'s performance ceilings with an 80% mobile audience in
mind — **particles are 400/sec desktop but 100/sec mobile**, and that budget is
the one most likely to be blown by the sound and FX work in P0 #1.

---

## 8. Measurement · S — do this first, it makes everything else cheaper

Nothing in `src/` fires an analytics event. Until that changes, every decision
in this document is an argument rather than a test.

Minimum viable funnel, using `AnalyticsService`:

| Event | Answers |
| --- | --- |
| `session_start` with platform + entry point | Is the mobile share of *our* players 80%? |
| `first_button_purchased` with seconds-since-join | Does `IDEAS.md` P1 #9's 30-second target actually hold? |
| `session_end` with duration + last milestone | Where does the 88-minute curve actually lose people? |
| `returned` with hours-since-last | Sessions per user per day, against the 1.5 target. |
| `rebirth` with number + time-to | Is the first rebirth reachable inside a session? |
| `offline_claim` with amount + whether the cap clipped | Is the return hook working, and is the cap the wall? |
| `friend_bonus_active` with friend count | Are we generating any co-play at all? |

Then watch, in the Creator Dashboard: **play-through rate** (the icon),
**sessions per user per day** (the return hook), and the **Day 1 / Day 2–7 /
Day 8–28 retention buckets** (the thing being ranked).

---

## 9. What we lack, consolidated

1. **No store page work at all** — no icon, no thumbnails, no positioning
   sentence, no description, no trailer. §3.
2. **No analytics.** §8.
3. **Session length fights the credit cap.** 87.7 min vs 60. §4.1.
4. **No social surface.** No friend bonus, no invite, no shared objective. §5.
5. **No mobile adaptation** for 80% of the audience. §7.
6. **No exit hook.** Nothing waiting, nothing running, nothing expiring. §4.3.
7. **No live-ops calendar**, and no staffing commitment behind one. §6.
8. **Everything built to help is behind a flag set to `false`**, and unexercised
   in Studio. §4.2.
9. **Two of six ranking signals forfeited** by the no-monetization decision. §2.
10. **No differentiating sentence** — we have a genre, not a pitch. §3.1.
11. **Session-locked persistence is still missing**, still the highest-severity
    defect in the repo per `HANDOFF_v3.md`, and it gates the highest-virality
    items in §5.4.

## 10. Where the evidence is thin

- **Roblox does not publish signal weights, and says so.** "There is no one
  signal that is most important." **[R]** Any weighted breakdown you encounter
  is invented. The six definitions in §1 are quoted verbatim and are the only
  hard part of this document.
- **The Day 1 / 2–7 / 8–28 bucketing is announced but not specified.** Roblox's
  newsroom post names the buckets and directs readers to the DevForum for
  detail; the DevForum post lists the six 7-day signals above without the
  bucket mechanics. The two do not fully reconcile and I could not close the gap.
- **`qPTR → play-through rate + first-play bounce` is third-party only.** It
  came via search summary of an analyst write-up, not from a Roblox post I could
  read. Treat §3.1's "punished twice" argument as plausible, not established.
- **The sessions/user/day thresholds (1.5 / 1.2), the 15- and 30-minute loop
  guidance, and the 24/72-hour return windows are all one analyst's numbers.**
  They are internally consistent and match the direction of Roblox's own
  announcement, which is the best that can be said for them.
- **The "3× algorithmic benefit at 30% D1" and the "D1 +30% / DAU +300%
  live-ops" figures are single-source and unaudited.** Directionally useful,
  not quotable.
- **Tycoon-specific retention figures (~38% D7 for prestige tycoons, 100K+ CCU
  peaks, 6–20h playthroughs) come from one content-marketing write-up** and
  should be treated as the weakest numbers here.
- **Mobile share, UGC volumes and CPI figures come from statistics aggregators**
  rather than primary filings, except the 132M DAU, which is Roblox's own.
- **Nothing here is measured on our own players, because there is nothing
  measuring them.** That is §8, and it is why §8 is first.

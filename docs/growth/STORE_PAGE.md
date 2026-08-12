# The store page

Everything before a player presses Play. `GROWTH-TODO.md` items 5 and 6.

This is the only document in the repo about work that is not code, and it exists
because the store page is **100% of acquisition and 0% of the repo**. Thirty-three
pull requests have gone into what happens after someone joins. Nothing has gone
into whether anyone does.

Nothing here can be verified by `tools/verify.py`, and nothing here can be built
by whoever reads it next without a person who can draw. What it can do is remove
every decision except the drawing.

---

## 1. The sentence

Start here, because the icon is downstream of it and so is everything else.

> **Your factory gets raided, and you fight them off with a bat.**

That is the pitch. It is not "tycoon" — tycoon is a genre, and "brainrot tycoon"
is the most cloned combination on the platform right now. If someone asks what
this game is and the answer is a genre, the conversation is already lost.

The reference point is Steal a Brainrot, whose entire hook is **one word —
*steal*** — and whose virality came from **visible loss**: clips of kids losing
things, legible to a viewer with no context at all.

We already own a sentence nobody else is saying, and the parts of it are already
built and shipping: the arena, the wave system, a boss every fifth wave,
geographic PvP zoning, raiders that chip your bank. **That is the thing.** The
conveyor belt is what the game IS. It is not what makes someone tap.

### Everything has to agree with the sentence

The icon, the three thumbnails, the title, the description, and the first thirty
seconds of actually playing. This is not a style note — first-play bounce is
measured now, so a mismatch is punished twice: once when they leave, and again
in the retention buckets behind it.

**If the icon promises a fight and minute one is watching a belt move, we get
punished for the mismatch on top of just losing the player.**

---

## 2. The icon

The highest-leverage single asset in the project, and the cheapest.

| | |
| --- | --- |
| Size | **512×512**, 1:1 |
| Method | design at **1024×1024** and downsample, so edges stay sharp |
| Format | PNG, under 2 MB |
| Renders at | **~150 px** in the feed |

### The rules that follow from 150 px

- **One subject.** Not a scene. Not a composition. One thing.
- **High contrast**, and check it against both a white and a dark feed background.
- **Basically no text.** Anything smaller than a face turns to mush at that size,
  and a word that is illegible is worse than no word because it still eats the
  space.
- **Show the sentence.** A Tung guy mid-swing connecting with a raider reads at
  150 px. A factory does not.

**Do not show a conveyor belt.** This is the single most likely mistake, because
the belt is the thing we are proudest of and the thing we have spent the most
time on. It is not what sells the click.

A player decides in roughly a quarter of a second, which is why a strong icon can
outweigh a month of features.

---

## 3. The three thumbnails

1920×1080. Three slots, and the discipline is that **each one sells a different
thing** rather than three angles on the same thing.

| # | Sells | Shot |
| --- | --- | --- |
| 1 | **The fantasy** | the full factory running, the income number large and legible |
| 2 | **The verb** | the bat connecting with a raider, mid-swing, at the moment of impact |
| 3 | **The thing nobody else has** | the arena raid with several players visibly in it |

Three is the whole budget. Spending two of them on the factory from different
angles is spending two thirds of the gallery on the half of the game that does
not sell.

---

## 4. The A/B loop

There is no icon A/B testing tool on Roblox. The method is manual and it works:

1. Ship one.
2. Watch **play-through rate** in the Creator Dashboard.
3. Change **exactly one element** — subject, background, expression, framing,
   text. One. Not two.
4. Ship again.

Worth running weekly for the first month, then monthly.

**It is worth nothing until analytics exists.** You cannot read a CTR change
against a game whose retention is also moving, and until this round both were
moving at once and neither was measured. The analytics PR in this round is what
makes this loop legible; run it after that lands, not before.

---

## 5. Visible stakes — the part that is code

Item 6 closes with something that belongs here rather than in the art brief:

> *"the raids need visible stakes. Right now a raider hitting your vault quietly
> decrements a number. If someone can SEE something being taken, that's a clip.
> If it's a number going down in a corner, it's nothing."*

`Economy.steal` is already called on every raider hit. Giving that call a body —
something a spectator can read without context — is what turns a raid into
something worth filming. That is tracked as its own change, not as art.

---

## 6. UGC as a free top-of-funnel, and its risk

The Marketplace is a real discovery channel that costs an upload rather than a
budget, and **emotes and animations are the fastest-growing and least saturated
category** — hair and accessories are picked over. A "tung tung tung" emote puts
the game's name in a surface players browse voluntarily.

**Flag the risk honestly before anyone does this.** Tung Tung Tung Sahur is a
character created by a TikTok user in February 2025. It is not ours. Shipping a
game that *references* a meme and shipping *Marketplace items* off somebody
else's character are materially different risk postures, and the second is a
takedown surface. If it is done at all, do it with an original silhouette rather
than a copy.

---

## 7. What we are not doing, and why

**Paid ads.** Ads only make sense if players eventually pay for themselves. We
have decided not to monetize, so LTV in Robux is zero, so ROAS is zero at any
CPI. Paid traffic into this game is pure cost with no payback mechanism.

The corollary is the useful half: **the algorithm is the ad budget.** A game that
retains 30% of its players gets roughly three times as much free traffic from
Roblox as one that retains 10%. Every hour spent on the retention items is an
hour spent on acquisition. Sponsoring a game that is not retaining is buying a
bounce.

---

## 8. The honest accounting

Two of the six things Roblox scores us on are about spending Robux. We have
chosen not to monetize, so **a third of that list is zero for us, permanently**,
and no amount of engagement work moves it. The other four have to be genuinely
good rather than adequate.

The upside is real and worth saying once: aggressive monetization is one of the
most-cited reasons players quit tycoons, and we have removed that entire class of
churn and that entire class of design compromise. It is a defensible position.

It was just not a free one.

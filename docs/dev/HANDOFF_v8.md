# Tung Tung Tycoon — Handoff v8

**Repo:** `github.com/adit-rah/ttt`
**Supersedes:** `HANDOFF_v7.md` **on the HUD's layout only.** v7 is still right
about everything else it covers, and its §10 question about the status card on a
real phone is answered below only in the sense that the numbers moved — nobody
has still looked at one.

`docs/dev/INVARIANTS.md` §7 is the live contract; this document is why this round
changed it. One pull request.

**The brief was "the UI looks odd — standardise it, make the positioning
relative, and move the invite out of the top-left card." Three of the four
defects behind that were findable by reading; the fourth was findable only by
adding up two numbers in two different files.**

---

## 1. What changed

| Area | What |
| --- | --- |
| `UiKit.lua` | `dock` — the four named corners every top-level region is now placed with — plus `railItem` and `personPlus`, the invite glyph drawn out of rounded rectangles |
| `HUD.lua` | Four docked regions in `Root`: `Column`, `Rail`, `Toasts`, `Actions`. The status card loses its friend row and its INVITE pill and gains a full-width terms line. `HUD.column()` is new. `HUD.toast` now destroys cards past `UI.Toast.MaxCards` |
| `SessionUI.lua` | Builds into `HUD.column()` with a `LayoutOrder`; knows no X and no Y. Eleven literals and three hand-copies of Config numbers deleted. `layoutTail()` is the only thing that sizes the panel |
| `Config.lua` | `UI.Rail`, `UI.TouchReserve`; `UI.SessionPanel` re-cut row by row with both heights derived; `UI.Toast` and both `UI.Modal` cards given their insides; `StatusCard.Y` and `SessionPanel.Y` **deleted** |
| `verify_config.lua` | Two friend-row checks retired, one tautology and one false proxy written and then withdrawn (see §3), fifteen added |
| `hud_spec.lua` | Two new specs; the boot-order spec now asserts through the column |
| `mock/instance.lua` | `GetDescendants`, and a property read that can return `false` (see §3) |

### The four defects

1. **The invite was inside the balance card.** A pill on a friend row, with five
   `Config.UI.StatusCard` keys and four derived Xs and Ys existing to fit it. It
   is a top-right rail item now — a person-with-a-plus glyph over a caption.

   The old design note argued that the row's ZERO state was the point: "+0% • no
   friends here yet" is what turns an invite into an offer. That argument was
   right and it moved with the control. The caption reads what ONE friend would
   be worth when you have nobody here, and what you are getting once you do — the
   price tag is now on the thing you press rather than three inches away from it.

2. **Every top-level surface spelled out its own corner.** Five call sites in
   three files each wrote an `AnchorPoint` and a `UDim2.new(1, -UI.Margin, …)`.
   The left column's two panels were positioned by two files reading
   `Config.UI.StatusCard.Y` and `Config.UI.SessionPanel.Y` separately — which is
   *exactly* the disagreement `Config.UI`'s own column comment says that table
   exists to catch. It had been one edit away the whole time. Both Ys are gone
   and the column is a `UIListLayout`.

3. **The action stack was on top of the jump button.** `buildActions` docked
   REBIRTH + LEAVE PLOT at `(1,-18),(1,-18)`: 200×112 in exactly the corner
   Roblox draws the touch jump button in, with the movement thumbstick in the
   corner opposite. Four out of five sessions are phones. Nothing in `src/` or
   `docs/dev/` had ever mentioned the touch-control zones. `UI.TouchReserve.Bottom`
   is a declared 170 design px and both bottom corners are now left alone.

4. **`SessionUI.layoutTail()` could build a panel taller than the verifier's
   number.** `UI.SessionPanel.TallHeight` was 258 — the ONE-optional-row height —
   and both optional rows (Vault Timer, pending offline grant) are up at once for
   any returning player who has not maxed the vault, which builds 310.
   `ColumnBottom` was measured against 258. It fitted the screen by luck.

   Nothing could see it: the two numbers were `PANEL_BASE_HEIGHT`/`STACK_TOP` in
   `SessionUI.lua` and `TallHeight` in `Config.lua`, and `verify_config.lua`
   cannot read `src/client`. Both heights derive from `OptionalRows` now, and a
   spec drives the state and reads the height back.

   `render()` was also writing a height and then calling `layoutTail()`, which
   overwrote it two lines later. Two writers, and the dead one was the wrong one.

### The layout, at the 1280×720 design canvas

```
+--------------------------------------------------+
| +----------+                          [ @+ ]     |  rail    18..90
| | (T) 12.4K|                    +--------------+  |
| |    x1.30 |                    | toast        |  |  toasts 100..394
| | 2 reb .. |                    +--------------+  |
| |----------|                                      |
| | NEXT UPG |                     +-------------+  |
| | Dropper  |                     |   REBIRTH   |  |  actions 438..550
| | ####--12 |                     | LEAVE PLOT  |  |
| +----------+                     +-------------+  |
| +----------+                                      |
| | SESSION  |                                      |
| +----------+                                      |
|   thumbstick                          jump        |  reserved, 170
+--------------------------------------------------+
```

The left column ends at y=562 of 720 at its tallest, against 542 before — the
card is 30 px shorter and the session panel's real worst case is 50 px taller
than the number that used to be asserted.

---

## 2. What this round got wrong on the way, and left in

Three assertions were written, run, and withdrawn. They are worth naming because
the repo's rule is to falsify everything you add, and falsifying is what found
all three.

- **"No row on the status card is a touch target's height."** Written as a proxy
  for "there is nothing on this card to press", which is the real invariant and
  which `Config` cannot express because it holds numbers and cannot see a
  `TextButton`. It failed against the shipped config the first time it ran: the
  balance row is 46 px tall to hold 38 px of text and is not a control. The
  invariant moved to `hud_spec.lua`, which walks the card's descendants.

- **`TallHeight - Height == OptionalRows * (RowHeight + RowGap) - RowGap`.** Both
  heights are derived from those three numbers eight lines apart in the same
  block, so the identity holds by construction whatever anybody types. It could
  not fail. The thing that CAN be wrong is `OptionalRows` disagreeing with the
  list `SessionUI` stacks, and that is a spec.

- **`ContentWidth > TextWidth` on the card.** `TextWidth` is defined as
  `ContentWidth - IconSize - IconGap`, so this is true for any positive coin.
  Deleted rather than shipped.

Fifteen assertions and three specs survived, and every one of them has been
watched failing under a mutation of the file it guards.

---

## 3. Two harness defects, found by the first spec that looked

Both are in `tools/testing/mock/`, both are fixed, and both had been invisible
because nothing had exercised them.

- **The Instance mock could not store `false`.** `__index` read
  `rawget(self, "_props") and self._props[key] or nil`, and `true and false or
  nil` is `nil`. Every boolean-false property in the game read back as nil:
  `Visible`, `TextScaled`, `AutoButtonColor`, `Enabled`, `ResetOnSpawn`. The
  first spec to read one was the invite's — whose entire contract is that it is
  hidden until account policy answers — and it failed with `got nil, want false`
  against code that was correct.

- **No `GetDescendants`.** Both modals walk their own descendants to force a
  ZIndex onto the card's `UICorner` and `UIStroke`. The method did not exist, so
  the whole path raised inside a signal handler, which the Signal mock swallows.

Neither is a claim about Roblox; both are the mock failing to be what it already
said it was.

---

## 4. What only Studio can tell you

The harness resolves no rectangle and advances no tween, so **every number in §1
is computed correct, not seen correct.** In rough order of what would hurt most.

1. **Is 170 design px the right bottom reserve?** It is a guess at how tall
   Roblox's touch controls get, guarded only by being at least two primary
   buttons. Open the place on a phone and look at where the jump button actually
   lands relative to REBIRTH. This is the single number this round would most
   like back.
2. **Does the person-with-a-plus read as a person at 40 px?** It is a head, a
   domed torso clipped at the container's bottom edge, and a plus in a disc,
   drawn out of five `Frame`s. Nobody has seen it. If it reads as a blob, the
   fallback is a wider glyph or a word under it — the caption slot is already
   there.
3. **Is the caption legible at `MinScale`?** 13 design px is 8.1 physical, which
   is the floor this repo declares and has never tested at.
4. **Does the rail collide with the 2026 unified topbar?** `IgnoreGuiInset =
   false` should push it clear, and `ScreenInsets = CoreUISafeInsets` is pcall'd
   on top. Top-right is the corner the engine's own chrome likes most.
5. **The left column on a real phone**, carried forward from v7 §10 and now with
   different numbers: 562 of 720 at its tallest. Whether sub-446px-tall landscape
   is supported at all is still a product decision nobody has made.
6. **Does one toast replacing another read as a drop?** `MaxCards = 4` is
   enforced now, where before the list silently overflowed. Four is a guess about
   how many notifications a player can be behind.
7. **The invite's hidden-at-construction window.** `inviteButton.Visible = false`
   before `CanSendGameInviteAsync` answers is unobservable in the harness — the
   mock resolves synchronously, so `refreshInvite` has already run by the time a
   spec can look. In Roblox that call is a web request and the window is real.

---

## 5. What is still not enforced

New `[nothing]` entries in `INVARIANTS.md` §7 from this round:

- **`UiKit.dock` names the corners, but nothing stops a new panel setting
  `Position` by hand.** A lint could look for `AnchorPoint` assignments in
  `src/client` outside `UiKit.lua`, the way the one-ScreenGui pass looks for
  `Instance.new("ScreenGui")`. It would have caught five of the call sites this
  round replaced. Not written, because a panel positioning a child inside itself
  is legitimate and the lint would need to tell the two apart.

- **The upgrade shop is still bottom-docked into the touch reserve.** Both its
  `Config.Prototypes` flags ship `false`, so it draws nothing and moving a
  surface nobody can see is a change nobody can check. When `PlayerUpgrades`
  graduates, `ui.ShopPanel.BottomGapNoUtility` has to start at
  `ui.TouchReserve.Bottom` rather than at `ui.Margin`, and `UpgradeUI.lua:384`'s
  toggle with it. There is a comment saying so at the derivation.

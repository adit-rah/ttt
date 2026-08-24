# HANDOFF v22 — the screen, drawn in one system

design:D-05, via #183. Seven stacked PRs, #184 through #190.

## 1. What moved

- **#184 — colour is a role.** `Config.UI.Palette` (what the colours are) and
  `Config.UI.Role` (what each is for). Every builder names a role; 26 raw
  `Color3` calls across seven files are gone, and a lint keeps the 27th out.
  Because the palette is in Config, `verify_config.lua` can do arithmetic on it:
  contrast is asserted against the card composited at `PanelAlpha` over a bright
  sky, which is what a label actually prints on.
- **#184 also — a field read off `UiKit` or `Style` must exist.** Written after
  the palette move deleted `UiKit.INK` and left three live reads of it, which
  every pass waved through. The same lint then found `Style.Font.head`, read at
  five sites that `Style.lua` has never defined — so every heading in the shop,
  the help card and the rebirth report had been rendering in the body face.
- **#185 — the wooden palette.** Grip-tape ink, walnut card, blonde-ash text,
  brand-stamp gold, burnt red, and one steel blue for notices. `accent` retired
  and its three jobs split. `PanelAlpha` 0.12 → 0.08, because the one risk the
  contrast maths cannot answer is a walnut card over a wooden wall.
- **#186 — one grid, one weight.** Four primitives — `rect`, `dot`, `bar`,
  `ring` — on a 24-unit grid, with the stroke weight resolved once per drawing.
  The letter `T` in a disc, `✓`, and `◆ ▲ ⌂ !` are drawn glyphs now.
  `personPlus` folded into the registry.
- **#187 — a button is a variant and a state.** Five variants, four states,
  `TextScaled` gone. Fixes all five sub-44px touch targets, the worst being the
  party decline button at 16×12 physical pixels.
- **#188 — the rail and the touch pad are the same tile.** `UiKit.tile` requires
  both a glyph and a caption; `railItem` handed back a slot two of its three
  callers dropped. `MovementClient`'s three buttons come through UiKit at last.
  Centred docks, so the compass and the tower banner stop overwriting their own
  anchor.
- **#189 — the shop is a list you can scan.** Its own `Config.UI.Shop`, a
  scrolling card, icon wells, tier pips, and it reads the balance — it did not,
  so an unaffordable buy fired the remote and came back as a toast saying no.
- **#190 — every card declares its size.** The card lint widened past its
  literal-only blind spot, and the column budget made honest: it counted two of
  four cards, and the four come to 934 design px in a 720 canvas.

## 2. What only Studio can tell you

1. **Do the glyphs read?** Nothing in the harness knows whether the bat looks
   like a bat. The coin at 48 px on the status card, the compass set at 20 px
   (which is 12 physical at `MinScale`, and `home` is the one most likely to turn
   to mush), and the bat and shield at 28 px in the shop's wells.
2. **Wood on wood.** The contrast maths measures the card against the SKY. A
   walnut card in front of a wooden wall is the comparison it cannot make, and
   `UI.PanelAlpha` is the lever if the card floats.
3. **The touch pad, held.** Three tiles bottom-left. Hold RUN: it should go green
   and stay green, the same look a running boost has. That surface had never once
   executed in the harness before this round.
4. **Does `info` read as help?** The `?` on the rail is a drawn info circle now,
   because a question mark is a smooth open curve the four primitives cannot make.
   This is an open question on #183, and this is the substitution it asks about.
5. **Does scrolling the HUD column feel wrong?** #190 makes the stack reachable
   rather than running off the bottom silently. If it feels wrong, the answer is
   that a card leaves the column — and which one is #183's second open question.
6. **Sized text, everywhere.** Every button label is a fixed size now, so a long
   one truncates instead of shrinking. `CLAIM x2 BOOST • 10 MIN` and
   `AFTER BAT FORGE` are the two most likely to clip.
7. **Four drawing claims only Roblox can settle.** That `UIStroke` on a
   transparent Frame gives a clean 2-px ring at 20 px; that `Rotation` on a small
   Frame antialiases acceptably; that a `UICorner` of half the height gives round
   caps rather than an ellipse; and that `ClipsDescendants` clips the person's
   torso the way it did before the fold.

## 3. What the harness learned

Three wrong claims about Roblox came out of the mock this round, all found by
speccing the touch pad:

- `UserInputService.InputEnded` did not exist, and `MovementClient` connects it
  on every platform — so that module's `start` had **never run** in this harness.
- `TouchEnabled` was false with no way to flip it, so the surface four out of
  five players see was unreachable. Specs set it before the module loads now.
- `instance.lua` said "every button in `src/client` connects `Activated`" as a
  statement of fact. `MovementClient` connected `MouseButton1Click`. It connects
  `Activated` now, and the mock grew the two halves of a hold.

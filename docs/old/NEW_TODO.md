The plain version of docs/ideas/EXPANSION.md. Same list, none of the arithmetic.

Ordered by what you can start today, NOT by what matters most. Items 1 through 3 are small and depend on nothing, so they're first. But item 4 is the actual point of this round. The second floor is the thing that gives the game somewhere to go, and items 5 and 6 are both waiting on it. If you only get one thing done, get that one.

1. The text bubbles on the plot are all shouting at the same volume
    - The grey locked ones are exactly as bright as the green buyable one. Only the colour changes between them — same panel, same opacity, same size, same little light. So the plot reads as a wall of labels instead of as one thing to walk towards.
    - Locked ones should be much fainter and thinner, and smaller wouldn't hurt. The buyable one should be the only thing your eye lands on.
    - The buy buttons currently show through walls. That's one setting and it's on for every state, so even the locked ones x-ray. Turn it off.
    - Careful though: that setting is doing a real job. Without it the label for the button you're walking at disappears behind the dropper standing next to it. So the labels probably need to sit a bit higher once they stop x-raying. Hiding behind a wall you're on the wrong side of is correct; hiding behind a machine two feet away isn't.
    - Two things should keep showing through everything: damage numbers, and enemy nameplates. The nameplates aren't our choice anyway, Roblox draws those on top no matter what.
    - While you're in there: we're using three different fonts, seven different outline settings, and view distances ranging from 90 studs to 1200, all picked one at a time. Pick one of each and use it everywhere. Also, statue faces currently render at unlimited distance, which is just an oversight.

2. Waves should be bigger and show up sooner
    - First raid 30 seconds after the world loads, and the next one 30 seconds after you clear the last one. Right now it's 60 and about 32.
    - Bigger too: start at 6 raiders instead of 4, add 4 per wave instead of 2, and let it climb to 40 instead of 26.
    - This does NOT undo the anti-swarm work. Only 8 raiders can engage you at once no matter how many are alive, so a bigger wave means more reinforcements arriving, not more people hitting you at the same time. Worth knowing before it looks like the two changes fight each other.
    - Do not shorten the warning time to close the gap. Twelve seconds is exactly how long it takes to run home from the arena, and it's the only reason someone standing on their plot can get back before the raiders land. Shorten the rest between waves instead.
    - One thing to actually watch: 40 raiders is a lot more parts on screen than 26. We've never tested what a full server looks like at full scale, and this is the change most likely to be the one that finds out.

3. The raid banner should be a sign in the world, not a bar across everyone's screen
    - Put it over the Tung statue in the middle of the arena. That's where the raid is, and the statue is visible from every plot.
    - One line, big, no box around it, nothing fancy. It should be readable at a glance and ignorable the rest of the time.
    - Three things about the current one are worth keeping when you move it: the countdown ticks locally instead of the server sending a message every second, it can't get blanked by a leftover timer from the previous wave, and it shows the quiet gap between waves counting down instead of going blank. Those were all deliberate.
    - Do this after item 1 so it uses whatever font and outline you settled on there.

4. The second floor, properly — this is the one that matters
    - Most of it is already written and switched off. There's a deck, railings, a belt, a collector, a dropper and a pair of teleport pads, all sitting behind a flag. None of it has ever run in Roblox.
    - There's one line stopping any of it from being real: buy buttons are always built at ground level, even when the game already knows the right height. Until that changes, nothing can be bought on the second floor and it can only ever be scenery with a free dropper on it. Fix that first.
    - The floor also needs to actually be a purchase. Right now it appears for free the moment you own the last dropper.
    - Move that unlock to roughly the halfway point of the build rather than the very end. At the end it's about eighty minutes in, which is too late for anyone to see it. There's a separate reason to want this too — see GROWTH-TODO item 1, the back third of our build is already too long to count for anything.
    - Known gap: the income readout won't include the second floor's dropper. Your plot sign and your vault sign will both under-report once it's running, and upgrader buttons will quote you less than they're actually worth.
    - Known gap: there's one shared limit on how many Tungs can be on a plot at once, and the ground floor already uses most of it. The second floor wants its own dropper and item 6 wants to speed everything up. Two of those three are pulling on the same number, so decide on purpose instead of finding out.
    - Also worth knowing: the deck is a tight fit. It sits flush against the back wall and clears the roof pillars by less than half a stud. And the roof already shrinks itself when the floor is switched on, which is the kind of arrangement that breaks quietly when either side moves.

5. The weapon and armour cabinets should show up with the second floor
    - They currently stand on the plot from the moment you claim it. Two big display cases and nine pedestals, for something you can't use yet and have no reason to care about. That's most of the visual noise in the first few minutes.
    - Gate them on the second floor unlocking, and don't build them at all until then.
    - Be aware what this costs: no weapon or armour upgrades at all until you unlock the floor. That's the whole reason item 4 moves the floor to the halfway mark instead of leaving it at the end — at the end you'd fight the entire first playthrough with the starting bat and no armour.
    - This obviously needs item 4 first.

6. A generator behind the factory, outside the plot
    - New buildable area past the back edge of the plot, behind the main run of the conveyor. Costs Tung, and upgrading it speeds up production.
    - It has to speed up the belt at the same rate it speeds up the droppers. Belt speed doesn't affect how much you earn, only how crowded the belt is — so raising it alongside is free, and it's the only way this works at all. We're already at about 80% of the belt's capacity, so speeding up the droppers on their own runs out of room almost immediately and then quietly starts eating the income you just paid for.
    - It's also the more honest version of the idea. A generator powers the line, so the line runs faster, belt included.
    - Build it as its own slab behind the plot rather than making the plot itself bigger. Everything on a plot is positioned by fixed coordinates, so growing the plot slides the pad out from under the walls, the belt, the totem, the cabinets and the second floor's deck all at once.
    - Growing backwards is cheap. Growing sideways is not — the whole ring of plots is spaced off the plot's width, so any change there re-solves where every plot in the game sits.
    - Doesn't strictly need item 4, but it reads better once there's a second floor to power.

One thing that applies to all six: none of this is checkable by the verifier. It
covers numbers, not how anything looks or feels. The last two rounds produced
three separate changes that passed every check we had and still had to be judged
by eye — two of them were animation bugs, and one was the bat, which we just
reverted. Budget Studio time for every item on this list.

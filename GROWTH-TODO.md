The plain version of docs/ideas/GROWTH.md. Same list, none of the sourcing.
Ordered by what actually moves the needle first, not by how hard it is.

1. The game takes too long in one sitting and that hurts us twice
    - Roblox only gives us credit for the first 60 minutes a person plays in a day. Anything past that is invisible to them. Our full build is 88 minutes, so the last three purchases literally don't count for anything.
    - It's worse than just wasted though. Someone who finishes the whole factory in one go has seen everything we have and has no reason to open the game tomorrow. We burned the whole thing in one night.
    - What we want is one satisfying run that finishes in about 50 minutes, and then something obviously waiting that they can't get to tonight. End on wanting more, not on being done.
    - The first rebirth is currently 10 minutes AFTER the full build, so basically nobody will ever see it. Pull it way earlier. Rebirth is supposed to be the thing that makes the game repeatable and right now it's parked behind a wall almost nobody reaches.
    - The good news is this is all just numbers in Config.lua and the verifier prints the whole curve in about a second, so we can try five versions in an afternoon.

2. A bunch of the stuff that fixes this is already written and just switched off
    - Offline earnings, the daily streak, the playtime ladder, the boost button, weekend double cash. All of it exists. All of it is sitting behind flags set to false in Config.
    - Roblox specifically counts how many separate DAYS someone plays, not just total hours. That is exactly what these features produce. This is the highest value-per-hour thing on the entire list and most of the work is already done.
    - Don't just flip the switches though. None of that code has ever actually run inside Roblox, and the last time we shipped something that was "reviewed and correct" it was broken in two completely different ways that only showed up in Studio. Budget a real testing session, not a config change.

3. There is no reason to come back tomorrow
    - Right now when you close the game, nothing is running, nothing is waiting, and nothing is going to be different when you get back. That's the whole problem in one sentence.
    - Offline earnings covers most of it, but the part people miss is that it needs to be VISIBLE when you leave, not just when you return. The vault should be visibly filling up as you walk away, with a number attached to it. "Come back tomorrow and this is bigger" needs to be something you can see, not something you find out about later.
    - A popup when you quit doesn't do this. A counter you watch tick does.
    - Also worth knowing: whatever we use to pull people back has to drop them into something fun within about ten minutes. Pulling someone back into a grind is worse than not pulling them back at all.

4. Nobody has any reason to bring a friend, and Roblox is counting
    - One of the things Roblox scores us on is how often people play with friends specifically — joining off a friend, an invite, or a private server. Not random matchmaking, actual friends.
    - We have zero of this. No friend detection, no invite button, nothing in the game that is better with two people. Six plots in a ring and every single person is alone in their own box watching their own number.
    - Cheapest fix is a bonus for having friends in the server, something like +10% each up to +30%, with the number shown on screen so it's obvious what another person is worth.
    - Then an invite button right at the moment they see that number, because at that point bringing someone has a price tag attached.
    - The bigger one is a boss the whole server fights together in the arena. We already have the arena, the wave system, and boss enemies every 5th wave. It's the one thing in this game that would actually need another human being, and it's most of the way built already.

5. The picture on the game page is the whole first impression and we don't have one
    - Before anyone plays a single second, they see a small square icon in a list and decide in about a quarter of a second. That icon matters more than a month of features and we have not thought about it once.
    - It shows up at roughly 150 pixels, so it needs one subject, big, high contrast, and basically no text. Anything smaller than a face turns to mush at that size.
    - Show a Tung guy mid-swing hitting a raider. Do not show a conveyor belt. The belt is what the game IS, but it's not what makes someone tap.
    - Three gallery thumbnails, and make each one sell a different thing instead of three angles on the same thing. One for the full factory running with a big number, one for the bat connecting, one for the arena with a bunch of players in it.
    - There's no A/B testing tool for this. You ship one, watch the click rate, change exactly one thing, ship again. Worth doing weekly for the first month.

6. We have a genre, not a pitch
    - "Tycoon" isn't a pitch. "Brainrot tycoon" is the single most copied thing on the platform right now. If someone asks what our game is and the answer is a genre, we've already lost.
    - Steal a Brainrot's entire hook is one word. Steal. That's it. And the reason it spread is that when someone loses their stuff on camera it's funny to a person who has no idea what the game is.
    - We already have a sentence nobody else is saying: your factory gets raided and you fight them off with a bat. The arena, the raids, the boss waves, the PvP zoning — that's all built and shipping right now. That's the thing.
    - Everything needs to agree with that sentence. The icon, the thumbnails, the title, the description, and the first thirty seconds of actually playing. If the icon promises a fight and minute one is watching a belt move, we get punished for the mismatch on top of just losing the player.
    - Related: the raids need visible stakes. Right now a raider hitting your vault quietly decrements a number. If someone can SEE something being taken, that's a clip. If it's a number going down in a corner, it's nothing.

7. Four out of five people play this on a phone and it looks bad there
    - 80% of all Roblox sessions are mobile now, up from 74% a year ago. More than half of Roblox is under 16.
    - Our UI is built in fixed pixel sizes. There's a 470x330 card in the session panel and a 430x250 one in the HUD, with no scaling of any kind. On a phone those eat the screen or run off it.
    - We also don't account for notches or home bars at all, so parts of the UI are going to end up underneath them.
    - Combat is actually fine, leave it alone — the bats are normal Roblox tools so the built-in mobile fire button already drives them for free. It's specifically the panels.
    - This isn't polish. This is the version of our game that most people's first impression is of.
    - One more thing to keep in mind while we do the sound and particle work: mobile can only handle about a quarter of the particles a desktop can. Easy to blow that budget without noticing on a dev machine.

8. We have no idea what any player actually does
    - There is not a single analytics event anywhere in the game. Not one.
    - So every argument about the price curve, the drop-off point, whether onboarding works — all of it is us guessing against industry averages instead of looking at our own players.
    - We don't need much. When someone joins and on what device, how long until they buy their first button, how long they played and where they stopped, how long before they came back, when they rebirth, what they claimed from offline earnings and whether the cap cut them off.
    - Do this early. It doesn't fix anything by itself but it makes every other thing on this list cheaper to get right, because we stop arguing and start reading.

9. Nothing is happening on a schedule
    - Roblox changed how they judge games this year. They used to look at a week, now they look at a month. So the question stopped being "is this fun tonight" and became "did this hold people for four weeks."
    - That makes the update calendar the actual growth strategy, not a nice-to-have. Something small every week, something big every month or season.
    - Be realistic about staffing though. A fortnightly update that actually ships beats a weekly one that keeps slipping.
    - Weekend double cash is already written and switched off, and it's the cheapest recurring thing we have. It needs no calendar and no work.
    - When we do codes, tie them to milestones instead of dates. A dated code just rewards whoever happened to already be playing. A code that unlocks when we hit some number rewards people for pushing the number, which is the whole point.
    - Give codes a timed boost as well as cash, because the boost is what makes someone actually play right now instead of claiming it and closing the game.

10. Two things worth saying out loud
    - We decided not to monetize, and that's fine, but two of the six things Roblox scores us on are about spending money. So a third of that list is zero for us forever and no amount of engagement work moves it. The other four have to be genuinely good, not just okay, to make up for it.
    - The upside is real though — aggressive monetization is one of the top reasons people quit tycoons, and we've removed that entire problem. Just don't let anyone tell you it was free.
    - Paid ads are pointless for us specifically. Ads only make sense if players eventually pay for themselves, and ours can't, so it's just spending money to get a bounce. Retention is our advertising budget — a game that keeps 30% of its players gets roughly three times as much free traffic from Roblox as one that keeps 10%. Every hour on items 1 through 4 is an hour of marketing.

11. One blocker worth flagging
    - The save system still has no session locking. That's been the highest severity thing in the repo for a while and it's still true.
    - It matters here because the highest-upside social stuff — anything where players wager, trade, or take something real off each other — is exactly the stuff that gets duped and exploited without it.
    - So it's not just a data safety problem anymore, it's the thing standing between us and the features most likely to make someone film this game.

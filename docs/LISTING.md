# Marketplace listing text (copy / paste)

**Name:** AKForeverWeaponBuffs
**Category:** Buffs & Debuffs (second: Combat)
**Game version:** World of Warcraft: Forever (1.60.1)
**License:** MIT
**Summary (one line):** Every timed weapon buff - imbues, oils, stones, poisons - with timers, reminders, one-click reapply and party sharing.

## Description

*Part of a small family of addons built for the WoW: Forever game mode, with one mission: minimalistic UI additions that bring out the utility
Blizzard's UI does not give - minimal in nature, no Lua errors, always smooth.*

Weapon buffs run out at the worst moment, and Blizzard's UI gives you a tiny icon and nothing else.
**AKForeverWeaponBuffs tracks every timed weapon buff** on your main hand, off hand and ranged weapon -
shaman imbues, oils, sharpening stones, weightstones, poisons - shows a timer for each, tells you when one is
missing, wrong or about to run out, and puts it back with one click.

- **No setup, no ID tables.** The addon learns which spell or item applies a buff the first time you apply
  it. Whatever Blizzard adds next works the same way.
- **One-click reapply, in combat too.** The big button reapplies the most urgent buff to the right hand.
- **Per weapon setup and per character:** one-hand, two-hand and dual wield each remember their own buffs.
  A small picker pins a buff to a hand or stops tracking it.
- **Party sharing.** Everyone running the addon shares their weapon buffs, so a shaman sees who is really
  getting Windfury Totem - and whose own weapon buff is blocking it.
- **Built not to break things:** the reapply button is Blizzard's own secure button, and nothing protected
  is touched in combat - no "action blocked" popups.

The successor to SodShamanWeaponBuffs (Season of Discovery), rewritten for the Forever client - and no
longer for shamans only.

### Commands

- `/wb` - lists the commands
- `/wb show` / `hide` - the frame; drag it to move it (out of combat), `/wb reset` puts it back in the middle
- `/wb empty` - keep the frame visible while there is nothing to track (handy for placing it)
- `/wb party` (`up` / `down`) - the party panel and the way it grows
- `/wb forget` - forget what was learned; right-click a buff in the picker to forget just that one
- `/wb comms`, `/wb diag` - what is being shared; a report for bug reports

### Known limitation of the 1.60.1 beta client

The beta client writes addon settings on logout but never reads them back, so the frame's position and your
tracked buffs last until you log out. The addon learns your buffs again the next time you apply them.

Source and issues: https://github.com/ajkatz/AKForeverWeaponBuffs

## Logo and screenshots

Logo (400 x 400): `..\ForeverBranding\out\AKForeverWeaponBuffs\logo-400.png` (master: `logo-1024.png`).
Screenshot to take in game: the frame with a running timer and the big reapply button; the party panel.

# AKForeverWeaponBuffs

## 2.1.2

- The party panel has a close button: the small x in its corner hides it, with a chat line and a tooltip
  that name `/wb party`, which brings it back. Until now the command was the only way, and nothing on
  the panel said so.
- "Don't track" keeps a greyed row that says "not tracked" instead of a slot that vanishes once its buff
  runs out: that row is the way back to the picker. Greyed rows alone keep no frame on the screen.
- Rows say what they are: `MH Imbue` for the weapon spell, `MH Oil` (or Stone, Poison, Lure) for what
  was rubbed on. Forever lets a shaman carry both on one weapon, and two rows both labelled "MH" made
  it a guess which picker set which. The picker's title and a line under it name the row the same way.
  The hand letters join the label only when more than one hand has rows, and a missing or wrong buff
  says `rebuff` / `wrong` in the timer slot, so the rows are no wider than before. `/wb show` now says
  why nothing appeared when there is nothing to track, and names `/wb empty`.
- **Settings follow the character again.** Client build 1.60.1.70170 (Oct 1 2026) moved a character's
  surname into the realm slot of `UnitName`, so every character started a fresh, empty profile. The profile
  is now keyed by the full name and the realm (`Purrdee Bubson - ClassicBetaPvE`, the spelling the older
  builds saved under) and bound at PLAYER_LOGIN, when the client knows the name for sure, so a cold login no
  longer lands in an `Unknown` profile. Profiles saved under the other spellings are folded into it the
  first time each character logs in: the long-standing profile keeps its values, the others fill its gaps,
  and `/wb diag` says what was adopted. The 2.0.1 realm-name merge is part of the same rule.
- The same client build reads saved settings back again, so "the position and the tracked buffs last until
  you log out" is history; the saved-settings bridge (`tools/Install-SavedStateBridge.ps1`) is no longer
  needed and `-Remove` takes it out.

## 2.1.1

- Fishing lures are learned and reapplied: the buff is recognised by the icon its enchant wears, since
  the enchant calls itself "Fishing Lure" and never matches the bauble's name.
- An enchant the client reports with icon 0 is treated as having no icon (0 is truthy in Lua, so it used
  to pass every icon check).

## 2.1.0 - first public release for WoW: Forever

For **World of Warcraft: Forever** (1.60.1, Interface 16001). The successor to SodShamanWeaponBuffs
(Season of Discovery), rewritten for the Forever client and no longer for shamans only.

- Tracks **every timed weapon buff** on main hand, off hand and ranged: shaman imbues, oils, sharpening
  stones, weightstones, poisons - with a timer per buff.
- **No ID tables:** the addon learns which spell or item applies a buff the first time you apply it, then
  reminds you when it is missing, wrong or under 60 seconds - and reapplies it with one click, in combat too.
- **Party sharing:** everyone running the addon shares their weapon buffs, so a shaman sees who is really
  getting Windfury Totem and whose own buff is blocking it.
- Per weapon setup (one-hand, two-hand, dual wield) and per character; a picker pins a buff to a hand or
  stops tracking it.
- Shaman extra: the skinning-knife swap for dual wield imbues.
- `/wb` lists the commands (`show`, `hide`, `reset`, `party`, `comms`, `forget`, `diag` ...).

Known limit of the 1.60.1 beta client, not of the addon: it writes addon settings on logout but never reads
them back, so the frame's position and your tracked buffs last until you log out - the addon learns your
buffs again the next time you apply them.

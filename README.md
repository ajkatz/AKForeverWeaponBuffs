# AKForeverWeaponBuffs

Weapon buff tracker for **World of Warcraft: Forever** (Interface `16001`).
Successor to [SodShamanWeaponBuffs](https://www.curseforge.com/wow/addons/sodshamanweaponbuffs) (v1.x,
Season of Discovery) - rewritten for the Forever client, and no longer for shamans only.

*Part of a small family of addons built for the WoW: Forever game mode, with one mission: minimalistic UI
additions that bring out the utility Blizzard's UI does not give - minimal in nature, no Lua errors, always
smooth.*

- Tracks **every timed weapon buff** on main hand, off hand and ranged: shaman imbues,
  oils, sharpening stones, weightstones, poisons - and whatever Blizzard adds next.
- **No ID tables.** The addon learns which spell or item applies a buff the first time
  you apply it, then reminds you (missing / wrong / under 60s) and offers a one-click reapply.
- **Party sharing.** Everyone running the addon broadcasts their weapon buffs, so a shaman
  can see who is actually receiving Windfury Totem and whose own buff is blocking it.
- Shaman extra: skinning-knife swap for dual wield imbues. (The shield charge counter was taken out in
  v2.0.3 - parked in `attic/shield-charge-counter`.)

## Install

From [CurseForge](https://www.curseforge.com/wow/addons/akforeverweaponbuffs) or
[Wago Addons](https://addons.wago.io/addons/akforeverweaponbuffs) (game version *World of Warcraft: Forever*),
or unpack a [release zip](https://github.com/ajkatz/AKForeverWeaponBuffs/releases) into
`_classic_beta_\Interface\AddOns\`. It works out of the box; `/wb` lists the commands.

## Using it

| You do | It does |
|---|---|
| Apply any weapon buff | Starts tracking it for that slot and weapon setup (1H / 2H / dual wield) |
| Click the big button | Reapplies the most urgent tracked buff (secure button, works in combat) |
| Click a row's small icon | Picker: *Auto* (follow what I apply), pin a specific buff, or *Don't track* |
| Right-click a buff in the picker | Forgets a wrongly learned buff |
| Drag the frame | Moves it (out of combat) |

`/wb` lists commands: `show`, `hide`, `reset`, `party`, `comms`, `comms test`, `forget`, `diag`, `debug`.

**Party panel** (`/wb party` toggles it): one row per party member *who has sent data* - members
without the addon get no row, and with nobody to show there is no panel. A member who runs the
addon with nothing on their weapons does get a row ("no weapon buffs": the rogue without poison).
`/wb party up` makes the panel sit on top of your own frame and grow upwards (first member nearest
to you, new rows appear above, nobody's row moves); `/wb party down` is the default.

## How it works

```
Core.lua         events, message bus, saved variables, session log, slash commands
Enchants.lua     read model over C_Item.GetWeaponEnchantInfo; rows keyed slot:type
Sources.lua      auto-learn: enchantID -> the spell/item that applies it
Tracker.lua      desires (auto / pinned / none), row status, fix-action choice
Comms.lua        party broadcast + roster ("U1^..." / "R1" on prefix WeaponBuffs)
UI/              PlayerFrame (secure fix button + rows), Picker, PartyPanel
Shaman.lua       skinning-knife strategy
Diagnostics.lua  /wb diag -> AKForeverWeaponBuffsDB.diag
```

Forever runs the retail (Midnight-era) API, not the Classic Era one. The things this
addon depends on were verified against Blizzard's own UI source for build 1.60.1:

- `C_Item.GetWeaponEnchantInfo(Enum.WeaponSlot.X)` returns a *list* of
  `{ hasEnchant, enchantType, timeLeft, charges, enchantID, enchantIconID }`;
  `Enum.ItemEnchantType` = None / Permanent / Temporary / Imbue.
- `WEAPON_ENCHANT_CHANGED` fires on changes (a 1s poll backs it up).
- `SecureActionButtonTemplate`: `type=item` + `target-slot` applies a consumable to a
  weapon slot; `macrotext` still works.
- `C_ChatInfo.SendAddonMessage` can answer `AddOnMessageLockdown`; updates are queued
  and re-sent when `InChatMessagingLockdown()` clears.

**Learning rule.** An enchant is attributed to a cast made within ~2s before it appeared,
only if the names agree (`Windfury Weapon` ~ `Windfury 4`, `Dense Sharpening Stone` ~
`Sharpened (+8 Damage)`), and never if it lasts under 60s. Those short ones are *pulsed*
(totem buffs): shown, shared with the party, never nagged about.

**Dual wield rule.** The game, not the player, picks the hand an imbue lands on, so a cast
meant for the off hand can overwrite the main hand. While dual wielding, a *spell* landing
on a hand that already has a different preference does **not** rewrite that preference -
the row goes red ("Rebuff ...") instead. Change a hand's imbue through the picker. Items
are aimed at a weapon by hand, so they always follow "last applied".

## Saved settings on the Forever beta

The beta client (1.60.1) **writes SavedVariables on logout but never reads them back**
(verified 2026-09-18: the load counter on disk stayed at 1 across sessions, while the file
held the right position and tracked buff). Until Blizzard fixes that:

```powershell
.\tools\Install-SavedStateBridge.ps1            # then restart the game client completely
.\tools\Install-SavedStateBridge.ps1 -Remove    # once the client loads SavedVariables again
```

It creates a companion addon, `AKForeverWeaponBuffs_SavedState`, whose `.toc` lists the account's
`SavedVariables\AKForeverWeaponBuffs.lua` through a directory junction. A SavedVariables file is just
Lua (`AKForeverWeaponBuffsDB = { ... }`), so the client runs it as addon code before AKForeverWeaponBuffs
loads (`## OptionalDeps`). Everything AKForeverWeaponBuffs saves, per-character data included
(`AKForeverWeaponBuffsDB.chars["Name - Realm"]`), is in that one account-wide file for exactly this
reason. `/wb diag` reports `savedStateSource`: `client`, `bridge addon` or `none`.

Never delete the companion folder with `Remove-Item -Recurse` in Windows PowerShell 5.1 -
it follows junctions and would empty the real SavedVariables folder. Use `-Remove`.

## Tests

```powershell
lua tests/run.lua
```

`tests/wowmock.lua` is a strict stand-in for the client: unknown widget methods fail, and
touching the secure button (or the frame it is anchored to) during combat raises like the
real `ADDON_ACTION_BLOCKED`. Every scenario also fails if the addon raised any Lua error.
The mock encodes our *assumptions* about the Forever API - passing tests prove the logic,
not the assumptions. Those are what the next section is for.

## Open questions to test in the beta

Run through these, then `/wb diag`, `/reload`, and look at
`WTF/Account/<account>/SavedVariables/AKForeverWeaponBuffs.lua` (`AKForeverWeaponBuffsDB.diag`).

1. Does the frame appear with no Lua errors (`/console scriptErrors 1`)?
2. Apply an imbue / oil / stone: does a row appear, with the right name and icon?
   Is it learned (`diag.state.sources`)? Does the button reapply it to the right hand?
3. Can a weapon hold an **Imbue and a Temporary** buff at once (two rows on one hand)?
4. In combat: do timers keep running? Is `diag.state.enchantsLocked` ever set (secret values)?
5. Windfury Totem: does the recipient get a short *pulsed* row, and does the shaman's
   party panel show it with a green frame? What blocks it?
6. In a dungeon boss fight: `/wb comms` - do `lockdown skips` climb, and do updates
   arrive after the fight?
7. Shaman dual wield: which hand does an imbue land on? (Decides whether the
   skinning-knife strategy is still needed.)
8. ~~Are SavedVariables read back?~~ **No** - confirmed client bug; see "Saved settings on
   the Forever beta". Still open: does the client follow the bridge's nested junction
   (`diag.savedStateSource` should say `bridge addon`, `savedVariableLoads` > 1)?

Answered so far from real saved data: shaman imbues are reported as type `Imbue`
(row `MH:IMBUE`), Rockbiter Weapon is enchant 29 and lasts 60 minutes.

## Development

The repo lives outside the game; the client sees it through a directory junction:

```powershell
New-Item -ItemType Junction `
  -Path "C:\Program Files (x86)\World of Warcraft\_classic_beta_\Interface\AddOns\AKForeverWeaponBuffs" `
  -Target "C:\path\to\your\checkout\AKForeverWeaponBuffs"
```

When Forever launches the client folder will likely change: re-create the junction there.

**Releases.** A pushed tag (`v2.1.0`) is tested and then packaged by the
[BigWigs packager](https://github.com/BigWigsMods/packager) (`.github/workflows/release.yml`, `.pkgmeta`),
which uploads to CurseForge, Wago and GitHub Releases. Every push to `main` runs the tests and a dry run of
the packaging. `tests`, `tools`, `docs` and `attic` stay out of the zip. MIT licensed - see `LICENSE`.

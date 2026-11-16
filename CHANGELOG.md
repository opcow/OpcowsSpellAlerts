# Changelog

## 0.17.0

### Added

- "On the target's nameplate": a set of icons can sit on your target's nameplate, just above it, and follow it. Tick it on any of the set's alerts, or use `/osa plate <n> on`. Unlocked, drag the icons to place them on the plate. While the target has no nameplate showing (nameplates off, or out of view), they go back to their usual spot, which you place by dragging them then. Shift-drag an icon out of its set first to put only that one on the nameplate.
- Nameplate side: a set on the nameplate can go above it, or to its left or right. Pick it next to "On the target's nameplate", or use `/osa plate <n> above|left|right`.
- Icon height: an alert's icon can be wider than it's high, or higher than it's wide. The picture keeps its shape and its top and bottom, or its sides, are cut off, as Plater does. Set it next to the icon size, or use `/osa height <n> <size|off>`.
- Icon border, per alert: the action bar's frame, a thin or thick black edge, or none. Pick it under the alert's settings, or use `/osa border <n> action|thin|thick|none`.

## 0.16.0

### Added

- "A debuff is on the target" alerts: the icon shows, with a sound, while a debuff is on your target, ex: Frostbite, which procs at random. Add one with "Debuff by name..." (any name or spell id, not only your spells), by cycling Alert when, or with `/osa add Frostbite on`. In combat the game's own debuff button is shown in the icon's place, as the game hides auras from addons there; if it also hides whether that button is showing, there's no sound in combat.
- "Only while on target" for usable and combo point alerts (`/osa need <n> Frostbite, Frost Nova`): the icon only shows while one of these debuffs is on your target, so related alerts become one icon, ex: Ice Lance while Frostbite or Frost Nova is on. In combat, when the game hides debuffs from addons, the game's own debuff button draws the spell's icon instead, so it shows only while one of them is on, with no sound.
- "Anyone's" (`/osa anyone <n> on`): count the debuff whoever put it on the target, not only yours.
- The first time a debuff name is added, its spell ids are looked up out of combat, which takes a few seconds; the list shows "looking up its spell ids" meanwhile.

## 0.15.0

### Added

- "Whole seconds" option: an icon shown early counts down in whole seconds all the way, without tenths under 3 seconds.

### Fixed

- Usable and debuff alerts could show a combo point number (often 0) on their icon after "Alert when" was cycled past Combo points reach. Only combo point alerts, and alerts that want at least 1 combo point, show it now.

## 0.14.0

### Added

- Target, Enemy and Friendly conditions: hide an alert while you have (or don't have) a target, a living enemy target you can attack, or a friendly target.
- Combo point alerts can skip needing an enemy target, with No target needed.
- `/osa debug` logs each alert's state changes to the SavedVariables file, written on /reload or logout.
- Uploads to CurseForge.

### Fixed

- Icons disappeared after each wand shot in combat. The shot locks your spells for about a second, which the game doesn't flag as the global cooldown. A lockout no longer than a global cooldown that you didn't start with a spell of your own now leaves the icon up.

### Changed

- The "Any time" check is now "No target needed", and it's shown for combo point alerts too.
- A combo point alert now waits for 0 combo points (any) by default, instead of 5.
- Icons have the action bar button's thin dark frame with rounded corners, or a thin black edge on a client without it. They used to have a gold, orange, red or white border depending on the kind of alert.

## 0.13

- First version in git.
- Alerts when a spell is usable, when a finisher has enough combo points, or when your debuff falls off the target.
- Next-swing spells light up when clicked.
- Icon sets: each icon has its own size, Shift-drag pulls an icon out on its own, and icons snap together.

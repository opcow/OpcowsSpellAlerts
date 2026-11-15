# Changelog

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

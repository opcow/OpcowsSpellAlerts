# Opcow's Spell Alerts

A WoW: Forever addon that shows a spell's icon and plays a sound when you should use it:

- **Usable:** the spell is off cooldown and usable, ex: Riposte or Overpower.
- **Combo points:** a finisher is usable with at least the combo points you pick on your target. 0 means any.
- **Debuff fell off:** your debuff is gone from the target, ex: Rupture.
- **Debuff is on:** a debuff is on your target, ex: Frostbite, which procs at random.

Each alert can also:

- Dim or hide while the spell waits on energy, rage or mana, or wait for a minimum amount.
- Show early with a countdown before its cooldown ends or its debuff falls off.
- Flash for a few seconds when it comes on.
- Change its look while your energy, the target's health or your combo points compare to numbers, conditions joined by and/or: dim, glow, grey, or a red, green or blue tint. Ex: Slice and Dice glowing at 5 combo points and target health >= 10%, or Shank dimmed above 80 energy. Click **Look...** in the alert's settings.
- Only show while one of a list of debuffs is on your target, so related alerts become one icon, ex: Ice Lance while Frostbite or Frost Nova is on.
- Skip needing a target. By default usable alerts wait for combat or an enemy target, and combo point alerts for an enemy target.
- Hide while a condition is true or false, ex: out of combat, or while your target isn't friendly.
- Hide on the wrong target, ex: Exorcism on anything but undead and demons, or whenever the spell can't be cast on your target, out of range too.
- Play its own sound and have its own icon size, square or not, and border.
- Sit on your target's nameplate, above it or to its left or right.
- Grow with its set: the showing icons fill the set's first spots in the list's order, and slide over to close up when one goes.

Unlock the icons to move them. Drag an icon to move its set, Shift-drag to pull it out on its own, and drop it touching other icons to snap to them.

## Use

Type `/osa` or click the minimap button to open the options window. Everything can be set there. Shift-click the minimap button to unlock or lock the icons.

`/osa help` lists the slash commands, ex: `/osa add Eviscerate combo 5`.

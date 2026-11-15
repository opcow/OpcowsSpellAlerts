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
- Only show while one of a list of debuffs is on your target, so related alerts become one icon, ex: Ice Lance while Frostbite or Frost Nova is on.
- Skip needing a target. By default usable alerts wait for combat or an enemy target, and combo point alerts for an enemy target.
- Hide while a condition is true or false, ex: out of combat, or while your target isn't friendly.
- Play its own sound and have its own icon size.

Unlock the icons to move them. Drag an icon to move its set, Shift-drag to pull it out on its own, and drop it touching other icons to snap to them.

## Use

Type `/osa` or click the minimap button to open the options window. Everything can be set there.

`/osa help` lists the slash commands, ex: `/osa add Eviscerate combo 5`.

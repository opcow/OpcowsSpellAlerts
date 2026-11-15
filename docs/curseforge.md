# Opcow's Spell Alerts

**Spell alerts for WoW: Forever.** A spell's icon pops up with a sound the moment you should use it: when it's usable, when a finisher has enough combo points, when your debuff falls off the target, or when a debuff lands on it. Watch the fight, not your action bars.

## Alerts

- **It's usable.** The spell can be cast and is off cooldown, ex: Riposte after a parry, Overpower after a dodge, Frost Nova coming back.
- **Combo points reach.** A finisher is usable with at least the combo points you pick on your target, ex: Eviscerate at 5. 0 means any.
- **My debuff falls off.** Your debuff on the target has run out, ex: Rupture or Shadow Word: Pain. When the game hides auras in combat, the debuff is timed from your cast. Its length comes from the debuff itself when it can be read, or from the spell's tooltip. You can also type it in.
- **A debuff is on the target.** Ex: Frostbite, which procs at random. Any debuff name or spell id, not only your spells, and yours or anyone's. In combat, when the game hides auras from addons, the game's own debuff button is shown in the icon's place.
- **Next-swing spells** light up while they wait for your swing, ex: Heroic Strike, so you can see the click took.

## Each alert can

- **Show early** with a countdown, a few seconds before its cooldown ends or its debuff falls off.
- **Dim or hide** while the spell waits on energy, rage or mana, or wait for a minimum amount, ex: an energy dump at 90.
- **Want combo points** too, ex: Rupture fell off but only alert at 4 points.
- **Only show while on target:** only while one of a list of debuffs is on your target, so related alerts become one icon, ex: Ice Lance while Frostbite or Frost Nova is on.
- **Show for a few seconds** when it comes on, fading in and out, ex: Sprint coming off cooldown.
- **Skip needing a target.** By default usable alerts wait for combat or an enemy target, so spells that are almost always usable don't sit on screen.
- **Hide while** a condition is true or false: dead, in an instance, party, raid, resting, on a flight path, in combat, mounted, have a target, enemy target, friendly target, or a Fire, Earth, Water or Air totem is down.
- Play its own **sound**: ping, raid warning, ready check, alarm, or none.
- Have its own **icon size**.

## Icons

- Each icon gets the action bar's thin dark frame.
- Unlock to move them. Drag an icon to move its set, **Shift-drag** to pull it out on its own, and drop it touching other icons to snap to them.
- **Test** shows every icon for 3 seconds, so you can place them out of combat.

## Getting started

1. Type `/osa`, or click the minimap button or the addon compartment, to open the options window.
2. Click **Add spell...**, or drag a spell from your spellbook onto the list.
3. Pick when it alerts, then set anything else you like.

Everything can be set in the options window. `/osa help` lists the slash commands.

## Notes

- WoW: Forever hides some cooldowns and auras from addons in combat. Spell Alerts works around it with the flags the game leaves readable and with timers from your own casts, so a debuff removed early by someone else may not be noticed.
- `/osa probe <spell>` prints what the game lets the addon read about a spell, in and out of combat, if an alert seems off.

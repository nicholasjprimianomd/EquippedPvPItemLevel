# Equipped PvP Item Level

World of Warcraft Retail addon that adds equipped item level and PvP item level information to player tooltips and the character panel.

## Behavior

- Shows equipped item level for player tooltips.
- Shows PvP item level only when the addon can calculate one from Blizzard APIs or inspected PvP item tooltip data.
- Omits PvP item level for inspected players when no PvP gear/scaling data is available.
- Shows the player's own PvP item level from Blizzard's average item level APIs when available.

## Slash Commands

- `/epvpilvl help`
- `/epvpilvl debug on|off`
- `/epvpilvl verbose on|off`
- `/epvpilvl snapshot`

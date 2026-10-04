# Animal Tracks Outline

A Project Zomboid (Build 42) client mod. Outlines animals and animal carcasses when
Search Mode is on and the search focus is set to **Animal Tracks**. Outline opacity
scales with the Tracking skill: none at level 0, 10% at level 1, about 43% at level 10.

- Steam Workshop: <https://steamcommunity.com/sharedfiles/filedetails/?id=3657097711>
- Singleplayer, multiplayer and split-screen.

## Repository layout

This is the mod's working copy (source of truth). Nothing reads it directly — it
is copied into the game's staging folder and published from there.

```
workshop.txt                              Workshop item metadata (title, id, description, tags)
preview.png                               Workshop item preview
Contents/mods/AnimalTracksOutline/
├── common/                               version-agnostic assets (currently empty)
└── 42/                                   Build 42 payload (pzversion in mod.info)
    ├── mod.info                          name, id, modversion
    ├── poster.png
    └── media/lua/client/
        └── AnimalTracksOutline.lua       the outline logic (OnPlayerUpdate)
```

## How it works

`AnimalTracksOutline.lua` runs on `Events.OnPlayerUpdate`. It is active only while
`ISSearchManager` reports Search Mode on and the search window's focus category is
`"Tracks"`, and the player has at least one level of Tracking.

- **Living animals:** taken from `IsoCell:getAnimals()` within 50 tiles.
  An animal is outlined while its square is visible (`IsoGridSquare:isCanSee`); when
  it leaves view, the outline fades out over a second instead of popping off.
- **Carcasses:** animal `IsoDeadBody` objects are not in the cell object list, so
  they are found by sweeping the squares within 50 tiles. Carcasses do not move, so
  the sweep runs every 500 ms rather than every frame. They stay outlined whether
  in view or not — spotting a carcass through tree crowns is the point.
- Outlines are drawn with `setOutlineHighlight` / `setOutlineHighlightCol` in the
  outline slot of the player being updated.

Lua errors from the per-frame loop are reported once each to `console.txt` rather
than being swallowed, so future engine API changes stay visible.

## Multiplayer and split-screen

The mod is client-side only, and that is enough: `setOutlineHighlight` is local render
state and sends nothing, so every client computes its own outlines. `OnPlayerUpdate` fires
only for local players — once per tick normally, once per player in split-screen — so all
state (outlined objects, fade timers, the corpse scan) is kept per local player and each
player's Search Mode and Tracking level decide their own outlines.

Multiplayer support was first worked out by the community in *Animal Tracks Outline MP*
(Workshop ID 3809241207).

## Building / publishing

There is no build step. Copy the tree into the game's Workshop staging folder
(`%USERPROFILE%\Zomboid\Workshop\AnimalTracksOutline\`), then publish from the game's
main menu → Workshop → Submit. Lua is read at startup — restart the game to test.

## License

MIT. See [LICENSE](LICENSE).

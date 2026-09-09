# Keybinds

Every key aowlspt owns, on one page. All of them are rebindable in the
[settings panel](settings.md) — each is an ordinary declared setting, so the key
you set persists to the owning mod's `config.json` like anything else.

| key | opens | notes |
|---|---|---|
| **F3** | [Debug overlay](mods.md#debug) | The info panel and the in-world bot markers |
| **F6** | [Admin menu](mods.md#admin-menu) | ESP, godmode, the item spawner |
| **F12** | [Settings](settings.md) | The whole configuration surface |
| **M** | [FOV](mods.md#fov) | Toggle zoom. Hold-to-zoom is the default; switch it to a toggle in the FOV section |

And, while the settings panel is open:

| key | does |
|---|---|
| **F8** | show or hide settings that are carried but [not yet acted on](settings.md) |
| **F9** / `-` | step the panel's opacity down |
| **F10** / `=` | step the panel's opacity up |
| **F11** | toggle fullscreen |
| **`/`** | put the cursor in the search field |
| **Esc** | give the keyboard back to the list, clearing the search term |
| **Enter** / **Tab** / **Down** | give it back and keep the term |

The function keys work whatever has focus. `-` and `=` are aliases for F9/F10
and work whenever the search field does not have focus, which is the state the
panel is in unless you put it in the other one on purpose.

Nothing here is bound in the game's own control scheme, so none of it collides
with a Tarkov binding and none of it is lost when you rebind something in the
game's settings.

## While a panel is open

Drag the title bar to move a panel; drag an edge or a corner to resize it. Both
the position and the size persist.

The debug overlay's widgets are individually draggable — see
[Debug](mods.md#debug).

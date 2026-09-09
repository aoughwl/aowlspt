# Settings

Press **F12**. Everything aowlspt can be told to do is on the other side of that
key: the host's own flags, every mod's settings, the emulator's server-side
configuration, and the mod manager.

The panel is drawn by aowlspt itself, over the game, so it works in the menu and
in a raid alike and does not depend on which screen you happen to be on.

## Getting around

**Pages nest.** The first screen is a list of sections — one per mod, plus the
host's own — and a section opens into its own page, which may open again into a
subsection. A large mod is a small tree, not one endless column. The header
shows where you are and walks you back up.

**Search finds anything, anywhere.** Type, and every setting in every page whose
label, key or description matches is listed with the page it lives on. This is
usually faster than navigating; if you know a setting is called something like
"bloom", search for it rather than guessing which mod owns it.

**The window is yours.** Drag it by the title bar, drag any edge or corner to
resize it, and press **F11** for fullscreen. **F9** and **F10** step the opacity
down and up, so you can leave it open over the game while you watch a change
take effect.

### Search has focus only when you give it

The search field is permanently **visible**; that is not the same as
permanently **focused**, and the difference is the whole input model:

- `/` or a click puts the cursor in it. While it has focus it takes every
  printable key, which is what a text field must do.
- **Esc** gives the keyboard back to the list and clears the term. **Enter**,
  **Tab** and **Down** give it back and keep the term.
- **Function keys are never swallowed.** F8 to F11 work whatever has focus,
  because they are not printable and so can never be something you meant to
  type. That is why the opacity control is F9/F10 — `-` and `=` are aliases and
  work whenever the field does not have focus.

A shortcut a text field can eat is not a shortcut.

## Themes

Four ship:

| theme | for |
|---|---|
| **Dark** | the default — the panel's original palette |
| **Light** | the same roles on an inverted ground, with every dim tone darkened rather than merely flipped, so "faint" stays readable instead of becoming pale grey on white |
| **High Contrast** | nothing dimmed below `#B0B0B0`, pure accent, black ground |
| **Amber** | the terminal look, one hue, for when the panel should stop competing with the game's blues |

**Write your own.** A theme is a plain `*.theme` file in
`%LOCALAPPDATA%\aowlspt\themes`, in a format that is a list of `role=RRGGBBAA`
lines:

```
name=Amber
bg=140F08F0
edge=C8912CFF
titlebg=241A0CFF
text=F0D8A8FF
dim=A88A50FF
faint=7A6238FF
on=8AA030FF
off=A0502CFF
hot=6E5220FF
selbg=4A3410FF
rowalt=1E1710C8
panebg=181208FF
warn=E8B040FF
err=E07048FF
good=A8C048FF
accent=FFCC66FF
```

Built-ins are listed first, then every `*.theme` file in that folder. Copy one
out, change the numbers, and it appears in the theme list. A file with no
`name=` line is named after itself, minus the extension.

## Changes apply immediately

There is no Apply button and no restart. Move a slider and the thing it controls
moves. Values are written to the owning mod's own `config.json`, beside its DLL,
so they survive a restart and a game update alike — and are readable and
editable by hand if you would rather.

## The honesty convention

Some rows are **greyed out and marked as not implemented**. They are not broken
and they are not a bug in the panel.

aowlspt carries the full configuration surface of the server it emulates —
including options that are declared, persisted and served, but that nothing has
been wired to act on yet. Every one of those is drawn, greyed, and labelled as
such.

The alternative was to hide them, and hiding them is worse. A setting that
silently does nothing is the most expensive thing a mod can ship: you change it,
nothing happens, and you have no way to tell whether the setting is dead or your
understanding of the game is wrong. A row that says plainly *"carried, not acted
on"* costs you three seconds and costs you nothing else.

Press **F8** to hide every unimplemented row, and again to show them. Show them
when you are wondering why a setting did nothing; hide them when you just want a
clean panel.

## What is on the panel

| section | what it holds |
|---|---|
| **Interface** | the panel itself: theme, opacity, scale, the launch hint |
| **Mods** | the mod manager — every installed mod, on or off, and which list is active |
| **Singleplayer** | the emulator's own configuration: the economy, raids, bots, the hideout, the flea market |
| **Bot AI** | difficulty bands, per-role tuning, and how many bots a raid gets |
| **Graphics** | tonemapping, presets, and the per-effect controls under them |
| **FOV** | field of view, in the menu and in a raid |
| **Maps** | per-map options |
| **Debug** | the F3 overlay's widgets and what each one shows |
| **Admin** | the F6 menu's own switches |
| **Host** | the client host's feature flags, the ones that decide what is patched at all |

## The same settings in a browser

Everything above is also served as a web page, at

```
https://127.0.0.1/aowlspt/ui/page/settings
```

Same sections, same search, same controls, plus deep links — the URL carries
the mod, the category, the subcategory and the search term, so a particular
screen is bookmarkable and survives a reload. It works whether or not the game
is running, which makes it the easy way to set up a profile on a second monitor
before you launch. The certificate is self-signed, because this is your own
machine talking to itself.

## Every mod is drawn the same way

Every one of those sections is a mod declaring its schema through the same API, so a mod
you write yourself appears in exactly the same place, drawn the same way, with
no work beyond declaring it. See [For mod authors](modding.md).

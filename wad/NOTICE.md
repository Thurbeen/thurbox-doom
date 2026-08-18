# What is in here, and under what terms

Two WADs ship with this plugin. They are **game data, not code**, and they are not
under the same terms as each other or as the rest of the repository — the pane is MIT
and the engine is GPL-2.0, neither of which covers either file below.

## `doom1.wad` — DOOM shareware, the default

id Software's shareware episode ("Knee-Deep in the Dead"), **unmodified**, and the one
most people mean by "DOOM".

| | |
|---|---|
| size | 4,196,020 bytes |
| md5 | `f0cefca49926d00903cf57551d901abe` — the canonical v1.9 shareware WAD |
| source | `doom19s.zip` from the idgames archive (`gamers.org/pub/idgames/idstuff/doom/`), md5 `244d181457c9be5f28b91b488e67e042`, extracted from id's own multi-volume installer |
| terms | **id Software's**, not an open licence. The shareware episode was released for free redistribution in unmodified form; that is what this is |
| shipped with it | `DOOM1-README.txt`, the README that accompanied it in that archive, including id's request that shareware levels not be modified |

It is here because it is what the game is *supposed* to look like. If you would rather
not carry data under a permission than a licence, `doom.wad` is one setting and
`freedoom1.wad` is beside it — nothing about the plugin depends on which you use.

## `freedoom1.wad` — Freedoom Phase 1, the free alternative

Free game data built for the DOOM engine, so it can be redistributed without relying
on anyone's permission.

| | |
|---|---|
| size | 28,795,076 bytes |
| sha256 | `7323bcc168c5a45ff10749b339960e98314740a734c30d4b9f3337001f9e703d` |
| source | `freedoom-0.13.0.zip`, whose SHA256 matched Freedoom's published `CHECKSUM` manifest |
| terms | **modified BSD** — see `COPYING.txt`, which its terms require to travel with it, and `CREDITS.txt` |

`COPYING.txt`, `CREDITS.txt` and `CREDITS-MUSIC.txt` belong to this one and must stay.

## Neither is required

Point `doom.wad` at any IWAD you own — `doom.wad`, `doom2.wad`, `plutonia.wad`,
`freedoom2.wad`. A commercial WAD you bought is yours, and shipping it would be
somebody else's problem, which is why neither of those is here.

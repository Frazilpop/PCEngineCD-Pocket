# PC Engine CD for Analogue Pocket

A PC Engine CD / TurboGrafx-CD core for the Analogue Pocket.

This for was originally forked from [Mazamars312's openfpga-pcengine-cd](https://github.com/Mazamars312/openfpga-pcengine-cd), which in turn is built on top of [agg23's Pocket port](https://github.com/agg23/openfpga-pcengine). The chips here are from [MiSTer's TurboGrafx16 core](https://github.com/MiSTer-devel/TurboGrafx16_MiSTer) by Gregory Estrade, srg320, greyrogue and dshadoff. CUE loading fixes by CedricPelchat, the save fix by davewongillies.

## On the card

Discs go in `Assets/pcecd/common` as `.cue` and `.bin`, in a folder each if you like. The system cards go in the same place: `bios_3_0_jap.pce` by default, with `bios_3_0_usa.pce`, `bios_2_0_usa.pce`, `bios_2_0_jap.pce` or `bios_1_0_jap.pce` as other choices. Saves go to `Saves/pcecd`.

A CD+G disc needs its subcode beside its CUE, in a `.sub` of the CUE's name (the CloneCD form, as MiSTer's core reads), or a `TRACK nn CDG` in the CUE (2448 bytes a sector). Its pictures are on the GRAPHICS screen of the system card's CD player, on system card 2.0 or later.

## Memory Base 128

The Memory Base 128 is the add-on that gave a console 128K for saves, on top of its own 2K. Turn on Memory Base 128 in Core Settings and a game that looks for one finds one. It's off by default, as it is on MiSTer. With it on, the game's `.sav` becomes 130K: the same 2K first, then the 128K, so an old 2K save loads as it was, and the layout is MiSTer's. Turning the setting off again doesn't cut a 130K save down. Mazamars312's core, if it's on the same card, reads the same save files and only knows the first 2K, so its next quit would lose the rest.

## Another disc

Another disc in Core Settings puts another disc in with the game running. The console sees the tray open and shut and keeps its memory, so a game that asks for its next disc carries on. For any other game, Reset core is in the same menu. The save stays with the disc the session started on, whichever disc is in at the end: it's the console's memory, as on a real one, so a game of two discs is best started from the same one each time. All of this has been seen on a Pocket, with quits and fresh starts after swaps: each session's save landed under the disc it started on, and the other discs' saves didn't move.

## Memories and Sleep

This core supports Memories and Sleep. A Memory holds the whole console: the drive's place on the disc, and CD music and voices part way through. It's 448K, 576K with the Memory Base 128 on, and up to 2.6 MB once a game has used the Arcade Card's RAM. A Memory made after Another disc puts that disc back in when it's loaded. A memory made with another system card, or with the Arcade Card in it while Arcade System is now off, won't load.

Licensed GPL-2.0, as what it came from.

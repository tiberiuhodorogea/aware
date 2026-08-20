# aware

Minimal nearby-cast visibility for World of Warcraft: Wrath of the Lich King
3.3.5a, developed against the Warmane client.

`aware` places a spell icon and cast-progress bar above visible nameplates. It
uses combat-log events for untargeted casters, preserves casts that began off
camera, supports unit-token channels, and prefers GUID matching when the client
provides enough information.

## Install

Copy the `aware` directory into:

```text
World of Warcraft 3.3.5a/Interface/AddOns/
```

Restart the client and enable **aware** on the character-selection AddOns
screen.

## Diagnostics

```text
/aware health
/aware log
/aware clear
```

The addon keeps compact session diagnostics in SavedVariables and enables
WoW's raw combat log for continuous disk-backed evidence.

## Current boundary

The 3.3.5a API does not expose reliable movement-cancellation information for
every arbitrary nearby player. Cancellation is exact when stop, failure,
interruption, or usable unit-token events are available; other inferred bars
expire from their normalized base duration.

# TitanLayer

TitanLayer is a lightweight Titan Panel plugin that displays the layer you have observed on a layered World of Warcraft realm. Version 1.1.0 includes a port for **World of Warcraft: Forever** (`Interface 16001`).

## Install

Download the latest release, then extract the `TitanLayer` folder to your client's `Interface/AddOns` directory. Install and enable Titan Panel as well; it is a required dependency.

## How detection works

TitanLayer reads the zone identifier in a creature's GUID when you target or mouse over an NPC. It ranks the identifiers it has seen on your **current realm and map**, in ascending order. Until it sees a usable NPC, the bar shows `?`.

This number is local to your sightings, not an official server-wide layer number. Seeing another identifier can renumber a layer you already know. Nameplates can confirm an identifier already known on the current map, but they do not discover new ones: nearby nameplates can belong to a different map across a zone border. Detection is skipped on taxis and inside instances.

## Features

- Show the current observed layer on the Titan Panel bar.
- Detect layers from target and mouseover NPCs; optionally scan nameplates to confirm known layers.
- Left-click to announce the layer in say, party, or guild chat, or print it only to your chat window. Local print is the default; choose a channel from the right-click menu.
- Show the current layer and known identifiers for the current map in the tooltip. When NovaWorldBuffs guild messages are available, the tooltip shows their reported layer distribution instead.
- Save sightings by realm and map. They expire two hours after their last sighting.
- Optionally prefer NovaWorldBuffs' current-layer value when that addon is installed. TitanLayer can also listen to NovaWorldBuffs guild messages without requiring NovaWorldBuffs on your own client; the highest reported number is only the highest observed, not a guaranteed total.

## Commands and options

| Command | Action |
| --- | --- |
| `/titanlayer` or `/tlayer` | Print the current reading and listener status. |
| `/titanlayer reset` or `/tlayer reset` | Clear saved sightings for the current realm and the in-memory NovaWorldBuffs reports. |

Right-click the TitanLayer button to choose the announcement channel, show the GUID zone identifier, prefer NovaWorldBuffs data, toggle nameplate scanning, or reset layer data.

## Compatibility notes

The TOC also lists interface numbers for several other WoW clients. A realm must expose readable creature GUIDs and use layers for detection to be useful. Wrath Classic is **not** listed in the 1.1.0 TOC, so compatibility with it is not claimed here.

Version 1.1.0 replaces the older flat saved-sighting list with realm-and-map storage. Older sightings are cleared on upgrade because they cannot be assigned safely to a map. The Forever port passed Lua 5.1 syntax and offline behavior checks, but it has not been verified in the Forever client.

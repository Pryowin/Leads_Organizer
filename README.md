# Leads Organizer (ESO addon)

**Leads Organizer** is an add-on for *The Elder Scrolls Online* that helps you manage **scrying leads**: filter what appears in your lists, choose how they are sorted, and open a **dedicated panel** so you do not have to cram extra controls into the Antiquities journal.

## What it does

- **Dedicated window** — Lists active lead candidates (in progress, has a lead, or does not require a lead) with zone, expiry-style info, “always available” greens, scrying-skill notes, and in-progress state where applicable.
- **Scrollable list** — Long lists scroll inside the panel.
- **Sort modes** — Zone, expiry (soonest first), or name. Sorting is also applied to the game’s **Active Leads** section in the Antiquities journal when the add-on can hook that data.
- **Filters** (saved account-wide) — Toggle “always available” leads, leads you have **completed before**, and optionally **hide** entries where your **Scrying** skill is too low. **Show leads in current zone only** (off by default) limits the panel and journal **All Active Leads** list to antiquities whose **lead zone** matches where your character is now; entries with no fixed zone are hidden while this is on.
- **No duplicate search UI** — Text search stays in the **Journal → Antiquities** UI; use the journal when you want to search by name.

## How to use

| Action | How |
|--------|-----|
| Open / close panel | `/leadsorg` or `/leadsorganizer` |
| Refresh data | `/leadsorganizer refresh` |
| Keybind | **Controls → Keybindings → General** → **Toggle Leads Organizer** |

## Installation

1. Copy the **`LeadsOrganizer`** folder into your ESO **AddOns** directory (same level as other add-ons’ folders), for example:
   - **Windows:** `Documents\Elder Scrolls Online\live\AddOns\`
   - **Mac:** `~/Documents/Elder Scrolls Online/live/AddOns/`
2. Enable **Leads Organizer** in the game’s **Add-Ons** menu and reload UI if prompted.

## Optional dependency

- **LibAddonMenu-2.0** — Optional; used if present for settings integration as implemented in the manifest.

## Project layout

- `LeadsOrganizer/` — Add-on files (`LeadsOrganizer.txt`, `LeadsOrganizer.lua`, `LeadsOrganizer.xml`, `Bindings.xml`).

Version and API targets are defined in `LeadsOrganizer/LeadsOrganizer.txt`.

---

*This add-on is not created by, affiliated with, or sponsored by ZeniMax Media Inc. or its affiliates. The Elder Scrolls and related logos are registered trademarks or trademarks of ZeniMax Media Inc.*

# Gage Widget user guide

Back to the [README](../README.md).

A small Windows desktop widget that shows the latest discharge and stage for selected USGS gages, with a 48-hour hydrograph for each one. It sits on the desktop layer, just above the wallpaper, and stays visible when you use Show Desktop (Win+D).

## Requirements

- Windows 10 or 11, using the built-in Windows PowerShell 5.1. Nothing to install.
- An internet connection. A USGS API key is optional; see [Do I need a USGS API key?](../README.md#do-i-need-a-usgs-api-key)

## Files

Keep these together in one folder. The widget saves its settings in this folder, so it must be somewhere you can write to, such as Documents.

| File | Purpose |
|---|---|
| `gage-widget.ps1` | The widget |
| `gage-widget.ico` | Logo used by the desktop shortcut |
| `Create Gage Widget shortcut.cmd` | Double-click once to put a Gage Widget shortcut on your desktop |
| `Create Gage Widget shortcut.ps1` | Does the work for the `.cmd`. You don't need to open it. |
| `gage-widget-sites.json` | Created the first time you add, remove, or reorder gages. Your gage list and saved short names. |
| `gage-widget.pos` | Created when you first drag the widget. Its screen position. |

## Setup

1. Copy all the files into one folder. From GitHub, use **Code > Download ZIP**. Extract the zip first; running from inside the zip points the shortcut at a temporary folder.
2. Double-click `Create Gage Widget shortcut.cmd`. A window confirms where it made the shortcut; press Enter to close it. A **Gage Widget** shortcut with the logo is now on your desktop. This also works if your desktop is synced to OneDrive.
3. Double-click **Gage Widget** to start it.
4. Optional: to start the widget at login, press Win+R, type `shell:startup`, and copy the Gage Widget shortcut into that folder.

If you move the folder, double-click the `.cmd` again so the shortcut points to the new location.

If Windows shows a "Windows protected your PC" warning the first time (common for files downloaded from the web or email), click **More info**, then **Run anyway**.

To launch the widget without the shortcut, run:

```
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\path\to\gage-widget.ps1"
```

## Using the widget

Each gage row shows:

- the short name and USGS gage number;
- the latest discharge in cfs and the latest stage in feet;
- when the latest reading was taken and how long ago that was;
- a hydrograph of the last 48 hours. Time runs along the bottom, with faint gridlines every 6 hours and labels at noon and midnight (midnight shows the day). The labels on the left are the 48-hour high and low, and the dot marks the latest reading.

**Read any point:** hover over a hydrograph. A thin line and dot snap to the nearest reading, and a box beside the cursor shows its discharge and time. The latest values on the left don't change.

**Move it:** drag it anywhere. It reopens in the same place next time.

**Reorder gages:** hover over a gage and a dotted handle appears just left of it. Drag the handle up or down; the other gages shift as you go, and the new order is saved when you let go.

**Right-click menu:**

- **Manage gages...** adds or removes gages (see below).
- **Refresh now** fetches new data immediately.
- **Close** quits the widget.

The widget checks USGS for new readings every 5 minutes and updates the "min ago" times every minute. The footer shows when it last checked successfully, or an error if it couldn't.

## Managing gages

Right-click the widget and choose **Manage gages...**.

- **On the widget** lists the current gages. Click **Remove** to take one off.
- **Add a gage**: type a gage ID, or pick one from the dropdown, enter a short name, and press Enter or click **Add**.
  - Gage IDs are 8 to 15 digits, without the `USGS-` prefix.
  - The dropdown remembers every gage you've added before but isn't currently shown. Picking one fills in its saved short name, which you can edit.
  - If you leave the short name blank, the widget uses the saved name, or the gage ID if there's none.
  - A re-added gage goes to the bottom of the widget.

Changes are saved to `gage-widget-sites.json` right away. If you added a gage, the widget fetches its data when you close the window.

## Settings

These are at the top of `gage-widget.ps1`. Restart the widget after editing them.

| Setting | Default | What it does |
|---|---|---|
| `$DefaultSites` | three Waco-area gages | Starting gage list, used only the first time the widget runs. After that, use **Manage gages...**. |
| `$RefreshMinutes` | `5` | How often to check for new readings. The 48-hour history is downloaded again only when a new reading has arrived. |
| `$LogScale` | `$false` | `$true` puts every hydrograph on a log10 axis; `$false` keeps them linear. |
| `$ApiKey` | `$env:API_USGS_PAT` | Optional USGS API key. Leave this line as it is and set the key as an environment variable instead; see the [README](../README.md#do-i-need-a-usgs-api-key). |

About the hydrograph axes:

- Each hydrograph scales to its own 48-hour high and low, so small changes on a large river can look dramatic. Read the axis labels.
- Log axes can't show zero, so zero flow plots at 0.01 cfs.

## Data source

The data come from the USGS Water Data API (`api.waterdata.usgs.gov/ogcapi/v1`). Each request covers every gage and both discharge (00060) and stage (00065).

- The printed values come from the `latest-continuous` collection, which holds the newest reading for each gage. It is checked every refresh.
- The hydrographs come from the `continuous` collection, which can lag behind the newest readings. The last 48 hours are downloaded on first load, on **Refresh now**, and whenever a new reading has arrived. The newest reading is added to the end of the plot if the history hasn't caught up yet.

At the default 5-minute refresh, that's 12 checks an hour plus up to 12 history downloads, so at most about 24 requests an hour. USGS limits requests per IP address per hour but doesn't publish the limit for requests without a key; see the [README](../README.md#do-i-need-a-usgs-api-key).

If a gage records more than one series for the same parameter, the widget uses whichever has the most recent reading.

## Troubleshooting

| Symptom | What it means / what to do |
|---|---|
| Footer says "Couldn't reach USGS" | No network, or the USGS server is down. The widget keeps the last data and retries in 2 minutes. This is common right after login. |
| Footer says "USGS rate limit hit" | Too many requests from your IP address, possibly from other users on a shared campus network. It retries in 2 minutes. A free API key fixes this; see the [README](../README.md#do-i-need-a-usgs-api-key). |
| A row says "No recent data" | The gage ID may have a typo, or USGS has no current reading for it. |
| Widget is off-screen, for example after unplugging a monitor | Close it, delete `gage-widget.pos`, and start it again. It reopens near the top-right of your screen. |
| Want to reset the gage list | Delete `gage-widget-sites.json`. The widget starts over from `$DefaultSites`. |
| The `.cmd` or the shortcut does nothing, or shows an execution-policy error | Your organization may block PowerShell scripts through Group Policy. In PowerShell, run `Get-ExecutionPolicy -List`. If MachinePolicy or UserPolicy shows `Restricted` or `AllSigned`, that overrides the shortcut's `-ExecutionPolicy Bypass`. Ask IT. |
| Widget hides behind the wallpaper or disappears on Win+D | The desktop-layer pinning hasn't been tested on every Windows build. Note your Windows version and what happens. |

# drift

Wind-aware routing and flight for a solar airship over Belgium. Native, written in Odin with raylib.

## Build

Requires Odin dev-2026-11a and the mold linker.

    git config core.hooksPath .githooks
    ./compile.sh debug      # hot reload: build/drift + build/game.so
    ./build/drift           # run from the repo root, rebuild while it runs
    ./compile.sh release    # one static executable

On Windows use compile.bat with the same arguments. Requires Visual Studio Build Tools (for Odin)
and Git for Windows. Run build\drift.exe from the repo root.

## Contributing

Read AGENTS.md, rules.txt, notes.txt and todo.txt first.

## Data

- Map data (c) OpenStreetMap contributors, ODbL. Extract from Geofabrik.
- Elevation: Copernicus DEM GLO-90 (c) DLR e.V. 2010-2014 and (c) Airbus Defence and Space GmbH 2014-2018,
  provided under COPERNICUS by the European Union and ESA.
- Weather: Open-Meteo.com, CC BY 4.0.

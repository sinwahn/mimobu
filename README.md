# mimobu

*Meant to spare you* **endless scrolling of mod pages**, **surprise version and mod loader incompatibilities**, and **hunting for integration mods**.

You group mods and resource packs into thematic modules, pick the modules you want in `build.yaml`, and the script does the rest:

- it checks every mod against your game version and mod loader on Modrinth or CurseForge
- it adds integration mods once both mods they connect are in the pack
- it pulls in required dependencies, adding new ones to `assets.yaml`
- it downloads everything into `output/` and checks each file against its published hash

## Setup

1. Windows PowerShell 5.1 (built into Windows) or PowerShell 7. On its first run the script installs the `powershell-yaml` module for your user.
2. Get a CurseForge API key at <https://console.curseforge.com> and give it to the script in either of these ways:
   - set it as the environment variable `CURSEFORGE_API_KEY`
   - put it in a file named `curseforge.key` next to `build.yaml`

   Both stay out of git (`curseforge.key` is in `.gitignore`). An old `cf_api_key:` line in `build.yaml` still works, but the script reminds you to move it.

If Windows refuses to run scripts, start them with `powershell -ExecutionPolicy Bypass -File .\main.ps1`. This changes no settings.

## Use

```powershell
.\main.ps1               # build the pack into output/
.\main.ps1 -DryRun       # show what would happen; downloads, moves and saves nothing
.\main.ps1 -Verbose      # explain every decision: why each mod was taken or left out
.\main.ps1 -OverwriteExisting   # download every file again
.\main.ps1 -OutputDir D:\packs\colony   # build somewhere else
```

The run ends with a summary:

- how many mods were taken, and from where: modules, integrations, dependencies or additions
- what was left out, grouped by reason
- what could not be checked (a missing key, a network error)
- files you have to download by hand
- anything in your YAML files that needs fixing, such as an unknown module or mod name

### What ends up in `output/`

- `mods/` and `resourcepacks/`: copy them into your instance.
- Running again only downloads what changed. A file that is already there and matches its hash is left alone.
- When a mod updates or leaves the build, the script moves its old file to `output/.old/`, so Minecraft never loads two versions. It only moves files it downloaded itself (it keeps a list in `output/.mimobu-files.json`). Jars you put there yourself are never touched.
- Some CurseForge authors block downloads by other programs. The script then looks for the same mod on Modrinth. If it isn't there, the summary gives you the CurseForge page. Download the file and put it into `output/mods/`. The next run recognizes it.

## Configuration

### `build.yaml`

```yaml
version: "1.20.1"        # quote it: YAML reads 1.20 as the number 1.2
modloader: neoforge      # forge, neoforge, fabric or quilt
allow_integrations: true
modules:                 # modules from modules.yaml, in any order
  - create
  - create_cannons
addition:
  mods:                  # single mods from assets.yaml, outside any module
    - jade
```

NeoForge on 1.20.1 and earlier uses Forge files. These versions of NeoForge load Forge mods, and the Forge tags on them are the reliable ones.

### `modules.yaml`

```yaml
platform_mods:           # one mod published as several projects: the first that fits is used
  traveler_s_titles:
    - traveler_s_titles
    - traveler_s_titles_forge_neoforge

main_modules:
  dim:
    aliases: [dimensions]          # other names build.yaml may use
    mods:
      - lootr
    platform_mods:
      - traveler_s_titles
    resourcepacks:
      - some_pack: { pinned: true }  # pinned: if nothing fits the version, take the newest file

sub_modules:                       # only enabled when the modules they depend on are
  create_cannons:
    depends_module: [create]
    mods: [create_big_cannons]

integrations:
  one2other:                       # host mod -> integration mod: the other mod it needs
    farmer_s_delight:
      alex_s_delight: alex_s_mobs
  manual:
    jadecolonies:
      depends_mods: [jade, minecolonies]
    some_compat:
      depends_mods_compound:       # cataclysm, and one of the two fortress mods
        and:
          l_ender_s_cataclysm:
          or:
            - yung_s_better_nether_fortresses_neoforge
            - yung_s_better_nether_fortresses_forge_neoforge
```

### `assets.yaml`

This is the list of every mod and resource pack you know of, keyed by name:

```yaml
mods:
  alex_s_mobs:
    name: Alex's Mobs
    source: curseforge   # or modrinth
    mod_id: "426558"     # CurseForge project id or Modrinth project id
```

You can fill it by hand or with `prismAssetDumper.ps1`. The dumper reads every Prism Launcher instance and adds what is installed there. Entries you already have are kept. By default it looks for `../instances`, so clone this repo inside your Prism Launcher folder, or pass `-InstancesDir`.

## Tests

The tests need Pester 5 (`Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser`). Run them with:

```powershell
Invoke-Pester ./tests
```

They never touch the network. The API answers come from `tests/fixtures/` and from fakes inside the tests.

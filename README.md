*intended to speed up the process of* **endless scrolling of mod pages** AND **surpises of version/modlauncher incompatibility** AND **searching for integration mods**

Clone the repo in the PrismLauncher folder if you want to populate asset list by already existing mods of yours

0. paste curseforge api key in `build.yaml` at `cf_api_key`
1. Create your own thematic groups of mods and resourcepacks in `modules.yaml` (there are also examples of integration mods)
2. Specify what you want in `build.yaml`
3. Just run it, and it will resolve dependencies and download everything

populate assets by hand or with `prismAssetDumper.ps1`, which grabs everything you have installed,
all you have to do is add or change stuff in `modules.yaml`

# App icon

`AppIcon.png` (1024x1024) is the icon the app ships with. `build.sh` converts it into
`AppIcon.icns` inside `DeepField.app`. To change the icon, replace this file and rebuild.

The current icon is option 6, "photon ring". All six options came from the scripts here, so
any of them can be tweaked and regenerated:

```bash
python3 Design/Icons/make.py    # writes Design/Icons/output/option-*.png (1024x1024)
python3 Design/Icons/sheet.py   # writes Design/Icons/output/icon-options.png (512/128/64/32 px, light and dark)
cp Design/Icons/output/option-6-photon-ring.png Design/Icons/AppIcon.png
```

Requires Python 3 with `numpy` and `Pillow`. `output/` is git-ignored.

| Option | Built from |
|---|---|
| 1 gargantua | `renders/src_garg.png`, a black hole render from the app |
| 2 synthwave | `renders/src_syn.png`, the same render with the Synthwave preset |
| 3 pixel-mark | procedural, a hand-built 24x24 cell black hole (`opt_minimal`) |
| 4 galaxy | `renders/src_gal.png`, a spiral galaxy render from the app |
| 5 deep-field | procedural (`opt_deepfield`) |
| 6 photon-ring | procedural (`opt_ring`) |

The renders were made with the dev CLI, for example
`.build/release/DeepField --snapshot src_garg.png --size 1024x1024 --scene blackHole`, then
cropped by `from_render` in `make.py` (center and crop size are the arguments there).

# Saw II XEX analysis

Initial target binary supplied with this project:

- Xbox 360 XEX2 executable
- Title: **Saw II: Flesh & Blood**
- Title ID: `4B4E0822`
- Media ID: `32FBD29B`
- Module name observed in the image: `Saw2Game-XeReleaseLTCG.exe`
- Region metadata reported by the local `file` XEX parser: all regions
- Size: `18,366,464` bytes
- MD5: `340b78e60ce41ab14eb729dbae657ccb`
- SHA-256: `0bb765d0c89de2674efea76056a9c1b6236173587398ddc248b08cc1a6092883`

The binary contains references to `XBOXKRNL` / `xboxkrnl.exe`. ReXGlue should
perform the actual XEX load, PPC discovery, import resolution, function graph
validation and C++ generation; this project deliberately does not attempt to
replace that logic with a home-grown XEX decoder.

## First bring-up goal

1. Run stamp-aware normal codegen and save every validation report.
2. Use `codegen --ignore-stamp` only for an intentional complete re-analysis.
3. Prove each missed LTCG function boundary against this exact XEX before
   adding a narrow manifest hint.
4. Rebuild and run after each hint, then fix the first dynamically reached
   guest target rather than hiding it with a stub.
5. Keep graphics, input, audio and filesystem evidence in separate Saw II logs.

## Case and asset state

The supplied executable is `game/Default.xex` with an uppercase `D`. The
manifest and all Linux tooling use that exact path. The current workspace also
contains the extracted `SAW2GAME` asset tree, so missing runtime files must be
verified individually from logs rather than assuming that only the XEX exists.

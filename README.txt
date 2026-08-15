SERVICES.R4X
============

SERVICES.R4X ist die Desktop-nahe Service-Uebersicht.

Projektstruktur seit 0.51.18:
- `build.zig` baut die App als eigenes SDK-Projekt.
- `build.zig.zon` bindet `r4os_sdk` als Paket.
- `module.R4MF` beschreibt Artefakt, Zielpfad und Contract.

Build:

    cd Code\System\Software\Services
    ..\..\..\DevTools\Zig\zig.exe build

Ergebnis:

    Code\System\Software\Services\zig-out\SERVICES.R4X

Contract:
- R4XStart-Entry: `services_main`
- App-Klasse: `gui`
- R4L-Imports: `R4DESK:Query:1`, `R4DRAW:Query:1`
- Zielpfad im Image: `C:\R4OS\SOFTWARE\DESKTOP\SERVICES.R4X`


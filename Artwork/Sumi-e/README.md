# Approved Sumi-e artwork

This project uses edition 0.4.1 of the [gekko styleguide](https://ios.gekko.de/styleguide). The application-specific drawings were approved for local integration on 13 September 2026.

Copyright holder: gekko. © 2026 gekko. The notice is documentation only and is not part of the icon pixels.

## Controlled sources

The PNG originals are retained byte for byte. `manifest.json` records their identifiers, hashes and target locations. The brush contours arise from pressure and lift; do not straighten them or replace them with distressed geometric outlines. SVG files used for placement embed the raster originals and are not editable vector reconstructions.

## Active artwork

- `../ProjectIcon.svg` and the matching 256/512/1024-pixel transparent PNGs.

For native targets, Xcode compiles the `.icon` document into the platform-specific icon outputs. The foreground stays matte; the system applies its mask and appearance treatment. The opaque background and transparent ink are separate. Do not restore retired `AppIcon.appiconset` folders or add pre-rounded source images. Target deployment requirements and application behaviour are independent of this artwork change.

Build and verify the target after any artwork edit. Inspect the compiled icon at actual size, in supported appearances and on the relevant device; renderer previews alone are not device evidence. The complete design archive, prompts and comparisons remain in the versioned styleguide source edition.

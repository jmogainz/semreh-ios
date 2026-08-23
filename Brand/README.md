# Semreh brand artwork

The supplied transparent PNGs are the source of truth for the product mark:

- `semreh-wing-light.png` — navy wing for light surfaces.
- `semreh-wing-dark.png` — white wing for dark surfaces.
- `semreh-wordmark-light.png` / `semreh-wordmark-dark.png` — matching wordmarks.

The iOS Home Screen icon is intentionally **wing only**, composited on an opaque deep-navy field. The app's in-product logo assets are registered as luminosity variants, so SwiftUI switches them automatically when the system changes between Light and Dark appearance.

Run `python3 scripts/generate_semreh_branding.py` after changing the supplied artwork. It regenerates the checked-in icon and copies the four logo variants into the asset catalog.

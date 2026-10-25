# macOS 15 map and inventory corruption

On the `m3-macos15` branch at `f71ea7b`, zooming the map could be followed by
magenta/noisy inventory icons and corrupted UI backgrounds. The affected session
logged a GPU address missing from the Metal 3 buffer registry. The following
changes were tested together on an M4 Mac with macOS 15.6 and Xcode 16.4.

## Metal 3 compatibility fixes

The reverse GPU-address registry previously stopped accepting buffers silently
after 1,024 live entries. A dropped registration was not recovered when another
buffer was removed: residency bookkeeping already considered it registered.
The registry now grows dynamically under its existing lock and ignores duplicate
object registrations. It preserves the existing non-owning resource lifetime
contract and most-recent-hit lookup optimization.

The Metal 4 renderer's `USE` macro checks residency only. For Metal 3, residency
does not describe reads/writes through argument buffers to automatic hazard
tracking. The Metal 3 path now declares indirect buffer and texture usage with
the appropriate shader stages, including a retained resource packet for the
render worker. Uniform renames and snapshots declare the buffer containing the
actual bound GPU address. Samplers are excluded because they are not resources.
Existing argument-buffer reuse remains scoped to a render pass.

## Upstream backports

The texture-layout and D16-clear changes come from upstream
[PR #3](https://github.com/ly05010419/MacNativeGames/pull/3), merged as
`70729e93786336c45a48a8fab4ffb113443183b9`:

- Truncate automatic GOB block-height selection before choosing a power of two.
  Rounding up can read padding as texels even when allocation sizes agree.
  Explicit packaged layouts retain precedence.
- Quantize D16 attachment and texture load-clears into the same bin as fragment
  depth writes. Other depth formats are unchanged.

The layout regression uses upstream's independent SDK metadata goldens. The depth
regression is adapted from upstream's GPU reference to compile on the macOS 15
SDK and exercise Metal 3 only. These backports are already in upstream's Metal 4
branch; the new compatibility fixes belong to this Metal 3 branch.

## Reproducing focused checks

No game data or keys are needed for these checks:

```sh
make -C games/totk probe-texture-auto-layout
make -C games/totk probe-m3-buffer-registry
make -C games/totk probe-depth16-m3
```

The GPU targets use the existing game-slot wrapper and wait for any running
game. Binaries are written outside the checkout under `TOTK_build/rendering-probes`
by default; override `RENDER_PROBE_DIR` to choose another external directory.

| Check | Original | Patched |
| --- | --- | --- |
| Lookup of 4,096 real, live Metal buffers | 3,072 misses | 0 misses |
| Buffer removal, reinsertion and duplicates | Fails | Passes |
| 40 SDK texture-layout cases and explicit-layout override | Fails | Passes |
| 777 load-clear/fragment-depth comparisons | 292 mismatches | 0 mismatches |

The patched 1.4.3 runtime also passed these existing production GPU probes with
Metal API validation: compressed aliases (1,280 checks), texture/sampler slots
(37,152), storage views (15,366), and uniform snapshots (16,408).

## Gameplay evidence and limits

An isolated copy of an existing 1.4.3 save was loaded at Lookout Landing. The
session exceeded the old registry limit and logged growth from 1,024 to 2,048.
Twenty map-zoom rounds (160 stick movements), with four map-layer changes,
were followed by 12 consecutive inventory frames showing intact icons and UI;
none contained the bright-magenta error pixels. The missing-buffer binding
error did not recur. The regular save profile remained byte-identical.

The player subsequently reported that the earlier black-particle flicker was
no longer visible. These changes were tested together, so that observation
does not isolate which fix affected that symptom or prove whole-game coverage.
Metal 4 gameplay was not tested on this macOS 15 machine.

The upstream upload-batch fixture and the fork's whole-window screenshot command
still contain Metal 4-only combined compute/blit calls; neither is counted as
passing validation. Gameplay evidence used the working raw-frame exporter.
No game files, keys, saves, generated apps, or screenshots are included here.

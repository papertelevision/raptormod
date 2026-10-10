---
name: azrael-volumetric-fog
description: Volumetric fog model (GPU compose pass): black absorbing air, shadowed in-scatter from placed lights via their cube maps, flashlight cut-through; room level held. First room only, built 2026-10-08, not yet seen in game. Tuning history inside.
metadata:
  type: project
---

Josh (2026-10-08): fog as LIGHTING. Black volumetric fog instead of lowering the light; the flashlight and the lights cut through it. Pilot in CORICORI. His prep: no torch embers, no distance fog, no ground mist there, and NO flashlight-dependent room darkening ("pure for now so I can analyze"). It is ray MARCHING, not ray tracing: ~+1.5 ms at 1600x900.

- **Where:** FS_COMP (the compose pass), after the old air block, when uVolOn.
  - T = max(exp(-dens*L), 1-max), from the depth buffer.
  - A jittered march (VolSteps up to VolFar). Each step: placed lights (up to 4) scatter with att = 1/(1+d^2/reach^2), times hgRel (Henyey-Greenstein relative to isotropic), times airLit (one texel of the light's ALL-ROUND cube map, so there are shafts and the player body shadows the air). Plus the flashlight via lampAir (no shadow).
  - col = col*T + fogColour*(1-T) + ins * dens*scatter*255.
- **CUT-THROUGH:** inside the lamp's halo cone, dens *= 1 - cut*cone*clamp(lampPower/1.5). Without it the fog absorbed the flashlight too and on/off looked identical.
- **Data:** MainUniforms (main pass, not refl) copies the lights, cube axes and slot textures to _vP/_vC/_vF/_vTex/_vAx; PostCompose binds them on units 6-9. Units 4-5 are the lamp maps in compose -- the first version clashed there.
- **Room file:** `"volume": {density, max, color, scatter, lamp, anisotropy, reach, far, steps, level, cut}`. The Get-RoomAtmosphere key is 'volume'. While it's on, r.LampRoom is HELD at volume.level (default LampRoomOff 0.82) instead of blending on/off. -NoVolume turns it off. Test-GpuLook has -NoVolume.
- **CORICORI now:** density 0.004, max 0.78, #000000, scatter 0.14, lamp 1.0, anisotropy 0.3, reach 55, far 700, steps 24, level 0.82, cut 0.65.
- **Tuning lessons:** the first try (scatter 0.6, reach 110, aniso 0.45) was an amber WASH, because forward scattering at g=0.45 is ~4.8x looking at the light and reach 110 spreads it room-wide. Black fog wants a scatter share around 0.1-0.2 and a reach around 50.
- Still on in that room: dust motes, ceiling drips, the faint beam (BeamHaze), and the GROUND MIST (Josh put it back 2026-10-08 after seeing the fog -- "exactly what I wanted"; "mist": null was removed from CORICORI.json). The mist is computed before the volume block, so the fog darkens it with distance like any surface.

Related: [[azrael-gpu-effects]], [[azrael-atmosphere]], [[azrael-player-shadow]].

**SPOTLIGHTS / SHAFTS (2026-10-08, Room Review round 1, CORICORI/2):** light fields in rooms\<R>.json:
- 'cone': [inner, outer] degrees round 'dir'. The main shader multiplies att by the cone; uLightDir/uLightCone.
- 'air': strength in the fog (default 1); 'airReach': its own reach (0 = the volume's).
- 'rays' 0..1: fbm across the cone's cross-section (constant along each line from the apex, so it reads as streaks), drifting with uTime.
- GPU: SetLightSpot / ClearLightSpots (_spot, 8 floats a light; NewSpots defaults air 1). Compose uVLB (cross axes) + uVLK (cos in/out, air, rays) + uVLR. Watcher: Set-GpuAtmosphere pushes them from $script:roomLights (Cone/Air/AirReach/Rays). The CPU/F9 path ignores cones.
- CORICORI's ceiling 'hole' (floorbit10, material 1ENTER) is PAINTED (solid face). The shaft is a distant light at y 363 above it, straight down, cone 3-6, shadow false (so it passes through the ceiling), #C8D6FF, power 0.45, air 26, rays 0.6.
- Air math: visible air ~ crossing length * att*colour*power*air * density*scatter*255. Air 5 gave ~8/255 (invisible), 14 barely, 24-26 subtle and visible.

**Placed lights cut through (Josh, 2026-10-09: from afar "the volumetric fog swallows" the torch and the shaft; "their own light should dispose of the fog just like my flashlight"):**
- **FS_MAIN writes alpha** = 1-exp(-2.5 * lum(placed-light light on this pixel)).
  - An all-round light counts only within LitReach (110 units, `volume.lightReach`), weighted by exp(-d^2/R^2).
  - A spot counts inside its beam only.
  - Bounce (GI) is NOT counted, because it is everywhere.
  - Flames write their coverage as alpha (glow 0.5 at most).
  - Particles and motes mask alpha off (glColorMask 1,1,1,0), or premultiplied blending would raise it.
- **Compose:** `T = mix(T, 1, uVolLit * alpha)`, with VolLit 0.85 (`volume.lightThrough`).
- **volMarch:** placed-light in-scatter is attenuated by mix(Tt, 1, VolLitAir) (0.7, `volume.lightThroughAir`). The flashlight beam keeps plain Tt.
- **FIRST TRY FAILED:** counting all light with GI made the whole room clear, because the torch falloff 1/(1+d^2/260^2) still gives 60% at 200 units. The clearing has to be LOCAL.
- Test-GpuLook takes -VolLit / -VolLitAir (0 = the old look). A far CORICORI view (-300, 255, yaw 126) is the one to check.
**The fog's light glow uses the 4 lights NEAREST the eye** (`_air[]` in MainUniforms; 2026-10-09). It used to take the first four in the room file, so MINEMAZE's fifth torch lit its walls but never glowed in the fog.
# Review

**Built:** storyline A, "Weight on the palm rest" (`STORYLINES.md`). Not built: B "The empty desk lies", C "One number lands".

**Creative calls**
- One continuous 3D take: laptop → hands land → x-ray to the accelerometer → the real trace rises into the screen → push through the screen into the heart page → end card.
- The red trace is real data: 20 s of the flat-table, wrists-on recording (Y axis, 1–10 Hz). No BPM number is shown anywhere, because the tests never produced a trustworthy one.
- Accelerometer placement inside the chassis is illustrative, not Apple's real board layout. The chassis tilt is exaggerated so it reads (real: ~1.5 mg).

**Measured:** `hyperframes check` passes with no errors. Snapshots were checked at every beat, at the desk→heart cut and at phone width.
**Sound:** HeyGen voiceover (6 lines, timed to the shots) over a HeyGen catalog music bed at 0.13. Measured, not heard: −14.5 LUFS integrated in `docs/demo.mp4`, no clipping.

**Kept warnings:** canvas_content_at_edge (the 3D floor and heart are meant to bleed); file size / track density on desk.html (one continuous take, intentionally one scene).

**Hands:** WebXR generic-hand glTF models (MIT, Amazon) with a skin material and capsule forearms.

**Weakest shot:** the forearm-to-wrist join, where the capsule forearm meets the scanned hand mesh. A full arm model would hide the seam.

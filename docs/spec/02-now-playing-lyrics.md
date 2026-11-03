# 02 — Now Playing, Lyrics, Queue, Player Motion

Extracted by reading the Android sources of **BitChord 1.9**. Every number below is copied from
code, not measured off screenshots. dp is Compose density-independent px; for macOS treat
**1 dp = 1 pt** at the default scale (the app's type is already SF Pro, see §12).

## 0. Where the code actually lives (read this first)

The brief said the player is in `ui/MainActivity.kt`; in 1.9 it moved into a KMP `sharedUi` module
shared by Android, desktop and TV, and `MainActivity.kt` now only hosts the sheet and wires
callbacks (`MainActivity.kt:2495`). Good news for the port: the player was written platform-neutral,
and the JVM palette quantiser cited below is already a portable port of Android's Palette
(`sharedUi/src/jvmMain/.../PaletteQuantizer.kt:11-18`).

| Alias | Path (root `BitChord-1.9/`) | Lines | Role |
|---|---|---|---|
| **NP** | `sharedUi/src/jvmSharedMain/kotlin/com/music/bitchord/ui/player/NowPlayingScreen.kt` | 4068 | whole player layout, collapse, docking |
| **CTL** | `.../ui/player/PlayerControls.kt` | 1915 | transport, scrubber labels, volume, action row |
| **SLD** | `.../ui/player/ThinSlider.kt` | 491 | the hairline seek/volume bar |
| **LYR** | `.../ui/player/PlayerLyrics.kt` | 3288 | lyric strip + full lyrics panel |
| **QUE** | `.../ui/player/PlayerQueue.kt` | 825 | queue panel, rows, drag-reorder |
| **MESH** | `.../ui/player/MeshGradient.kt` | 416 | 4-blob mesh backdrop + palette from art |
| **BLUR** | `.../ui/player/ArtworkMeshBackdrop.kt` | 750 | blurred-artwork backdrop (the default) |
| **PAL** | `.../ui/theme/ArtworkPalette.kt` | 463 | artwork colour maths, player tint |
| **LSC** | `.../ui/player/LandscapePlayer.kt` | 569 | two-column layout (the desktop model) |
| **MOT** | `app/.../ui/player/PlayerSheetMotion.kt` | 357 | sheet open/close spring |
| **THM** | `app/.../ui/theme/Theme.kt` | 179 | colour scheme + type scale |
| **MA** | `app/.../ui/MainActivity.kt` | 6612 | sheet host, scrim, menu |

Settings defaults that decide what you see out of the box
(`app/.../data/settings/AppSettings.kt`): `fullBleedArtwork = true` (:550),
`lyricsBlur = true` (:483), `syncedLyrics = true` (:579), **`legacyMeshGradient = false`** (:567).
So the shipping backdrop is the **blurred artwork**, and the mesh is a legacy opt-in.

## 1. Screen skeleton, top to bottom

The player is a full-window modal sheet: no top corners, no drag handle from Material, transparent
container, square shape, window-wide (`MA:4654-4681`), dim behind it `Color.Black` at
`0.32 × openFraction` (`MA:6147`, `MA:4707`). Root of the content is **opaque black**
(`NP:2261`), so nothing shows through at any point of the open/close.

```
[ top strip 32dp ]            ← the only region that drags the sheet: scrim + handle + caption
[ artwork block, weight(1f), top pad 8 / bottom 18 ]
   └ square sleeve, centred · 20dp gap · credits row 60dp
[ bottom deck, natural height, pinned to the foot ]            (NP:3844-3990)
   lyric strip (20dp line box) · scrubber+times (7dp bar, 34dp touch) · 8+spread/2
   transport · 12+spread/2 · volume 32dp · 6dp · action row 44dp · 18dp
```

Horizontal padding for the entire content column is `PLAYER_GUTTER = 30.dp` (`NP:335`, applied
`NP:2695`), and the content is capped at `PLAYER_MAX_WIDTH = 560.dp` and centred (`NP:342`,
`NP:2715`) — on anything wider than 620dp the column stops growing. That cap is the single most
important number for the desktop port.

**Top strip** (`DISMISS_STRIP_HEIGHT = 32.dp`, `NP:268`; drawn `NP:2538-2596`)

| Element | Spec |
|---|---|
| Drag handle | 38×5dp, corner 3dp, `shadow(2.dp)`, fill = player tint @ **0.70**, y = 6dp when the player is open, glides to `(32-5)/2 = 13.5dp` when a panel owns the screen (`NP:2560-2580`) |
| Status-bar scrim | 8 vertical stops, alpha `A·(1-t)^1.5`, `A` = 0.16 → 0.65 derived from the top band luminance of the artwork (`PAL:358-366`); drawn *above* the strip up to the screen's top (`NP:2545-2555`) |
| Origin caption | `labelSmall` (11sp W600, ls 0.3) + black shadow(α .55, offset 0,1, blur 4), tint = player tint, one line, ellipsised, start/end padding 30dp, bottom 1dp, fades with the collapse (`CTL:166-190`, `NP:2588-2598`) |
| Chevrons / tab switcher | **None.** This player has no back chevron and no tab bar. The only navigation affordances are the `⋯` glyph at the right of the credits row and the lyrics/queue glyphs in the action row. Do not invent a segmented header. |

Bottom deck visibility: hidden while the lyrics panel is open and its controls have auto-hidden
(5s idle, `NP:557`), and while a share-pick is active (`NP:3845-3848`).

## 2. Artwork

- Square. `wantArt = min(width, roomy − 20 − 60)`; `fullArt` is clamped to the box's real height
  and floored at 54dp (`NP:2752-2755`). `roomy` = box height + control spread. On a phone
  (360–430dp wide, ≤620dp of controls space) this is `width − 60dp`, i.e. **~300dp on a 390dp
  phone**; the sleeve is centred horizontally and vertically in the block (`NP:2828-2838`).
- **Corner radius 8dp** — `sleeveCorner()` returns `8.dp * (1 − sleeveShown)` (`NP:3025-3029`),
  applied twice (shadow layer + clip layer, `NP:3119-3145`). The placeholder tile uses the same
  8dp (`NP:490`). A music-video picture box uses **10dp** (`NP:3432`, `NP:3440`).
- **Shadow elevation 10dp while there is a real image**, fading out as the sleeve becomes the
  full-bleed banner or docks into the mini player (`NP:3120-3130`). Placeholder tile: no shadow,
  just `Color.Black @ 0.18` fill and a 40dp music-note glyph at white 0.35 (`NP:3224-3240`).
- **Paused shrink: scale 0.86**, spring `dampingRatio = LowBouncy, stiffness = Low`; plays back to
  1.0 when playing (`NP:1192-1199`). This is the signature Apple Music motion — keep it.
- **Swipe-to-skip**: horizontal drag moves the sleeve with the finger (spring
  `StiffnessMediumLow`), threshold **72dp** (`NP:1174`, `NP:1195-1205`); a 16dp FastForward /
  FastRewind hint fades in between artwork and credits at up to 0.85 alpha (`NP:3465-3490`).
- Collapsed into a panel header: sleeve → **54dp thumbnail** (`THUMB_SIZE`, `NP:232`), 16:9 box for
  video (54 × 16/9 = 96dp, `NP:2863`), corner still 8dp.
- Full-bleed mode (default on): the sleeve morphs into a banner spanning the player's width, from
  behind the status bar down to `statusBarTop + 32 + 8 + groupTop + fullArt + 10`
  (`NP:2868-2872`), dissolving its bottom edge over the last **42%** of its height
  (`HERO_FADE_FRACTION`, `NP:285`).

## 3. Credits (title / artist / glyphs)

Row height **60dp** (`HEADER_HEIGHT`, `NP:233`), sitting **20dp** under the sleeve
(`ART_TITLE_GAP`, `NP:234`); it does not move with the pause shrink.

| Piece | Spec |
|---|---|
| Title | `titleLarge` overridden to **20sp / W700 / ls −0.2**, white; explicit badge prepended in the artist colour; album link on tap (`NP:3574-3584`) |
| Artist | `titleLarge` **20sp / W500**, colour = **player tint @ 0.55** (`NP:3596-3600`, tint at `NP:3570`) |
| Marquee | scrolls only on overflow, `26 dp/s`, 48dp gap between passes, 5s rest before the first pass; artist waits an extra **3s** if the title also scrolls (`CTL:1328-1367`) |
| Like glyph | `CircleGlyph` 34dp disc, tint @ **0.18** idle / **0.34** active, glyph 19dp; star / filled star (`CTL:730-775`) |
| Overflow `⋯` | same `CircleGlyph`; 10dp gap before the like glyph, 8dp between like and menu (`NP:3611-3670`); anchored `menuAnchor()` to the host's action sheet (`MA:4556-4610`) |
| Crossfade | title+artist `Crossfade` over 300ms on track change (`NP:3551-3555`) |
| Collapsed | whole column scales to **0.80** about its left edge, text start moves to `thumb + 12dp` (`NP:3531-3541`, `NP:2862-2866`) |

## 4. Progress bar and time labels

`ThinSlider` (`SLD:76-93`, drawing `SLD:190-250`): Material's Slider cannot be shaped this way —
**there is no thumb knob at all**.

| Property | Value |
|---|---|
| Track height idle / dragging | **7dp / 12dp** (`SLD:92-93`) |
| Corner radius | `height / 2` (full capsule, `SLD:191`) |
| Played fill | `Color.White @ 0.92` |
| Unplayed track | `Color.White @ 0.26` |
| Automix window marker | `Color.White @ 0.5`, feathered 40% of its span, 6–40dp, smoothstep ends (`SLD:168-200`) |
| Fill minimum width | `height` (never a dot at 0:00) (`SLD:243-247`) |
| Touch target | `activeHeight + 22dp` = **34dp**, invisible (`SLD:177`) |
| Height animation | spring `dampingRatio = MediumBouncy, stiffness = MediumLow` (`SLD:128-134`) |
| Gesture | one loop: a tap seeks immediately to that fraction and starts a drag (`SLD:178-200`) |
| Loading | the fill retracts and a sheen sweeps the full thickness, 450ms morph, 1000ms ping-pong pass over a 34%-band gradient (`SLD:263-300`, `SLD:404-420`) |

Times: `labelMedium` (12sp W600, ls 0.25), player tint **@ 0.55**, left = elapsed, right =
`"-" + remaining`, formatted `m:ss` (`CTL:243-268`, `CTL:1641-1647`). The row is pulled up by
**9dp** into the slider's invisible touch area (`CTL:238`). A `Lossless / Hi-Res` badge (or
"Mixing", +0.5sp, alpha 0.85) is pinned dead-centre between the two times (`CTL:232-247`,
`CTL:281-300`).

## 5. Transport

`Arrangement.SpaceAround` so the outer margins take half a gap (`CTL:483-490`).

| Piece | Normal | Compact (landscape phone) |
|---|---|---|
| Play/pause glyph | **74dp**, touch 92dp | 58dp / 76dp |
| Skip glyph / touch | **53dp / 53dp**, `scaleY = 0.85` (flatter) | 44dp / 53dp |
| Loading spinner | 38dp, stroke 3dp, white | 30dp |
| Disabled | alpha **0.3**, still clickable-off (never removed) | same |

Gaps around the transport are `8dp + spread/2` above and `12dp + spread/2` below, where `spread` is
leftover vertical space granted in whole px, capped at `CONTROL_GAP_SPREAD_MAX × 2 = 48dp`
(`NP:400`, `NP:2780-2822`, `NP:3950-3985`). The play glyph is not padded inside a smaller box —
the glyph itself is 74dp inside a 92dp touch target.

## 6. Volume and action row

Volume (`CTL:536-580`): 20dp speaker glyphs at tint **@ 0.5**, 10dp spacers, slider at 6dp idle /
10dp active, row height 32dp (`VOLUME_ROW_HEIGHT`, `CTL:532`). Hidden by a setting but its 32dp
footprint is retained (`NP:3980-3986`).

Action row (`CTL:582-720`): lyrics glyph left, queue glyph right, one capsule centred.

| Element | Spec |
|---|---|
| Glyph box | **44dp**, glyph **26dp**, tint 1.0 lit / **0.75** rest |
| Lit tile | 35dp rounded rect, corner **7dp**, fill = tint @ **0.62**, drawn with `BlendMode.SrcOut` so the glyph is *cut out* of the tile (`CTL:730-775`, `CTL:837-841`) |
| Capsule | height 44dp, `CircleShape`, fill = tint @ **0.12**; animates its width with spring `dampingRatio 0.82, stiffness MediumLow` (`CTL:886-897`) |
| Segment | **64 × 44dp**, divider 1dp @ **0.20**; highlighted segment fill tint @ **0.14**, glyph 1.0 / 0.75 (`CTL:907-913`, `CTL:1030-1070`) |
| Segment icons | 24dp default; optical overrides 23 / 22 / 21 / 17dp so headphones/person/cast/watch read as a matched pair (`CTL:855-872`) |
| Segment label | 17sp Bold (`"1"` for repeat-one), trailing count 13sp Bold |
| Contents | output + party, or (queue open) shuffle · repeat · autoplay; crossfade 180ms with `SizeTransform(clip = false)` 220ms (`CTL:636-700`) |
| Placement | `edgeInset = (width − 2·44 − pillWidth) / 4`; the two glyphs slide inward by `closeIn` over 220ms when the capsule drops to one segment (`CTL:600-640`) |

`pillWidth(n) = 64·n + 1·(n−1)` (`CTL:874`).

## 7. Backdrop

### 7.1 Default — blurred artwork (`BLUR:98-170`)

Decode the cover at 128px, run **3 box-blur passes** on a worker thread, cache by URL, draw as one
bilinear image cropped to fill, crossfade **320ms** on change (`BLUR:104-131`, `BLUR:145-160`).

Scrim over it — the only thing protecting white text:

| Stop | Colour |
|---|---|
| 0.00 | `#000000` @ **0.34** |
| 0.55 | `#000000` @ **0.48** |
| 1.00 | `#000000` @ **0.64** |

(`BLUR:428-433`). Fallback before any art is read: **`#121212`** (`BLUR:435`). When a panel
(lyrics/queue) opens over it the same backdrop stays, crossfaded to full over 360ms — it never
re-blurs while moving (`NP:2273-2301`).

### 7.2 Legacy mesh — 4 blobs (`MESH:77-232`)

| Property | Value |
|---|---|
| Colours | 4 (`MeshPalette.colors`), each `tuned()`: **S × 1.35** (cap 1.0), **L clamped 0.28–0.58** (`MESH:403-410`) |
| Anchors (fractions of W/H) | (0.20, 0.25) · (0.80, 0.20) · (0.75, 0.80) · (0.25, 0.75) (`MESH:186-191`) |
| Drift | `±0.16` of each axis, phase speeds `1, −0.7, 0.85, −1.15`, irrational multiples so it never repeats (`MESH:192-200`) |
| Blob radius | `0.62 × maxDimension` |
| Blob alpha at centre | **0.85**, falling along `smootherStep` to 0 (`MESH:201-231`, `MESH:232`) |
| Blur | whole layer `.blur(64.dp)` after a `1.3×` scale (so clamped edges never show) (`MESH:176-190`) |
| Base fill | colour[0] at **L = 0.12** |
| Scrim | black **0.10 → 0.38** vertical |
| Settle | `DRIFT_RADIANS = π·0.45` in **8000ms**, `FastOutSlowInEasing`; then it stops dead (never orbits) (`MESH:142-165`, `MESH:328`) |
| Palette crossfade | `tween(1400)` per colour slot (`MESH:124-140`) |
| Fallback palette | `#3A1C71` `#D76D77` `#2B5876` `#FFAF7B` (`MESH:53-58`) |

### 7.3 How the palette is derived (`MESH:295-416`, `PAL:245-300`, `PaletteQuantizer.kt`)

1. Decode the cover at **128px** with pixel access (`MESH:306-320`).
2. Quantise exactly as androidx Palette does: nearest-neighbour downscale to a 112×112 area,
   RGB555 histogram, median cut by box volume, **24** requested colours
   (`PaletteQuantizer.kt:20-60`). Default filter drops **L ≤ 0.05**, **L ≥ 0.95**, and the red
   I-line (hue 10–37° with S ≤ 0.82) (`PaletteQuantizer.kt:205-215`).
3. Sort swatches by **population desc**; if the filtered set is empty, re-run with filters cleared
   (`MESH:347-365`).
4. Drop near-duplicates: two colours are "the same" when **hue gap < 15° and ΔL < 0.12**
   (`MESH:368-380`).
5. If fewer than 4 survive, fan out: take existing colours in order, **hue + 24°·n**, **L + 0.12·n**
   clamped to 0.20–0.70 (`MESH:382-397`).
6. Weights are **not** used — the four keep their population order, which is what makes colour[0]
   the base fill.

For non-backdrop chrome the player uses a second, luminance-aware derivation: `rememberPlayerTint`
picks the first of {dominant, vibrant} whose **channel spread ≥ 0.08**, then sets
**S clamped 0.18–0.40, L = 0.88** (`PAL:170-196`). That colour is the player's entire secondary
text colour (artist, timestamps, badges, glyphs, inactive lyrics) — white until the art has been
read (`CTL:326-337`).

## 8. Lyric strip (the one line above the scrubber)

Shown only while the lyrics panel is closed even if nothing was found — the slot always exists so
opening lyrics cannot grow the player (`NP:3880-3900`).

| Property | Value |
|---|---|
| Type | `titleMedium` (16sp W600, ls 0.05) with `lineHeight = 20sp`, `LineHeightStyle` centre/no-trim so scripts with taller metrics don't shift the sleeve (`LYR:2806-2816`) |
| Colour | white; unsung portion of a word-synced line at **0.55** (strip uses a lighter dim than the panel) (`LYR:212`) |
| Layout | 4dp vertical padding, tap target clipped to 8dp radius, disclosure chevron 14dp @ 0.5 at the trailing edge, 6dp before it (`LYR:2975-2996`) |
| Line change | `AnimatedContent`: slide in from `+0.35 × height`, old line fades *and* slides `−0.35 × height`, **340ms** `FastOutSlowIn`; snapped when Reduce Motion is on (`LYR:2884-2929`) |
| Self fade | alpha = `0.78 × clamp(remaining/fade, 0, 1)`, fade = `28%` of the line's span clamped **160–700ms** (`LYR:2785-2787`, `LYR:2937-2952`) |
| Instrumental | 16dp note glyph + "Instrumental"; before the first sung line, one of the `lyrics_intro_lines` (`LYR:2860-2900`) |
| No timings | note glyph + "Lyrics" + chevron, tap opens the panel (`LYR:2836-2866`) |

## 9. Lyrics panel

Placed full-size under the header (`padding(top = 60dp)`) and only *after* the sleeve finishes
collapsing: `panelFade` runs `tween(200, FastOutSlowIn)` on `collapseDone` (`NP:1275-1288`,
`NP:3679-3690`).

### 9.1 Typography

| Role | Size / line height / weight | Alpha |
|---|---|---|
| Lead line, synced | **34sp / 41sp / ExtraBold** (`headlineLarge` overridden) | 1.0 active, falloff if not |
| Lead line, unsynced | **30sp / 38sp / ExtraBold** (`headlineMedium`) | 0.95 flat |
| Translation / romanization | **20sp / 25sp / Bold** | × **0.85**, tucked up **6dp** under the lead |
| Answering vocal (duet) | **23sp / 29sp** | × **0.72** |
| Translation of backing | 16sp / 21sp | × 0.72 × 0.85 |
| Section header (Genius) | 11.5sp / Bold / ls 1.3, uppercase, pill `white @ 0.14`, corner 6dp, padding 11×4dp | 0.90 |

Citations: `LYR:258-300`, `LYR:2224-2240`, `LYR:2368-2380`, `LYR:2474-2520`, `LYR:2071-2095`.
Colour: active line = **`Color.White`**; every other line = **player tint**
(`LYR:2581-2588`), animated so a line warms to white as it is reached.

### 9.2 Falloff away from the sung line

Indexed by distance (phone values; a centred/landscape column uses the shorter set):

| distance | 0 | 1 | 2 | 3 | 4 | 5 | 6+ |
|---|---|---|---|---|---|---|---|
| alpha (phone) | 1.0 | 0.74 | 0.60 | 0.48 | 0.40 | 0.34 | 0.34 |
| alpha (centred) | 1.0 | 0.80 | 0.70 | 0.58 | 0.46 | 0.46 | 0.46 |
| blur | 0 | 1 | 1 | **1.7** | **2.4** | 2.4 | 2.4 dp |

`LYR:362-373`. All four properties (alpha, blur, scale, scroll) share one curve:
`CubicBezierEasing(0.41f, 0f, 0.12f, 0.99f)` over **400ms** (`LYR:436-437`). Alpha/blur are forced to
0 and one flat **0.80** while the reader is hand-scrolling (`BROWSING_ALPHA`, `LYR:403`).

### 9.3 Scale

Active **1.0**, inactive **0.98**, pressed **0.96** (120ms), origin at the text's start edge so the
words don't slide under the highlight (`LYR:406-410`, `LYR:2259-2270`).

### 9.4 Word-level highlight (karaoke sweep)

- Word-synced lines draw two stacked copies: a dim copy at **alpha 0.45** (a finished line animates
  its dim tail back up to 1.0) and a lit copy clipped to `line.revealedChars(position)`
  (`LYR:900-935`, `LYR:2596-2626`).
- The leading edge is **feathered 30dp** (≈1.5 characters), and only on the active line — a hard edge
  reads as a bar travelling across the words (`LYR:310`, `LYR:2606-2618`).
- The word being sung **rises 2dp** (`WORD_RISE`), with 3× headroom reserved (`LYR:319-330`); held
  notes get a **per-letter bloom**, alpha **0.62**, blur **6dp**, composited offscreen so only carried
  letters light up — not a band under the sweep (`LYR:231-249`, `LYR:940-1000`).
- Lines past `endMs` or before `timeMs` cost one comparison per frame and never redraw (`LYR:880-895`).

### 9.5 Scroll behaviour

- Auto-follow **leads** the singing: the list starts moving `scrollLead` before the next line,
  where `scrollLead = clamp(gap between current line's end and next line's start, 350, 500)` ms,
  and the move itself takes the same duration on the shared easing (`LYR:426-491`, `LYR:1960-2030`).
- Rows **stagger**: up to 3 rows behind the target start `6%` of the run later each, so spacing
  fans open/closed instead of a block sliding (`STAGGER_STEPS/FRACTION`, `LYR:450-455`).
- Hand scrolling suspends following; it resumes **600ms** after settling on-screen, or **5s** if
  the reader scrolled away (`LYR:1902-1920`).
- Scrolling **up** by >20dp brings the bottom player back; scrolling down hides it
  (`CONTROLS_SCROLL_SLOP`, `LYR:495`, `LYR:1725-1760`). Controls also stand down after **5s** of
  no touch/scrub (`NP:557`, `NP:1222-1236`).
- List padding: top `40 − 10dp`, bottom `0.80 × viewport`, sides `30 − 10dp` (the 10dp is the glow
  inset each row carries) (`LYR:2058-2072`). Row clip **10dp** (`LYR:2321`).

### 9.6 Instrumental breaks

Row height animates `0 → 56dp` (**40 + 16dp** spacing) so no dead space is carried through the
verses; content is **3 dots** of 13dp with 5dp gaps, unlit at **0.25**, lighting left-to-right
across the break, resting scale 0.76 (`LYR:340-352`, `LYR:405-425`, `LYR:2160-2200`).

### 9.7 States

| State | Rendering |
|---|---|
| Loading (`looking`) | Skeleton: bars 26dp tall standing on 15dp leading, block gap 35dp, 5 hard-coded ragged line shapes, shimmer period 1400ms (`LYR:384-400`, `LYR:1656-1716`) |
| Not found, panel | "No lyrics for this track" — `titleMedium`, white @ **0.6**, centred (`LYR:2032-2040`; string `sharedUi/src/commonMain/composeResources/values/strings.xml:103`) |
| Not found, strip | The same line holds 5s then fades over 900ms rather than lingering (`LYR:497-498`, `LYR:3005-3030`) |
| Not found, landscape pane | "Lyrics not available" (`NP:2169-2174`) |
| Provider attribution | `lyricsSource != null → "Lyrics by %s"` (`LYR:3269`, string `strings.xml:54`); shown as the status caption above the scrubber, `titleMedium`, **tint @ 0.55, underlined**, tap opens the provider sheet (`LYR:529-565`, `NP:3915-3925`) |

### 9.8 Translation / romanization

Two 34dp circular buttons floated over the bottom corners of the panel (not in the flow), tint
@ **0.78** available / **1.0** active / **0.42** disabled, disc @ **0.18 / 0.34**, glyph 19dp,
loading spinner 16dp @ 1.7dp stroke (`LYR:1461-1565`, `NP:3745-3772`). They fade with the controls
(220ms in, 160ms out). Toggling runs a 540ms glyph-particle transition instead of a re-scroll
(`LYR:508`, `LYR:1569-1600`).

Duet lines: only when the source marks a second voice; each voice keeps a **44dp lane** clear on
the far side (`LYR:340`, `LYR:2285-2290`).

## 10. Queue

Header: `"Queue"` in **`titleLarge` 20sp W700 ls −0.2**, white; a `Clear` text button
(`titleMedium`, white **@ 0.75**, pill-clipped, 8×4dp padding) at the trailing edge (`QUE:275-300`,
`QUE:449-458`).

Sections, in order, each with `titleMedium` white @ **0.75** heading padded `top 12/16, bottom 6`:
`Previously played` · `Now playing` · `Next in queue` · `Next from {album|source}` · `Autoplay`
(infinity glyph 18dp @ 0.75 + two-line heading) (`QUE:310-400`, `QUE:431-500`).

Row (`QUE:722-825`):

| Element | Spec |
|---|---|
| Container | full width, corner **8dp**, vertical padding **6dp**; lifted copy fill `white @ 0.06` |
| Drag handle | `DragHandle` 20dp, tint white **@ 0.4**, `offset(x = −4dp)`, 4dp gap, drags vertically only |
| Artwork | **44dp** (16:9 for video), corner **6dp**, hairline `thumbnailBorder`, fill `white @ 0.08` behind |
| Gap | 12dp |
| Title | `titleMedium` (16sp W600): white when current, else **0.92**; explicit badge inline |
| Artist | `bodyMedium` (14sp W400), white **@ 0.55**, one line ellipsised |
| Current marker | `GraphicEq` 18dp white, then 10dp |
| Remove | 32dp circle, `Close` 18dp, white **@ 0.55** |
| Reorder | dragged row stays in the list at alpha 0 (keeps the gesture), the visible copy is drawn over the list at the finger; rows trade slots over `tween(200, FastOutSlowIn)` (`QUE:125-127`, `QUE:390-425`, `QUE:505-540`) |
| Edge auto-scroll | starts 40dp from either end, accelerates to **340 dp/s** (`QUE:503-505`) |

## 11. Motion

| Transition | Spec |
|---|---|
| **Sheet open / close** | `spring(dampingRatio = Spring.DampingRatioNoBouncy (1.0), stiffness = 195, visibilityThreshold = 0.5f px)`. Critically damped, ~0.45s response, never bounces; the finger's release velocity is fed in as `initialVelocity`, so a flick leaves fast and a slow pull settles gently. Position is clamped to `[0, travel]` so a hard throw can't overshoot (`MOT:33-39`, `MOT:333-355`) |
| Sheet reveal | the window's own enter/exit animation is disabled for 600ms while the app places the content (`MOT:47-53`, `MOT:212-224`) |
| Backdrop dim | black `0.32 × openFraction` (`MA:4707`) |
| Sleeve collapse (to panel header) | `tween(420, FastOutSlowIn)`, one value driving sleeve size/position, credits scale, panel fade and title alpha (`NP:1250-1263`) |
| Queue drag-in | same 420ms value, driven directly by the finger; release opens if ≥ **30%** travelled **or** abs(velocity) ≥ **450 px/s** in the drag direction (`NP:243-260`, `NP:4027-4065`) |
| Hero (full-bleed) | `tween(420, FastOutSlowIn)` (`NP:1424-1433`) |
| Backdrop crossfade | 360ms (player) / 320ms (art) (`NP:2277-2282`, `BLUR:150`) |
| Panel fade | 200ms after the collapse completes (`NP:1281-1288`) |
| Deck slide | 420ms `FastOutSlowIn`; first-open fade 700ms **linear** (`NP:563`, `NP:578-600`) |
| Artwork pause | spring LowBouncy / StiffnessLow (`NP:1192-1199`); landscape pose uses `CubicBezierEasing(0.215, 0.61, 0.355, 1)` over 500ms instead, because a spring lags a scrub (`NP:389-390`) |
| Track swipe | spring `StiffnessMediumLow`, threshold 72dp (`NP:1188-1205`) |
| Reduce Motion | colour snaps instead of crossfading, mesh freezes, lyric transitions cut, sheet closes with Material's own animation (`MESH:139`, `NP:2884-2929`, `MA:4610`) |

## 12. Token tables

### Colour

| Token | Value | Source |
|---|---|---|
| Player root / scrim behind | `#000000` | `NP:2261` |
| Sheet dim | `#000000` @ 0.32·open | `MA:6147` |
| Backdrop fallback | `#121212` | `BLUR:435` |
| Backdrop scrim | 0.34 / 0.48 / 0.64 black | `BLUR:428-433` |
| Mesh scrim | 0.10 → 0.38 black | `MESH:222-230` |
| Mesh fallback ×4 | `#3A1C71` `#D76D77` `#2B5876` `#FFAF7B` | `MESH:53-58` |
| Primary text | `#FFFFFF` | §3, §9.1 |
| Secondary text / glyphs | player tint @ 0.55 (artist, times, badges) or tint @ 0.75 (glyph rest) | §3, §6 |
| Progress played / track | white @ 0.92 / 0.26 | `SLD:92-93` |
| Danger/brand red (unused here) | `#FA2D48` | `THM:26` |
| App dark scheme (behind the player) | bg `#000000`, surface `#0D0D0F`, variant `#1C1C1E`, onVariant `#8E8E93`, outline `#2C2C2E` | `THM:30-39` |

### Type (all SF Pro Display — `THM:67-73`, scale `THM:84-96`)

| Style | Size | Weight | Letter spacing | Used for |
|---|---|---|---|---|
| titleLarge | 20sp | W700 | −0.2 | track title, "Queue" header |
| titleMedium | 16sp | W600 | +0.05 | lyric strip, queue row titles, status caption, section heads |
| bodyMedium | 14sp | W400 | +0.3 | queue artist |
| labelMedium | 12sp | W600 | +0.25 | elapsed / remaining, badges |
| labelSmall | 11sp | W600 | +0.3 | origin caption |
| overrides | 34 / 30 / 23 / 20sp | ExtraBold / Bold | — | lyrics panel, sub-lines |

Note the weights in `THM` are *shifted one cut lighter* when drawn: `W800→Bold`,
`W700→Semibold`, `W600→Medium`, `W500→Regular` (`THM:44-73`). A SwiftUI port using the real SF Pro
should map the **drawn** cut, not the requested enum.

### Layout

| Token | Value | Source |
|---|---|---|
| Player gutter | 30dp | `NP:335` |
| Max content width | 560dp | `NP:342` |
| Header height | 60dp | `NP:233` |
| Collapsed thumb | 54dp | `NP:232` |
| Art→credits gap | 20dp | `NP:234` |
| Art corner / shadow | 8dp / 10dp | `NP:3026`, `NP:3124` |
| Top strip | 32dp | `NP:268` |
| Control glyph box | 44dp | `CTL:829` |
| Lyrics panel row clip | 10dp | `LYR:2321` |

## 13. macOS adaptation notes

**Keep 1:1 — these define the look**

1. The type scale and drawn cuts in §12 — SF Pro Display is already bundled in this repo
   (`resources/fonts/`); use it rather than the system face if you want the exact widths.
2. The colour maths in §7.3 verbatim: 128px decode, median cut, 15°/0.12 dedupe, +24° fan-out,
   same tuning bands. The secondary-text tint is what makes this look like Apple Music instead of a
   white-on-black mock.
3. The scrubber: **7dp bar, no thumb, 12dp when dragging**, times at 0.55 alpha pulled 9dp up.
4. Transport (74/92 play, 53/53 skip at scaleY 0.85), 44dp action glyphs, 64×44 pill segments, 8dp
   album corner, 35dp/7dp lit tile with the glyph cut out.
5. Lyrics: 34/41 ExtraBold, the falloff + blur table, one cubic-bezier(0.41,0,0.12,0.99) at 400ms,
   30dp feather, 2dp word rise, 0.45 dim, 350–500ms scroll lead.
6. The sheet spring (stiffness 195, damping 1.0, threshold 0.5pt) — port it directly.
7. The 560dp content cap. A 1600pt window must **not** stretch the transport across it.

**Change — Android idioms with no desktop equivalent**

| Android | macOS |
|---|---|
| Full-window `ModalBottomSheet`, status bar hidden, top scrim keyed to artwork luminance | Own `Window`/`WindowGroup` for the player, or an in-window `.sheet` with `.presentationDetents([.large])`. Replace the status-bar scrim with a **44–52pt toolbar** inset by the traffic lights (78pt leading), or hide window chrome with `.windowStyle(.hiddenTitleBar)` and keep a translucent top bar. Give the window corner radius ~12pt. |
| Sheet *drag* to dismiss | Keep: a click-drag on the top strip closing the window is still right. Keep the 32pt strip as the only drag region. |
| Baked 128px blurred artwork (chosen because a live `RenderEffect` is expensive) | Same approach — bake a `CIGaussianBlur` of a 128px crop once per track and crossfade 320ms. Do **not** put an `NSVisualEffectView` behind moving artwork; it costs the same on a Mac as it did on a phone and looks smudgier. |
| `LocalPlayerTint` (artwork-derived) | Keep exactly; it is the single strongest "this is Apple Music" signal. |
| Haptics on every glyph | Drop. Replace with a subtle 0.96 press scale (already the lyric press) and hover states. |
| Safe-area insets for status/nav bars | `.safeAreaInset` for the window title bar; keep 30pt side gutters and 18pt bottom. |
| One-handed phone column | **Two columns above ~900pt width** — see below. |
| Canvas/music-video autoplay | Pause on `NSWindow.occlusionState`, on `scenePhase != .active`, and when the window is miniaturised. |

**Two-column desktop layout** — the app already ships the exact arrangement for landscape, so copy
`LSC` rather than inventing one (`LSC:120-240`): max total width **1100dp**, two equal columns,
gutter **30dp** (**20dp** when the window is short, `< 440dp` tall), outer top padding 24dp
(12dp short), bottom 20dp (8dp short), each column `weight(1)`.

- **Left column:** sleeve sized `min(columnWidth, remainingHeight)` — it is the height that usually
  wins on a laptop, so the album never pushes the transport off-screen — then 24dp, then the
  lyrics · capsule · queue row and the output caption. Always visible; it is the "which panel"
  control.
- **Right column:** an `AnimatedContent` swapping three pages — credits+transport, lyrics sheet,
  queue — with **fade in 220ms after a 90ms delay, fade out 140ms** (`LSC:103-105`). The artwork
  never moves between columns, which is what makes the swap read as a page turn, not a re-layout.
  Above ~1400pt stop at 1100pt and centre; do not add a third column.

**Hover and pointer**

- `CircleGlyph` (like, `⋯`, translate, romanize): disc 0.18 idle / 0.34 active (`CTL:739-742`) —
  add **0.26 on hover**; give it a `.help()` tooltip.
- Scrubber: on hover, thicken to the drag height (12dp) and show the time under the pointer;
  clicking jumps, dragging scrubs. Keep the no-thumb look until hover.
- Queue rows: reveal the drag handle and remove button only on row hover (always visible on touch);
  hover fill `white @ 0.06`, the same token as the lifted row. Action-row glyphs raise tint
  0.75 → 1.0 over 120ms.
- Cursor: `.pointingHand` on every glyph, `.resizeUpDown` on the queue handle, default elsewhere.

**Keyboard** (nothing on Android maps 1:1 — add it)

| Key | Action |
|---|---|
| Space | play / pause |
| ← / → | seek −/+ 5s |
| ⌘← / ⌘→ | previous / next track |
| L | toggle lyrics panel (focus the panel; `esc` returns) |
| Q | toggle queue |
| ↑ / ↓ | move the lyric selection one line and seek to it |
| ⌘F | toggle full-bleed artwork (or `⌃⌘F` for the window) |
| Esc | close panel → close player (in that order — the Android back handlers are stacked exactly like this, `NP:1087-1105`) |

**Text and layout robustness**

- Lock the desktop type scale (no Dynamic Type above 1.15×) except in the lyrics panel, where it
  should flow through the 41/34 line-height ratio. Long titles keep the marquee, but reveal the
  full string as a tooltip on hover instead of restarting the crawl.
- The 34sp lyric line assumes a ~500pt column; below 420pt of column width step to 28sp / 34sp —
  the falloff and blur table does not change.

**What must not be "improved"**

No drop shadows on lyric text · no sleeve corner above 8dp at phone-ish sizes · no thumb knob on the
scrubber · no tint on the transport or seek bar (pure white by design, `CTL:330-336`) · no bounce on
the player sheet.

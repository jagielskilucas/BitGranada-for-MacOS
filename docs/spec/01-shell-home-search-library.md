# 01 — App Shell, Home, Search, Library (BitChord 1.9, Android/Compose → macOS/SwiftUI)

Extracted by reading source only. Every number below is a literal from the Kotlin. Units are **dp**;
at the default macOS scale **1 dp ≡ 1 pt** (Android dp = 1/160 in, macOS pt = 1/72 in, but the app is
a phone layout being reproduced 1:1 in points, so treat every `dp` as `pt` verbatim).

Two things to know before reading:

1. **Material defaults also count.** Several surfaces (buttons, dividers) use Material 3 defaults that the
   app never overrides. Those are flagged `[M3 default]`.
2. **Default appearance is the non-glass path.** `liquidGlass = false`, `progressiveBlur = false`,
   `reduceDynamicBlur = false`, `themeMode = DARK` are the shipped defaults (`data/settings/AppSettings.kt:411-480`).
   So out of the box the shell draws `FloatingBottomBar` + `MiniPlayer` (Haze blur), **not** `GlassNavBar`.
   Both are specified; §2.5 is the glass variant.

### Source legend (paths are relative to `BitChord-1.9/`)

| Key | File |
|---|---|
| MA | `app/src/main/java/com/music/bitchord/MainActivity.kt` |
| AN | `app/src/main/java/com/music/bitchord/ui/navigation/AppNavigator.kt` |
| TH | `app/src/main/java/com/music/bitchord/ui/theme/Theme.kt` |
| FBB | `app/src/main/java/com/music/bitchord/ui/components/FloatingBottomBar.kt` |
| FTB | `app/src/main/java/com/music/bitchord/ui/components/floatingtabbar/FloatingTabBar.kt` |
| GSP | `app/src/main/java/com/music/bitchord/ui/components/floatingtabbar/GlassSelectionPill.kt` |
| GNB | `app/src/main/java/com/music/bitchord/ui/components/GlassNavBar.kt` |
| MP | `app/src/main/java/com/music/bitchord/ui/components/MiniPlayer.kt` |
| TBR | `app/src/main/java/com/music/bitchord/ui/components/FrostedTopBar.kt` |
| BFS | `app/src/main/java/com/music/bitchord/ui/components/BottomFadeScrim.kt` |
| TFB | `app/src/main/java/com/music/bitchord/ui/components/TopFadeBlur.kt` |
| LG | `app/src/main/java/com/music/bitchord/ui/components/LiquidGlass.kt` |
| QT | `app/src/main/java/com/music/bitchord/ui/components/QueueActionNotice.kt` |
| LPP | `app/src/main/java/com/music/bitchord/ui/screens/LibraryPhoneParts.kt` |
| HS | `sharedUi/src/jvmSharedMain/kotlin/com/music/bitchord/ui/screens/HomeScreen.kt` |
| SS | `sharedUi/src/jvmSharedMain/kotlin/com/music/bitchord/ui/screens/SearchScreen.kt` |
| LS | `sharedUi/src/jvmSharedMain/kotlin/com/music/bitchord/ui/screens/LibraryScreen.kt` |
| TPS | `sharedUi/src/jvmSharedMain/kotlin/com/music/bitchord/ui/screens/TopPicksShelf.kt` |
| CM | `sharedUi/src/jvmSharedMain/kotlin/com/music/bitchord/ui/components/Common.kt` |
| SR | `sharedUi/src/jvmSharedMain/kotlin/com/music/bitchord/ui/components/ShelfRow.kt` |
| SF | `sharedUi/src/jvmSharedMain/kotlin/com/music/bitchord/ui/components/SearchField.kt` |
| SK | `sharedUi/src/jvmSharedMain/kotlin/com/music/bitchord/ui/components/Skeletons.kt` |
| ST | `sharedUi/src/jvmSharedMain/kotlin/com/music/bitchord/ui/components/SongText.kt` |
| PS | `sharedUi/src/jvmSharedMain/kotlin/com/music/bitchord/ui/components/PillSegmentedControl.kt` |
| SQ | `sharedUi/src/jvmSharedMain/kotlin/com/music/bitchord/ui/components/SquirclePillShape.kt` |

---

## 1. Navigation structure

### 1.1 Tabs — exactly four, in this order (`MA:1303-1310`)

| # | Index const | Label (en) | Icon | Tab shows |
|---|---|---|---|---|
| 0 | `TAB_HOME = 0` (`MA:6175`) | **Home** | `BitChordIcons.Home` — filled+stroked house, 24pt viewport, stroke 1.7, round joins (`BitChordIcons.kt:122-152`) | `HomeScreen` (`MA:3336`) |
| 1 | `TAB_EXPLORE = 1` (`MA:6176`) | **Explore** | `BitChordIcons.TabExplore` — 4 filled squares, 2×2, 512-unit em box (`BitChordIcons.kt:167-176`) | `ExploreScreen` / `MoodGenrePlaylistsScreen` (`MA:3400-3437`) |
| 2 | `TAB_LIBRARY = 2` (`MA:6177`) | **Library** | `BitChordIcons.TabLibrary` — filled "stacked card" outline (`BitChordIcons.kt:181-188`) | `LibraryScreen` (`MA:3621`) |
| 3 | `TAB_SEARCH = 3` (`MA:6178`) | **Search** | `BitChordIcons.TabSearch` — filled magnifier (`BitChordIcons.kt:190-196`) | `SearchScreen` (`MA:3438`) |

Labels come from `strings.xml` (`home`/`explore`/`library`/`search`). **Search is special**: it is the
*standalone* tab, drawn as its own circle beside the tab pill, not a quarter of it — and it is last in
order deliberately (`GNB:128-131`).

### 1.2 What floats over every tab (z-order, bottom → top) (`MA:2749-4202`)

1. Root `Box` filled `colorScheme.background` (`MA:2749-2755`).
2. Page content — an `AnimatedContent` keyed by `AppDestination` (`MA:2803-2883`).
3. Top fade/blur (`MA:3723-3739`), then `FrostedTopBar` (`MA:3741-4085`).
4. `BottomFadeScrim` (`MA:4088-4095`).
5. `FloatingBarsTapGuard` — dead touch strip, bars height + 8 pt (`BFS:116-165`, `MA:4100-4103`).
6. `QueueActionNoticeHost` + the bars (`MA:4121-4202`), a `Column` capped at **440 pt** wide and centred
   (`CM:154`, `MA:4124`, `MA:4166`).

Page transitions: **tab↔tab is no animation at all**; `Library`↔its "Show all" grid likewise; everything
else cross-fades 180 ms (`MA:2832-2846`).

### 1.3 How Settings and detail pages stack

One back stack, `AppNavigator` (`AN:79-157`). Routes that are **not** tabs (`AN:18-52`):
`Settings`, `AccountScrobbling`, `Sources`, `ListenTogether`, `WearOs`, `Equalizer`, `Replay`, `History`,
`Discord`, `Spotify`, `Downloads`, `LibraryShowAll(shelf)`, `ArtistShelf`, `Moods`,
`SettingsSection(category)`, `SettingsChoice(kind)`, `EqualizerPresets`.

Album / artist / playlist pages are **not** routes: they live on `MainViewModel.detailStack` and are
interleaved with routes by depth (`AN:9-17`, `AN:92-99`), so "album opened from a Settings page" pops back
to that Settings page.

- Tab press **clears everything** pushed above the tab, then selects it (`MA:4108-4119`).
- **There is no Settings tab.** Settings opens from the account avatar in the top bar (`MA:4073-4082`), or
  from the signed-out avatar. Settings rows push `SettingsSection`, which push `SettingsChoice` pages.
- Back: pop route → else close mood/genre → else jump to Home (Home itself hands back to the system) (`MA:2743-2751`).
- A pushed page keeps its scroll state for as long as it is on the stack (`MA:3659-3662`).

---

## 2. The floating nav bar

### 2.1 Geometry (default, non-glass — `FloatingBottomBar`)

| Property | Value | Cite |
|---|---|---|
| Outer width | fill screen, **max 440 pt**, centred | `CM:154`, `MA:4166` |
| Side gutter | **19 pt** each side (`NAV_BAR_GUTTER`) | `FBB:85` |
| Distance above bottom | gesture-inset floor **15 pt** + lift **6 pt** | `FBB:91,106`, `BFS:80` |
| Shape | capsule — `RoundedCornerShape(percent = 50)`, i.e. radius = height/2 | `FBB:185` |
| Inner padding | **4 pt** all round (`PILL_INSET`) | `FBB:79`, `FBB:269` |
| Tab gap | **6 pt** (`Arrangement.spacedBy(6.dp)`) | `FBB:336` |
| Tab vertical padding | **6.5 pt** (`TAB_VERTICAL_PADDING`) | `FBB:118`, `FBB:401` |
| Icon box | **28 pt** | `FBB:128` |
| Icon→label gap | **1 pt** | `FBB:121` |
| Label | 10 pt, `labelSmall` copy, tracking **+0.5 pt**, `maxLines = 1`, ellipsis | `FBB:132-133` |
| **Bar height** | **62 pt** = 4 + 6.5 + 28 + 1 + ~12 (label line) + 6.5 + 4 | `FBB:126-128` |
| Each tab | `weight(1f)` — equal shares of the pill, not content-sized | `FBB:354` |

### 2.2 Glass / blur treatment (three materials, in priority order) (`FBB:256-268`)

1. `reduceDynamicBlur` on → flat `colorScheme.surface` (`#0D0D0F` dark).
2. `liquidGlass` on **and** API ≥ 31 → `Modifier.liquidGlass(shape)` (`LG:202-249`): vibrance 1.0
   (saturation ×1.5), blur 8 pt, lens refraction height 24 pt / amount 24 pt capped 48, chromatic
   aberration on, sampled at **1/3 resolution**, surface tint `#121212` @ **0.40** dark, `#FAFAFA` @ 0.40
   light, plus `Highlight.Default` rim and `Shadow.Default`.
3. Otherwise (default) → **Haze "regular" material** over `surface` (`FBB:262-266`).
Then, always, a hairline: **0.5 pt, white @ 10 %** (`LG:88-89`, `FBB:268`).

### 2.3 Selected indicator

- A capsule **exactly** the size of one tab cell: `width = (rowWidth − gap·(n−1))/n`, height = row height;
  its travel step is `(rowWidth + gap)/n` (`FBB:204-212`, `FBB:271-289`).
- Fill: `colorScheme.primary.copy(alpha = 0.14)` → dark **#FFFFFF @ 14 %**, light **#000000 @ 14 %**
  (`FBB:287`).
- Travel: `animateFloatAsState` on `selectedIndex * tabStep + dragOffset` with `GlassSpring` =
  **spring(dampingRatio 0.72, stiffness 320)** ≈ 330 ms, settles on the second approach — one soft
  overshoot, not bouncy (`FBB:147`, `FBB:225-229`).
- **Liquid stretch**: `lag = |target − animated| / tabStep` (0→1) drives `scaleX = 1 + 0.16·lag`,
  `scaleY = 1 − 0.16·0.5·lag`; scaled **about its own centre** so it draws out both ways (`FBB:163,174,236-285`).
- Glyph scale: **1.08** when selected, same spring (`FBB:374-378`).
- Tint cross-fade: selected `primary`, unselected `onSurfaceVariant`, `tween(200)` (`FBB:380-388`).
- Icons are **always the same glyph**, never filled-vs-outline: selection is tint + 8 % scale + the pill.

### 2.4 Behaviour on scroll, and on drag

- The bar does **not** hide. Only the glass variant folds (§2.5); the plain bar is static.
- Horizontal drag across the row: `detectHorizontalDragGestures`; every drag measures from the tab
  selected at drag start; `totalDrag/step` rounds to the nearest tab; a **Tick** haptic fires each time
  the rounded index changes; on release `onTabSelected(new)` (`FBB:295-335`). The indicator follows the
  finger through `dragOffset` while still stretching by `lag`.
- Tab press: no ripple (`indication = null`), a **Select** haptic when it is not already selected
  (`FBB:394-400`, `GNB:232-235`).

### 2.5 The liquid-glass bar (`GlassNavBar`) — when Liquid Glass is on

Two states, one component, cross-faded by `AnimatedContent` (`FTB:222-256`).

**Expanded** (`FTB:619-695`): a `Column`, `spacedBy(8)` — now-playing accessory full width **above**, then a
row of `[tab pill, weight 1] [8 pt] [Search circle, aspect 1:1]`. Pill content padding 4 pt
(`GNB:211`); tabs `weight(1f)` with **no horizontal padding**, 6.5 pt vertical; so pill height **62 pt**
(`GNB:212`, `FBB:118`). Search circle = same height, width = height.

**Inline / collapsed** (`FTB:408-479`): single row, height **48 pt** (28 pt glyph in 10 pt padding,
`GNB:489-493`), gutters **28 pt** (`INLINE_GUTTER`), items **14 pt** apart, lifted **7 pt**
(`INLINE_LIFT`) so it folds onto the expanded centre line (`GNB:485-493`). **Labels are dropped in this
state — icon only** (`FTB:1052-1054`).

**Fold trigger**: `rememberFloatingTabBarScrollConnection()` with default `OnScrollDown` and a **50 pt**
accumulated-scroll threshold; direction change resets the accumulator; the page's scroll is dispatched in
via `.nestedScroll(navBarScroll)` on the content `AnimatedContent` (`FTB:160-163,346-356`, `MA:545`, `MA:2866`).
Collapse/expand itself is a plain `fadeIn togetherWith fadeOut` (`FTB:224`).

**Selection pill physics** (`GSP:82-380`) — this is the signature motion:
tap → pill **lifts 9 pt taller than the bar** (`PILL_GROW_HEIGHT`, `GSP:53`) on two under-damped
springs (width 250/19, height 250/22.1), travels on spring (stiffness 280, damping 31.4), and deflates
where it lands once travel reaches **92 %** (`HANDOVER_START`). Glass comes on at stiffness 1000/damping 63.3
and sheds with τ 0.09 s out / 0.05 s back; while lifted it refracts the bar (lens 12 pt height, 14 pt amount),
with rim + contact shadow (radius 12 pt, y +2 pt, black @ 30 %) fading out by the time hand-off is 55 %
through (`GSP:336-362`, `GSP:555-575`). Drag = the same lift held open by the finger; drag follow is
exponential with τ 0.05 s (`GSP:270-278`).

**Docked now-playing row** (`GNB:294-482`): artwork **30.4 × 30.4 pt**, corner **5.7 pt**; title 13 pt
**W700** tracking +0.15, artist 12 pt tracking +0.35 at **white @ 70 %**; row padding start 16, end 8
(inline) / 12 (expanded), top/bottom 4; art→text 8 (inline) / 9; play slot 32 / 40 pt, glyph 24 / 29 pt;
next button dropped inline; glyph centres 44 pt apart; loading spinner 18 / 20 pt, stroke 2 pt; pressing
the glass scales it to **1.04** on `spring(StiffnessMediumLow)` (`GNB:314-330,375-384,437-479`).

---

## 3. The mini player (`MiniPlayer`, default path)

| Property | Value | Cite |
|---|---|---|
| Position | directly above the tab bar, **8 pt** gap | `MA:4172-4194` |
| Side gutter | 16 pt (`BAR_GUTTER` = `PAGE_GUTTER`) | `MP:377`, `CM:124` |
| Shape | capsule, `percent 50` → radius **28 pt** | `MP:374` |
| Height | **56 pt** = 40 art + 8 + 8 padding | `MP:112-116` |
| Material | Haze **thin** material over `surface`; solid `surface` under reduce-dynamic-blur | `MP:393-402` |
| Hairline | **0.5 pt white @ 10 %** | `MP:403` |
| Row padding | 12 pt horizontal, 8 pt vertical | `MP:116-128,410-415` |
| Artwork | **40 × 40 pt**, corner **8 pt**, 1 pt `white@0.15` (dark) / `black@0.15` (light) ring, placeholder fill `surfaceVariant` | `MP:138,424-430`, `ST:41-47` |
| Video artwork | **71 × 40 pt** (16:9), animated width | `MP:345,420-423` |
| Art→text gap | **10 pt** | `MP:451` |
| Title | `titleMedium` 16 pt W600 → Medium cut, `onBackground`, explicit-badge before it, **fade-out** overflow 36 pt | `MP:455-461`, `ST:143` |
| Subtitle | `bodyMedium` 14 pt W400, `onSurfaceVariant`, fade-out overflow | `MP:462-466` |
| Play button | slot **40 pt**, glyph **32 pt** | `MP:82,93` |
| Loading spinner | **22 pt**, stroke 2 pt, `onBackground` | `MP:96,470-475` |
| Gap play→next | **8 pt** | `MP:110` |
| Next glyph | **25 pt**, squashed `scaleY 0.85` | `MP:521-532` |
| **Progress bar** | **none — there is no progress bar in either mini player.** Position is only readable by opening the full player. | `MP:409-508`, `GNB:371-480` |

Gestures (`MP:211-314`): one detector, direction decided once past touch slop.
- Horizontal swipe → prev/next at a **72 pt** threshold; committed on finger lift (max one skip per gesture).
- Upward: `|dy| > 1.5·|dx|` counts as a pull; pull lifts the bar via `0.5·d`/`√(1+d/72)` and drives the
  player sheet; on release the bar springs home `spring(0.65, StiffnessMediumLow)`.
- Tap anywhere on the bar → expand the player (silent, no ripple) (`MP:407`).
- `controlsLocked` (party host holds controls): next glyph fades to **30 %** and stays in place so the bar
  keeps its shape (`MP:500-506`).

---

## 4. Home

### 4.1 Top-to-bottom

1. **Wordmark, no greeting text.** `HomeTitle` draws only the logo: height = `0.9 × 34 pt` ≈ **30.6 pt**,
   aspect **730 : 484** (1.508), `onBackground` tint, bottom padding **14 pt**, column padding 16 h / 8 v
   (`HS:489-516`). The "Listen Now" heading is **commented out** in source (`HS:503-508`) — do not render a
   text title.
2. Because of that, the whole feed is pulled up **28 pt** (`HOME_TITLE_LIFT`): content top = status + 52 + 12 − 28
   (`HS:97,187-194`).
3. Optional **sign-in banner** when signed out (`HS:199-209`, `CM:871-938`): capsule-ish card corner **22 pt**,
   full-bleed mesh gradient, padding 20/20/20/18, headline 22 pt W800 white, white pill CTA (Google G 18 pt,
   8 pt gap, label 15 pt W700 black, 16/20 × 10 padding), pressed scale **0.98** on `spring(900)`.
4. **Top Picks for You** (`HS:210-222`, `TPS:146-195`).
5. **Shelves**, with **Find Your Mood inserted before shelf index 1** (`HS:298-302`).

### 4.2 Section header (`HS:525-564`)

- Row, padding 16 h / **10 v**, title column `weight(1)`, vertically centred.
- Title `titleMedium` 16 pt W600, `onBackground`, **2 lines** max, ellipsis.
- Subtitle `bodyMedium` 14 pt W400, `onSurfaceVariant`, 1 line.
- "**Show all**": `titleSmall` (`[M3 default]` 14 pt W500 +0.1 tracking), `colorScheme.primary` (white in dark,
  black in light), tap target = text + 12 left / 4 top / 4 bottom padding. Only drawn where a caller passes it
  (Library, Find Your Mood).
- Each shelf block ends with **26 pt** bottom padding.

### 4.3 Compact card carousel (`Shelf`, `HS:838-877`)

| Property | Value | Cite |
|---|---|---|
| Card width | **150 pt** (`SHELF_CARD_WIDTH`) | `CM:163` |
| Art | 1:1, corner **12 pt**, 1 pt thumbnail ring, `surfaceVariant` placeholder | `HS:1098-1104` |
| Art→title gap | **10 pt** | `HS:1116` |
| Title | `titleMedium` 16 pt, `onBackground`, 1 line | `HS:1130-1137` |
| Subtitle | `bodyMedium` 14 pt, `onSurfaceVariant`, 1 line | `HS:1140-1146` |
| Pinned mark | 14 pt pin icon, 4 pt gap, before title | `HS:1121-1129` |
| Row insets | 16 pt horizontal content padding | `HS:852` |
| Card gap | **14 pt** | `HS:853` |
| Row scroll | `LazyRow` + `rememberSnapFlingBehavior` — always settles on a cell edge | `SR:39-57` |
| Device-folder cards | mesh gradient + 40 pt white glyph, same 12 pt corner | `HS:1011-1096` |

Video shelves use `VideoShelfCard` instead: width **248 pt**, art **16:9**, corner **12 pt**, 10 pt gap,
same title/subtitle styles (`HS:886-942`).

### 4.4 Lead "hero" shelf (first shelf only, when it is `ShelfLayout.CARDS`)

- Card width = `min(0.70 × rowWidth, 320 pt)` (`CM:174,188,203`).
- Aspect **0.92** (width/height → taller than wide), corner **18 pt** (`CM:191`, `HS:785-787`).
- Caption sits on a bottom scrim `verticalGradient(Transparent → black @ 78 %)`, padding 16/16, top 34, bottom 14
  (`HS:799-808`).
- Title `titleLarge` 20 pt W700 white; subtitle `bodyMedium` 14 pt **white @ 72 %**, 2 lines (`HS:810-826`).
- Row gap **14 pt** (`HS:755`).

### 4.5 Recents (list-style lead shelf: `ShelfLayout.LIST`, or first shelf titled "Recents")

- Column width = `min(0.88 × rowWidth, 400 pt)`; **4 rows per column**, paged sideways (`CM:206-230`, `HS:100,356-368`).
- Row: art **48 pt** corner **7 pt**, 12 pt gap, 4 pt vertical padding; title `titleMedium`, subtitle
  `bodyMedium` `onSurfaceVariant`; trailing ⋮ if long-press exists (`HS:437-478`).
- Column gap **12 pt** (`HS:354`).

### 4.6 Top Picks for You (`TPS`)

- Card width `min(0.60 × rowWidth, 280 pt)`, aspect **0.75** (3:4 portrait), corner **12 pt**, gap 14 pt,
  row bottom padding 26 pt (`TPS:133-144,165-195`).
- Caption at bottom-left, padding 16/16/16 (`TPS:371-406`):
  eyebrow **13 pt / line 16 pt**, colour per card kind; title **17 pt / line 21 pt W600 white**, 2 lines;
  subtitle **13 pt / 16 pt, white @ 86 %**, 2 lines.
- Photo cards get `Transparent → black@0.45 (0.72) → black@0.82 (1.0)` gradient and a `white @ 62 %` eyebrow
  (`TPS:340-350,409`). Branded cards get the BitChord wordmark 15 pt tall, top-right, 12 pt inset (`TPS:355-366`).

### 4.7 Find Your Mood (`TPS:1552-1567,1597-1634`)

- Header "Find Your Mood" **with Show all**.
- The **7 core moods** (`ENERGY, RELAX, FEELING_BLUE, FEEL_GOOD, FOCUS, HEARTBREAK, LOVE` — `TopPicks.kt:95`)
  as square tiles at `SHELF_CARD_WIDTH` 150 pt, corner 12 pt, 10 pt gap, name below in `titleMedium`;
  wordmark 11 pt at top-right, 8 pt inset. Row gap 14 pt, block bottom padding 26 pt.
- "Show all" → `AppRoute.Moods`: all **28** moods *and activities* in a grid using the same `libraryGrid`
  arithmetic as the Library's Show-all page (§6.4), horizontal 12 pt / vertical 20 pt (`TPS:1573-1595`).

### 4.8 Loading / error

- Loading: `feedSkeleton` — hero skeleton + 2 shelf skeletons; skeletons mirror real metrics exactly
  (`heroCardWidth`, 150 pt cards, 18 pt / 12 pt corners) so nothing jumps (`SK:154-252`).
- Shimmer: base `surfaceVariant`, highlight `onSurfaceVariant @ 16 %` composited over it, band 50 % of width,
  **1400 ms linear, infinite** (`SK:44,61-88`).
- Error: `MessageState` — 22 pt h / 48 pt v padding, `bodyLarge` `onSurfaceVariant` centred, then a Material
  `Button` (`CM:940-964`).

---

## 5. Search

### 5.1 Where the field lives

On the phone the field is **not in the page** — it is the top bar's accessory, filling the bar from the leading
gutter to the action buttons; `SearchScreen` is called with `showField = false` (`MA:3568-3569`). The page's
content starts at `topBarHeight() + 4 pt` (`MA:3568`). The field is the bar's **accessory**: a **44 pt**-tall
squircle pill (`TBR:462-491`, `SQ:32-97`) that spans from the leading gutter up to the trailing actions pill,
with an 8 pt gap before it (`TBR:338`). On glass its glyphs/words use the glass content colour and its hint
drops to **60 %** (`TBR:477-495`).

### 5.2 The field itself (`SF:56-160`)

| Property | Value |
|---|---|
| Standalone shape | `RoundedCornerShape(11 pt)`, fill `surfaceVariant` (`SF:84`) |
| Standalone height | **46 pt** (`SF:82-83`) |
| On-surface variant | fills the host's height (44 pt), no fill of its own (`SF:78-80,47`) |
| Padding | start **8 pt**, end **12 pt** (asymmetric so the magnifier gets a real target) (`SF:90`) |
| Magnifier | 32 pt box, 6 pt inner padding → **20 pt glyph**, `onSurfaceVariant`, circular, tappable when the query is non-empty (submits) (`SF:97-106`) |
| Icon→text gap | **4 pt** (`SF:107`) |
| Placeholder | `bodyLarge` **16 pt**, `onSurfaceVariant`, 1 line, ellipsis (`SF:110-118`) |
| Text | `bodyLarge` 16 pt, `onBackground`; caret `primary` (`SF:120-133`) |
| Clear button | **28 pt** circle, **18 pt** × glyph, appears only when non-empty (`SF:137-158`) |
| Hints | `Artists, Songs, Lyrics and More` / `Songs, Artists and Albums` / `Search your addons` |

### 5.3 Source switcher and filters (`SS:234-258`)

- Source switcher: `YouTube` / `Library` / `Addons`, full width, 16 pt side insets, 4 pt bottom; shown **only
  while the query is empty**, `fadeIn + expandVertically` / `fadeOut + shrinkVertically`.
- Filters: `All, Songs, Videos, Albums, Artists, Playlists` (`Models.kt:391-399`), shown only once a result set
  exists and not while suggesting; 6 pt bottom.
- Both are `PillSegmentedControl`: squircle track (exponent **2.1**), track fill `#767680` @ **24 %** dark /
  **12 %** light, 4 pt track padding, label 18 pt h / 9 pt v padding → **≈42 pt** tall; selected pill `#636366`
  (dark) / `#FFFFFF` (light), labels white / black, `labelMedium` 12 pt W600 +0.25; slide spring
  `spring(0.8, StiffnessMediumLow)`; haptic on change; overflow scrolls with a 28 pt edge fade (`PS:70-212`).

### 5.4 Results

- **Top result card** (`SS:510-584`): padding 16 h / 18 top / 8 bottom; "Top result" in `labelLarge`
  (`[M3 default]` 14 pt W500) `onSurface`; 10 pt gap; art **72 pt** corner **10 pt**; 14 pt gap;
  title `titleLarge` 20 pt, 2 lines; 4 pt gap; artist `bodyMedium`; ⋮ at 24 pt glyph; 12 pt gap; two
  `OutlinedButton`s 10 pt apart (Play, Add-to-playlist) — `[M3 default]`: 40 pt tall, fully rounded, 1 pt outline,
  `onSurface` content.
- **Section headings** (`SS:348-363`): `titleSmall` 14 pt, `onSurface`, padding 16/16, top 16, bottom 6.
  Sections in `All`: Songs, Artists, Albums, Playlists, More (`SS:418-427`).
- **Result row** = `SongRow` (`CM:290-670`): padding 16 h / 4 v; art **52 pt**, corner **8 pt**, 1 pt ring;
  14 pt gap; title `titleMedium`; 2 pt gap; subtitle `bodyMedium` `onSurfaceVariant` (artist · format);
  then, in order: downloaded badge 16 pt, current-item glyph 20 pt, **duration `labelMedium` 12 pt** 8 pt in,
  trailing control, **⋮ 36 pt box / 20 pt glyph** hanging **14 pt** into the gutter (`CM:678-705`).
  Search rows use `searchPlayingStyle`: instead of the current glyph, the artwork carries the animated
  playing bars — a **24 pt** black@52 % plate, corner 6 pt, three white 3 pt bars with 2 pt gaps (`CM:761-803`).
  Row divider: **0.5 pt**, `outline`, starting **84 pt** from the leading edge (`CM:127`, `SS:393-399`).
- **Swipe on a row** reveals a `primary @ 18 %` panel with "Queue" / "Play next"; commits past **45 %** width
  with a Tick haptic; always snaps back (`CM:383-500`).
- **Suggestions** (`SS:595-682`): 8 pt top inset, then up to **3** completion rows: 22 pt magnifier, 16 pt gap,
  `titleMedium` term, 40 pt / 18 pt "fill the field" arrow (`NorthWest`); padding 16 start / 8 end / 6 v.
- **Typeahead dropdown** (`SS:689-795`): 0.5 pt divider at `outline @ 40 %`, then media rows — 52 pt art,
  8 pt corner, 14 pt gap, title + 2 pt gap + artist, 6 pt vertical padding.
- **Recent searches** (`SS:802-1006`): header `headlineMedium` 22 pt W700 + "Clear" (`titleMedium`, `primary`,
  capsule tap area 10/4); rows 52 pt art (8 pt corner), 14 pt gap, title/subtitle, 40 pt remove button with
  18 pt ×.
- **Empty** — no history: `MessageState("Search millions of songs on YouTube Music.")` (`SS:307-309`).
  Library/Addons empty and no-result states exist too (`SS:450-469`).
- **Loading** — `songListSkeleton(8)`; `circular = true` for the Artists filter (`SS:321`, `SK:116-145`).

---

## 6. Library

### 6.1 Order of the page (`LS:128-228`)

1. Big heading **"Library"**, `displayLarge` **34 pt W800**, tracking −0.5, `onBackground`, padding 16 h / 8 v
   (`LS:133-142`, `TH:85`).
2. **Replay** row of cards (or its skeleton, or nothing) (`LS:143`, `LPP:146-165`).
3. **Device folder list** — the "Local files" affordance (`LS:144-146`, `LS:241-295`):
   rows `heightIn(min = 54 pt)`, 16 pt h padding, **24 pt** icon (`primary` tint, or a brand logo),
   **16 pt** gap, title `bodyLarge` 16 pt, trailing chevron **20 pt** at `onSurfaceVariant @ 60 %`,
   0.5 pt `outline` hairline between rows starting at **56 pt** (16 + 24 + 16).
   Rows: **Downloads**, **Local Music**, *Cached songs* (opt-in), *WebDAV*, *SMB*, *Spotify* (`LPP:56-92`).
   Icons: Download, Folder, Storage, Cloud, Lan (`LPP:126-133`).
4. **On Device** shelf (`LS:147-157`).
5. **Playlists** shelf, always drawn — with a leading "**New playlist**" card (+ optional "**Import Spotify**")
   even when empty (`LS:158-202`, `LS:305-341`).
6. Remaining shelves as grid shelves (`LS:203-225`).

Signed out: Playlists shelf + `MessageState(library_sign_in_description, "Sign in")` and stop (`LS:158-178`).

### 6.2 Library shelf row (`LS:356-388`)

- Card width **150 pt**, square art, corner **12 pt** — identical to Home's shelf cards.
- **Stops at 5 cards** (`LIBRARY_ROW_MAX_ITEMS`, leading card counts against it).
- "Show all" appears in the header **only when there are more than 5**.
- Card gap **12 pt** here (Home uses 14) (`LS:375`).
- "New playlist" card: dashed-intent tile — 1:1 `surfaceVariant`, centred 34 pt `primary` glyph (or 44 pt logo),
  10 pt gap, `titleMedium` label, `bodyMedium` subtitle (`HS:949-1004`).

### 6.3 Library "Show all" grid page (`LS:394-446`)

- `libraryGrid(w − 32 pt)`: `columns = clamp(floor((w−32+12)/(140+12)), 2, 5)`,
  `cardWidth = (w − 32 − 12·(columns−1)) / columns` (`CM:232-278`).
- Horizontal spacing **12 pt**, vertical spacing **20 pt**, page padding 16 pt.
- Same `ShelfCard`, but `fillMaxWidth()` inside the cell; "New playlist" is the first grid item when offered.
- Toolbar on this page: sort menu icon in the top bar (`MA:3934-3961`).

### 6.4 Empty / loading

- Loading: `librarySkeleton` = one shelf skeleton + section header + 7 song-row skeletons (`SK:282-286`).
- Empty shelves still render their header + an empty row (Playlists) — never a blank page.

---

## 7. Shell chrome details (needed to reproduce the look)

### 7.1 Top bar (`FrostedTopBar`, mounted `transparentBackdrop = true`, `artworkPageChrome = true`)

| Property | Value | Cite |
|---|---|---|
| Height | status inset + **52 pt** (`TopBarContentHeight`) | `TBR:91,133-135` |
| Content gap below | **12 pt** (`TopBarContentGap`) | `TBR:97,141` |
| Back / action control | **44 pt** (`TOP_CONTROL_SIZE`) | `TBR:698` |
| Back circle | centred vertically at leading edge, `padding(start = 16)` | `TBR:292-301` |
| Actions pill | trailing, `padding(end = 16)`; gap between actions **10 pt**; extra edge inset **1.5 pt** once >1 action; spring-grows via `animateContentSize` | `TBR:319-345,383-414,705-706` |
| Avatar | **28 pt** circle, 1 pt ring; swipe up/down 28 pt to switch profile, rubber-bands ±9 pt | `TBR:558-617,720` |
| Hairline | 0.5 pt `outline @ 60 %` — **but alpha 0 with `transparentBackdrop`**, so no line is visible in the shell | `TBR:194-203,347` |
| Title text | **currently not rendered** — the whole title block is commented out (`TBR:220-287`) | `TBR:220-287` |
| Refresh puck | **40 pt** circle, rests **16 pt** below the bar, `surfaceContainerHigh`, 22 pt ring, stroke 2.5 pt, rotation = fraction × 180° | `TBR:635-712` |

Action order on the trailing pill: update notice (Home root only) → history (Library root only) → sort
(Library Show-all) → search/sort/more (release pages) → share (artist) → downloads → avatar (suppressed on
Settings routes and release pages) (`MA:3893-4083`).

### 7.2 Top edge treatment

Two implementations, same intent — content scrolling under the bar is frosted:
`TopFadeBlur` when progressive blur is available (height = bar + **16 pt**, blur **24 pt**, 1/3 resolution,
vertical progressive 1→0 with `EaseInOut`, then a DstIn foot fade from **60 %** down) (`TFB:33-111`), else
`BottomFadeScrim` rotated 180° (`MA:3723-3739`). On Home the top fade's alpha is **0 at rest** and ramps to 1
over the first item's height, so the wordmark is never washed out (`MA:3708-3722`).

### 7.3 Bottom edge treatment (`BottomFadeScrim`)

Flat `background` colour, **cubic ease-in** alpha ramp cut into **16 stops**; height **180 pt** normally,
**254 pt** with the mini player, plus the gesture inset; height animates `tween(220)` (`BFS:28-108`).

### 7.4 Queue notice (`QT:36-76`)

`Surface` colour **#282828**, content white, corner **5 pt**, 4 pt shadow, 16 pt side inset, 8 pt above the bar,
text `bodyLarge` with 20/16 padding; enters fading + sliding half its height.

---

## 8. Colour + type tokens

### 8.1 Colours (hex, alpha) — `TH:26-48`

| Token | Dark (default) | Light |
|---|---|---|
| background | `#000000` | `#FFFFFF` |
| onBackground | `#FFFFFF` | `#000000` |
| surface | `#0D0D0F` | `#F7F7F9` |
| surfaceVariant | `#1C1C1E` | `#F2F2F7` |
| onSurfaceVariant | `#8E8E93` | `#6E6E73` |
| outline | `#2C2C2E` | `#E5E5EA` |
| primary / onPrimary | `#FFFFFF` / `#000000` | `#000000` / `#FFFFFF` |
| AccentRed (unused in shell) | `#FA2D48` | — |

Derived: selection pill `primary @ 14 %`; glass edge `#FFFFFF @ 10 %` (`LG:89`); glass content = pure white or
black by surface luminance (`LG:103-104`); glass indicator = `white @ 14 %` dark / `white @ 50 %` light
(`LG:115-121`); thumbnail ring 1 pt `white @ 15 %` dark / `black @ 15 %` light (`ST:41-47`); segmented track
`#767680 @ 24 %` dark / `@ 12 %` light, selected `#636366` dark / white light (`PS:199-205`); playing-bars
plate `black @ 52 %` (`CM:784`); queue notice `#282828`.

### 8.2 Type (`TH:84-94`, family `TH:67-73`)

| Style | Size | Weight | Tracking | Draws cut |
|---|---|---|---|---|
| displayLarge | 34 | W800 | −0.5 | Bold |
| headlineLarge | 30 | W800 | −0.4 | Bold |
| headlineMedium | 22 | W700 | −0.25 | Semibold |
| titleLarge | 20 | W700 | −0.2 | Semibold |
| titleMedium | 16 | W600 | +0.05 | Medium |
| bodyLarge | 16 | W400 | +0.2 | Regular |
| bodyMedium | 14 | W400 | +0.3 | Regular |
| labelMedium | 12 | W600 | +0.25 | Medium |
| labelSmall | 11 | W600 | +0.3 | Medium |
| titleSmall `[M3 default]` | 14 | W500 | +0.1 | Regular |
| labelLarge `[M3 default]` | 14 | W500 | +0.1 | Regular |

**Critical:** the font family maps every weight **one cut lighter** than asked — W800→Bold, W700→Semibold,
W600→Medium, W500/W400→Regular (`TH:50-73`). On macOS with SF Pro, ask for the *drawn* cut (e.g. a `titleMedium`
should be rendered in SF Pro **Medium**, not Semibold). `AppFont.LEGACY` restores the unshifted mapping with
tighter tracking (`TH:110-120`) — ignore unless reproducing that setting.

---

## 9. Motion inventory (duration / easing)

| Animation | Spec | Cite |
|---|---|---|
| Tab indicator + glyph pop | `spring(damping 0.72, stiffness 320)` | `FBB:147` |
| Tab tint | `tween(200)` | `FBB:386` |
| Glass pill travel / lift / material | springs 280-31.4 / 250-19-22.1 / 1000-63.3; hand-off τ 0.09 s, glass return τ 0.05 s | `GSP:336-362` |
| Tab icons enter/exit (glass) | 150 ms keyframes; alpha 0→1 between 50 %-80 %; blur 12 pt→0 | `FTB:1088-1150` |
| Bar fold (inline ↔ expanded) | default fade in/out | `FTB:224` |
| Page push | fade 180 ms | `MA:2844` |
| Tab swap | none | `MA:2842` |
| Bottom scrim height | `tween(220)` | `BFS:85` |
| Top bar title alpha / divider | `tween(220)` | `TBR:189,201` |
| Actions pill growth | `spring(NoBouncy, StiffnessMediumLow)` | `TBR:396-401` |
| Glass press scale (accessory) | `spring(StiffnessMediumLow)`, → 1.04 | `GNB:314-318` |
| Mini-player pull settle | `spring(0.65, StiffnessMediumLow)` | `MP:306-310` |
| Sign-in card press | `spring(900)`, → 0.98 | `CM:884` |
| Skeleton shimmer | 1400 ms linear, infinite | `SK:44,69` |
| Playing bars | frame gap 25 ms; per-bar period 520/650/780 ms, peak at 260/310/360 ms | `CM:730,749-759` |
| Queue notice | fade + slide half height | `QT:44-51` |

---

## 10. macOS adaptation notes

Keep the phone metric; change only the input model and the width budget.

1. **Window sizing.** Everything above assumes a ~390-448 pt wide column. Soft minimum window width **720 pt**
   (search field + account actions need it), default **1000 × 760 pt**. The floating bars stop growing at
   **440 pt** and centre themselves (`CM:154`) — keep them pinned to the *content* column, not the window, if
   you add a sidebar.
2. **Width breakpoints already in the source.** Hero cards cap at **320 pt** and the desktop passes
   `leadHero = false` so *every* shelf is an ordinary row (`HS:140-145`, `CM:188`); track columns cap at
   **400 pt** (`CM:222`); Top Picks cap at **280 pt** (`TPS:140`); Library grids compute 2-5 columns from a
   **140 pt** minimum (`CM:232-278`); pages drop their big heading on desktop (`HS:125`, `LS:117`).
3. **Sideways shelves need chrome.** A mouse cannot swipe a `LazyRow`; the source anticipates this with
   `ShelfRowChrome` / `LocalShelfRowChrome` (`SR:15-32`). Implement: hover arrows (28 pt circular, `surface`
   fill at 80 %, 0.5 pt white@10 % edge, fades to 0 at the row ends), horizontal wheel / trackpad scroll,
   and optionally drag-to-page. Keep **snap-to-cell** behaviour (`SR:54`).
4. **Pointer affordances to add (Android has none):**
   - Hover on cards/rows/tabs: `white @ 4 %` overlay in dark, `black @ 4 %` in light, 120 ms; cursor →
     pointing hand.
   - Row hover reveals the ⋮ at full opacity (it is otherwise always visible, `CM:666-668`).
   - Tab hover: glyph at 100 % (unselected is 65 % on glass, `GNB:118`) — no scale, scale is reserved for
     selection.
   - Keep hit targets ≥ **36 pt** (⋮ boxes are 36 pt, `CM:689`); do not shrink them for the desktop.
5. **Long press becomes right-click.** `contextClick()` is an `expect fun` that is a no-op on the phone
   (`CM`/`ContextClick.kt:5-12`). Every row and card also accepts right-click for the same menu. Keep the
   press-and-hold path too — trackpads still have it.
6. **Haptics.** All `Haptic.Select/Tick/Skip*` calls map to `NSHapticFeedbackManager` (or the trackpad's
   `.alignment`/`.levelChange`) and are best-effort; nothing visual depends on them.
7. **Glass.** `Material`/`Haze` → SwiftUI `.ultraThinMaterial` for the default bar and mini player, plus a
   `white.opacity(0.10)` 0.5 pt stroke. For the liquid-glass variant, `.glassEffect()` on macOS 26+ with the
   same numbers: 8 pt blur radius surface, 0.40 surface tint, 12/14 pt lens, 12 pt radius / 2 pt y contact
   shadow at 30 % (`LG:60-70`, `GSP:561-575`). If glass is unavailable, fall back to the flat `surface` fill
   at 4 pt padding — the geometry must not change.
8. **Status bar inset → 0.** Replace `stableStatusBarInsets()` with 0 (or the window titlebar height if you
   use a transparent titlebar); the top bar then becomes a plain 52 pt row with 12 pt of clearance under it.
   The bottom gesture floor (15 pt) becomes **0**; keep the 6 pt lift and the 180/254 pt scrim.
9. **Scrolling.** Map Compose's nested-scroll fold to `NSScrollView`/`ScrollView` offset deltas: collapse the
   glass bar after **50 pt** of net downward scroll, expand after 50 pt up, reset the accumulator on direction
   change (`FTB:286-336`).
10. **Keyboard.** ⌘F focuses the search field (mirrors the Search-tab tap that requests focus, `MA:4113-4118`);
    Return submits; Esc clears then closes. Arrow keys move row selection only if you add it — the Android
    build has no focus model to copy.
11. **Do not** add: a progress bar to the mini player (there is none), a centered top-bar title (it is
    commented out), a Settings tab (it is a pushed route), or an ellipsis-style truncation in the mini
    player's title/artist (they fade over 36 pt, `ST:143`).

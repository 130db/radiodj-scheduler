# RadioDJ Scheduler - Install Guide

Work through this from top to bottom. Each step tells you what to run, what the
answer should look like, and what to do if it isn't.

**You do not need to understand SQL.** You need to be able to open HeidiSQL, pick
your station's database, paste a block, and press the blue play button.
Everything else is explained as you go.

---

## Read this first

> **THIS SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.**
> See [LICENSE](LICENSE). Nobody is on call for your transmitter.

It runs four radio stations today. It has still never seen *your* station, *your*
rotations or *your* library.

### Test it somewhere that is not on air first

The safe way, and it costs about an hour:

1. Take a full backup of your RadioDJ database - [Step 0](#step-0---back-up).
2. Restore that backup into a **second, empty** database - the commands are in
   [Step 0](#restore-it-into-a-test-database-first). Call it something like
   `mystation_test`.
3. Do this whole install against `mystation_test`.
4. Build a day, look at it, decide whether you like what it did.
5. Only then repeat on the real one.
6. **Delete the test database afterwards** - also in
   [Step 0](#restore-it-into-a-test-database-first), and it matters more than it
   sounds.

If you skip that, you are testing in production, and the first thing you will
learn is what your station sounds like at 3am with an empty playlist.

---

## What this is

RadioDJ can rotate categories. It cannot express *"this hour, on this weekday,
has this shape"*, and it cannot build tomorrow's log in advance so you can look
at it before it airs.

This adds both: a weekly clock grid, and a materialised schedule built a day
ahead.

**What it does not do.** It does not replace RadioDJ's own rotations - it *uses*
them. You still design the shape of an hour in RadioDJ's rotation editor; this
scheduler decides which hour gets which shape, and picks the actual tracks a
day in advance. It does not touch your audio files and it does not delete tracks.

---

## Before you start

| | |
|---|---|
| ☐ | RadioDJ **3.0.0.2** |
| ☐ | **MySQL 8.0.x. Not MariaDB.** The official RadioDJ docs suggest MariaDB; this is developed and tested on MySQL and uses MySQL 8 features (window functions, `CHECK` constraints) |
| ☐ | HeidiSQL, connected to your RadioDJ database |
| ☐ | At least one rotation already built in RadioDJ, with real audio in the categories it references |
| ☐ | A backup - [Step 0](#step-0---back-up), do not skip it |
| ☐ | 30-60 minutes. Do not start this an hour before a live show |

**Select your database before you run anything.** Click your station's database
in HeidiSQL's left-hand tree. There is no `USE` statement anywhere in these
files, on purpose - that is what lets the same file work on any station. It also
means an unselected database installs nothing, or installs into the wrong place.

### Contents

- [Step 0 - Back up](#step-0---back-up)
- [Step 1 - Where am I?](#step-1---where-am-i)
- [Step 2 - Fix RadioDJ's own schema](#step-2---fix-radiodjs-own-schema)
- [Step 3 - Install the scheduler](#step-3---install-the-scheduler)
- [Step 4 - Tell it about your station](#step-4---tell-it-about-your-station)
- [Step 5 - Create clocks](#step-5---create-clocks)
- [Step 6 - Paint the weekly grid](#step-6---paint-the-weekly-grid)
- [Step 7 - Fill order](#step-7---fill-order)
- [Step 8 - Build a day and look at it](#step-8---build-a-day-and-look-at-it)
- [Step 9 - Create the event in RadioDJ](#step-9---create-the-event-in-radiodj)
- [Step 10 - Turn on the nightly build](#step-10---turn-on-the-nightly-build)
- [Step 11 - Tomorrow morning](#step-11---tomorrow-morning)
- [Day-to-day use](#day-to-day-use)
- [Optional extras](#optional-extras)
- [Technical notes](#technical-notes)
- [If something goes wrong](#if-something-goes-wrong)

---

## Step 0 - Back up

Not in SQL, because a backup taken from inside the thing you are about to change
is not a backup. In a terminal or Command Prompt:

```bash
mysqldump -u root -p --single-transaction --routines --events \
  YOUR_DATABASE > YOUR_DATABASE-before-scheduler.sql
```

On Windows use `^` to continue the line instead of `\`.

**`--routines --events` matter.** Without them you back up your tracks and lose
every stored procedure, which is most of what RadioDJ's own maintenance is made
of.

Check the file is not empty and is a few megabytes at least. A 0-byte backup file
is the classic way to discover the password was wrong.

### Restore it into a test database first

`mysqldump` writes no `CREATE DATABASE`, so make the empty one yourself, then
load the backup into it. Two commands:

```bash
mysql -u root -p -e "CREATE DATABASE mystation_test CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql -u root -p mystation_test < YOUR_DATABASE-before-scheduler.sql
```

Select `mystation_test` in HeidiSQL and do the rest of this guide against it.
Nothing here writes outside the database you have selected, so a mistake costs
you a `DROP DATABASE` and nothing else.

**Then delete it when you are done.**

```sql
DROP DATABASE mystation_test;
```

This is not tidiness. The scheduler's three events live *in* the database, and
your backup carries a copy of RadioDJ's tables with it. Once
[Step 10](#step-10---turn-on-the-nightly-build) turns the event scheduler on
permanently, the events in `mystation_test` keep firing too - building a day
every night and pushing a playlist every hour, forever, into a database nobody
is looking at. They are scoped to their own database so they cannot reach your
real station, but they are a background job you will never think about again,
and `schedule_log` in there grows without limit.

If you would rather keep the test database around for a while, disable its
events instead of dropping it - select it in HeidiSQL and run:

```sql
ALTER EVENT `ScheduleNextDay` DISABLE;
ALTER EVENT `SchedulePushPlaylist` DISABLE;
ALTER EVENT `SubcategoryRecalculateRuntimes` DISABLE;
```

---

## Step 1 - Where am I?

Confirms you are pointed at the right database and that it really is RadioDJ.
Everything after this assumes both.

```sql
SELECT
    DATABASE()                                              AS you_are_installing_into,
    (SELECT COUNT(*) FROM information_schema.TABLES
      WHERE TABLE_SCHEMA = DATABASE())                      AS tables_here,
    (SELECT COUNT(*) FROM information_schema.TABLES
      WHERE TABLE_SCHEMA = DATABASE()
        AND TABLE_NAME IN ('songs','category','subcategory',
                           'rotations','rotations_list','events'))
                                                            AS radiodj_tables_found,
    (SELECT COUNT(*) FROM songs)                            AS tracks_in_library,
    (SELECT COUNT(*) FROM rotations)                        AS rotations_defined,
    VERSION()                                               AS mysql_version;
```

| Column | Must be |
|---|---|
| `you_are_installing_into` | **Your station.** `NULL` means you have not selected a database |
| `radiodj_tables_found` | **6.** Fewer means this is not a RadioDJ database |
| `rotations_defined` | **At least 1.** If it is 0, stop and build a rotation in RadioDJ first - this scheduler has nothing to schedule without one |
| `mysql_version` | Starts with **8.0** |

---

## Step 2 - Fix RadioDJ's own schema

> **Run [`radiodj-schema-fixes.sql`](radiodj-schema-fixes.sql) now, then come back.**

Five things RadioDJ itself gets wrong. They are not caused by this scheduler and
they bite whether you install it or not:

1. The database's default collation does not match its tables.
2. `history` truncates artist and title at 200 characters while `songs` allows
   250, so long titles are silently cut.
3. **`rotations_list` stores three columns as `UNSIGNED` that RadioDJ writes
   *negative* values into.** On such a station RadioDJ **cannot save** a rotation
   rule that contains an SQL query, a manual event or a listener request. It
   fails, and you may never have worked out why.
4. **The same defect in `playlists_list.sID`.** A playlist can hold a manual
   event as well as songs, marked the same way - a negative sentinel in a
   column RadioDJ declared `UNSIGNED`. A playlist containing one cannot be
   saved until this fix runs.
5. `songs.lang` defaults to the wrong sentinel.

**Fixes 3 and 4 are the ones to care about, and this scheduler depends on
them** - without them, special rotation entries and manual events in
playlists can never be saved.

**If you already run this station, you may be looking at the result right
now.** Both defects fail silently - RadioDJ shows no error, the entry is
simply never written. If you have ever added an SQL-query or listener-request
rotation rule, a manual event inside a rotation, or a manual event inside a
playlist, and it didn't stick, this is why. There is nothing to migrate: a
write that failed left no row behind to recover. Run this fix, then check
your rotations and playlists against what you remember building, and re-add
whatever is missing by hand.

The file is safe to re-run and prints `OK` or `FAILED` for each fix. **Re-run it
after every RadioDJ upgrade** - a RadioDJ update can quietly put any of the five
back.

Confirm you actually ran it. All five must read `OK`:

```sql
SELECT 'db collation' AS fix, IF((SELECT DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA
      WHERE SCHEMA_NAME = DATABASE()) = 'utf8mb4_unicode_ci','OK','NOT DONE') AS status
UNION ALL SELECT 'history widths', IF((SELECT COUNT(*) FROM information_schema.COLUMNS
      WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME='history'
        AND COLUMN_NAME IN ('artist','original_artist','title','album','composer','publisher','copyright','isrc')
        AND CHARACTER_MAXIMUM_LENGTH = 250) = 8,'OK','NOT DONE')
UNION ALL SELECT 'rotation sentinels', IF((SELECT COUNT(*) FROM information_schema.COLUMNS
      WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME='rotations_list'
        AND COLUMN_NAME IN ('catID','subID','genID') AND COLUMN_TYPE LIKE '%unsigned%') = 0,'OK','NOT DONE')
UNION ALL SELECT 'playlists_list.sID', IF((SELECT COLUMN_TYPE FROM information_schema.COLUMNS
      WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME='playlists_list'
        AND COLUMN_NAME='sID') NOT LIKE '%unsigned%','OK','NOT DONE')
UNION ALL SELECT 'songs.lang default', IF((SELECT COLUMN_DEFAULT FROM information_schema.COLUMNS
      WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME='songs' AND COLUMN_NAME='lang') = 'und','OK','NOT DONE');
```

---

## Step 3 - Install the scheduler

> **Run [`scheduler-create.sql`](scheduler-create.sql) now, then come back.**

It adds 11 tables, 14 procedures and functions, 3 events, and 3 columns to
RadioDJ's `subcategory` table. It does **not** touch your audio files and it
deletes nothing.

It also adds **one trigger to RadioDJ's own `songs` table**, `SongsInsert`. It
is the only thing here that writes to a RadioDJ table, it only fires on
`INSERT`, and it exists so that a library import does not put every new track on
the air at once - [The `songs` trigger](#the-songs-trigger) in Technical notes
explains it in full. Read that before your next bulk import.

**It must be run from HeidiSQL**, not from a script or a programming language. It
contains `DELIMITER` lines, which are an instruction to the *client*, not to
MySQL - a driver sends them to the server, which has never heard of `DELIMITER`,
and the whole thing fails on the first line.

**It is not re-runnable.** It is a fresh install. If it fails halfway, run
[`scheduler-remove.sql`](scheduler-remove.sql) and start again rather than
running it twice.

```sql
SELECT
    (SELECT COUNT(*) FROM information_schema.TABLES
      WHERE TABLE_SCHEMA = DATABASE()
        AND TABLE_NAME IN ('clocks','schedule','schedule_log','scheduler_config',
                           'clock_grids','clock_grid_hours','clock_grid_schedule',
                           'clock_grid_rotations','clock_grid_rotation_entries',
                           'clock_grid_monthly_rules','clock_overrides'))  AS tables_want_11,
    (SELECT COUNT(*) FROM information_schema.ROUTINES
      WHERE ROUTINE_SCHEMA = DATABASE()
        AND ROUTINE_NAME LIKE 'Schedule%')                                AS schedule_routines_want_6,
    (SELECT COUNT(*) FROM information_schema.ROUTINES
      WHERE ROUTINE_SCHEMA = DATABASE()
        AND ROUTINE_NAME LIKE 'ClockGrid%')                               AS grid_routines_want_6;
```

### Check the column defaults specifically

`average_runtime` and `fill_priority` are columns this scheduler adds to
RadioDJ's `subcategory` table. **They must carry defaults.** RadioDJ does not
know the columns exist, so it does not supply values when you add a subcategory
in its UI - and if MySQL rejects that insert, **RadioDJ shows no error.** You
click "add subcategory", nothing happens, and nothing explains why.

```sql
SELECT COLUMN_NAME, COLUMN_TYPE,
       IFNULL(COLUMN_DEFAULT, '*** NO DEFAULT ***') AS default_value,
       IF(COLUMN_DEFAULT IS NOT NULL, 'OK',
          '*** FIX BELOW - you cannot add subcategories in RadioDJ ***') AS verdict
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'subcategory'
  AND COLUMN_NAME IN ('average_runtime', 'fill_priority')
ORDER BY COLUMN_NAME;
```

If either says `NO DEFAULT`, run the matching line:

```sql
ALTER TABLE `subcategory` MODIFY `average_runtime` decimal(11,5) unsigned NOT NULL DEFAULT 0.00000;
ALTER TABLE `subcategory` MODIFY `fill_priority`   int unsigned NOT NULL DEFAULT 100;
```

---

## Step 4 - Tell it about your station

Four numbers. This is the only place your station's own IDs live, and getting
`playlist_id` wrong is the single most common way to end up with a scheduler that
reports perfect health and changes nothing on air.

**Do not copy these numbers from someone else's station, or from an old backup.**
Read them from *this* database, now.

### 4a - Your categories

You want the ID of your **music** category and the ID of your **jingles**
category (sweepers, links, station IDs - whatever you call the short things
between songs).

```sql
SELECT ID, name FROM category ORDER BY ID;
```

### 4b - Your playlists

The scheduler writes the next hour into **one** playlist, and RadioDJ loads that
playlist on the hour.

```sql
SELECT ID, name FROM playlists ORDER BY ID;
```

### 4c - This is the important one

RadioDJ has its own hourly event that loads a playlist. Its `data` looks like:

```
Load Playlist|<position>|<PLAYLIST ID>|<name>|Top
```

The number in the third position is the playlist RadioDJ will **actually** load.
`playlist_id` below must be that number.

```sql
SELECT ID, name, type, data FROM events WHERE data LIKE '%Load Playlist|%';
```

> **If the two disagree, the scheduler fills playlist A, RadioDJ loads playlist
> B, and both sides report success.** Nothing errors. You just hear the wrong
> thing, or silence.

If this returns **no rows**, you have not built RadioDJ's hourly loader yet.
That is [Step 9](#step-9---create-the-event-in-radiodj), and it is mandatory -
without it nothing you schedule ever reaches the air. You can carry on to 4d for
now and come back: 4c only needs the playlist ID from 4b, which you already
have.

### 4d - Which category marks a jingle

Usually the same number as your jingles category from 4a.

```sql
SELECT catID, COUNT(*) AS entries_using_it
FROM rotations_list WHERE catID > 0 GROUP BY catID ORDER BY catID;
```

### 4e - Now write it

Replace the four placeholders with the numbers you just read.

```sql
INSERT INTO `scheduler_config`
    (`ID`, `playlist_id`, `music_parentid`, `jingle_parentid`, `jingle_catid`)
VALUES (1, <playlist_id from 4c>, <music category from 4a>,
           <jingles category from 4a>, <jingle catID from 4d>)
ON DUPLICATE KEY UPDATE
    `playlist_id`     = VALUES(`playlist_id`),
    `music_parentid`  = VALUES(`music_parentid`),
    `jingle_parentid` = VALUES(`jingle_parentid`),
    `jingle_catid`    = VALUES(`jingle_catid`);
```

Then check it agrees with RadioDJ. `verdict` must say `AGREES`:

```sql
SELECT cfg.*,
       CAST(SUBSTRING_INDEX(SUBSTRING_INDEX(
           SUBSTRING_INDEX(e.data, 'Load Playlist|', -1), '|', 2), '|', -1)
           AS UNSIGNED)                     AS radiodj_will_load,
       IF(cfg.playlist_id = CAST(SUBSTRING_INDEX(SUBSTRING_INDEX(
           SUBSTRING_INDEX(e.data, 'Load Playlist|', -1), '|', 2), '|', -1)
           AS UNSIGNED), 'AGREES', '*** MISMATCH - FIX THIS ***') AS verdict
FROM scheduler_config cfg
LEFT JOIN events e ON e.data LIKE '%Load Playlist|%'
WHERE cfg.ID = 1;
```

---

## Step 5 - Create clocks

A "clock" here is just a **name pointing at one of your RadioDJ rotations**. It
is how the grid in Step 6 refers to *"this hour looks like that"*.

**You do not need 24 of them.** You need one per distinct *shape* of hour. Many
stations need two or three. One is perfectly valid. The order you create them in
does not matter at all.

```sql
SELECT r.ID, r.name, COUNT(rl.ID) AS entries_in_it
FROM rotations r LEFT JOIN rotations_list rl ON rl.pID = r.ID
GROUP BY r.ID, r.name ORDER BY r.ID;
```

Create one clock per rotation you want to schedule. `name` is for you; it does
not have to match anything.

```sql
INSERT INTO `clocks` (`name`, `rotation_id`) VALUES
    ('Daytime', <a rotation ID from above>),
    ('Nights',  <another rotation ID>);
```

Check them. **A clock with `rotation_id` NULL can never fill anything**, and the
scheduler refuses to build a day that uses one:

```sql
SELECT c.ID, c.name, c.rotation_id, r.name AS rotation
FROM clocks c LEFT JOIN rotations r ON r.ID = c.rotation_id ORDER BY c.ID;
```

---

## Step 6 - Paint the weekly grid

The grid is 7 days × 24 hours = **168 cells**, and each cell says which clock
owns that hour of that weekday.

> **If you want one layout for the whole week, this step is two lines.** Do 6a
> and skip 6b. That is a complete, working setup.

Day numbers are **1 = Monday** through **7 = Sunday**.

### 6a - Create the grid and fill all 168 cells

```sql
INSERT INTO `clock_grids` (`name`, `is_default`) VALUES ('Regular', 1);
CALL ClockGridFill(LAST_INSERT_ID(), <your main clock ID>, @cells);
```

### 6b - Optional: change the hours that differ

Nights, every day, 00:00-05:59:

```sql
UPDATE clock_grid_hours SET clock_id = <night clock>
WHERE grid_id = (SELECT ID FROM clock_grids WHERE is_default = 1)
  AND `hour` BETWEEN 0 AND 5;
```

Weekend daytime only - Saturday and Sunday, 08:00-17:59:

```sql
UPDATE clock_grid_hours SET clock_id = <weekend clock>
WHERE grid_id = (SELECT ID FROM clock_grids WHERE is_default = 1)
  AND dow IN (6, 7) AND `hour` BETWEEN 8 AND 17;
```

### 6c - Check the grid is complete

`cells` must be **168**:

```sql
SELECT g.ID, g.name, g.is_default,
       (SELECT COUNT(*) FROM clock_grid_hours WHERE grid_id = g.ID) AS cells,
       IF((SELECT COUNT(*) FROM clock_grid_hours WHERE grid_id = g.ID) = 168,
          'OK', '*** INCOMPLETE - the day build will fail ***') AS verdict
FROM clock_grids g ORDER BY g.ID;
```

### 6d - Read the grid back

24 rows for one date, naming which clock owns each hour and why. **Do this after
every change you make.**

```sql
CALL ClockGridExplain(CURDATE() + INTERVAL 3 DAY);
```

---

## Step 7 - Fill order

**Do not skip this if any subcategory is small.**

`subcategory.fill_priority` decides **which slots get first pick of the
library**. The fill walks slots in `fill_priority ASC` order - *lower number is
filled first* - and every track it takes is then unavailable to later slots for
the length of the separation window.

Default is 100 for everything, which means "no preference".

### Why it matters, and why small subcategories especially

A subcategory with 400 tracks can afford to pick late. Whatever is left over will
still contain something eligible.

A subcategory with 12 tracks cannot. If it is filled last, the few tracks it is
allowed to use may already have been placed elsewhere in the day, and separation
then rules out every remaining candidate. **The slot comes out empty - not
because the subcategory is empty, but because it queued behind everyone else.**

Give it a lower number and it chooses first, while its whole pool is still
available. The big pools absorb the constraint instead, because they can.

> **Rule of thumb: order by scarcity, not by importance.** The scarcest pool goes
> first.

### 7a - How much audio each subcategory really has

Worst first. This is the list to set priorities from.

```sql
SELECT sc.ID, sc.name, c.name AS category,
       COUNT(s.ID)                              AS tracks,
       COUNT(DISTINCT s.artist)                 AS distinct_artists,
       ROUND(SUM(s.duration) / 3600, 2)         AS hours_of_audio,
       sc.fill_priority
FROM subcategory sc
LEFT JOIN category c ON c.ID = sc.parentid
LEFT JOIN songs s    ON s.id_subcat = sc.ID AND s.enabled = 1
GROUP BY sc.ID, sc.name, c.name, sc.fill_priority
ORDER BY hours_of_audio ASC;
```

### 7b - Set them

Lower goes first. Leave everything else at 100.

```sql
UPDATE subcategory SET fill_priority = 10 WHERE ID = <your scarcest subcategory>;
UPDATE subcategory SET fill_priority = 20 WHERE ID = <the next scarcest>;
```

Any positive numbers work; only their relative order matters. 10 / 20 / 30 leaves
room to insert something between later without renumbering everything.

```sql
SELECT fill_priority, COUNT(*) AS subcategories,
       GROUP_CONCAT(name ORDER BY name SEPARATOR ', ') AS which
FROM subcategory GROUP BY fill_priority ORDER BY fill_priority;
```

A subcategory needs **more audio than its separation window is long**, whatever
its priority. A rule that must not repeat a track within 7 hours needs more than
7 hours of eligible audio. `fill_priority` decides who gets first pick of what
exists; it cannot create tracks.

---

## Step 8 - Build a day and look at it

Three days from now, so it cannot collide with anything RadioDJ is about to play,
and so the automatic nightly build does not overwrite it while you are looking.

> **Never build a date in the past.** The track picker needs *"this track was
> last played more than N hours before this slot"* to be true, and for a past
> date that is never true. It completes without error and fills nothing.

```sql
SET @d := CURDATE() + INTERVAL 3 DAY;

CALL SubcategoryRecalculateRuntimes();
CALL ScheduleBuildSkeleton(@d, 0, @slots);
CALL ScheduleResolveSql(@d, 0, @sql_ok, @sql_bad);
CALL ScheduleFill(@d, @filled, @unfilled);
CALL ScheduleFillFallback(@d, @fb_filled, @fb_unfilled);
CALL ScheduleRecalculateAirtime(@d, 0, @air);

SELECT @slots AS slots_built, @filled AS filled, @unfilled AS unfilled,
       @fb_filled AS filled_from_fallback, @fb_unfilled AS still_empty;
```

### The honest check

Trust this over the counters above.

```sql
SELECT COUNT(*) AS slots, SUM(song_id IS NULL) AS really_empty,
       IF(SUM(song_id IS NULL) = 0, 'FULL DAY',
          CONCAT('*** ', SUM(song_id IS NULL), ' EMPTY SLOTS ***')) AS verdict
FROM schedule WHERE schedule_date = CURDATE() + INTERVAL 3 DAY;
```

Look at what it actually chose. This is your log for that day:

```sql
SELECT `hour`, `order`, artist, title,
       SEC_TO_TIME(`hour` * 3600 + airtime) AS approx_on_air
FROM schedule WHERE schedule_date = CURDATE() + INTERVAL 3 DAY
ORDER BY `hour`, `order` LIMIT 60;
```

### If you have empty slots

Which subcategory ran dry:

```sql
SELECT sc.name AS subcategory, COUNT(*) AS empty_slots
FROM schedule s LEFT JOIN subcategory sc ON sc.ID = s.subcategory_id
WHERE s.schedule_date = CURDATE() + INTERVAL 3 DAY AND s.song_id IS NULL
GROUP BY sc.name ORDER BY empty_slots DESC;
```

The usual cause is a subcategory with less audio in it than its separation window
is long. Three remedies, in order of preference: add tracks; shorten that rule's
separation in RadioDJ's rotation editor; or give the subcategory a fallback.

```sql
UPDATE subcategory SET fallback_subcategory_id = <other subcategory ID>
WHERE ID = <the starved subcategory ID>;
```

Then re-run Step 8.

### Clean up the test day

So the nightly build is not confused by it:

```sql
DELETE FROM schedule WHERE schedule_date = CURDATE() + INTERVAL 3 DAY;
```

---

## Step 9 - Create the event in RadioDJ

Everything so far fills a playlist. Nothing yet tells RadioDJ to play it. This
step is the handoff, and without it the whole chain runs perfectly and is
inaudible.

> **Do this in RadioDJ's interface, never in SQL.** RadioDJ reads the `events`
> table into memory and only re-reads it when you open the Event Window. An
> event you `INSERT` yourself sits in the database looking correct and never
> fires - and anything of ours that reads the table sees it, so both sides
> report healthy. See
> [RadioDJ caches its events in memory](#radiodj-caches-its-events-in-memory).

In RadioDJ, open the events window and add a new event:

| Field | Value |
|---|---|
| Event Name | `Schedule` |
| Event Type | **Repeat by Day and Hour** |
| Event Category | `Schedule` |
| Enabled | ticked |
| Event Hour | leave it - the dialog says *Hour will be ignored!* |
| Smart Timing | unticked |
| Days | **all seven ticked** |
| Hours | **all 24 ticked** |

Then add five actions, **in this order**:

```
1  AutoDJ Disable!
2  Clear Playlist!
3  Load Playlist|0|<YOUR PLAYLIST ID>|<name>|Top
4  Load Rotation|<ROTATION ID>|<name>
5  AutoDJ Enable!
```

Actions 3 and 4 are the ones you configure. Action 3 is the playlist you chose
in [4b](#4b---your-playlists), inserted at `Top`. The other three are literal.

**Action 4 is your safety net, and it is worth having.** Loading a rotation
alongside the playlist means that if the playlist arrives empty for any reason -
a build that failed, the event scheduler switched off after a MySQL restart, a
starved subcategory leaving holes - AutoDJ has something to fall back on and the
station keeps talking. Without it, an empty playlist is silence. Point it at
whatever rotation you would want on air if you were not there.

If you want the fallback to match the hour rather than be one blanket rotation,
build it as separate per-hour events instead, each with its own
`Load Rotation` and its hours ticked accordingly. That is more events to
maintain, and one rotation covers most stations.

**The order is the point.** `Clear Playlist!` before the load is what stops the
playlist growing by an hour every hour. The `AutoDJ Disable!` / `AutoDJ Enable!`
pair around the whole group stops RadioDJ reaching for anything during the
moment the playlist is empty mid-swap.

Save the event. Now check that what RadioDJ stored agrees with what the
scheduler fills - `verdict` must say `AGREES`:

```sql
SELECT e.ID, e.name, e.type,
       CAST(SUBSTRING_INDEX(SUBSTRING_INDEX(
           SUBSTRING_INDEX(e.data, 'Load Playlist|', -1), '|', 2), '|', -1)
           AS UNSIGNED)                     AS radiodj_will_load,
       cfg.playlist_id                      AS scheduler_fills,
       IF(cfg.playlist_id = CAST(SUBSTRING_INDEX(SUBSTRING_INDEX(
           SUBSTRING_INDEX(e.data, 'Load Playlist|', -1), '|', 2), '|', -1)
           AS UNSIGNED), 'AGREES', '*** MISMATCH - FIX THIS ***') AS verdict
FROM events e
CROSS JOIN scheduler_config cfg
WHERE e.data LIKE '%Load Playlist|%' AND cfg.ID = 1;
```

**No rows** means RadioDJ did not save what you think it saved - reopen the
event and check action 3. A `MISMATCH` means the two numbers disagree, and that
is the failure where the scheduler fills playlist A, RadioDJ loads playlist B,
and neither reports a problem.

### Optional: a manual trigger for mid-hour reloads

The event above fires on the hour. Make a second one with the **same four
actions** and Event Type **Manual**, named something like `Schedule (M)`. Firing
it from the events window reloads the current hour immediately, which is what
you want after rebuilding part of today - see
[Rebuild part of today](#rebuild-part-of-today).

---

## Step 10 - Turn on the nightly build

Two events do the work from here, plus one that pushes each hour to air:

| When | What |
|---|---|
| `23:25` | Recalculate how long the average track in each subcategory is. The schedule uses it to predict when each slot airs |
| `23:30` | Build tomorrow |
| `hh:59` | Push the next hour into the playlist RadioDJ loads |

**None of them run unless MySQL's event scheduler is on, and it is off by default
after every MySQL restart, silently.**

**This is a server setting, not a per-database one.** If this MySQL instance
hosts more than one station, turning it on here activates every station's
scheduler events at once - including one that hasn't reached Step 4 yet,
which will just log `scheduler_config row 1 is missing` harmlessly until it
does.

```sql
SHOW VARIABLES LIKE 'event_scheduler';
```

If that says `OFF`:

```sql
SET GLOBAL event_scheduler = ON;
```

### Make it survive a reboot

Add this to MySQL's `my.ini` under `[mysqld]`, then restart the MySQL service.
On Windows that file is usually at
`C:\ProgramData\MySQL\MySQL Server 8.0\my.ini`.

```ini
event_scheduler=ON
```

Without it, the scheduler works until the next power cut and then quietly stops,
and nothing tells you.

```sql
SELECT EVENT_NAME, STATUS, INTERVAL_VALUE, INTERVAL_FIELD, STARTS
FROM information_schema.EVENTS WHERE EVENT_SCHEMA = DATABASE()
ORDER BY EVENT_NAME;
```

---

## Step 11 - Tomorrow morning

Check it built overnight. Run this the next day.

```sql
SELECT logged_at, event, schedule_date, slots, filled, unfilled,
       fb_filled, fb_unfilled, ok, message
FROM schedule_log ORDER BY logged_at DESC LIMIT 10;

SELECT schedule_date, COUNT(*) AS slots, SUM(song_id IS NULL) AS empty_slots
FROM schedule GROUP BY schedule_date ORDER BY schedule_date DESC LIMIT 7;
```

`ok = 0` means a build failed and `message` says why. **No rows at all** means
the event scheduler is off - back to [Step 10](#step-10---turn-on-the-nightly-build).

---

## Day-to-day use

### Rebuild a whole day

Three days out. Never a past date, and never tomorrow - tomorrow is overwritten
at 23:30.

```sql
SET @d := CURDATE() + INTERVAL 3 DAY;
CALL SubcategoryRecalculateRuntimes();
CALL ScheduleBuildSkeleton(@d, 0, @s);
CALL ScheduleResolveSql(@d, 0, @r, @rf);
CALL ScheduleFill(@d, @f, @u);
CALL ScheduleFillFallback(@d, @ff, @fu);
CALL ScheduleRecalculateAirtime(@d, 0, @a);
SELECT @s slots, @f filled, @u unfilled, @ff fb_filled, @fu fb_unfilled;
```

### Rebuild part of today

From a given hour onward, keeping what is already there.

> **Set `@h` to the *next* hour, never the hour that is on air.** Rebuilding the
> current hour re-picks tracks RadioDJ has already loaded, and the two then
> disagree silently.

```sql
SET @d := CURDATE();
SET @h := 14;
CALL ScheduleBuildSkeleton(@d, @h, @s);
CALL ScheduleResolveSql(@d, @h, @r, @rf);
CALL ScheduleFill(@d, @f, @u);
CALL ScheduleFillFallback(@d, @ff, @fu);
CALL ScheduleRecalculateAirtime(@d, @h, @a);
```

Hours below `@h` are untouched and act as fixed separation context - a track
sitting unplayed in an earlier hour still blocks candidates in the rebuilt hours.
That is the point of a partial rebuild.

Then push it to air: RadioDJ reloads the playlist on the hour, or you can fire
your "Load Playlist" event manually from RadioDJ's event window to make it
immediate.

### See why an hour has the clock it has

```sql
CALL ClockGridExplain('2026-12-24');
```

---

## Optional extras

Skip all of this if one weekly layout is enough.

### Which wins when several apply

Highest first:

| Priority | Source | Scope |
|---|---|---|
| 1 | `clock_overrides` | one hour |
| 2 | `clock_grid_schedule` | a pinned date |
| 3 | `clock_grid_monthly_rules` | a whole day |
| 4 | `clock_grid_rotations` | a whole week |
| 5 | `clock_grids.is_default` | always |

`ClockGridExplain` names which one decided each hour.

### A holiday

Make a second grid that inherits from your normal one and only changes the hours
that differ, then pin it to a date.

```sql
INSERT INTO `clock_grids` (`name`, `is_default`, `feeder_grid_id`)
VALUES ('Christmas', 0, (SELECT ID FROM clock_grids WHERE is_default = 1));

-- only the hours that differ; everything else is inherited
INSERT INTO `clock_grid_hours` (`grid_id`, `dow`, `hour`, `clock_id`)
VALUES ((SELECT ID FROM clock_grids WHERE name='Christmas'), 3, 18, <clock>);

INSERT INTO `clock_grid_schedule` (`on_date`, `grid_id`, `reason`)
VALUES ('2026-12-24', (SELECT ID FROM clock_grids WHERE name='Christmas'),
        'Christmas Eve');
```

### A show every other week

`anchor_date` is any date the show **does** air; `dow` is 1=Monday..7=Sunday;
`hour` is 0-23.

```sql
INSERT INTO `clock_overrides`
    (`name`, `clock_id`, `hour`, `recurrence`, `dow`, `every_n`, `anchor_date`)
VALUES ('Rock Hour', <clock>, 20, 'nweekly', 6, 2, '2026-09-05');
```

### A show once a month

`nth` is 1-5, or `-1` for "the last one".

```sql
INSERT INTO `clock_overrides`
    (`name`, `clock_id`, `hour`, `recurrence`, `dow`, `nth`)
VALUES ('Monthly Special', <clock>, 10, 'monthly_nth_dow', 6, 1);
```

### Alternating weeks, whole layout

Two grids, swapping every week.

> **Careful: the swap happens on the weekday of `start_date`.** A Tuesday
> `start_date` means grids change on Tuesdays, and the Monday before a swap still
> belongs to the *outgoing* grid.

```sql
INSERT INTO `clock_grid_rotations` (`name`, `start_date`) VALUES ('A/B', '2026-09-07');
INSERT INTO `clock_grid_rotation_entries` (`rotation_id`, `position`, `grid_id`)
VALUES ((SELECT ID FROM clock_grid_rotations WHERE name='A/B'), 0, <grid A>),
       ((SELECT ID FROM clock_grid_rotations WHERE name='A/B'), 1, <grid B>);
```

---

## Technical notes

### Architecture

Your rotations stay in RadioDJ and define the *shape* of an hour.
`clock_grid_hours` maps (weekday, hour) to a clock, and a clock names a rotation.
`ScheduleBuildSkeleton` resolves the grid for a date and expands the rotation
into one `schedule` row per slot. `ScheduleFill` then picks an actual track for
each slot, honouring separation. `SchedulePushPlaylist` copies the next hour into
the playlist RadioDJ loads. Nothing is cached in between - the day is built from
`rotations_list` every time.

### What lives where

Station-specific values: `scheduler_config`, row 1. Four numbers.

Separation and genre rules: **per rotation rule, in RadioDJ's own rotation
editor** - `repeatRule`, `track_separation`, `artist_separation`,
`title_separation`, `genID`. This scheduler reads the same columns RadioDJ does,
so one edit covers both.

`0` in a separation column means *"not set"* and inherits a default, **not
"off"**. `repeatRule = 0` is the actual off switch.

### Separation defaults

In seconds, applied where a rule leaves a dimension at 0:

| | track | artist | title |
|---|---|---|---|
| music | 25200 (7h) | 7200 (2h) | 4200 (70m) |
| other | 4200 (70m) | 1800 (30m) | 0 (off) |

They are constants inside **both** `ScheduleFill` and `ScheduleFillFallback`. If
you change them, change both.

### Which version is installed

`scheduler_config.version` records which release of `scheduler-create.sql` built
this install. Nothing reads it - it exists so the question has an answer.

```sql
SELECT version FROM scheduler_config WHERE ID = 1;
```

Quote it when you report a problem. The `DEFAULT` only stamps fresh installs, so
an upgrade has to `UPDATE` it; an install predating this column has no `version`
column at all, which is itself the answer.

### Sentinels, not NULL

RadioDJ stores "never happened" as a magic value, not NULL:
`date_played = '2002-01-01 00:00:01'`, `year = '1900'`, `'Not Set'`, `'und'`,
`-1`. **Never test these with `IS NULL`.**

### The `songs` trigger

`scheduler-create.sql` installs `SongsInsert`, a `BEFORE INSERT` trigger on
RadioDJ's `songs` table. It is the only object here that writes to a table
RadioDJ owns, so it is worth understanding rather than discovering.

**The problem it solves.** RadioDJ stamps every newly added track with
`date_played = '2002-01-01 00:00:01'` - the never-played sentinel from the
section above. Both RadioDJ's rotations and this scheduler choose the **least
recently played** eligible track, and 2002 is older than any real date in your
library. Every track you add is therefore, simultaneously, the most overdue
track you own.

Import 300 tracks in the evening and the next several hours are those 300 back
to back in import order, because each one out-ranks everything already in
rotation. The rest of the library goes quiet until the block drains. The same
happens on `title_played` and title separation.

**What it does.** On insert, and only when the value is exactly the sentinel, it
replaces it with a random moment inside the last 8 hours:

```sql
IF NEW.date_played = '2002-01-01 00:00:01' THEN
    SET NEW.date_played = DATE_SUB(NOW(), INTERVAL FLOOR(RAND() * 28800) SECOND);
END IF;
```

The same for `title_played`. New tracks land scattered through the pool instead
of stacked at the front of it, and they work into rotation over the following
days rather than all at once.

**What it does not do.** It does not fire on `UPDATE`, so it never rewrites the
play history of a track already in your library. A row that arrives carrying a
real date is left exactly as it is. Note the one edge this leaves: restoring a
database dump is a stream of `INSERT`s, so any track that was genuinely
never-played in that backup comes back with a fresh random date instead of the
sentinel. Drop the trigger before a restore if that matters to you.

**The trade-off.** After an import, nothing in your library reads as
never-played. `WHERE date_played = '2002-01-01 00:00:01'` returns nothing, and
"which tracks have never aired?" stops being a question the database can answer.
If you would rather keep the sentinel and handle the flood yourself - by staging
an import into a holding subcategory, say - drop it:

```sql
DROP TRIGGER IF EXISTS `SongsInsert`;
```

Nothing else in the scheduler depends on it, and
[`scheduler-remove.sql`](scheduler-remove.sql) drops it as part of a full
teardown.

### Negative IDs are meaningful

In `rotations_list`, `catID` of `-50` means "an SQL query" and `-100` "a
listener request" - both repeat the same value into `subID` and `genID`.
`-10` means "a manual event", but here `subID` and `genID` hold the
`events.ID` instead, not the sentinel. This is why fix 3 in
`radiodj-schema-fixes.sql` matters.

**`playlists_list` uses the same trick with a different number.** A manual
event inside a playlist is marked `sID = -100`, with the event's ID in
`swID` - and `-100` here means "manual event", not "listener request" the
way it does in `rotations_list`. Read the table you're looking at, not the
number alone. This is fix 4.

### The playlist ID is stored twice

Once in `scheduler_config.playlist_id`, once inside RadioDJ's own event `data`,
and nothing enforces agreement. When they diverge, both sides report healthy.
[Step 4](#step-4---tell-it-about-your-station) checks it; check it again after
editing events in RadioDJ.

### RadioDJ caches its events in memory

It only re-reads them when you open its Event Window. Editing the `events` table
with SQL changes nothing about what RadioDJ actually fires. **Author events in
RadioDJ.**

### No foreign keys in RadioDJ's own schema

Deletes never cascade and nothing stops an orphan. The tables this scheduler adds
*do* use foreign keys, which is why `scheduler-remove.sql` drops things in a
specific order.

### `history` self-prunes

RadioDJ's `DAYS_2_KEEP_HISTORY` setting means what it says, and **0 means "delete
everything", not "keep forever"**. Do not treat `history` as a permanent play
log. `schedule` is never pruned by this scheduler, so it is the durable record of
what was planned.

### Two RadioDJ install notes

**Never install RadioDJ under `C:\Program Files`** - Windows blocks it from
writing its own files. `C:\RDJ\<STATION>\` is a good convention.

**Keep `StoreSettingsToDatabase` set to False.** Settings belong in the XML
files; storing them in the database means a database problem takes your settings
with it.

---

## If something goes wrong

| Error or symptom | Cause |
|---|---|
| `no grid resolves for <date>` | No default grid, or it has fewer than 168 cells → [6c](#6c---check-the-grid-is-complete) |
| `no clock for <date> hour N` | That cell is empty → [6c](#6c---check-the-grid-is-complete) |
| `clock N owns … but has no rotation` | A clock with `rotation_id` NULL → [Step 5](#step-5---create-clocks) |
| `scheduler_config row 1 is missing` | [Step 4](#step-4---tell-it-about-your-station) was skipped |
| Empty slots | A subcategory holds less audio than its separation window is long → [Step 8](#step-8---build-a-day-and-look-at-it) groups them |
| Everything looks right in the database but nothing changes on air | No loader event in RadioDJ, or the playlist IDs disagree → [Step 9](#step-9---create-the-event-in-radiodj) |
| Adding a subcategory in RadioDJ silently does nothing | A column default is missing → [Step 3](#check-the-column-defaults-specifically) |
| It worked, then stopped after a reboot | MySQL's event scheduler is off → [Step 10](#step-10---turn-on-the-nightly-build) |
| You want it all gone | Run [`scheduler-remove.sql`](scheduler-remove.sql). It removes this scheduler and nothing of RadioDJ's - but it *does* delete your clocks, your grid and every built day |

---

When reporting a problem, include `SELECT version FROM scheduler_config WHERE
ID = 1;` and `SELECT VERSION();` - the first says which release you are running,
the second which MySQL.

If this saved you some work, there is a link at the bottom of
[README.md](README.md).

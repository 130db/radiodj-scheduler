# RadioDJ Scheduler

**A weekly clock grid and a day-ahead schedule builder for [RadioDJ](https://www.radiodj.ro/).**

RadioDJ can rotate categories. It cannot say *"this hour, on this weekday, has
this shape"*, and it cannot build tomorrow's log in advance so you can look at it
before it airs. This adds both, in SQL, inside your existing RadioDJ database.

It does not replace RadioDJ's rotations - it uses them. You still design the
shape of an hour in RadioDJ's rotation editor; this scheduler decides which
hour of which weekday gets which shape, picks the actual tracks a day ahead,
and hands each hour to RadioDJ through a playlist.

---

## Status

| | |
|---|---|
| **Version** | 1.0.0 - an installed database reports its own with `SELECT version FROM scheduler_config WHERE ID = 1;` |
| **RadioDJ** | 3.0.0.2 |
| **Database** | MySQL 8.0.x - tested on 8.0.45. **Not MariaDB** (see [Requirements](#requirements)) |
| **Licence** | [MIT](LICENSE) |
| **In production on** | Radio Nemiers · Nemiers Lite · Nemiers GFT · Radio Liepāja |

Four stations run this daily. It has still never seen *your* station.
**Test it off-air first** - [INSTALL.md](INSTALL.md) Step 0
explains how, and it costs about an hour.

---

## Start here

Read **[INSTALL.md](INSTALL.md)** and work through it from the top. It is a
guided install: numbered steps, plain-language explanations of every number it
asks you for, and a check after each one so you know it worked before moving on.

You do not need to know SQL. You need to be able to open HeidiSQL, select your
station's database, paste a block, and press play.

**The two-line version, if one layout for the whole week is all you need:**

```sql
INSERT INTO clock_grids (name, is_default) VALUES ('Regular', 1);
CALL ClockGridFill(LAST_INSERT_ID(), <your clock ID>, @cells);
```

That is a complete, working setup. Everything else in this repo is for stations
that need more than that.

---

## The files

| File | What it is |
|---|---|
| **[`INSTALL.md`](INSTALL.md)** | **The guided install.** Start here. Also the day-to-day reference, the technical notes and the troubleshooting table. |
| [`radiodj-schema-fixes.sql`](radiodj-schema-fixes.sql) | Five fixes to **RadioDJ's own schema**, not to anything here. Run it first, and again after every RadioDJ upgrade. |
| [`scheduler-create.sql`](scheduler-create.sql) | The scheduler itself: 11 tables, 14 routines, 3 events, 3 columns added to RadioDJ's `subcategory`, and one trigger on RadioDJ's `songs` - [see below](#new-tracks-and-the-songs-trigger). Fresh install, not re-runnable. |
| [`scheduler-remove.sql`](scheduler-remove.sql) | Complete removal. Takes your clocks, grid and built days with it - that is what removal means. |

All three SQL files contain no `USE` statement and no database name. Select your database in
HeidiSQL first; the same files then work on any station.

---

## Run `radiodj-schema-fixes.sql` even if you skip everything else

Five defects in the schema RadioDJ ships. They bite whether or not you install
this scheduler:

1. The database's default collation does not match its own tables, so any table
   added later throws *Illegal mix of collations* on its first text join.
2. `history` truncates artist and title at 200 characters while `songs` allows
   250 - long titles are silently cut on the way into your play history.
3. **`rotations_list` stores three columns as `UNSIGNED` that RadioDJ writes
   negative values into.** On such a station RadioDJ *cannot save* a rotation
   rule containing an SQL query, a manual event or a listener request. Under
   MySQL's default strict mode the write fails outright - you may have hit this
   and never worked out why.
4. A signedness mismatch in `playlists_list`.
5. `songs.lang` defaults to the wrong sentinel.

Number 3 is the one to care about, and this scheduler depends on it. The file is
idempotent and prints `OK` or `FAILED` for each fix.

**Re-run it after every RadioDJ upgrade.** A RadioDJ update can quietly put any
of the five back, and nothing tells you.

---

## How it decides what airs

### The pieces

```
rotations / rotations_list    RadioDJ's own. The SHAPE of an hour:
   (built in RadioDJ's UI)    subcategory, subcategory, jingle, ...

clocks                        A name pointing at one rotation.
   |
clock_grid_hours              (weekday, hour) -> clock.  168 cells.
   |
schedule                      The materialised day: one row per slot,
                              with the chosen track.
   |
playlists_list                The next hour, handed to RadioDJ.
   |
RadioDJ event "Schedule"      Clears and reloads that playlist, hourly.
   (built in RadioDJ's UI)     You create this one yourself - Step 9.
```

You need **one clock per distinct shape of hour**, not 24. Many stations need
two or three. One is fine.

### Which clock owns an hour

Five layers, **first match wins**. Most stations only ever use the last one.

| Priority | Source | Scope | For |
|---|---|---|---|
| 1 | `clock_overrides` | one hour | A single show - weekly, every *n*th week, *n*th weekday of the month, or a one-off date |
| 2 | `clock_grid_schedule` | whole day | A holiday, pinned to a date |
| 3 | `clock_grid_monthly_rules` | whole day | "First Saturday of the month" |
| 4 | `clock_grid_rotations` | whole week | Two or more layouts alternating week by week |
| 5 | `clock_grids.is_default` | always | **The normal week. This is all you need to start.** |

`CALL ClockGridExplain('2026-12-24')` returns 24 rows for one date naming which
layer decided each hour. Run it after every change - with five overlapping
layers, *"why is Tuesday showing that clock?"* is the question you will actually
have, and this answers it.

### Grid inheritance

A grid can name another as its `feeder_grid_id`. Any hour it does not define is
taken from the feeder. So a Christmas grid defines the six hours that differ and
inherits the other 162 - rather than being a 168-cell copy that drifts out of
sync with your normal week every time you change it.

### The nightly chain

| When | What |
|---|---|
| `23:25` | Recompute each subcategory's average track length. The schedule uses it to predict when each slot airs, and separation is measured against those offsets. |
| `23:30` | Build tomorrow. |
| `hh:59` | Push the next hour into the playlist RadioDJ loads. |

None of it runs unless MySQL's event scheduler is on, and **it is off by default
after every MySQL restart, silently.** [INSTALL.md](INSTALL.md) Step 10 covers
making that survive a reboot.

### The handoff to RadioDJ

The scheduler fills a playlist. It does not play it. **You have to create one
event inside RadioDJ** that clears the playlist, loads the one the scheduler
fills, and does it every hour of every day. Without it the whole chain above
runs correctly and nothing reaches the air.

That same event should also load a rotation as a fallback. If the playlist ever
arrives empty - a failed build, the event scheduler off after a MySQL restart -
AutoDJ then has something to reach for instead of putting out silence.

It has to be built in RadioDJ's own events window, not with SQL: RadioDJ reads
the `events` table into memory once and only re-reads it when you open that
window, so an event inserted with SQL sits there looking right and never fires.
[INSTALL.md](INSTALL.md) Step 9 is the field-by-field walkthrough, including the
action order, which matters more than it looks like it should.

### New tracks and the `songs` trigger

`scheduler-create.sql` installs one trigger, `SongsInsert`, on RadioDJ's own
`songs` table - the only thing here that writes to a RadioDJ table.

RadioDJ stamps every new track as never-played, which makes it the single
most overdue track in your library the moment it's imported. Import 300
tracks and the next few hours are those 300, back to back, while the rest of
the library falls silent. The trigger fixes this by scattering new tracks'
play timestamps across the last 8 hours instead, at insert time only.

Full explanation, the trade-off, and how to drop it if you'd rather not have
it: [INSTALL.md § The songs trigger](INSTALL.md#the-songs-trigger).

---

## Four things that will cost you an afternoon if nobody warns you

**Never remove the default from `subcategory.average_runtime`.** This scheduler
adds three columns to RadioDJ's `subcategory` table. RadioDJ does not know they
exist, so it does not supply values when you add a subcategory in its UI - and
if MySQL rejects that insert because a `NOT NULL` column has no default,
**RadioDJ shows no error at all.** You click "add subcategory", nothing happens,
and nothing anywhere tells you why. You would be hunting a bug in RadioDJ, over
a column RadioDJ has never heard of. `scheduler-create.sql` gets this right;
Step 3 of [INSTALL.md](INSTALL.md) verifies it, because an install from an
earlier release can be missing it.

**The playlist ID is stored twice and nothing enforces agreement.** Once in
`scheduler_config.playlist_id`, once inside RadioDJ's own hourly event `data`.
When they diverge, the scheduler fills playlist A, RadioDJ loads playlist B, and
**both sides report success.** Nothing errors. Step 4 of [INSTALL.md](INSTALL.md) checks it;
check it again any time you edit events in RadioDJ.

**Set `fill_priority` if any subcategory is small.** The fill walks slots in
`subcategory.fill_priority ASC` order - lower number gets first pick of the
library - and every track it takes becomes unavailable to later slots for the
length of the separation window. A subcategory with 400 tracks can afford to
pick last. One with 12 cannot: by the time its turn comes, separation may rule
out every track it is allowed to use, and the slot comes out **empty even though
the subcategory is not**. Order by scarcity, not importance. Step 7 of [INSTALL.md](INSTALL.md) lists your
subcategories by hours of audio, worst first.

**A rotation needs more audio than its separation window is long.** A rule that
must not repeat a track within 7 hours needs more than 7 hours of eligible audio
to choose from. Less than that and slots come out empty. Either add tracks,
shorten that rule's separation in RadioDJ's rotation editor, or give the
subcategory a fallback:

```sql
UPDATE subcategory SET fallback_subcategory_id = <other subcategory ID>
WHERE ID = <the starved one>;
```

---

## Requirements

- **RadioDJ 3.0.0.2**, .NET Framework 4.8, Windows 10 or 11
- **MySQL 8.0.x.** The official RadioDJ documentation suggests MariaDB; this is
  developed and tested on MySQL and uses MySQL 8 features (window functions,
  `CHECK` constraints, recursive resolution). It is pinned to 8.0 rather than
  8.4 because 8.0 is what these stations run.
- **HeidiSQL**, or any client that understands the `DELIMITER` directive.
  `scheduler-create.sql` defines stored routines, and `DELIMITER` is a
  *client-side* instruction - send it to MySQL from a driver or a script and it
  fails on the first line. Run these files from HeidiSQL.
- At least one rotation already built in RadioDJ, with real audio behind it.

---

## Disclaimer

THIS SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED. See [LICENSE](LICENSE) for the full text.

In plainer terms:

- **Back up before you start.** `mysqldump --routines --events`. Without those
  two flags you back up your tracks and lose every stored procedure.
- **Test on a copy of your database first**, not on the one that is on air.
- This writes to your RadioDJ database, including `playlists_list`, which is
  what RadioDJ plays from. A misconfiguration can put the wrong thing to air, or
  nothing at all.
- It does not modify or delete your audio files, and it does not delete rows from
  `songs`. It does install one trigger that sets `date_played` and `title_played`
  on tracks **as they are inserted** - [why](#new-tracks-and-the-songs-trigger).
  It never rewrites an existing row.
- Nobody is on call for your transmitter.

---

## Author

Built by **Aigars Sukurs** - self-taught radio engineer. Five stations built so
far: Radio 101, Rīga Radio, Latvijas Radio 5, [Radio Nemiers](https://radionemiers.com/)
and Radio Liepāja.

This scheduler came out of needing it for the three Nemiers stations, and then
needing the same thing again for Radio Liepāja - which is why it keys everything
on the selected database and holds each station's own values in one config row,
rather than being four copies that drift apart.

### If you found this useful

It is free and it stays free. If it saved you some work and you would like to
say thank you, Radio Nemiers is an independent station and every bit helps:

**→ [radionemiers.com/#contribute](https://radionemiers.com/#contribute)**

No obligation, and nothing here is gated behind it.

---

## Contributing

Issues and pull requests are welcome. Two things that will make a PR much easier
to accept:

- **Say which MySQL version and RadioDJ version you tested on.** "Works for me"
  is not testable.
- **Do not remove a comment because it looks verbose.** The long comments in
  these files are mostly the record of something that failed in production once.
  A few of them are the only reason the same thing has not happened twice.

If you hit something these files do not explain, open an issue - the gap in the
documentation is usually the actual bug.

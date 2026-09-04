-- =====================================================================
-- Custom scheduler — full baseline
-- RadioDJ 3.0.0.2 / MySQL 8.0.x / any station
--
-- Regenerated 2026-08-31 from the migration chain 002-014, all of
-- which are applied in production. This supersedes the original HeidiSQL
-- dump: that file still held the pre-003 procedure bodies, so a
-- reinstall from it resurrected every bug the chain fixed.
--
-- Assembled programmatically from the migration chain that produced the
-- live state, not retyped by hand.
--
-- Differences from a HeidiSQL dump, on purpose:
--   * no AUTO_INCREMENT= values (meaningless on a fresh install)
--   * no DEFINER= clauses, so this restores onto a station that has
--     no root@localhost
--   * SET NAMES carries an explicit collation, so routines are not
--     stamped utf8mb4_0900_ai_ci
--
-- ITS ROLE, AND WHAT IT IS NOT
--
--   This file        FULL INSTALL onto a database that has none of it.
--                    No DROP statements, no guards, not idempotent.
--                    Run scheduler-remove.sql first if any of
--                    these objects already exist.
--
--   A step-by-step migration is the other shape: it drops and
--   recreates only what it touches and is safe against a live
--   database. This file is not that. Do not make it re-runnable.
--
-- Keep the two roles separate. Do NOT add DROP statements here to make
-- it re-runnable — that is the migrations' job, and blurring it makes
-- a full install silently destructive. Do NOT generate a migration by
-- copying bodies out of this file without adding the DROPs back: that
-- is exactly how 011 shipped broken.
--
-- This file is regenerated from the migration chain after a migration
-- lands, so it always describes the current end state.
-- =====================================================================

SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;

-- No USE statement, on purpose: select the target database in your
-- client before running this, so the same file works unchanged on
-- every station. All lookups key on DATABASE().


-- ===== schema =========================================================

-- fallback_subcategory_id is nullable where the other two are not:
-- "no fallback" is a real state, and NULL lets the self-FK clean up
-- after itself instead of leaving a dangling ID. ON DELETE SET NULL so
-- RadioDJ deleting a subcategory can never be blocked by us.
ALTER TABLE `subcategory`
-- THE DEFAULT IS LOAD-BEARING. average_runtime, fill_priority and
-- fallback_subcategory_id are all OURS, not RadioDJ's — the stock
-- `subcategory` table has only ID, parentid, name and sweeper_subID.
-- RadioDJ therefore knows nothing about this column and does not
-- supply it when you add a subcategory in its UI. Without a default,
-- MySQL rejects that INSERT:
--     ERROR 1364 Field 'average_runtime' doesn't have a default value
--
-- AND RADIODJ SWALLOWS THE ERROR. It shows no message. You click "add
-- subcategory", nothing appears, and nothing tells you why — you would
-- be looking for a bug in RadioDJ, in a column RadioDJ has never heard
-- of. Same reason fill_priority carries a default. NEVER REMOVE EITHER.
ADD COLUMN `average_runtime` decimal(11,5) unsigned NOT NULL DEFAULT 0.00000,
ADD COLUMN `fill_priority` int unsigned NOT NULL DEFAULT '100',
ADD COLUMN `fallback_subcategory_id` int unsigned DEFAULT NULL,
ADD KEY `ix_subcategory_fallback` (`fallback_subcategory_id`),
ADD CONSTRAINT `FK_subcategory_fallback`
    FOREIGN KEY (`fallback_subcategory_id`) REFERENCES `subcategory` (`ID`)
    ON DELETE SET NULL ON UPDATE CASCADE;

-- RadioDJ ships idx_artist_title (artist, title) on `songs`, so the
-- ARTIST separation subquery can look same-artist tracks up directly.
-- Nothing leads on title, so the optimiser inverted the TITLE subquery
-- into a scan of the whole schedule window per candidate — 116 ms of a
-- 120 ms slot, and the single biggest cost in a day build. This makes
-- the two paths symmetrical. Additive to RadioDJ's own schema and
-- untouched by its upgrades; removed again by the teardown script.
ALTER TABLE `songs` ADD KEY `ix_title` (`title`);


CREATE TABLE IF NOT EXISTS `clocks` (
  `ID` int unsigned NOT NULL AUTO_INCREMENT,
  `name` varchar(200) COLLATE utf8mb4_unicode_ci NOT NULL,
  `rotation_id` int unsigned DEFAULT NULL,
  PRIMARY KEY (`ID`),
  KEY `FK_clocks_rotations` (`rotation_id`),
  CONSTRAINT `FK_clocks_rotations` FOREIGN KEY (`rotation_id`) REFERENCES `rotations` (`ID`) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `schedule` (
  `ID` int unsigned NOT NULL AUTO_INCREMENT,
  `schedule_date` date NOT NULL,
  `hour` int NOT NULL,
  `order` int NOT NULL,
  `clock_id` int NOT NULL,
  `entry_type` tinyint unsigned NOT NULL DEFAULT 0 COMMENT '0 subcategory, 1 jingle, 2 SQL, 3 manual event, 4 request',
  `subcategory_id` int DEFAULT NULL,
  `repeat_rule` tinyint(1) NOT NULL DEFAULT 1 COMMENT 'Snapshot of rotations_list.repeatRule taken at skeleton build.',
  `genre_id` int unsigned NOT NULL DEFAULT 0 COMMENT 'Snapshot of rotations_list.genID at skeleton build. 0 = genre does not matter.',
  `track_separation` int unsigned NOT NULL DEFAULT 0 COMMENT 'MINUTES. 0 = inherit the procedure default.',
  `artist_separation` int unsigned NOT NULL DEFAULT 0 COMMENT 'MINUTES. 0 = inherit the procedure default.',
  `title_separation` int unsigned NOT NULL DEFAULT 0 COMMENT 'MINUTES. 0 = inherit the procedure default.',
  `event_id` int unsigned DEFAULT NULL,
  `entry_data` text DEFAULT NULL,
  `song_id` int DEFAULT NULL,
  `artist` varchar(255) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `title` varchar(255) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  `airtime` int NOT NULL,
  `runtime` int DEFAULT NULL,
  PRIMARY KEY (`ID`),
  UNIQUE KEY `uq_slot` (`schedule_date`,`hour`,`order`),
  KEY `ix_date_song` (`schedule_date`,`song_id`),
  -- ix_song_date is not a duplicate of ix_date_song. The separation
  -- subqueries filter `song_id = ?` with `schedule_date >= ?` — a range
  -- on the leading column of ix_date_song, which stops it being usable
  -- for song_id. Leading on song_id makes those a covering lookup and
  -- is most of the difference between a day building in seconds and in
  -- minutes. The two indexes this pairs with took a day build from
  -- 189 s to 4.1 s on a station with ~450 slots a day, with no change
  -- in output; see README.md.
  KEY `ix_song_date` (`song_id`,`schedule_date`,`hour`,`airtime`),
  KEY `ix_date_subcat` (`schedule_date`,`subcategory_id`),
  KEY `ix_date_entry_type` (`schedule_date`,`entry_type`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

CREATE TABLE IF NOT EXISTS `schedule_log` (
  `ID`            int unsigned NOT NULL AUTO_INCREMENT,
  `logged_at`     datetime     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `event`         varchar(40)  COLLATE utf8mb4_unicode_ci NOT NULL,
  `schedule_date` date         DEFAULT NULL,
  `hour`          tinyint      DEFAULT NULL,
  `slots`         int          DEFAULT NULL,
  `filled`        int          DEFAULT NULL,
  `unfilled`      int          DEFAULT NULL,
  `fb_filled`     int          DEFAULT NULL,
  `fb_unfilled`   int          DEFAULT NULL,
  `pushed`        int          DEFAULT NULL,
  `ok`            tinyint(1)   NOT NULL DEFAULT 1,
  `message`       varchar(255) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
  PRIMARY KEY (`ID`),
  KEY `ix_logged_at` (`logged_at`),
  KEY `ix_date_event` (`schedule_date`, `event`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;


CREATE TABLE IF NOT EXISTS `scheduler_config` (
  `ID`               tinyint unsigned NOT NULL DEFAULT 1,
  `playlist_id`      int unsigned NOT NULL COMMENT 'Playlist SchedulePushPlaylist fills. MUST equal the id in RadioDJ event 32 data: Load Playlist|pos|ID|name|Top. Mismatch is silent.',
  `music_parentid`   int unsigned NOT NULL DEFAULT 1 COMMENT 'category.ID for Music. Slots under it inherit the music default separations in ScheduleFill.',
  `jingle_parentid`  int unsigned NOT NULL DEFAULT 5 COMMENT 'category.ID for Jingles. Slots under it inherit the other default separations in ScheduleFill.',
  `jingle_catid`     int          NOT NULL DEFAULT 5 COMMENT 'rotations_list.catID marking a jingle entry. Normally same value as jingle_parentid.',
  `version`          varchar(16)  COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '1.0.0'
      COMMENT 'Version of scheduler-create.sql that built this install. Nothing reads it; it exists so the question "which version is this?" has an answer. A migration must UPDATE it; the DEFAULT only stamps fresh installs.',
  PRIMARY KEY (`ID`),
  CONSTRAINT `ck_scheduler_config_one_row` CHECK (`ID` = 1)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;


-- ===== the clock grid (from the weekly-grid release) ===========================

CREATE TABLE IF NOT EXISTS `clock_grids` (
    `ID`             int unsigned NOT NULL AUTO_INCREMENT,
    `name`           varchar(100) COLLATE utf8mb4_unicode_ci NOT NULL,
    `is_default`     tinyint(1)   NOT NULL DEFAULT 0
        COMMENT 'The fallback grid when nothing else resolves. Exactly one row should have this set.',
    `feeder_grid_id` int unsigned DEFAULT NULL
        COMMENT 'Inherit undefined hours from this grid, recursively. NULL = no inheritance.',
    `notes`          varchar(255) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
    PRIMARY KEY (`ID`),
    UNIQUE KEY `uq_clock_grids_name` (`name`),
    KEY `ix_clock_grids_default` (`is_default`),
    KEY `ix_clock_grids_feeder` (`feeder_grid_id`),
    CONSTRAINT `FK_clock_grids_feeder` FOREIGN KEY (`feeder_grid_id`)
        REFERENCES `clock_grids` (`ID`) ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;


-- =====================================================================
-- 2. GRID HOURS — the cells
--
-- `dow` is ISO: 1 = Monday ... 7 = Sunday. NOT MySQL's DAYOFWEEK(),
-- which is 1 = Sunday. The conversion happens in ClockGridDow() and
-- nowhere else. Getting it wrong airs Sunday's programming on Monday,
-- silently, forever.
--
-- The FK to `clocks` means a grid cannot reference a clock that does
-- not exist, and ON DELETE CASCADE means deleting a clock takes its
-- cells with it rather than leaving the grid pointing at nothing.
-- =====================================================================

CREATE TABLE IF NOT EXISTS `clock_grid_hours` (
    `ID`       int unsigned NOT NULL AUTO_INCREMENT,
    `grid_id`  int unsigned NOT NULL,
    `dow`      tinyint unsigned NOT NULL COMMENT 'ISO day of week: 1 = Monday ... 7 = Sunday.',
    `hour`     tinyint unsigned NOT NULL,
    `clock_id` int unsigned NOT NULL,
    PRIMARY KEY (`ID`),
    UNIQUE KEY `uq_grid_cell` (`grid_id`, `dow`, `hour`),
    KEY `ix_grid_hours_clock` (`clock_id`),
    CONSTRAINT `FK_grid_hours_grid`  FOREIGN KEY (`grid_id`)
        REFERENCES `clock_grids` (`ID`) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT `FK_grid_hours_clock` FOREIGN KEY (`clock_id`)
        REFERENCES `clocks` (`ID`) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT `ck_grid_dow`  CHECK (`dow`  BETWEEN 1 AND 7),
    CONSTRAINT `ck_grid_hour` CHECK (`hour` BETWEEN 0 AND 23)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;


-- =====================================================================
-- 3. GRID SCHEDULE — pin one date to one grid
--
-- Holidays, and any day whose whole layout differs. Beats the rotation,
-- loses to an override. One row per date, so it cannot be ambiguous.
-- =====================================================================

CREATE TABLE IF NOT EXISTS `clock_grid_schedule` (
    `on_date` date         NOT NULL,
    `grid_id` int unsigned NOT NULL,
    `reason`  varchar(255) COLLATE utf8mb4_unicode_ci DEFAULT NULL
        COMMENT 'Why this date differs. Read by humans, never by code.',
    PRIMARY KEY (`on_date`),
    KEY `ix_grid_schedule_grid` (`grid_id`),
    CONSTRAINT `FK_grid_schedule_grid` FOREIGN KEY (`grid_id`)
        REFERENCES `clock_grids` (`ID`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;


-- =====================================================================
-- 4. ROTATIONS — ordered cycles of grids, one grid per week
--
-- The arithmetic below is deliberate and is the part people get
-- wrong, so it is spelled out rather than left to be inferred.
--
-- THE CYCLE IS 7-DAY ARITHMETIC FROM `start_date`, NOT ISO WEEKS:
--
--     position = FLOOR(DATEDIFF(date, start_date) / 7) % entry_count
--
-- Consequences, both deliberate:
--   * A Tuesday `start_date` swaps grids ON TUESDAYS, mid-week. The
--     Monday before a swap still belongs to the OUTGOING grid. Any
--     calendar that renders Monday-start weeks and assumes a rotation
--     boundary sits on the week edge will show the wrong grid.
--   * Dates BEFORE `start_date` are not in the rotation at all and
--     fall through to the next layer.
--
-- Do NOT normalise these dates to Monday to make the arithmetic
-- tidier. A rotation is allowed to swap mid-week, and forcing it onto
-- the week edge silently changes which grid a given date resolves to.
--
-- SEVERAL rotations may be active at once provided their date ranges
-- do not overlap — a summer rotation and a winter one. Overlap is a
-- configuration error; section 13 has the query that finds it.
-- =====================================================================

CREATE TABLE IF NOT EXISTS `clock_grid_rotations` (
    `ID`         int unsigned NOT NULL AUTO_INCREMENT,
    `name`       varchar(100) COLLATE utf8mb4_unicode_ci NOT NULL,
    `start_date` date NOT NULL
        COMMENT 'Week 0 of the cycle. The weekday of THIS date is the day grids swap on.',
    `end_date`   date DEFAULT NULL COMMENT 'NULL = runs indefinitely.',
    `is_active`  tinyint(1) NOT NULL DEFAULT 1,
    `notes`      varchar(255) COLLATE utf8mb4_unicode_ci DEFAULT NULL,
    PRIMARY KEY (`ID`),
    UNIQUE KEY `uq_rotation_name` (`name`),
    KEY `ix_rotation_window` (`is_active`, `start_date`, `end_date`),
    CONSTRAINT `ck_rotation_window` CHECK (`end_date` IS NULL OR `end_date` >= `start_date`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;

-- `position` is 0-based and dense. A gap means MOD addresses a
-- position that does not exist, and the rotation silently
-- contributes nothing.
CREATE TABLE IF NOT EXISTS `clock_grid_rotation_entries` (
    `rotation_id` int unsigned NOT NULL,
    `position`    tinyint unsigned NOT NULL COMMENT '0-based, dense. Week N uses position N % COUNT(*).',
    `grid_id`     int unsigned NOT NULL,
    PRIMARY KEY (`rotation_id`, `position`),
    KEY `ix_rotation_entry_grid` (`grid_id`),
    CONSTRAINT `FK_rot_entry_rotation` FOREIGN KEY (`rotation_id`)
        REFERENCES `clock_grid_rotations` (`ID`) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT `FK_rot_entry_grid` FOREIGN KEY (`grid_id`)
        REFERENCES `clock_grids` (`ID`) ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;


-- =====================================================================
-- 5. MONTHLY RULES — calendar-anchored, whole grid
--
-- An ordinal plus an ISO weekday selects a grid for that date. "First Saturday of the month
-- runs the Holiday grid."
--
-- This sits ABOVE the rotation and BELOW a dated pin, matching the
-- API's precedence exactly.
--
-- A NUMBERED RULE BEATS A `LAST` RULE when both land on the same date —
-- their documented behaviour, and the reason `ordinal DESC` orders the
-- lookup (-1 sorts last).
--
-- Note this is grid-granular. For a single show in a single hour, use
-- `clock_overrides` in section 6 instead: swapping a whole week's grid
-- to move one hour means a grid per combination of shows, which is the
-- combinatorial trap their console works around by cloning grids.
-- Feeder inheritance (section 1) is our answer to that, and it is the
-- one place we deliberately do better than the API rather than match it.
-- =====================================================================

CREATE TABLE IF NOT EXISTS `clock_grid_monthly_rules` (
    `ID`         int unsigned NOT NULL AUTO_INCREMENT,
    `name`       varchar(100) COLLATE utf8mb4_unicode_ci NOT NULL,
    `ordinal`    tinyint NOT NULL
        COMMENT '1-5 for first..fifth, or -1 for the last such weekday of the month.',
    `dow`        tinyint unsigned NOT NULL COMMENT 'ISO 1 = Monday ... 7 = Sunday.',
    `grid_id`    int unsigned NOT NULL,
    `valid_from` date DEFAULT NULL,
    `valid_to`   date DEFAULT NULL,
    `is_active`  tinyint(1) NOT NULL DEFAULT 1,
    PRIMARY KEY (`ID`),
    KEY `ix_monthly_lookup` (`is_active`, `dow`, `ordinal`),
    KEY `ix_monthly_grid` (`grid_id`),
    CONSTRAINT `FK_monthly_grid` FOREIGN KEY (`grid_id`)
        REFERENCES `clock_grids` (`ID`) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT `ck_monthly_ordinal` CHECK (`ordinal` BETWEEN -1 AND 5 AND `ordinal` <> 0),
    CONSTRAINT `ck_monthly_dow` CHECK (`dow` BETWEEN 1 AND 7)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;


-- =====================================================================
-- 6. OVERRIDES — recurring or one-off, at hour granularity
--
-- This is where bi-weekly and monthly SHOWS live, as opposed to
-- bi-weekly WEEKS which are the rotation's job. A single show on
-- Saturday at 14:00 does not justify swapping a whole week's grid, and
-- if you tried, one bi-weekly show plus one monthly show would need a
-- grid per combination.
--
-- The rule is stored, not its expansion: it is evaluated for the one
-- date the nightly build asks about. That avoids owning a generator, a
-- table of pre-computed dates, and the question of how far ahead it
-- has run. See README.md.
--
-- `priority` breaks ties, then `ID`. Deterministic on purpose: two
-- overrides claiming the same hour must resolve identically on every
-- rebuild, or the same date builds differently run to run.
-- =====================================================================

CREATE TABLE IF NOT EXISTS `clock_overrides` (
    `ID`           int unsigned NOT NULL AUTO_INCREMENT,
    `name`         varchar(100) COLLATE utf8mb4_unicode_ci NOT NULL
        COMMENT 'The show or reason. Appears in ClockGridExplain output.',
    `clock_id`     int unsigned NOT NULL,
    `hour`         tinyint unsigned NOT NULL,
    `recurrence`   enum('weekly','nweekly','monthly_nth_dow','monthly_day','once')
                   COLLATE utf8mb4_unicode_ci NOT NULL,
    `dow`          tinyint unsigned DEFAULT NULL
        COMMENT 'ISO 1 = Monday. Required for weekly, nweekly, monthly_nth_dow.',
    `every_n`      tinyint unsigned NOT NULL DEFAULT 2
        COMMENT 'nweekly only: 2 = every other week, 3 = every third.',
    `anchor_date`  date DEFAULT NULL
        COMMENT 'nweekly only: a date in a week the show DOES air. Normalised to its Monday.',
    `nth`          tinyint NOT NULL DEFAULT 1
        COMMENT 'monthly_nth_dow only: 1-5, or -1 for the last such weekday of the month.',
    `day_of_month` tinyint unsigned DEFAULT NULL
        COMMENT 'monthly_day only: 1-31.',
    `on_date`      date DEFAULT NULL
        COMMENT 'once only: the single date.',
    `valid_from`   date DEFAULT NULL COMMENT 'NULL = no lower bound.',
    `valid_to`     date DEFAULT NULL COMMENT 'NULL = runs indefinitely. Set it to retire a show without deleting it.',
    `priority`     smallint NOT NULL DEFAULT 0 COMMENT 'Higher wins. Ties break on ID ascending.',
    PRIMARY KEY (`ID`),
    KEY `ix_overrides_hour` (`hour`, `recurrence`),
    KEY `ix_overrides_clock` (`clock_id`),
    CONSTRAINT `FK_overrides_clock` FOREIGN KEY (`clock_id`)
        REFERENCES `clocks` (`ID`) ON DELETE CASCADE ON UPDATE CASCADE,
    CONSTRAINT `ck_ovr_hour`  CHECK (`hour` BETWEEN 0 AND 23),
    CONSTRAINT `ck_ovr_dow`   CHECK (`dow` IS NULL OR `dow` BETWEEN 1 AND 7),
    CONSTRAINT `ck_ovr_nth`   CHECK (`nth` BETWEEN -1 AND 5 AND `nth` <> 0),
    CONSTRAINT `ck_ovr_dom`   CHECK (`day_of_month` IS NULL OR `day_of_month` BETWEEN 1 AND 31),
    CONSTRAINT `ck_ovr_every` CHECK (`every_n` >= 1),
    -- Each recurrence kind needs its own parameters present. Enforced
    -- here rather than trusted, because a NULL dow on a weekly rule
    -- would silently never match and the show would just not air.
    CONSTRAINT `ck_ovr_params` CHECK (
        (`recurrence` = 'weekly'          AND `dow` IS NOT NULL)
     OR (`recurrence` = 'nweekly'         AND `dow` IS NOT NULL AND `anchor_date` IS NOT NULL)
     OR (`recurrence` = 'monthly_nth_dow' AND `dow` IS NOT NULL)
     OR (`recurrence` = 'monthly_day'     AND `day_of_month` IS NOT NULL)
     OR (`recurrence` = 'once'            AND `on_date` IS NOT NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;


-- NOT NULL throughout with the current values as defaults: a NULL gap
-- would make every comparison fail and fill nothing. The CHECK pins it
-- to a single row so there is no question which config is live.

-- ===== functions ======================================================


DELIMITER //
CREATE FUNCTION `SongsCueValue`(
	`p_cue` TEXT,
	`p_key` VARCHAR(10)
) RETURNS decimal(12,5)
    DETERMINISTIC
    COMMENT 'Extract track''s cue values. Used by SchedulePushPlaylist'
BEGIN
    IF p_cue IS NULL OR p_cue NOT LIKE CONCAT('%&', p_key, '=%') THEN
        RETURN 0;
    END IF;
    RETURN CAST(
        SUBSTRING_INDEX(SUBSTRING_INDEX(p_cue, CONCAT('&', p_key, '='), -1), '&', 1)
        AS DECIMAL(12,5));
END//
DELIMITER ;

DELIMITER //
-- ISO day of week: 1 = Monday ... 7 = Sunday.
--
-- THE ONLY PLACE THIS CONVERSION HAPPENS. MySQL gives you two wrong
-- answers to choose from: DAYOFWEEK() is 1 = Sunday, WEEKDAY() is
-- 0 = Monday. Anything computing dow by hand will be off by one and
-- will air Sunday's programming on Monday without erroring.
CREATE FUNCTION `ClockGridDow`(`p_date` DATE) RETURNS TINYINT
    DETERMINISTIC
    COMMENT 'ISO day of week, 1=Monday..7=Sunday. Use this, never DAYOFWEEK().'
BEGIN
    RETURN WEEKDAY(p_date) + 1;
END//
DELIMITER ;


DELIMITER //
-- Which grid applies on p_date. Four layers, FIRST MATCH WINS, in the
-- this precedence, which is what makes "why is Tuesday showing that
-- clock" answerable at all:
--
--   1  clock_grid_schedule       a dated pin        (their programme_day)
--   2  clock_grid_monthly_rules  nth weekday        (their monthly_rule)
--   3  clock_grid_rotations      weekly cycle       (their rotation)
--   4  clock_grids.is_default    the fallback       (their station_default)
--
-- Returns NULL if nothing resolves. The API treats that as a valid
-- "nothing scheduled" state; we do NOT — ScheduleBuildSkeleton signals,
-- because their consumer is a programme guide and ours drives playout.
-- A radio station cannot have an hour with no clock, and a nightly
-- build that quietly picked "some" grid is worse than one that stops.
CREATE FUNCTION `ClockGridResolve`(`p_date` DATE) RETURNS INT UNSIGNED
    READS SQL DATA
    COMMENT 'Grid for a date: dated pin, then monthly rule, then rotation, then is_default.'
BEGIN
    DECLARE v_grid INT UNSIGNED DEFAULT NULL;
    DECLARE v_dow  TINYINT DEFAULT ClockGridDow(p_date);

    -- 1. an explicit pin for this date
    SELECT grid_id INTO v_grid FROM clock_grid_schedule WHERE on_date = p_date;
    IF v_grid IS NOT NULL THEN
        RETURN v_grid;
    END IF;

    -- 2. a monthly rule. `ordinal DESC` puts numbered rules ahead of
    --    -1 (last), which is the API's documented tie-break: a
    --    numbered rule beats a LAST rule when both land on one date.
    SELECT mr.grid_id INTO v_grid
    FROM clock_grid_monthly_rules mr
    WHERE mr.is_active = 1
      AND mr.dow = v_dow
      AND (mr.valid_from IS NULL OR p_date >= mr.valid_from)
      AND (mr.valid_to   IS NULL OR p_date <= mr.valid_to)
      AND ((mr.ordinal > 0  AND CEIL(DAYOFMONTH(p_date) / 7) = mr.ordinal)
        -- "last" = no further same weekday remains in the month
        OR (mr.ordinal = -1 AND DAYOFMONTH(p_date) + 7 > DAY(LAST_DAY(p_date))))
    ORDER BY mr.ordinal DESC, mr.ID ASC
    LIMIT 1;
    IF v_grid IS NOT NULL THEN
        RETURN v_grid;
    END IF;

    -- 3. the rotation. 7-day arithmetic from the rotation's OWN
    --    start_date — not from a Monday, and not from WEEK(). A Tuesday
    --    start_date therefore swaps grids on Tuesdays. `p_date >=
    --    start_date` keeps DATEDIFF non-negative, so MOD cannot go
    --    negative and look for a position that does not exist.
    SELECT re.grid_id INTO v_grid
    FROM clock_grid_rotations r
    JOIN clock_grid_rotation_entries re ON re.rotation_id = r.ID
    WHERE r.is_active = 1
      AND p_date >= r.start_date
      AND (r.end_date IS NULL OR p_date <= r.end_date)
      AND re.position = MOD(
            FLOOR(DATEDIFF(p_date, r.start_date) / 7),
            (SELECT COUNT(*) FROM clock_grid_rotation_entries WHERE rotation_id = r.ID))
    ORDER BY r.start_date DESC, r.ID DESC
    LIMIT 1;
    IF v_grid IS NOT NULL THEN
        RETURN v_grid;
    END IF;

    -- 4. the default
    SELECT ID INTO v_grid FROM clock_grids WHERE is_default = 1 ORDER BY ID LIMIT 1;
    RETURN v_grid;
END//
DELIMITER ;


DELIMITER //
-- The clock a grid gives for (dow, hour), walking up feeder_grid_id
-- while the cell is undefined. Depth capped at 8; a cycle signals
-- rather than spinning, because a grid feeding itself is a
-- configuration error and not a fixpoint.
CREATE FUNCTION `ClockGridCellClock`(`p_grid` INT UNSIGNED, `p_dow` TINYINT, `p_hour` TINYINT)
    RETURNS INT UNSIGNED
    READS SQL DATA
    COMMENT 'Clock for one grid cell, inheriting through feeder_grid_id.'
BEGIN
    DECLARE v_grid  INT UNSIGNED DEFAULT p_grid;
    DECLARE v_clock INT UNSIGNED DEFAULT NULL;
    DECLARE v_depth INT DEFAULT 0;

    WHILE v_grid IS NOT NULL AND v_depth < 8 DO
        SELECT clock_id INTO v_clock FROM clock_grid_hours
        WHERE grid_id = v_grid AND dow = p_dow AND `hour` = p_hour;

        IF v_clock IS NOT NULL THEN
            RETURN v_clock;
        END IF;

        SELECT feeder_grid_id INTO v_grid FROM clock_grids WHERE ID = v_grid;
        SET v_depth = v_depth + 1;
    END WHILE;

    IF v_depth >= 8 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'ClockGridCellClock: feeder chain deeper than 8 - probable cycle in clock_grids.feeder_grid_id';
    END IF;

    RETURN NULL;
END//
DELIMITER ;


DELIMITER //
-- THE ENTRY POINT. Which clock owns (p_date, p_hour).
--
-- Overrides beat everything, then the resolved grid's cell. Returns
-- NULL when nothing claims the hour, which the caller treats as fatal.
CREATE FUNCTION `ClockGridClockFor`(`p_date` DATE, `p_hour` TINYINT) RETURNS INT UNSIGNED
    READS SQL DATA
    COMMENT 'Clock for one date and hour: overrides, then the resolved grid.'
BEGIN
    DECLARE v_dow   TINYINT DEFAULT ClockGridDow(p_date);
    DECLARE v_clock INT UNSIGNED DEFAULT NULL;
    DECLARE v_grid  INT UNSIGNED DEFAULT NULL;

    -- 1. overrides. The CASE is the recurrence evaluation.
    SELECT o.clock_id INTO v_clock
    FROM clock_overrides o
    WHERE o.`hour` = p_hour
      AND (o.valid_from IS NULL OR p_date >= o.valid_from)
      AND (o.valid_to   IS NULL OR p_date <= o.valid_to)
      AND CASE o.recurrence
          WHEN 'once'   THEN o.on_date = p_date
          WHEN 'weekly' THEN o.dow = v_dow
          WHEN 'nweekly' THEN
              o.dow = v_dow
              -- whole weeks between the two Mondays, so a mid-week
              -- anchor and a mid-week target still land on the same
              -- parity. Never WEEK(): its numbering restarts yearly.
              AND MOD(FLOOR(DATEDIFF(
                      DATE_SUB(p_date,        INTERVAL WEEKDAY(p_date)        DAY),
                      DATE_SUB(o.anchor_date, INTERVAL WEEKDAY(o.anchor_date) DAY)
                  ) / 7), o.every_n) = 0
          WHEN 'monthly_nth_dow' THEN
              o.dow = v_dow
              AND ((o.nth > 0  AND CEIL(DAYOFMONTH(p_date) / 7) = o.nth)
                -- "last" is the occurrence with no further same weekday
                -- left in the month.
                OR  (o.nth = -1 AND DAYOFMONTH(p_date) + 7 > DAY(LAST_DAY(p_date))))
          WHEN 'monthly_day' THEN o.day_of_month = DAYOFMONTH(p_date)
          ELSE 0
          END
    ORDER BY o.priority DESC, o.ID ASC
    LIMIT 1;

    IF v_clock IS NOT NULL THEN
        RETURN v_clock;
    END IF;

    -- 2. the grid
    SET v_grid = ClockGridResolve(p_date);
    IF v_grid IS NULL THEN
        RETURN NULL;
    END IF;

    RETURN ClockGridCellClock(v_grid, v_dow, p_hour);
END//
DELIMITER ;
DELIMITER ;
DELIMITER //
CREATE PROCEDURE `ScheduleBuildSkeleton`(
    IN  `p_date`      DATE,
    IN  `p_from_hour` INT,
    OUT `p_slots`     INT
)
    COMMENT 'Materialise a day''s slots from the clock grid and rotations_list.'
BEGIN
    DECLARE v_jingle_cat INT DEFAULT NULL;
    DECLARE h            INT DEFAULT 0;
    DECLARE v_clock      INT UNSIGNED DEFAULT NULL;
    DECLARE v_rot        INT UNSIGNED DEFAULT NULL;
    DECLARE v_msg        VARCHAR(255);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    SET p_slots = 0;

    IF p_date IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'ScheduleBuildSkeleton: p_date is NULL';
    END IF;

    IF p_from_hour IS NULL OR p_from_hour < 0 OR p_from_hour > 23 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'ScheduleBuildSkeleton: p_from_hour must be 0-23';
    END IF;

    -- jingle_catid decides which rotation entries are links rather than
    -- music. Station-specific, so it lives in scheduler_config and the
    -- procedure refuses to guess.
    SELECT jingle_catid INTO v_jingle_cat FROM scheduler_config WHERE ID = 1;
    IF v_jingle_cat IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'scheduler_config row 1 is missing';
    END IF;

    -- ----- pre-flight, outside the transaction -----
    SET h = p_from_hour;
    WHILE h < 24 DO
        SET v_clock = ClockGridClockFor(p_date, h);

        IF v_clock IS NULL THEN
            SET v_msg = CONCAT('ScheduleBuildSkeleton: no clock for ', p_date, ' hour ', h,
                               ' - the resolved grid leaves that cell empty and no feeder fills it');
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
        END IF;

        SET v_rot = NULL;
        SELECT rotation_id INTO v_rot FROM clocks WHERE ID = v_clock;
        IF v_rot IS NULL THEN
            SET v_msg = CONCAT('ScheduleBuildSkeleton: clock ', v_clock, ' owns ', p_date,
                               ' hour ', h, ' but has no rotation - it can never fill');
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
        END IF;

        SET h = h + 1;
    END WHILE;

    START TRANSACTION;

    DELETE FROM schedule
    WHERE schedule_date = p_date
      AND `hour` >= p_from_hour;

    INSERT INTO schedule
        (schedule_date, `hour`, `order`, clock_id, entry_type,
         subcategory_id, event_id, entry_data, airtime,
         repeat_rule, genre_id, track_separation, artist_separation, title_separation)
    SELECT p_date, x.h, x.ord_in_hour, x.clock_id, x.entry_type,
           x.subcategory_id, x.event_id, x.entry_data, x.airtime,
           x.repeat_rule, x.genre_id, x.track_separation, x.artist_separation, x.title_separation
    FROM (
        SELECT
            hg.h,
            hg.clock_id,
            ROW_NUMBER() OVER (PARTITION BY hg.h ORDER BY rl.ord, rl.ID) AS ord_in_hour,
            -- Negative catID marks a special entry. subID means
            -- something different in each case, so it is only trusted
            -- as a subcategory when catID is a real category. Moved
            -- verbatim from the routine that used to build the template. This
            -- is the single most dangerous expression in the file: catID,
            -- subID and genID are SIGNED and reused as sentinels.
            CASE rl.catID
                WHEN  -50 THEN 2                                  -- SQL query
                WHEN  -10 THEN 3                                  -- manual event
                WHEN -100 THEN 4                                  -- request
                ELSE IF(rl.catID = v_jingle_cat, 1, 0)
            END                                              AS entry_type,
            IF(rl.catID < 0, NULL, rl.subID)                 AS subcategory_id,
            IF(rl.catID =  -10, rl.subID, NULL)              AS event_id,
            IF(rl.catID =  -50, NULLIF(rl.data, ''), NULL)   AS entry_data,
            -- Predicted on-air offset within the hour: the running sum
            -- of the average runtimes of everything before this entry.
            -- A special entry has no subcategory, so the LEFT JOIN
            -- below yields NULL and it contributes 0 — same as before,
            -- and the reason the join is on the guarded expression
            -- rather than on rl.subID directly.
            ROUND(COALESCE(
                SUM(COALESCE(sc.average_runtime, 0)) OVER (
                    PARTITION BY hg.h
                    ORDER BY rl.ord, rl.ID
                    ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
                ), 0))                                       AS airtime,
            IF(rl.repeatRule = 1, 1, 0)                      AS repeat_rule,
            IF(rl.catID < 0, 0, GREATEST(rl.genID, 0))       AS genre_id,
            GREATEST(rl.track_separation,  0)                AS track_separation,
            GREATEST(rl.artist_separation, 0)                AS artist_separation,
            GREATEST(rl.title_separation,  0)                AS title_separation
        FROM (
            SELECT hh.n AS h, ClockGridClockFor(p_date, hh.n) AS clock_id
            FROM (SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3
                  UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7
                  UNION ALL SELECT 8 UNION ALL SELECT 9 UNION ALL SELECT 10 UNION ALL SELECT 11
                  UNION ALL SELECT 12 UNION ALL SELECT 13 UNION ALL SELECT 14 UNION ALL SELECT 15
                  UNION ALL SELECT 16 UNION ALL SELECT 17 UNION ALL SELECT 18 UNION ALL SELECT 19
                  UNION ALL SELECT 20 UNION ALL SELECT 21 UNION ALL SELECT 22 UNION ALL SELECT 23) hh
            WHERE hh.n >= p_from_hour
        ) hg
        JOIN clocks         ck ON ck.ID  = hg.clock_id
        JOIN rotations_list rl ON rl.pID = ck.rotation_id
        LEFT JOIN subcategory sc ON sc.ID = IF(rl.catID < 0, NULL, rl.subID)
    ) x;

    SET p_slots = ROW_COUNT();

    IF p_slots = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'ScheduleBuildSkeleton: the resolved clocks'' rotations produced no entries - schedule left untouched';
    END IF;

    COMMIT;
END//
DELIMITER ;

DELIMITER //
CREATE PROCEDURE `ScheduleFill`(
    IN  `p_date`     DATE,
    OUT `p_filled`   INT,
    OUT `p_unfilled` INT
)
BEGIN
  DECLARE done INT DEFAULT 0;
  DECLARE v_playlist INT; DECLARE v_music INT; DECLARE v_jingle INT;

  -- ===== DEFAULT separation windows, SECONDS ==========================
  -- Formerly scheduler_config.{music,other}_{track,artist,title}_gap.
  -- A slot uses these only where its rotation rule leaves that dimension
  -- at 0. Duplicated verbatim in ScheduleFillFallback - keep in sync.
  DECLARE c_m_track  INT DEFAULT 25200;   -- 7 h    music, same track
  DECLARE c_m_artist INT DEFAULT  7200;   -- 2 h    music, same artist
  DECLARE c_m_title  INT DEFAULT  4200;   -- 70 min music, same title (covers)
  DECLARE c_o_track  INT DEFAULT  4200;   -- 70 min non-music, same track
  DECLARE c_o_artist INT DEFAULT  1800;   -- 30 min non-music, same artist
  DECLARE c_o_title  INT DEFAULT     0;   -- off     non-music, same title
  -- ====================================================================

  DECLARE v_def_track INT; DECLARE v_def_artist INT; DECLARE v_def_title INT;
  DECLARE v_seen INT DEFAULT 0;
  DECLARE v_id INT; DECLARE v_subcat INT; DECLARE v_parent INT; DECLARE v_abs INT;
  DECLARE v_repeat INT; DECLARE v_genre INT;
  DECLARE v_rl_track INT; DECLARE v_rl_artist INT; DECLARE v_rl_title INT;
  DECLARE v_song INT; DECLARE v_dur DECIMAL(11,5);
  DECLARE v_artist VARCHAR(255); DECLARE v_title VARCHAR(255);
  DECLARE v_track_gap INT; DECLARE v_artist_gap INT; DECLARE v_title_gap INT;
  DECLARE v_real DATETIME; DECLARE v_back DATE;

  DECLARE cur CURSOR FOR
      SELECT sch.id, sch.subcategory_id, sc.parentid,
             (sch.hour * 3600 + sch.airtime) AS abs_time,
             sch.repeat_rule, sch.genre_id,
             sch.track_separation, sch.artist_separation, sch.title_separation
      FROM schedule sch
      JOIN subcategory sc ON sc.ID = sch.subcategory_id
      WHERE sch.schedule_date = p_date
        AND sch.song_id IS NULL
      -- No parentid restriction. It used to read
      --     AND sc.parentid IN (v_music, v_jingle)
      -- which silently skipped every slot from any other category AND
      -- left them out of p_unfilled, because that counts only rows the
      -- cursor fetched. One station reported "filled 447, unfilled 0"
      -- on a day that actually had 60 empty slots, every one of them
      -- in a category the cursor could not see.
      --
      -- music_parentid is still needed below, but only to choose which
      -- DEFAULT separation set a slot inherits - and everything that is
      -- not music already takes the other set. The restriction bought
      -- nothing except the holes, and the counters reported a full
      -- day while 60 slots were empty.
      ORDER BY sc.fill_priority ASC, sch.hour, sch.`order`;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

  SELECT playlist_id, music_parentid, jingle_parentid
    INTO v_playlist, v_music, v_jingle
    FROM scheduler_config WHERE ID = 1;

  IF v_music IS NULL THEN
      SIGNAL SQLSTATE '45000'
          SET MESSAGE_TEXT = 'scheduler_config row 1 is missing - run 011 seed';
  END IF;

  SET p_filled = 0;
  SET p_unfilled = 0;
  SET v_back = DATE_SUB(p_date, INTERVAL 1 DAY);

  OPEN cur;
  read_loop: LOOP
      FETCH cur INTO v_id, v_subcat, v_parent, v_abs,
                     v_repeat, v_genre, v_rl_track, v_rl_artist, v_rl_title;
      IF done THEN LEAVE read_loop; END IF;

      SET v_seen = v_seen + 1;

      -- Which default set this slot inherits from, if it inherits.
      IF v_parent = v_music THEN
          SET v_def_track = c_m_track, v_def_artist = c_m_artist, v_def_title = c_m_title;
      ELSE
          SET v_def_track = c_o_track, v_def_artist = c_o_artist, v_def_title = c_o_title;
      END IF;

      -- Resolution. repeat_rule = 0 zeroes every window; a zero window
      -- short-circuits its predicate below, so the one candidate query
      -- serves both branches and there is no second copy to drift.
      -- NULLIF(x,0) is what makes 0 mean "not set" rather than "off":
      -- NULL * 60 is NULL, so COALESCE falls through to the default.
      IF v_repeat = 1 THEN
          SET v_track_gap  = COALESCE(NULLIF(v_rl_track,  0) * 60, v_def_track);
          SET v_artist_gap = COALESCE(NULLIF(v_rl_artist, 0) * 60, v_def_artist);
          SET v_title_gap  = COALESCE(NULLIF(v_rl_title,  0) * 60, v_def_title);
      ELSE
          SET v_track_gap = 0, v_artist_gap = 0, v_title_gap = 0;
      END IF;

      SET v_real = DATE_ADD(p_date, INTERVAL v_abs SECOND);
      SET v_song = NULL;

      BEGIN
          DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_song = NULL;

          SELECT s.ID, s.duration, s.artist, s.title
          INTO v_song, v_dur, v_artist, v_title
          FROM songs s
          WHERE s.enabled = 1
            AND s.id_subcat = v_subcat
            -- Genre is an independent filter, NOT part of the repeat
            -- rule. It applies on both branches. 0 = any genre.
            AND (v_genre = 0 OR s.id_genre = v_genre)
            -- RadioDJ's own rotation honours these; this scheduler did not.
            -- play_limit 0 means no limit. Not separation - repeat_rule = 0
            -- does not switch them off.
            AND (s.play_limit = 0 OR s.count_played < s.play_limit)
            -- '2002-01-01 00:00:01' is the unset sentinel, not a real
            -- date (RadioDJ uses sentinel values, never NULL). Comparing against it directly would
            -- exclude every track that has no window set.
            AND (s.start_date = '2002-01-01 00:00:01' OR s.start_date <= v_real)
            AND (s.end_date   = '2002-01-01 00:00:01' OR s.end_date   >= v_real)
            -- Separation against the day being built.
            AND (v_track_gap = 0 OR NOT EXISTS (
                  SELECT 1 FROM schedule x
                  WHERE x.song_id = s.ID
                    AND x.schedule_date >= v_back
                    AND x.airtime < 3600
                    AND ABS(TIMESTAMPDIFF(SECOND,
                          DATE_ADD(x.schedule_date, INTERVAL (x.hour*3600 + x.airtime) SECOND),
                          v_real)) < v_track_gap))
            AND (v_artist_gap = 0 OR NOT EXISTS (
                  SELECT 1 FROM schedule x JOIN songs xs ON xs.ID = x.song_id
                  WHERE xs.artist = s.artist
                    AND x.schedule_date >= v_back
                    AND x.airtime < 3600
                    AND ABS(TIMESTAMPDIFF(SECOND,
                          DATE_ADD(x.schedule_date, INTERVAL (x.hour*3600 + x.airtime) SECOND),
                          v_real)) < v_artist_gap))
            AND (v_title_gap = 0 OR NOT EXISTS (
                  SELECT 1 FROM schedule x JOIN songs xs ON xs.ID = x.song_id
                  WHERE xs.title = s.title
                    AND x.schedule_date >= v_back
                    AND x.airtime < 3600
                    AND ABS(TIMESTAMPDIFF(SECOND,
                          DATE_ADD(x.schedule_date, INTERVAL (x.hour*3600 + x.airtime) SECOND),
                          v_real)) < v_title_gap))
            -- Separation against what RadioDJ actually aired.
            AND (v_track_gap  = 0 OR TIMESTAMPDIFF(SECOND, s.date_played,   v_real) >= v_track_gap)
            AND (v_artist_gap = 0 OR TIMESTAMPDIFF(SECOND, s.artist_played, v_real) >= v_artist_gap)
            AND (v_title_gap  = 0 OR TIMESTAMPDIFF(SECOND, s.title_played,  v_real) >= v_title_gap)
          -- Identical on both branches. date_played ASC IS "least
          -- recently played", which is all repeat_rule = 0 asks for; the
          -- leading term keeps a small pool from repeating within the
          -- same day even with every window off.
          ORDER BY
            (SELECT COUNT(*) FROM schedule u
               WHERE u.schedule_date = p_date AND u.song_id = s.ID) ASC,
            s.date_played ASC, s.count_played ASC
          LIMIT 1;
      END;

      IF v_song IS NOT NULL THEN
          UPDATE schedule
          SET song_id = v_song, runtime = v_dur, artist = v_artist, title = v_title
          WHERE id = v_id;

          SET p_filled = p_filled + 1;
      END IF;
  END LOOP;
  CLOSE cur;

  SET p_unfilled = v_seen - p_filled;
END//
DELIMITER ;

DELIMITER //
CREATE PROCEDURE `ScheduleFillFallback`(
    IN  `p_date`     DATE,
    OUT `p_filled`   INT,
    OUT `p_unfilled` INT
)
BEGIN
      DECLARE done INT DEFAULT 0;
      DECLARE v_playlist INT; DECLARE v_music INT; DECLARE v_jingle INT;

      -- ===== DEFAULT separation windows, SECONDS ======================
      -- Duplicated verbatim from ScheduleFill - keep the two in sync.
      DECLARE c_m_track  INT DEFAULT 25200;
      DECLARE c_m_artist INT DEFAULT  7200;
      DECLARE c_m_title  INT DEFAULT  4200;
      DECLARE c_o_track  INT DEFAULT  4200;
      DECLARE c_o_artist INT DEFAULT  1800;
      DECLARE c_o_title  INT DEFAULT     0;
      -- ================================================================

      DECLARE v_def_track INT; DECLARE v_def_artist INT; DECLARE v_def_title INT;
      DECLARE v_seen INT DEFAULT 0;
      DECLARE v_id INT; DECLARE v_parent INT; DECLARE v_fallback INT; DECLARE v_abs INT;
      DECLARE v_repeat INT; DECLARE v_genre INT;
      DECLARE v_rl_track INT; DECLARE v_rl_artist INT; DECLARE v_rl_title INT;
      DECLARE v_song INT; DECLARE v_dur DECIMAL(11,5);
      DECLARE v_artist VARCHAR(255); DECLARE v_title VARCHAR(255);
      DECLARE v_track_gap INT; DECLARE v_artist_gap INT; DECLARE v_title_gap INT;
      DECLARE v_real DATETIME; DECLARE v_back DATE;

      DECLARE cur CURSOR FOR
          SELECT sch.id, sc.parentid,
                 sc.fallback_subcategory_id,
                 (sch.hour * 3600 + sch.airtime) AS abs_time,
                 sch.repeat_rule, sch.genre_id,
                 sch.track_separation, sch.artist_separation, sch.title_separation
          FROM schedule sch
          JOIN subcategory sc ON sc.ID = sch.subcategory_id
          WHERE sch.schedule_date = p_date
            AND sch.song_id IS NULL
            AND sc.fallback_subcategory_id IS NOT NULL
          ORDER BY sc.fill_priority ASC, sch.hour, sch.`order`;
      DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

      SELECT playlist_id, music_parentid, jingle_parentid
        INTO v_playlist, v_music, v_jingle
        FROM scheduler_config WHERE ID = 1;

      IF v_music IS NULL THEN
          SIGNAL SQLSTATE '45000'
              SET MESSAGE_TEXT = 'scheduler_config row 1 is missing - run 011 seed';
      END IF;

      SET p_filled = 0;
      SET p_unfilled = 0;
      SET v_back = DATE_SUB(p_date, INTERVAL 1 DAY);

      OPEN cur;
      read_loop: LOOP
          FETCH cur INTO v_id, v_parent, v_fallback, v_abs,
                         v_repeat, v_genre, v_rl_track, v_rl_artist, v_rl_title;
          IF done THEN LEAVE read_loop; END IF;

          SET v_seen = v_seen + 1;

          -- The slot's own rule still governs, even though the pool is
          -- the fallback subcategory. A fallback is a substitute source,
          -- not a licence to break the rule the clock asked for. Note
          -- this makes the genre filter apply to the fallback pool too:
          -- if a slot says "rock only" its fallback stays rock, and if
          -- the fallback pool has no rock the slot goes unfilled and
          -- shows up in schedule_log.fb_unfilled.
          IF v_parent = v_music THEN
              SET v_def_track = c_m_track, v_def_artist = c_m_artist, v_def_title = c_m_title;
          ELSE
              SET v_def_track = c_o_track, v_def_artist = c_o_artist, v_def_title = c_o_title;
          END IF;

          IF v_repeat = 1 THEN
              SET v_track_gap  = COALESCE(NULLIF(v_rl_track,  0) * 60, v_def_track);
              SET v_artist_gap = COALESCE(NULLIF(v_rl_artist, 0) * 60, v_def_artist);
              SET v_title_gap  = COALESCE(NULLIF(v_rl_title,  0) * 60, v_def_title);
          ELSE
              SET v_track_gap = 0, v_artist_gap = 0, v_title_gap = 0;
          END IF;

          SET v_real = DATE_ADD(p_date, INTERVAL v_abs SECOND);
          SET v_song = NULL;

          BEGIN
              DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_song = NULL;

              SELECT s.ID, s.duration, s.artist, s.title
              INTO v_song, v_dur, v_artist, v_title
              FROM songs s
              WHERE s.enabled = 1
                AND s.id_subcat = v_fallback
                AND (v_genre = 0 OR s.id_genre = v_genre)
                -- RadioDJ's own rotation honours these; this scheduler did not.
                -- play_limit 0 means no limit.
                AND (s.play_limit = 0 OR s.count_played < s.play_limit)
                -- '2002-01-01 00:00:01' is the unset sentinel, not a real
                -- date (RadioDJ uses sentinel values, never NULL). Comparing against it directly would
                -- exclude every track that has no window set.
                AND (s.start_date = '2002-01-01 00:00:01' OR s.start_date <= v_real)
                AND (s.end_date   = '2002-01-01 00:00:01' OR s.end_date   >= v_real)
                AND (v_track_gap = 0 OR NOT EXISTS (
                      SELECT 1 FROM schedule x
                      WHERE x.song_id = s.ID
                        AND x.schedule_date >= v_back
                        AND x.airtime < 3600
                        AND ABS(TIMESTAMPDIFF(SECOND,
                              DATE_ADD(x.schedule_date, INTERVAL (x.hour*3600 + x.airtime) SECOND),
                              v_real)) < v_track_gap))
                AND (v_artist_gap = 0 OR NOT EXISTS (
                      SELECT 1 FROM schedule x JOIN songs xs ON xs.ID = x.song_id
                      WHERE xs.artist = s.artist
                        AND x.schedule_date >= v_back
                        AND x.airtime < 3600
                        AND ABS(TIMESTAMPDIFF(SECOND,
                              DATE_ADD(x.schedule_date, INTERVAL (x.hour*3600 + x.airtime) SECOND),
                              v_real)) < v_artist_gap))
                AND (v_title_gap = 0 OR NOT EXISTS (
                      SELECT 1 FROM schedule x JOIN songs xs ON xs.ID = x.song_id
                      WHERE xs.title = s.title
                        AND x.schedule_date >= v_back
                        AND x.airtime < 3600
                        AND ABS(TIMESTAMPDIFF(SECOND,
                              DATE_ADD(x.schedule_date, INTERVAL (x.hour*3600 + x.airtime) SECOND),
                              v_real)) < v_title_gap))
                AND (v_track_gap  = 0 OR TIMESTAMPDIFF(SECOND, s.date_played,   v_real) >= v_track_gap)
                AND (v_artist_gap = 0 OR TIMESTAMPDIFF(SECOND, s.artist_played, v_real) >= v_artist_gap)
                AND (v_title_gap  = 0 OR TIMESTAMPDIFF(SECOND, s.title_played,  v_real) >= v_title_gap)
              ORDER BY
                (SELECT COUNT(*) FROM schedule u
                   WHERE u.schedule_date = p_date AND u.song_id = s.ID) ASC,
                s.date_played ASC, s.count_played ASC
              LIMIT 1;
          END;

          IF v_song IS NOT NULL THEN
              UPDATE schedule
              SET song_id = v_song, runtime = v_dur, artist = v_artist, title = v_title
              WHERE id = v_id;

              SET p_filled = p_filled + 1;
          END IF;
      END LOOP;
      CLOSE cur;

      SET p_unfilled = v_seen - p_filled;
  END//
DELIMITER ;

DELIMITER //
CREATE PROCEDURE `ScheduleRecalculateAirtime`(
    IN  `p_date`      DATE,
    IN  `p_from_hour` INT,
    OUT `p_slots`     INT
)
BEGIN
    SET p_slots = 0;

    IF p_date IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'ScheduleRecalculateAirtime: p_date is NULL';
    END IF;

    IF p_from_hour IS NULL OR p_from_hour < 0 OR p_from_hour > 23 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'ScheduleRecalculateAirtime: p_from_hour must be 0-23';
    END IF;

    -- Safe per-hour: the window partitions on (schedule_date, hour), so
    -- hours below p_from_hour cannot influence hours above it.
    --
    -- The derived table is not a style choice. A window function cannot
    -- be merged into the outer UPDATE, and that is exactly what stops
    -- MySQL raising 1093 for reading `schedule` while writing it. Do
    -- not rewrite this as a correlated subquery.
    --
    -- Unfilled slots have runtime NULL and SUM skips them, so they
    -- contribute 0. Deliberate: SchedulePushPlaylist requires
    -- song_id IS NOT NULL, so an unfilled slot never airs and must not
    -- push the following slots later. airtime is the predicted on-air
    -- offset, not the planned clock position. Do not COALESCE this to
    -- average_runtime.
    UPDATE schedule sch
    JOIN (
        SELECT
            ID,
            ROUND(COALESCE(SUM(runtime) OVER (
                PARTITION BY schedule_date, `hour`
                ORDER BY `order`
                ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING), 0)) AS a
        FROM schedule
        WHERE schedule_date = p_date
          AND `hour` >= p_from_hour
    ) x ON x.ID = sch.ID
    SET sch.airtime = x.a;

    -- Rows in scope, not rows changed. ROW_COUNT() after UPDATE counts
    -- only rows whose value actually differed, so a recompute that
    -- confirms existing values would report 0 and look like a failure.
    SELECT COUNT(*) INTO p_slots
    FROM schedule
    WHERE schedule_date = p_date
      AND `hour` >= p_from_hour;
END//
DELIMITER ;


DELIMITER //
CREATE PROCEDURE `ScheduleResolveSql`(
    IN  `p_date`      DATE,
    IN  `p_from_hour` INT,
    OUT `p_resolved`  INT,
    OUT `p_failed`    INT
)
BEGIN
    DECLARE done INT DEFAULT 0;
    DECLARE v_slot INT;
    DECLARE v_sql TEXT;

    DECLARE cur CURSOR FOR
        SELECT ID, entry_data
        FROM schedule
        WHERE schedule_date = p_date
          AND `hour` >= p_from_hour
          AND entry_type = 2
          AND song_id IS NULL
          AND entry_data IS NOT NULL
        ORDER BY `hour`, `order`;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

    SET p_resolved = 0;
    SET p_failed = 0;

    IF p_from_hour IS NULL OR p_from_hour < 0 OR p_from_hour > 23 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'ScheduleResolveSql: p_from_hour must be 0-23';
    END IF;

    OPEN cur;
    read_loop: LOOP
        FETCH cur INTO v_slot, v_sql;
        IF done THEN LEAVE read_loop; END IF;

        SET @_sched_song := NULL;

        -- The stored statement ends in a semicolon and may open with a
        -- comment. Strip the terminator and wrap it as a derived table;
        -- the newlines keep a leading -- comment from swallowing the
        -- rest of the line.
        SET @_q := CONCAT('SELECT t.ID INTO @_sched_song FROM (\n',
                          TRIM(TRAILING ';' FROM TRIM(v_sql)),
                          '\n) t LIMIT 1');

        BEGIN
            -- Both handlers are needed. SQLEXCEPTION catches a broken
            -- statement; NOT FOUND shadows the cursor's handler, which
            -- would otherwise see this SELECT return no rows and end
            -- the loop early.
            DECLARE CONTINUE HANDLER FOR SQLEXCEPTION SET @_sched_song = NULL;
            DECLARE CONTINUE HANDLER FOR NOT FOUND    SET @_sched_song = NULL;

            PREPARE _stmt FROM @_q;
            EXECUTE _stmt;
            DEALLOCATE PREPARE _stmt;
        END;

        IF @_sched_song IS NOT NULL THEN
            UPDATE schedule sch
            JOIN songs s ON s.ID = @_sched_song
            SET sch.song_id = s.ID, sch.runtime = s.duration,
                sch.artist  = s.artist, sch.title = s.title
            WHERE sch.ID = v_slot;

            SET p_resolved = p_resolved + ROW_COUNT();
        ELSE
            SET p_failed = p_failed + 1;
        END IF;
    END LOOP;
    CLOSE cur;
END//
DELIMITER ;

-- ===== playout ========================================================


DELIMITER //
CREATE PROCEDURE `SchedulePushPlaylist`(
    IN `p_date` DATE,
    IN `p_hour` INT
)
BEGIN
    DECLARE v_pushed INT DEFAULT 0;
    DECLARE v_playlist INT DEFAULT NULL;
    DECLARE v_msg VARCHAR(255);

    DECLARE done INT DEFAULT 0;
    DECLARE v_slot INT;
    DECLARE v_req INT;
    DECLARE v_req_song INT;

    DECLARE cur CURSOR FOR
        SELECT ID FROM schedule
        WHERE schedule_date = p_date AND `hour` = p_hour
          AND entry_type = 4 AND song_id IS NULL
        ORDER BY `order`;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 v_msg = MESSAGE_TEXT;
        ROLLBACK;
        INSERT INTO schedule_log (event, schedule_date, `hour`, ok, message)
        VALUES ('push_hour', p_date, p_hour, 0, v_msg);
    END;

    SELECT playlist_id INTO v_playlist FROM scheduler_config WHERE ID = 1;

    IF v_playlist IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'scheduler_config row 1 is missing - run 011 seed';
    END IF;

    -- Requests first, so the INSERT below sees them as ordinary songs.
    -- A request slot with nothing pending stays NULL and is skipped;
    -- the hour is simply one item shorter, which is correct.
    OPEN cur;
    req_loop: LOOP
        FETCH cur INTO v_slot;
        IF done THEN LEAVE req_loop; END IF;

        SET v_req = NULL;

        BEGIN
            DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_req = NULL;
            SELECT r.ID, r.songID INTO v_req, v_req_song
            FROM requests r
            JOIN songs s ON s.ID = r.songID AND s.enabled = 1
            WHERE r.played = 0
            ORDER BY r.requested ASC
            LIMIT 1;
        END;

        IF v_req IS NOT NULL THEN
            UPDATE schedule sch
            JOIN songs s ON s.ID = v_req_song
            SET sch.song_id = s.ID, sch.runtime = s.duration,
                sch.artist  = s.artist, sch.title = s.title
            WHERE sch.ID = v_slot;

            UPDATE requests SET played = 1 WHERE ID = v_req;
        END IF;
    END LOOP;
    CLOSE cur;

    START TRANSACTION;

    DELETE FROM playlists_list WHERE pID = v_playlist;

    INSERT INTO playlists_list
        (pID, sID, cstart, cnext, cend, fin, fout, swID, swplay, vtID, vtplay, swfirst, ord)
    SELECT v_playlist,
            IF(sch.entry_type = 3, -100, sch.song_id),
            IF(sch.entry_type = 3, 0, SongsCueValue(s.cue_times, 'sta')),
            IF(sch.entry_type = 3, 0, SongsCueValue(s.cue_times, 'xta')),
            IF(sch.entry_type = 3, 0, SongsCueValue(s.cue_times, 'end')),
            IF(sch.entry_type = 3, 0, SongsCueValue(s.cue_times, 'fin')),
            IF(sch.entry_type = 3, 0, SongsCueValue(s.cue_times, 'fou')),
            IF(sch.entry_type = 3, sch.event_id, 0),
            -100, 0, -100, 0,
            sch.`order`
    FROM schedule sch
    LEFT JOIN songs s ON s.ID = sch.song_id
    WHERE sch.schedule_date = p_date
      AND sch.hour = p_hour
      AND (sch.entry_type = 3 OR sch.song_id IS NOT NULL)
    ORDER BY sch.`order`;

    SET v_pushed = ROW_COUNT();

    COMMIT;

    INSERT INTO schedule_log (event, schedule_date, `hour`, pushed, ok, message)
    VALUES ('push_hour', p_date, p_hour, v_pushed,
            v_pushed > 0,
            IF(v_pushed > 0, NULL,
               'no scheduled tracks for this hour - RadioDJ will run on its own rotation'));
END//
DELIMITER ;
DELIMITER //
CREATE PROCEDURE `SubcategoryRecalculateRuntimes`()
    COMMENT 'Recompute subcategory.average_runtime from the library. Run before a day build.'
BEGIN
    UPDATE subcategory s
    JOIN (
        SELECT id_subcat, ROUND(AVG(duration), 2) AS average_runtime
        FROM songs
        WHERE song_type IN (0, 1)
        GROUP BY id_subcat
    ) x ON x.id_subcat = s.ID
    SET s.average_runtime = x.average_runtime;
END//
DELIMITER ;
DELIMITER ;


DELIMITER //
CREATE PROCEDURE `ClockGridExplain`(IN `p_date` DATE)
    COMMENT 'For one date: 24 rows of hour, clock, and which layer chose it.'
BEGIN
    DECLARE v_dow  TINYINT DEFAULT ClockGridDow(p_date);
    DECLARE v_grid INT UNSIGNED DEFAULT ClockGridResolve(p_date);

    SELECT
        p_date                                        AS on_date,
        v_dow                                         AS iso_dow,
        DAYNAME(p_date)                               AS day_name,
        h.n                                           AS `hour`,
        ClockGridClockFor(p_date, h.n)                AS clock_id,
        (SELECT name FROM clocks WHERE ID = ClockGridClockFor(p_date, h.n)) AS clock_name,
        CASE
            WHEN o.ID IS NOT NULL
                THEN CONCAT('override / ', o.name, ' (', o.recurrence, ')')
            WHEN (SELECT COUNT(*) FROM clock_grid_schedule WHERE on_date = p_date) > 0
                THEN CONCAT('programme_day / ', g.name)
            WHEN EXISTS (SELECT 1 FROM clock_grid_monthly_rules mr
                         WHERE mr.is_active = 1 AND mr.dow = v_dow AND mr.grid_id = v_grid
                           AND (mr.valid_from IS NULL OR p_date >= mr.valid_from)
                           AND (mr.valid_to   IS NULL OR p_date <= mr.valid_to)
                           AND ((mr.ordinal > 0  AND CEIL(DAYOFMONTH(p_date) / 7) = mr.ordinal)
                             OR (mr.ordinal = -1 AND DAYOFMONTH(p_date) + 7 > DAY(LAST_DAY(p_date)))))
                THEN CONCAT('monthly_rule / ', g.name)
            WHEN EXISTS (SELECT 1 FROM clock_grid_rotations r
                         WHERE r.is_active = 1 AND p_date >= r.start_date
                           AND (r.end_date IS NULL OR p_date <= r.end_date))
                THEN CONCAT('rotation / ', g.name)
            ELSE CONCAT('station_default / ', g.name)
        END                                           AS decided_by
    FROM (SELECT 0 n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3
          UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7
          UNION ALL SELECT 8 UNION ALL SELECT 9 UNION ALL SELECT 10 UNION ALL SELECT 11
          UNION ALL SELECT 12 UNION ALL SELECT 13 UNION ALL SELECT 14 UNION ALL SELECT 15
          UNION ALL SELECT 16 UNION ALL SELECT 17 UNION ALL SELECT 18 UNION ALL SELECT 19
          UNION ALL SELECT 20 UNION ALL SELECT 21 UNION ALL SELECT 22 UNION ALL SELECT 23) h
    LEFT JOIN clock_grids g ON g.ID = v_grid
    LEFT JOIN clock_overrides o ON o.ID = (
        SELECT o2.ID FROM clock_overrides o2
        WHERE o2.`hour` = h.n
          AND (o2.valid_from IS NULL OR p_date >= o2.valid_from)
          AND (o2.valid_to   IS NULL OR p_date <= o2.valid_to)
          AND CASE o2.recurrence
              WHEN 'once'   THEN o2.on_date = p_date
              WHEN 'weekly' THEN o2.dow = v_dow
              WHEN 'nweekly' THEN o2.dow = v_dow
                  AND MOD(FLOOR(DATEDIFF(
                          DATE_SUB(p_date,         INTERVAL WEEKDAY(p_date)         DAY),
                          DATE_SUB(o2.anchor_date, INTERVAL WEEKDAY(o2.anchor_date) DAY)
                      ) / 7), o2.every_n) = 0
              WHEN 'monthly_nth_dow' THEN o2.dow = v_dow
                  AND ((o2.nth > 0  AND CEIL(DAYOFMONTH(p_date) / 7) = o2.nth)
                    OR (o2.nth = -1 AND DAYOFMONTH(p_date) + 7 > DAY(LAST_DAY(p_date))))
              WHEN 'monthly_day' THEN o2.day_of_month = DAYOFMONTH(p_date)
              ELSE 0 END
        ORDER BY o2.priority DESC, o2.ID ASC LIMIT 1)
    ORDER BY h.n;
END//
DELIMITER ;


-- =====================================================================
-- 11. ClockGridFill — paint a whole grid from one clock
--
-- 168 cells is a lot to type. This gives a grid a uniform starting
-- state you then differentiate. Idempotent per cell.
-- =====================================================================


DELIMITER //
CREATE PROCEDURE `ClockGridFill`(
    IN  `p_grid`  INT UNSIGNED,
    IN  `p_clock` INT UNSIGNED,
    OUT `p_cells` INT
)
    COMMENT 'Set every one of a grid''s 168 cells to one clock. Overwrites.'
BEGIN
    DECLARE d TINYINT DEFAULT 1;
    DECLARE h TINYINT DEFAULT 0;

    SET p_cells = 0;

    IF (SELECT COUNT(*) FROM clock_grids WHERE ID = p_grid) = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'ClockGridFill: grid does not exist';
    END IF;
    IF (SELECT COUNT(*) FROM clocks WHERE ID = p_clock AND rotation_id IS NOT NULL) = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'ClockGridFill: clock does not exist or has no rotation';
    END IF;

    WHILE d <= 7 DO
        SET h = 0;
        WHILE h < 24 DO
            INSERT INTO clock_grid_hours (grid_id, dow, `hour`, clock_id)
            VALUES (p_grid, d, h, p_clock)
            ON DUPLICATE KEY UPDATE clock_id = VALUES(clock_id);
            SET p_cells = p_cells + 1;
            SET h = h + 1;
        END WHILE;
        SET d = d + 1;
    END WHILE;
END//
DELIMITER ;
DELIMITER ;

DELIMITER //
CREATE EVENT `ScheduleNextDay`
ON SCHEDULE EVERY 1 DAY STARTS '2026-06-22 23:30:00'
ON COMPLETION PRESERVE ENABLE
DO BEGIN
    DECLARE v_next DATE DEFAULT NULL;
    DECLARE v_slots INT DEFAULT 0;
    DECLARE v_sql_ok INT DEFAULT 0;
    DECLARE v_sql_bad INT DEFAULT 0;
    DECLARE v_filled INT DEFAULT 0;
    DECLARE v_unfilled INT DEFAULT 0;
    DECLARE v_fb_filled INT DEFAULT 0;
    DECLARE v_fb_unfilled INT DEFAULT 0;
    DECLARE v_air INT DEFAULT 0;
    DECLARE v_msg VARCHAR(255);

    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        GET DIAGNOSTICS CONDITION 1 v_msg = MESSAGE_TEXT;
        INSERT INTO schedule_log
            (event, schedule_date, slots, filled, unfilled, fb_filled, fb_unfilled, ok, message)
        VALUES ('build_day', v_next, v_slots, v_filled, v_unfilled,
                v_fb_filled, v_fb_unfilled, 0, v_msg);
        RESIGNAL;
    END;

    SET v_next = DATE_ADD(CURDATE(), INTERVAL 1 DAY);

    CALL ScheduleBuildSkeleton(v_next, 0, v_slots);
    CALL ScheduleResolveSql(v_next, 0, v_sql_ok, v_sql_bad);
    CALL ScheduleFill(v_next, v_filled, v_unfilled);
    CALL ScheduleFillFallback(v_next, v_fb_filled, v_fb_unfilled);
    CALL ScheduleRecalculateAirtime(v_next, 0, v_air);

    INSERT INTO schedule_log
        (event, schedule_date, slots, filled, unfilled, fb_filled, fb_unfilled, ok, message)
    VALUES ('build_day', v_next, v_slots, v_filled + v_sql_ok, v_unfilled,
            v_fb_filled, v_fb_unfilled, 1,
            IF(v_sql_bad > 0, CONCAT(v_sql_bad, ' SQL rotation entries failed to resolve'), NULL));
END//
DELIMITER ;

DELIMITER //
CREATE EVENT `SchedulePushPlaylist` ON SCHEDULE EVERY 1 HOUR STARTS '2026-07-23 00:59:10' ON COMPLETION PRESERVE ENABLE COMMENT 'Calculate current date and next hour for Schedule push' DO BEGIN
	DECLARE v_hour INT;
	DECLARE v_date DATE;
	
	SET v_hour = (HOUR(NOW()) + 1) % 24;
	SET v_date = IF(v_hour = 0, DATE_ADD(CURDATE(),INTERVAL 1 DAY), CURDATE());
	
	CALL SchedulePushPlaylist(v_date,v_hour);
END//
DELIMITER ;

DELIMITER //
CREATE EVENT `SubcategoryRecalculateRuntimes` ON SCHEDULE EVERY 1 DAY STARTS '2026-06-22 23:25:00' ON COMPLETION PRESERVE ENABLE COMMENT 'Recalculate average runtimes per category' DO BEGIN
	CALL `SubcategoryRecalculateRuntimes`();
END//
DELIMITER ;

DELIMITER //
CREATE TRIGGER `SongsInsert` BEFORE INSERT ON `songs` FOR EACH ROW BEGIN
	DECLARE randomSeconds INT;
	SET randomSeconds = FLOOR(RAND() * 28800);
	
	IF NEW.date_played = '2002-01-01 00:00:01' THEN
		SET NEW.date_played = DATE_SUB(NOW(),INTERVAL randomSeconds SECOND);
	END IF;
	
	IF NEW.title_played = '2002-01-01 00:00:01' THEN
		SET NEW.title_played = DATE_SUB(NOW(),INTERVAL randomSeconds SECOND);
	END IF;
END//
DELIMITER ;


-- =====================================================================
-- CONFIGURE BEFORE USE — the install is inert until this row exists.
--
-- Every procedure reads scheduler_config row 1 and signals
-- 'scheduler_config row 1 is missing' if it is absent. That is on
-- purpose: a fresh install refusing to run beats one quietly writing
-- to another station's playlist ID.
--
-- Look up the real IDs on THIS station first — the defaults below are
-- one station's values and mean nothing anywhere else.
-- =====================================================================

-- SELECT ID, name FROM category  ORDER BY ID;   -- music / jingle parents
-- SELECT ID, name FROM playlists ORDER BY ID;   -- the playout playlist

-- INSERT INTO `scheduler_config`
--     (`ID`, `playlist_id`, `music_parentid`, `jingle_parentid`, `jingle_catid`)
-- VALUES (1, <playlist_id>, <music>, <jingle>, <jingle_cat>);
--
-- playlist_id must match the playlist RadioDJ's own hourly loader
-- event pulls (type 2, data `Load Playlist|<pos>|<id>|<name>|Top`).
-- Do not copy a value from any dump — dumps drift from live.

-- THE CLOCK GRID MUST BE PAINTED BEFORE THE FIRST BUILD.
-- This file creates the grid tables but cannot seed them: it also
-- creates `clocks`, so at this point there is no clock to reference.
-- After you have created your clocks:
--
--   INSERT INTO `clock_grids` (`name`, `is_default`)
--   VALUES ('Regular', 1);
--   CALL ClockGridFill(LAST_INSERT_ID(), <your main clock ID>, @cells);
--
-- That gives one clock every hour of every day — correct for a station
-- running a single grid, and the starting point for one that is not.
-- Then differentiate cells, and read a date back before trusting it:
--
--   CALL ClockGridExplain(CURDATE() + INTERVAL 3 DAY);
--
-- Until a default grid exists with all 168 cells, ScheduleBuildSkeleton
-- signals 'no grid resolves for <date>' rather than guessing.
-- README.md has the full model.

-- Separation is per rotation rule, not per station. The defaults
-- 25200/7200/4200 (music) and 4200/1800/0 (everything else), in
-- seconds, are declared inside ScheduleFill and ScheduleFillFallback
-- and apply only where a rule leaves that dimension at 0. Set
-- rotations_list.repeatRule and the three *_separation columns from
-- RadioDJ's rotation editor; they arrive here on the next clock build.
-- repeatRule = 0 means no separation window at all for that rule --
-- the slot takes the least recently played eligible track.

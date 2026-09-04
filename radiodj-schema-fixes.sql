-- =====================================================================
-- RadioDJ schema fixes - every correction we make to RadioDJ's OWN
-- schema, in one re-runnable file.
--
-- Target: RadioDJ 3.0.0.2 / MySQL 8.0.x / ANY station.
--
-- WHY THIS FILE EXISTS AND MUST NOT BE DELETED
--
-- Everything here fixes a defect in the schema RadioDJ ships, not in
-- anything we built. That matters for one reason: **a RadioDJ upgrade
-- can ship its own schema migration and revert any of it.** When that
-- happens there is no error, no log line, and no symptom until a title
-- gets truncated in `history` or a rotation rule refuses to save.
--
-- So this is not a migration. Migrations are history and were deleted
-- once every station was aligned. This is a **standing repair kit**:
--
--     RUN IT AFTER EVERY RadioDJ VERSION UPGRADE, ON EVERY STATION,
--     AND READ SECTION 9.
--
-- It is also what a brand-new station needs before anything else - a
-- fresh RadioDJ install has all five defects.
--
-- STATION-AGNOSTIC BY DESIGN. There is no `USE` statement and no
-- database name anywhere. Everything keys on `DATABASE()`, including
-- the `ALTER DATABASE`, which is built dynamically for that reason.
-- Select the target database in your client first.
--
-- Applies to every station, including ones added later. Not every station needs every fix; each one is guarded
-- and reports itself as APPLIED or ALREADY OK.
--
-- SAFE TO RE-RUN. Every step checks information_schema before firing.
-- No `DELIMITER`: this file defines no routines, so it runs from any
-- client, not just HeidiSQL.
--
-- BEFORE YOU RUN
--   * Take a dump:
--       mysqldump -u root -p --single-transaction --routines --events \
--         <station> > <station>-before-fixes.sql
--   * Fix 2 takes a brief metadata lock on `history`. RadioDJ keeps
--     playing; it just cannot write history for that instant.
--   * Nothing here touches the scheduler, our tables, or any data.
--     Fixes 1, 3, 4 and 5 are metadata-only.
-- =====================================================================


-- =====================================================================
-- 1. PRE-FLIGHT - the current state of all five fixes
-- =====================================================================

SELECT
    (SELECT DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA
      WHERE SCHEMA_NAME = DATABASE())                       AS db_collation,
    (SELECT CHARACTER_MAXIMUM_LENGTH FROM information_schema.COLUMNS
      WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'history'
        AND COLUMN_NAME = 'artist')                         AS history_artist_len,
    (SELECT COUNT(*) FROM information_schema.COLUMNS
      WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'rotations_list'
        AND COLUMN_NAME IN ('catID','subID','genID')
        AND COLUMN_TYPE LIKE '%unsigned%')                  AS rotation_cols_unsigned,
    (SELECT COLUMN_TYPE FROM information_schema.COLUMNS
      WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'playlists_list'
        AND COLUMN_NAME = 'sID')                            AS playlists_sid_type,
    (SELECT COLUMN_DEFAULT FROM information_schema.COLUMNS
      WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'songs'
        AND COLUMN_NAME = 'lang')                           AS songs_lang_default;

-- Any table off the house collation. Expect zero rows. This is a
-- REPORT, not a fix - converting a table is not always what you want,
-- and on our own appended tables it would mask a missing explicit
-- COLLATE rather than fix it. If a row appears, look at why before
-- running CONVERT TO on it.
SELECT TABLE_NAME, TABLE_COLLATION
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = DATABASE()
  AND TABLE_COLLATION IS NOT NULL
  AND TABLE_COLLATION <> 'utf8mb4_unicode_ci';

-- How much history already sits at the 200-char ceiling. These rows
-- were truncated on insert; fix 2 cannot recover them, only stop
-- future loss. Skip if history_artist_len already reads 250.
SELECT SUM(CHAR_LENGTH(artist)          >= 200) AS artist_at_limit,
       SUM(CHAR_LENGTH(original_artist) >= 200) AS orig_artist_at_limit,
       SUM(CHAR_LENGTH(title)           >= 200) AS title_at_limit,
       SUM(CHAR_LENGTH(album)           >= 200) AS album_at_limit,
       SUM(CHAR_LENGTH(composer)        >= 200) AS composer_at_limit,
       SUM(CHAR_LENGTH(publisher)       >= 200) AS publisher_at_limit,
       SUM(CHAR_LENGTH(copyright)       >= 200) AS copyright_at_limit,
       SUM(CHAR_LENGTH(isrc)            >= 200) AS isrc_at_limit,
       COUNT(*)                                 AS history_rows
FROM history;

-- Range check for fix 3. Converting unsigned to signed halves the
-- ceiling to 2147483647; under STRICT_TRANS_TABLES an over-range value
-- would error rather than clamp. Category, subcategory and genre IDs
-- are small integers, so this is a formality worth proving.
SELECT COUNT(*) AS rotation_entries,
       MAX(catID) AS max_catid, MAX(subID) AS max_subid, MAX(genID) AS max_genid,
       SUM(catID < 0) AS special_entries
FROM rotations_list;


-- =====================================================================
-- 2. FIX 1 - database default collation
--
-- RadioDJ creates the database without specifying a collation, so it
-- inherits the MySQL 8 server default `utf8mb4_0900_ai_ci` while every
-- table RadioDJ then creates is `utf8mb4_unicode_ci`.
--
-- The mismatch is invisible until someone appends a table without an
-- explicit COLLATE. That table inherits the database default, and the
-- first text join against a RadioDJ table throws
--     ERROR 1267 Illegal mix of collations
-- (a table created without an explicit COLLATE inherits the database default and throws 'Illegal mix of collations' on its first text join). Every table we add carries an explicit COLLATE for this
-- reason, but the database default is the trap underneath it, and a
-- trap you have to remember is a trap.
--
-- Existing tables are NOT touched - this only changes what a future
-- bare CREATE TABLE inherits. Instant, metadata-only, and naturally
-- idempotent, so it needs no guard.
--
-- THE DATABASE NAME IS DELIBERATELY OMITTED. `ALTER DATABASE` takes an
-- optional name and applies to the currently selected database when it
-- is left out - which is what keeps this file station-agnostic.
--
-- Do not "improve" this into a guarded PREPARE like the other four
-- fixes. ALTER DATABASE cannot go through the prepared-statement
-- protocol at all:
--     ERROR 1295 This command is not supported in the prepared
--                statement protocol yet
-- and CONCAT-ing DATABASE() into a prepared string hits exactly that.
-- Measured on MySQL 8.0.45.
--
-- Select the right database in your client before running this file.
-- =====================================================================

ALTER DATABASE CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;


-- =====================================================================
-- 3. FIX 2 - widen history text columns 200 -> 250
--
-- RadioDJ declares these eight columns at varchar(200) in `history`
-- and varchar(250) in `songs`. Every insert into history therefore
-- truncates silently at 200 characters. Long classical titles and
-- multi-artist credits are the usual casualties.
--
-- All 8 in ONE statement = one operation, not eight.
--
-- NOT changed: `label` is already 250; `year` is varchar(4) and is the
-- unknown-year sentinel column, leave it alone (songs.year is varchar(4) and '1900' is the unknown-year sentinel, not a real year).
--
-- NOT NULL and COLLATE are restated because MySQL's MODIFY replaces
-- the entire column definition - omitting them would silently make
-- these columns nullable.
--
-- ALGORITHM=INPLACE, LOCK=NONE is a safety assertion, not an
-- optimisation. utf8mb4 at 200 chars = 800 bytes and at 250 = 1000
-- bytes; both use a 2-byte length prefix, so InnoDB does this in place
-- with no table rebuild. If that ever stops being true, MySQL refuses
--     ERROR 1846 ALGORITHM=INPLACE is not supported
-- instead of silently copying a million-row table under a write lock.
-- If you see 1846, find out why rather than deleting the clause.
--
-- A result of "Records: 0 ... Duration 0.000 sec" is SUCCESS, not a
-- no-op (an instant, metadata-only DDL reports Records: 0 and looks like it did nothing). Verify with section 9, never with HeidiSQL's
-- Structure tab, which caches (HeidiSQL caches table structure and keeps showing the old definition until you refresh).
-- =====================================================================

SET @sql := IF((SELECT CHARACTER_MAXIMUM_LENGTH FROM information_schema.COLUMNS
                WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'history'
                  AND COLUMN_NAME = 'artist') >= 250,
    'DO 0',
    "ALTER TABLE `history`
        MODIFY `artist`          varchar(250) COLLATE utf8mb4_unicode_ci NOT NULL,
        MODIFY `original_artist` varchar(250) COLLATE utf8mb4_unicode_ci NOT NULL,
        MODIFY `title`           varchar(250) COLLATE utf8mb4_unicode_ci NOT NULL,
        MODIFY `album`           varchar(250) COLLATE utf8mb4_unicode_ci NOT NULL,
        MODIFY `composer`        varchar(250) COLLATE utf8mb4_unicode_ci NOT NULL,
        MODIFY `publisher`       varchar(250) COLLATE utf8mb4_unicode_ci NOT NULL,
        MODIFY `copyright`       varchar(250) COLLATE utf8mb4_unicode_ci NOT NULL,
        MODIFY `isrc`            varchar(250) COLLATE utf8mb4_unicode_ci NOT NULL,
        ALGORITHM=INPLACE, LOCK=NONE");
PREPARE s FROM @sql; EXECUTE s; DEALLOCATE PREPARE s;


-- =====================================================================
-- 4. FIX 3 - rotations_list.catID / subID / genID must be SIGNED
--
-- THE MOST CONSEQUENTIAL FIX IN THIS FILE. Found on a live station
-- where all three columns were `int unsigned`.
--
-- rotations_list reuses catID as a type marker. A negative catID means
-- the rotation entry is not a subcategory at all:
--
--     -50    an SQL query        (the statement lives in `data`)
--     -10    a manual event      (events.ID lives in subID)
--     -100   a listener request
--
-- and the row then carries the SAME sentinel in subID AND genID.
--
-- On an unsigned column under STRICT_TRANS_TABLES - which is the MySQL
-- 8 default and what production runs - the write does not clamp, it
-- FAILS:
--     ERROR 1264 Out of range value for column 'catID' at row 1
-- Measured, not inferred. So RadioDJ simply cannot save an SQL,
-- manual-event or request rotation rule on such a station. There are
-- no bad rows to find, because there are no rows.
--
-- And the scheduler resolves entry type with `IF(rl.catID < 0, ...)`,
-- a test that is unreachable on an unsigned column - so an entry that
-- did somehow land would be built as a real subcategory with subID 0,
-- matching nothing, and the slot would silently never fill.
--
-- Migration 012 existed because of this data model; 016 existed
-- because genID got copied into an unsigned column and overflowed in
-- production (rotations_list reuses catID, subID and genID as signed sentinels).
--
-- No foreign key references any of these columns, so a plain MODIFY is
-- safe. Verify with the range check in section 1 first.
-- =====================================================================

SET @sql := IF((SELECT COUNT(*) FROM information_schema.COLUMNS
                WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'rotations_list'
                  AND COLUMN_NAME IN ('catID','subID','genID')
                  AND COLUMN_TYPE LIKE '%unsigned%') = 0,
    'DO 0',
    "ALTER TABLE `rotations_list`
        MODIFY `catID` int NOT NULL COMMENT 'Negative = special entry: -50 SQL, -10 manual event, -100 request. MUST stay signed.',
        MODIFY `subID` int NOT NULL COMMENT 'Subcategory ID, or the same sentinel as catID on a special entry.',
        MODIFY `genID` int NOT NULL COMMENT 'Genre filter, 0 = any. Carries the catID sentinel on a special entry.'");
PREPARE s FROM @sql; EXECUTE s; DEALLOCATE PREPARE s;


-- =====================================================================
-- 5. FIX 4 - playlists_list.sID signedness
--
-- `int unsigned` on some stations, `int` on others. Cosmetic: song IDs
-- are always positive and nothing writes a negative one. Aligned only
-- so a schema diff between two stations comes back empty and therefore
-- stays worth running.
-- =====================================================================

SET @sql := IF((SELECT COLUMN_TYPE FROM information_schema.COLUMNS
                WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'playlists_list'
                  AND COLUMN_NAME = 'sID') NOT LIKE '%unsigned%',
    'DO 0',
    'ALTER TABLE `playlists_list` MODIFY `sID` int NOT NULL');
PREPARE s FROM @sql; EXECUTE s; DEALLOCATE PREPARE s;


-- =====================================================================
-- 6. FIX 5 - songs.lang default
--
-- 'Not Set' on some stations, 'und' on others. RadioDJ writes 'und'
-- (ISO 639-2 for undetermined) for a track with no language tag, and
-- 'und' is the value our library tooling treats as the sentinel.
--
-- Affects only rows inserted from now on. Existing rows are left
-- alone deliberately - a blanket UPDATE would overwrite real language
-- tags on stations where language is actually curated.
-- =====================================================================

SET @sql := IF((SELECT COLUMN_DEFAULT FROM information_schema.COLUMNS
                WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'songs'
                  AND COLUMN_NAME = 'lang') = 'und',
    'DO 0',
    "ALTER TABLE `songs` MODIFY `lang` varchar(150) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT 'und'");
PREPARE s FROM @sql; EXECUTE s; DEALLOCATE PREPARE s;


-- =====================================================================
-- 9. VERIFY - read this. All five must say OK.
-- =====================================================================

SELECT 'fix 1  db default collation' AS fix,
       (SELECT DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA
         WHERE SCHEMA_NAME = DATABASE()) AS value,
       IF((SELECT DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA
            WHERE SCHEMA_NAME = DATABASE()) = 'utf8mb4_unicode_ci',
          'OK', 'FAILED') AS status
UNION ALL
SELECT 'fix 2  history text widths',
       CONCAT((SELECT COUNT(*) FROM information_schema.COLUMNS
                WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'history'
                  AND COLUMN_NAME IN ('artist','original_artist','title','album',
                                      'composer','publisher','copyright','isrc')
                  AND CHARACTER_MAXIMUM_LENGTH = 250), ' of 8 at 250'),
       IF((SELECT COUNT(*) FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'history'
              AND COLUMN_NAME IN ('artist','original_artist','title','album',
                                  'composer','publisher','copyright','isrc')
              AND CHARACTER_MAXIMUM_LENGTH = 250) = 8, 'OK', 'FAILED')
UNION ALL
SELECT 'fix 2b history NOT NULL kept',
       CONCAT((SELECT COUNT(*) FROM information_schema.COLUMNS
                WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'history'
                  AND COLUMN_NAME IN ('artist','original_artist','title','album',
                                      'composer','publisher','copyright','isrc')
                  AND IS_NULLABLE = 'NO'), ' of 8 NOT NULL'),
       IF((SELECT COUNT(*) FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'history'
              AND COLUMN_NAME IN ('artist','original_artist','title','album',
                                  'composer','publisher','copyright','isrc')
              AND IS_NULLABLE = 'NO') = 8, 'OK', 'FAILED')
UNION ALL
SELECT 'fix 3  rotation sentinels signed',
       CONCAT((SELECT COUNT(*) FROM information_schema.COLUMNS
                WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'rotations_list'
                  AND COLUMN_NAME IN ('catID','subID','genID')
                  AND COLUMN_TYPE LIKE '%unsigned%'), ' still unsigned'),
       IF((SELECT COUNT(*) FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'rotations_list'
              AND COLUMN_NAME IN ('catID','subID','genID')
              AND COLUMN_TYPE LIKE '%unsigned%') = 0, 'OK', 'FAILED')
UNION ALL
SELECT 'fix 4  playlists_list.sID',
       (SELECT COLUMN_TYPE FROM information_schema.COLUMNS
         WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'playlists_list'
           AND COLUMN_NAME = 'sID'),
       IF((SELECT COLUMN_TYPE FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'playlists_list'
              AND COLUMN_NAME = 'sID') NOT LIKE '%unsigned%', 'OK', 'FAILED')
UNION ALL
SELECT 'fix 5  songs.lang default',
       (SELECT COLUMN_DEFAULT FROM information_schema.COLUMNS
         WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'songs'
           AND COLUMN_NAME = 'lang'),
       IF((SELECT COLUMN_DEFAULT FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'songs'
              AND COLUMN_NAME = 'lang') = 'und', 'OK', 'FAILED');


-- =====================================================================
-- ROLLBACK
--
-- There is no reason to roll any of this back. Each fix corrects a
-- defect and none changes behaviour RadioDJ depends on. If you must:
--
--   fix 1  ALTER DATABASE <station> CHARACTER SET utf8mb4
--              COLLATE utf8mb4_0900_ai_ci;
--   fix 2  MODIFY the 8 columns back to varchar(200) - ONLY if no row
--          now exceeds 200 chars, because narrowing truncates silently
--          in non-strict mode and errors in strict mode. Check with
--          the section 1 query first.
--   fix 3  MODIFY catID/subID/genID back to int unsigned. Do NOT,
--          unless you are also removing the scheduler: it depends on
--          the signed form, and RadioDJ itself cannot store a special
--          rotation entry without it.
--   fix 4  MODIFY sID back to int unsigned.
--   fix 5  MODIFY lang default back to 'Not Set'.
--
-- In practice the rollback is the dump you took before running.
-- =====================================================================

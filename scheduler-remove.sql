-- =====================================================================
-- Custom scheduler — full teardown
-- Pair of scheduler-create.sql. Regenerated 2026-08-31.
--
-- The previous version failed on its first statement: it dropped
-- `clocks` while `clocks_list` still held FK_clock_list_clocks, which
-- MySQL refuses (errno 3730). It also predated schedule_log,
-- ScheduleRecalculateAirtime and ClocksListBuildFromClock, so it left
-- objects behind and the create script then failed on re-run.
--
-- Order here is deliberate and no FOREIGN_KEY_CHECKS override is used:
-- events before the procedures they call, children before parents,
-- clocks_list before both clocks and the subcategory columns it
-- references. If a statement errors, the order is wrong — fix the
-- order, do not disable the checks.
--
-- THIS DELETES YOUR CLOCKS, YOUR SCHEDULE AND YOUR LOG. Back up first:
--   mysqldump -u root -p --single-transaction --routines --events \
--     <database> > backup-before-teardown.sql
-- =====================================================================

-- No USE statement, on purpose: select the target database in your
-- client before running this, so the same file works unchanged on
-- every station. All lookups key on DATABASE().


-- ===== events (call the procedures, so they go first) =================
DROP EVENT IF EXISTS `ScheduleNextDay`;
DROP EVENT IF EXISTS `SchedulePushPlaylist`;
DROP EVENT IF EXISTS `SubcategoryRecalculateRuntimes`;

-- ===== triggers =======================================================
DROP TRIGGER IF EXISTS `SongsInsert`;

-- ===== procedures and functions =======================================
DROP PROCEDURE IF EXISTS `ClockGridExplain`;
DROP PROCEDURE IF EXISTS `ClockGridFill`;
DROP PROCEDURE IF EXISTS `ClocksListBulidFromRotation`;   -- pre-008 name, dead since 008
DROP PROCEDURE IF EXISTS `ClocksListBuildDay`;            -- removed by 020
DROP PROCEDURE IF EXISTS `ClocksListBuildFromClock`;      -- removed by 020
DROP PROCEDURE IF EXISTS `ScheduleBuildSkeleton`;
DROP PROCEDURE IF EXISTS `ScheduleFill`;
DROP PROCEDURE IF EXISTS `ScheduleFillFallback`;
DROP PROCEDURE IF EXISTS `ScheduleRecalculateAirtime`;
DROP PROCEDURE IF EXISTS `ScheduleResolveSql`;
DROP PROCEDURE IF EXISTS `SchedulePushPlaylist`;
DROP PROCEDURE IF EXISTS `SubcategoryRecalculateRuntimes`;
DROP FUNCTION  IF EXISTS `SongsCueValue`;

DROP FUNCTION IF EXISTS `ClockGridClockFor`;
DROP FUNCTION IF EXISTS `ClockGridCellClock`;
DROP FUNCTION IF EXISTS `ClockGridResolve`;
DROP FUNCTION IF EXISTS `ClockGridDow`;

-- ===== tables =========================================================
-- clocks_list holds FKs to clocks and to subcategory, so it goes
-- before both the clocks drop and the subcategory ALTER below.
-- clocks_list, its trigger, its build procedures and its 23:20 event
-- were removed by the release that removed the template table — ScheduleBuildSkeleton resolves the
-- grid directly now. The drops above cover a station still on 019.
--
-- The grid tables go before `clocks`: clock_grid_hours and
-- clock_overrides both carry a foreign key to it, and MySQL refuses to
-- drop a parent whose children still reference it (errno 3730). Within
-- the grid, children before parents for the same reason —
-- clock_grid_rotation_entries references both a rotation and a grid.
DROP TABLE IF EXISTS `clock_overrides`;
DROP TABLE IF EXISTS `clock_grid_rotation_entries`;
DROP TABLE IF EXISTS `clock_grid_rotations`;
DROP TABLE IF EXISTS `clock_grid_monthly_rules`;
DROP TABLE IF EXISTS `clock_grid_schedule`;
DROP TABLE IF EXISTS `clock_grid_hours`;
DROP TABLE IF EXISTS `clock_grids`;

DROP TABLE IF EXISTS `clocks_list`;   -- only on a station still at 019
DROP TABLE IF EXISTS `clocks`;
DROP TABLE IF EXISTS `schedule`;
DROP TABLE IF EXISTS `schedule_log`;
DROP TABLE IF EXISTS `scheduler_config`;

-- ===== indexes added to RadioDJ's own table ===========================
-- ix_title on `songs` exists only to make the title separation
-- subquery a lookup instead of a scan. MySQL 8 has no DROP INDEX IF
-- EXISTS, hence the guard.
SET @ix := (SELECT COUNT(*) FROM information_schema.STATISTICS
            WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'songs'
              AND INDEX_NAME = 'ix_title');
SET @sql := IF(@ix = 0, 'DO 0', 'ALTER TABLE `songs` DROP KEY `ix_title`');
PREPARE s FROM @sql; EXECUTE s; DEALLOCATE PREPARE s;

-- ===== columns added to RadioDJ's own table ===========================
-- The self-FK must go before its column, and MySQL 8 has no
-- DROP FOREIGN KEY IF EXISTS, so this is conditional on it existing.
SET @fk := (SELECT CONSTRAINT_NAME FROM information_schema.TABLE_CONSTRAINTS
            WHERE CONSTRAINT_SCHEMA = DATABASE()
              AND TABLE_NAME = 'subcategory'
              AND CONSTRAINT_NAME = 'FK_subcategory_fallback' LIMIT 1);
SET @sql := IF(@fk IS NULL, 'DO 0',
               'ALTER TABLE `subcategory` DROP FOREIGN KEY `FK_subcategory_fallback`');
PREPARE s FROM @sql; EXECUTE s; DEALLOCATE PREPARE s;

ALTER TABLE `subcategory`
    DROP COLUMN `fallback_subcategory_id`,
    DROP COLUMN `average_runtime`,
    DROP COLUMN `fill_priority`;


-- =====================================================================
-- VERIFY — all three should return zero rows
-- =====================================================================
SELECT TABLE_NAME FROM information_schema.TABLES
WHERE TABLE_SCHEMA = DATABASE()
  AND TABLE_NAME IN ('clocks','clocks_list','schedule','schedule_log','scheduler_config');

SELECT ROUTINE_NAME, ROUTINE_TYPE FROM information_schema.ROUTINES
WHERE ROUTINE_SCHEMA = DATABASE()
  AND ROUTINE_NAME IN ('ClocksListBuildDay','ClocksListBuildFromClock',
      'ClocksListBulidFromRotation','ScheduleBuildSkeleton','ScheduleFill',
      'ScheduleFillFallback','ScheduleRecalculateAirtime',
      'SchedulePushPlaylist','SubcategoryRecalculateRuntimes','SongsCueValue');

SELECT COLUMN_NAME FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'subcategory'
  AND COLUMN_NAME IN ('average_runtime','fill_priority','fallback_subcategory_id');

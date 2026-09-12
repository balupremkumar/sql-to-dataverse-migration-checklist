/*
  inventory.sql
  Section 1 of the SQL Server to Dataverse migration checklist (items 1 to 4 and 8).
  Read-only. Run it in SSMS, Azure Data Studio or sqlcmd, connected to the instance.

  Part A runs against the instance (any database).
  Part B runs against one database: set the USE line first, or run it while connected to the production database.

  Needs VIEW SERVER STATE for the usage figures and read access to msdb for backups and jobs.
  If a query fails on permissions, the rest still runs; note the gap and move on.

  MIT licence. Balu Premkumar, Kove, kove.nz. Version 1, September 2026.
*/

SET NOCOUNT ON;

/* ---------- PART A: the instance ---------- */

/* A1. Item 1: exact version and edition. Compare against kove.nz/microsoft-end-of-support-dates */
SELECT
    @@VERSION                               AS version_string,
    SERVERPROPERTY('ProductVersion')        AS product_version,
    SERVERPROPERTY('ProductLevel')          AS product_level,
    SERVERPROPERTY('Edition')               AS edition,
    SERVERPROPERTY('MachineName')           AS machine_name,
    SERVERPROPERTY('Collation')             AS collation;

/* A2. Item 2: every user database, its size, and when it was last backed up (item 9 starts here) */
SELECT
    d.name                                                          AS database_name,
    d.state_desc                                                    AS state,
    d.compatibility_level                                           AS compat_level,
    d.recovery_model_desc                                           AS recovery_model,
    CAST(SUM(CASE WHEN mf.type_desc = 'ROWS' THEN mf.size END) * 8.0 / 1024 AS decimal(12, 1)) AS data_mb,
    CAST(SUM(CASE WHEN mf.type_desc = 'LOG'  THEN mf.size END) * 8.0 / 1024 AS decimal(12, 1)) AS log_mb,
    (SELECT MAX(b.backup_finish_date) FROM msdb.dbo.backupset b
      WHERE b.database_name = d.name AND b.type = 'D')              AS last_full_backup
FROM sys.databases d
JOIN sys.master_files mf ON mf.database_id = d.database_id
WHERE d.database_id > 4
GROUP BY d.name, d.state_desc, d.compatibility_level, d.recovery_model_desc
ORDER BY d.name;

/* A3. Item 2: is each database still used? Last read or write since the service last started (counters reset on restart) */
SELECT
    DB_NAME(us.database_id)                                        AS database_name,
    MAX(us.last_user_seek)                                         AS last_seek,
    MAX(us.last_user_scan)                                         AS last_scan,
    MAX(us.last_user_update)                                       AS last_update,
    (SELECT sqlserver_start_time FROM sys.dm_os_sys_info)          AS counters_since
FROM sys.dm_db_index_usage_stats us
WHERE us.database_id > 4
GROUP BY us.database_id
ORDER BY database_name;

/* A4. Item 4: scheduled jobs (SQL Agent). Express has no Agent; an empty result there is normal */
SELECT
    j.name                                                         AS job_name,
    j.enabled,
    j.description,
    STUFF((SELECT '; ' + s.step_name + ' [' + s.subsystem + ']'
           FROM msdb.dbo.sysjobsteps s WHERE s.job_id = j.job_id
           ORDER BY s.step_id FOR XML PATH('')), 1, 2, '')         AS steps,
    (SELECT MAX(h.run_date) FROM msdb.dbo.sysjobhistory h
      WHERE h.job_id = j.job_id AND h.step_id = 0)                 AS last_run_yyyymmdd
FROM msdb.dbo.sysjobs j
ORDER BY j.name;

/* A5. Item 6: linked servers and anything else that reaches out */
SELECT name AS linked_server, product, provider, data_source
FROM sys.servers
WHERE is_linked = 1;

/* A6. Item 5: who connects right now, and with what. Run it mid-morning on a busy day, more than once */
SELECT
    s.login_name,
    s.host_name,
    s.program_name,
    DB_NAME(s.database_id)                                         AS database_name,
    COUNT(*)                                                       AS sessions,
    MAX(s.last_request_end_time)                                   AS last_request
FROM sys.dm_exec_sessions s
WHERE s.is_user_process = 1
GROUP BY s.login_name, s.host_name, s.program_name, s.database_id
ORDER BY sessions DESC;


/* ---------- PART B: one database ---------- */
/* USE [YourProductionDatabase]; */

/* B1. Item 3: row count and size on disk per table, plus the flags that matter for the load */
SELECT
    s.name + '.' + t.name                                          AS table_name,
    SUM(CASE WHEN p.index_id IN (0, 1) THEN p.row_count ELSE 0 END) AS row_count,
    CAST(SUM(p.reserved_page_count) * 8.0 / 1024 AS decimal(12, 1)) AS reserved_mb,
    CASE WHEN EXISTS (SELECT 1 FROM sys.identity_columns ic WHERE ic.object_id = t.object_id) THEN 'yes' ELSE '' END AS has_identity,
    CASE WHEN EXISTS (SELECT 1 FROM sys.columns c JOIN sys.types ty ON ty.user_type_id = c.user_type_id
                      WHERE c.object_id = t.object_id AND ty.name IN ('varbinary', 'image')) THEN 'yes' ELSE '' END AS has_blobs,
    (SELECT COUNT(*) FROM sys.foreign_keys fk WHERE fk.parent_object_id = t.object_id) AS fks_out,
    (SELECT COUNT(*) FROM sys.foreign_keys fk WHERE fk.referenced_object_id = t.object_id) AS fks_in,
    (SELECT COUNT(*) FROM sys.indexes i WHERE i.object_id = t.object_id AND i.is_unique = 1 AND i.is_primary_key = 0) AS unique_indexes,
    (SELECT COUNT(*) FROM sys.triggers tr WHERE tr.parent_id = t.object_id) AS triggers
FROM sys.tables t
JOIN sys.schemas s ON s.schema_id = t.schema_id
JOIN sys.dm_db_partition_stats p ON p.object_id = t.object_id
GROUP BY s.name, t.name, t.object_id
ORDER BY row_count DESC;

/* B2. Item 2 and 18: tables nobody has touched since the service started */
SELECT
    s.name + '.' + t.name                                          AS table_name,
    MAX(COALESCE(us.last_user_seek, us.last_user_scan, us.last_user_lookup)) AS last_read,
    MAX(us.last_user_update)                                       AS last_write
FROM sys.tables t
JOIN sys.schemas s ON s.schema_id = t.schema_id
LEFT JOIN sys.dm_db_index_usage_stats us ON us.object_id = t.object_id AND us.database_id = DB_ID()
GROUP BY s.name, t.name
ORDER BY last_write, last_read;

/* B3. Item 4: every stored procedure, function, view and trigger, with its size in lines. One line each of what it does is your job */
SELECT
    o.type_desc                                                    AS object_type,
    s.name + '.' + o.name                                          AS object_name,
    o.create_date,
    o.modify_date,
    LEN(m.definition) - LEN(REPLACE(m.definition, CHAR(10), '')) + 1 AS approx_lines,
    CASE WHEN m.definition LIKE '%OPENQUERY%' OR m.definition LIKE '%xp_cmdshell%' OR m.definition LIKE '%sp_send_dbmail%'
         THEN 'reaches outside the database' ELSE '' END          AS note
FROM sys.objects o
JOIN sys.schemas s ON s.schema_id = o.schema_id
LEFT JOIN sys.sql_modules m ON m.object_id = o.object_id
WHERE o.type IN ('P', 'FN', 'IF', 'TF', 'V', 'TR')
  AND o.is_ms_shipped = 0
ORDER BY o.type_desc, object_name;

/* B4. Item 8 and 20: columns that need a decision before the load: blobs, unique indexes, computed columns, odd types */
SELECT
    s.name + '.' + t.name                                          AS table_name,
    c.name                                                         AS column_name,
    ty.name                                                        AS sql_type,
    c.max_length,
    c.precision,
    c.scale,
    CASE
        WHEN ty.name IN ('varbinary', 'image')                                   THEN 'blob: export files first'
        WHEN c.is_computed = 1                                                    THEN 'computed: recreate as formula column'
        WHEN ty.name IN ('float', 'real')                                         THEN 'float: five decimal places in Dataverse'
        WHEN ty.name IN ('xml', 'geography', 'geometry', 'hierarchyid', 'sql_variant') THEN 'no Dataverse equivalent'
        WHEN ty.name = 'time'                                                     THEN 'no time-only column in Dataverse'
        WHEN ty.name IN ('varchar', 'nvarchar') AND c.max_length = -1             THEN 'max: multiline text, 1,048,576 cap'
        WHEN ty.name IN ('varchar', 'char') AND c.max_length > 4000               THEN 'over 4,000: multiline text'
        WHEN ty.name IN ('nvarchar', 'nchar') AND c.max_length > 8000             THEN 'over 4,000: multiline text'
    END                                                            AS decision
FROM sys.columns c
JOIN sys.tables t ON t.object_id = c.object_id
JOIN sys.schemas s ON s.schema_id = t.schema_id
JOIN sys.types ty ON ty.user_type_id = c.user_type_id
WHERE ty.name IN ('varbinary', 'image', 'float', 'real', 'xml', 'geography', 'geometry', 'hierarchyid', 'sql_variant', 'time')
   OR c.is_computed = 1
   OR (ty.name IN ('varchar', 'nvarchar', 'char', 'nchar') AND (c.max_length = -1 OR c.max_length > 4000))
ORDER BY table_name, c.column_id;

/* B5. Item 20: unique indexes and constraints that become alternate keys by hand */
SELECT
    s.name + '.' + t.name                                          AS table_name,
    i.name                                                         AS index_name,
    STUFF((SELECT ', ' + c.name
           FROM sys.index_columns ic
           JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
           WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
           ORDER BY ic.key_ordinal FOR XML PATH('')), 1, 2, '')    AS key_columns
FROM sys.indexes i
JOIN sys.tables t ON t.object_id = i.object_id
JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE i.is_unique = 1 AND i.is_primary_key = 0 AND t.is_ms_shipped = 0
ORDER BY table_name, index_name;

/* B6. Item 13 and 22: relationships, so parents load before children, and orphan checks can be written */
SELECT
    fk.name                                                        AS fk_name,
    OBJECT_SCHEMA_NAME(fk.parent_object_id) + '.' + OBJECT_NAME(fk.parent_object_id)         AS child_table,
    COL_NAME(fkc.parent_object_id, fkc.parent_column_id)          AS child_column,
    OBJECT_SCHEMA_NAME(fk.referenced_object_id) + '.' + OBJECT_NAME(fk.referenced_object_id) AS parent_table,
    COL_NAME(fkc.referenced_object_id, fkc.referenced_column_id)  AS parent_column,
    fk.is_disabled,
    fk.is_not_trusted                                              AS may_have_orphans
FROM sys.foreign_keys fk
JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
ORDER BY parent_table, child_table;

/* B7. Item 28: identity columns and where the sequence is up to, for the autonumber seed */
SELECT
    OBJECT_SCHEMA_NAME(ic.object_id) + '.' + OBJECT_NAME(ic.object_id) AS table_name,
    ic.name                                                        AS column_name,
    CAST(ic.seed_value AS bigint)                                  AS seed_value,
    CAST(ic.increment_value AS bigint)                             AS increment_value,
    CAST(ic.last_value AS bigint)                                  AS last_value
FROM sys.identity_columns ic
ORDER BY table_name;

<#
.SYNOPSIS
  Reads a SQL Server database's schema and writes a CSV of suggested Dataverse column types and warnings.

.DESCRIPTION
  Section 3 of the SQL Server to Dataverse migration checklist (items 19 to 23).
  Read-only: it queries the catalog views and touches no data.
  One row per column: SQL type, suggested Dataverse column, the warning from data-type-map.md,
  and an empty DisplayName column for you to fill in (item 23: what "fld_x2" means).

  Works in Windows PowerShell 5.1 and PowerShell 7 on Windows (uses System.Data.SqlClient).

.PARAMETER Server
  Instance name, for example "SERVER01\SQLEXPRESS" or "localhost".

.PARAMETER Database
  The production database to map.

.PARAMETER Credential
  SQL login. Leave out to use Windows authentication.

.PARAMETER OutFile
  CSV path. Defaults to .\<Database>-dataverse-map.csv

.EXAMPLE
  .\Map-SqlSchemaToDataverse.ps1 -Server "SERVER01\SQLEXPRESS" -Database Jobs

.EXAMPLE
  .\Map-SqlSchemaToDataverse.ps1 -Server localhost -Database Jobs -Credential (Get-Credential) -OutFile C:\temp\jobs-map.csv

.NOTES
  MIT licence. Balu Premkumar, Kove, kove.nz. Version 1, September 2026.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $Server,
    [Parameter(Mandatory = $true)] [string] $Database,
    [System.Management.Automation.PSCredential] $Credential,
    [string] $OutFile
)

$ErrorActionPreference = 'Stop'
if (-not $OutFile) { $OutFile = Join-Path (Get-Location) ("{0}-dataverse-map.csv" -f $Database) }

$builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
$builder['Data Source'] = $Server
$builder['Initial Catalog'] = $Database
$builder['Application Name'] = 'Map-SqlSchemaToDataverse'
$builder['Connect Timeout'] = 30
if ($Credential) {
    $builder['User ID'] = $Credential.UserName
    $builder['Password'] = $Credential.GetNetworkCredential().Password
} else {
    $builder['Integrated Security'] = $true
}

$sql = @'
SELECT
    s.name                                   AS SchemaName,
    t.name                                   AS TableName,
    c.column_id                              AS Ordinal,
    c.name                                   AS ColumnName,
    ty.name                                  AS SqlType,
    c.max_length                             AS MaxLength,
    c.precision                              AS Precision,
    c.scale                                  AS Scale,
    c.is_nullable                            AS IsNullable,
    c.is_identity                            AS IsIdentity,
    c.is_computed                            AS IsComputed,
    CASE WHEN EXISTS (
        SELECT 1 FROM sys.index_columns ic JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
        WHERE ic.object_id = c.object_id AND ic.column_id = c.column_id AND i.is_primary_key = 1) THEN 1 ELSE 0 END AS IsPrimaryKey,
    CASE WHEN EXISTS (
        SELECT 1 FROM sys.index_columns ic JOIN sys.indexes i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
        WHERE ic.object_id = c.object_id AND ic.column_id = c.column_id AND i.is_unique = 1 AND i.is_primary_key = 0) THEN 1 ELSE 0 END AS InUniqueIndex,
    (SELECT TOP 1 OBJECT_SCHEMA_NAME(fk.referenced_object_id) + '.' + OBJECT_NAME(fk.referenced_object_id)
       FROM sys.foreign_key_columns fkc JOIN sys.foreign_keys fk ON fk.object_id = fkc.constraint_object_id
      WHERE fkc.parent_object_id = c.object_id AND fkc.parent_column_id = c.column_id) AS ReferencesTable,
    (SELECT SUM(p.rows) FROM sys.partitions p WHERE p.object_id = t.object_id AND p.index_id IN (0, 1)) AS TableRows
FROM sys.columns c
JOIN sys.tables t  ON t.object_id = c.object_id
JOIN sys.schemas s ON s.schema_id = t.schema_id
JOIN sys.types ty  ON ty.user_type_id = c.user_type_id
WHERE t.is_ms_shipped = 0
ORDER BY s.name, t.name, c.column_id;
'@

function Get-DataverseMapping {
    param($r)
    $type = [string]$r.SqlType
    $len  = [int]$r.MaxLength
    $dv = ''; $warn = ''

    if ([int]$r.IsPrimaryKey -eq 1 -and [int]$r.IsIdentity -eq 1) {
        return @('Autonumber (plus the GUID Dataverse adds)', 'Set the autonumber seed so the sequence continues; old integer IDs also land in a Whole Number column for matching')
    }
    if ($r.ReferencesTable -isnot [DBNull] -and $r.ReferencesTable) {
        return @(("Lookup to {0}" -f $r.ReferencesTable), 'Load the parent table first; the dataflow matches on an alternate key, not the old integer')
    }
    if ([int]$r.IsComputed -eq 1) {
        return @('Formula or Calculated column', 'Values do not migrate; recreate the expression')
    }

    switch -Regex ($type) {
        '^(int|smallint|tinyint)$'            { $dv = 'Whole Number' }
        '^bigint$'                            { $dv = 'Big Integer'; $warn = 'Canvas apps do not display Big Integer natively' }
        '^(decimal|numeric)$'                 { $dv = 'Decimal Number'; if ([int]$r.Scale -gt 10) { $warn = 'Scale over 10 places; Dataverse keeps 10' } }
        '^(float|real)$'                      { $dv = 'Floating Point Number'; $warn = 'Five decimal places in Dataverse; change to decimal at the source if precision matters' }
        '^(money|smallmoney)$'                { $dv = 'Currency'; $warn = 'One base currency per environment' }
        '^(nvarchar|nchar)$'                  { if ($len -eq -1 -or $len -gt 8000) { $dv = 'Multiline Text'; $warn = '1,048,576-character cap' } else { $dv = ("Text ({0})" -f ($len / 2)) } }
        '^(varchar|char)$'                    { if ($len -eq -1 -or $len -gt 4000) { $dv = 'Multiline Text'; $warn = '1,048,576-character cap' } else { $dv = ("Text ({0})" -f $len) } }
        '^(text|ntext)$'                      { $dv = 'Multiline Text'; $warn = 'Deprecated SQL type; 1,048,576-character cap' }
        '^bit$'                               { $dv = 'Yes/No'; if ([int]$r.IsNullable -eq 1) { $warn = 'Nullable bit: NULL becomes No unless you decide otherwise' } }
        '^(datetime|datetime2|smalldatetime|datetimeoffset)$' { $dv = 'Date and Time'; $warn = 'Decide user-local or time-zone independent per column before the load' }
        '^date$'                              { $dv = 'Date Only'; $warn = 'Not supported in Dataverse for Teams' }
        '^time$'                              { $dv = 'Text or Date and Time'; $warn = 'No time-only column in Dataverse' }
        '^uniqueidentifier$'                  { $dv = 'Unique Identifier'; $warn = 'Keys only; if it is data, store as Text' }
        '^(varbinary|image)$'                 { $dv = 'File or Image'; $warn = 'Blobs do not load through a dataflow; export the files first' }
        '^(xml|geography|geometry|hierarchyid|sql_variant)$' { $dv = 'Multiline Text or redesign'; $warn = 'No Dataverse equivalent' }
        '^(timestamp|rowversion)$'            { $dv = '(drop)'; $warn = 'Row version; Dataverse keeps its own' }
        default                               { $dv = '(decide)'; $warn = ("Unmapped SQL type {0}" -f $type) }
    }
    if ([int]$r.InUniqueIndex -eq 1) {
        $warn = (@($warn, 'Part of a unique index: recreate as an alternate key by hand') | Where-Object { $_ }) -join '; '
    }
    if ([int]$r.IsIdentity -eq 1 -and [int]$r.IsPrimaryKey -ne 1) {
        $warn = (@($warn, 'Identity column that is not the primary key: decide whether it becomes an autonumber') | Where-Object { $_ }) -join '; '
    }
    return @($dv, $warn)
}

$conn = New-Object System.Data.SqlClient.SqlConnection $builder.ConnectionString
$rows = New-Object System.Collections.Generic.List[object]
try {
    $conn.Open()
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = $sql
    $cmd.CommandTimeout = 120
    $reader = $cmd.ExecuteReader()
    $table = New-Object System.Data.DataTable
    $table.Load($reader)
} finally {
    $conn.Close()
}

foreach ($r in $table.Rows) {
    $map = Get-DataverseMapping $r
    $rows.Add([pscustomobject]@{
        Table           = ("{0}.{1}" -f $r.SchemaName, $r.TableName)
        TableRows       = $r.TableRows
        Column          = $r.ColumnName
        SqlType         = $r.SqlType
        MaxLength       = $r.MaxLength
        Precision       = $r.Precision
        Scale           = $r.Scale
        Nullable        = [int]$r.IsNullable
        Identity        = [int]$r.IsIdentity
        PrimaryKey      = [int]$r.IsPrimaryKey
        UniqueIndex     = [int]$r.InUniqueIndex
        ReferencesTable = if ($r.ReferencesTable -is [DBNull]) { '' } else { $r.ReferencesTable }
        DataverseColumn = $map[0]
        Warning         = $map[1]
        DisplayName     = ''
        StillUsed       = ''
    })
}

$rows | Export-Csv -Path $OutFile -NoTypeInformation -Encoding UTF8

$tables   = ($rows | Select-Object -ExpandProperty Table -Unique).Count
$warnings = ($rows | Where-Object { $_.Warning }).Count
Write-Host ("Mapped {0} columns across {1} tables. {2} need a decision. CSV: {3}" -f $rows.Count, $tables, $warnings, $OutFile)
Write-Host 'Fill in DisplayName (item 23) and StillUsed (item 18), then hand the sheet to whoever quotes.'

# The data-type map: SQL Server and Access to Dataverse

The same table serves both sources.
Limits are Dataverse's, checked September 2026.
`Map-SqlSchemaToDataverse.ps1` applies the SQL Server column of this table automatically.

| SQL Server type | Access type | Dataverse column | Watch for |
|---|---|---|---|
| int, smallint, tinyint | Number: Integer, Long Integer | Whole Number | Range is plus or minus 2,147,483,647 |
| bigint | Large Number | Big Integer | Usable through the API; canvas apps do not display it natively |
| decimal, numeric | Number: Decimal | Decimal Number | Up to 10 decimal places |
| float, real | Number: Single, Double | Floating Point Number | Up to 5 decimal places; change to Decimal at the source if that matters |
| money, smallmoney | Currency | Currency | One base currency per environment; the migration assumes it |
| nvarchar(n), varchar(n), char, nchar | Short Text | Text | 4,000-character cap |
| nvarchar(max), varchar(max), text, ntext | Long Text, Rich Text | Multiline Text, Rich Text | Up to 1,048,576 characters |
| bit | Yes/No | Yes/No | NULL becomes No unless you decide otherwise |
| datetime, datetime2, smalldatetime, datetimeoffset | Date/Time | Date and Time | Choose user-local or time-zone independent per column; get it wrong and every date shifts by 12 hours |
| date | Date/Time (date part) | Date Only | Not supported in Dataverse for Teams |
| time | Date/Time (time part) | Text or Date and Time | No time-only column; store as text or attach a fixed date |
| uniqueidentifier | GUID | Unique Identifier | Used as keys only |
| identity column | AutoNumber | Autonumber | Set the seed so the sequence continues |
| foreign key | Lookup (single value) | Lookup (relationship) | Load parents first; match on an alternate key |
| varbinary, image | Attachment, OLE Object | File or Image | Not loaded by dataflow or the Access tool; export the files first |
| xml, geography, geometry, hierarchyid, sql_variant | (none) | Multiline Text or a redesign | Nothing in Dataverse holds these natively; decide per column |
| computed column | Calculated field | Formula or Calculated column | The Access tool stores the value; recreate the formula |
| unique index | Unique index | Alternate key | Not migrated by either tool; recreate by hand |
| lookup table with fixed values | Multi-value lookup, value list | Choice, Choices | Needs the two-column shape in Access before export |
| hyperlink stored as text | Hyperlink | URL | Fine |

## The two mistakes that cost the most

**Date and Time behaviour.** Every Date and Time column in Dataverse is user-local or time-zone independent.
A date of birth, an invoice date or a "due Friday" must be time-zone independent (or Date Only), or New Zealand users see it shift a day at the edges of the calendar.
A timestamp of when something happened is user-local.
Decide per column before the load, because changing it afterwards does not rewrite stored values.

**Float precision.** SQL `float` and Access Single and Double are binary floating point.
Dataverse's Floating Point Number keeps five decimal places.
If a column carries money, hours to four places, or anything someone reconciles, change it to `decimal` at the source so the load is exact.

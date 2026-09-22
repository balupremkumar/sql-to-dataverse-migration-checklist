# SQL Server and Access to Dataverse: migration checklist for a small business

Thirty-eight checks, in the order they happen, for moving the database that runs a 5 to 20 person firm into Microsoft 365 (SharePoint lists or Dataverse).
It is the list I work from.
Take it to whoever you hire, including someone who is not me.

Every item is a yes or no.
A provider who cannot answer sections 1 to 3 before quoting is guessing at the price.

What is in this repo:

| File | What it is for |
|---|---|
| `README.md` | The checklist itself |
| `data-type-map.md` | SQL Server and Access types to Dataverse columns, with the limits that bite |
| `inventory.sql` | Read-only T-SQL that answers most of section 1 in one run |
| `Map-SqlSchemaToDataverse.ps1` | Reads a database's schema and writes a CSV of suggested Dataverse column types and warnings |
| `inventory-template.csv` | The section 1 sheet, blank |

Version 1, September 2026.
The web version, with the reasoning behind each section, is at [kove.nz/sql-migration-checklist](https://kove.nz/sql-migration-checklist).
Prices are Microsoft's New Zealand list prices before GST, checked September 2026.

## How to run

### Running inventory.sql

The inventory.sql script answers items 1 to 4 and 8 for SQL Server. It runs without making any changes.

1. Open SQL Server Management Studio, Azure Data Studio, or connect via sqlcmd to your SQL Server instance.
2. For the whole instance (version, edition, list of databases), paste Part A of inventory.sql and run it. Any database connection works.
3. For your production database, switch to it and paste Part B of inventory.sql, starting from the `USE [YourProductionDatabase];` line. Edit the USE line to match your database name.
4. Run each query section (B1 through B7) and save or export the results.
5. If a query fails on permissions, note the gap. The rest will still run. The queries are read-only and need VIEW SERVER STATE and read access to msdb.

### Running the PowerShell mapper

The Map-SqlSchemaToDataverse.ps1 script maps every column in your database to a suggested Dataverse column type and notes warnings (items 19 to 23).

1. Open PowerShell 5.1 or PowerShell 7 on Windows.
2. Navigate to the folder where Map-SqlSchemaToDataverse.ps1 lives.
3. Run the script with your server and database:
   ```
   .\Map-SqlSchemaToDataverse.ps1 -Server "SERVER01\SQLEXPRESS" -Database Jobs
   ```
4. If your server uses SQL login instead of Windows authentication, add the credential flag:
   ```
   .\Map-SqlSchemaToDataverse.ps1 -Server "SERVER01\SQLEXPRESS" -Database Jobs -Credential (Get-Credential)
   ```
5. The script creates a CSV file named `Jobs-dataverse-map.csv` in your current folder (or specify a different path with `-OutFile C:\temp\jobs-map.csv`).
6. Open the CSV and fill in the DisplayName column (what each column means) and StillUsed (whether it is still used). Hand this sheet to whoever quotes.

## 1. Inventory (before anyone quotes)

1. Exact version and edition of SQL Server (`SELECT @@VERSION`) or Access, and the Windows Server underneath. Check both against the [end-of-support dates](https://kove.nz/microsoft-end-of-support-dates).
2. Every database on the instance, including the two nobody recognises, and whether each is still used.
3. Row count of every table in the production database, and the size on disk.
4. Every stored procedure, trigger, view and scheduled job, with one line each on what it does. Unknown is an acceptable answer at this stage; it is not acceptable at quote time.
5. Every front end: Access forms and reports, a Windows or web app, Excel links, Power BI, anything with a connection string.
6. Every integration: label printers, Xero or MYOB syncs, ODBC links, email jobs, a supplier portal. These are what people forget and what breaks on Monday.
7. Who uses it, how many people on a busy day, and which two people know it best.
8. Where the files live: attachments inside the database as blobs, or on a share it points at.
9. A tested backup restored somewhere else, before anything else happens. Not the Friday USB drive.

`inventory.sql` answers 1 to 4 and 8 for a SQL Server source.

## 2. Decide the home

10. Biggest table over about 20,000 rows, or will be within three years? Leans Dataverse.
11. Money on the records (invoices, payments, payroll hours, anything an accountant reconciles)? Leans Dataverse.
12. More than three people editing on the same day? Leans Dataverse.
13. Three or more tables that genuinely relate (not just a lookup)? Leans Dataverse.
14. Need to prove who changed what and when? Dataverse.
15. Mostly no to 10 to 14? SharePoint lists, no extra licence. Mostly yes? Dataverse, at NZ$32.40 per user per month before GST (Power Apps Premium on Microsoft's NZ price list). The reasoning: [SharePoint or Dataverse](https://kove.nz/insights/sharepoint-vs-dataverse).
16. Licence line written down against real headcount, per month and per year, before the build is priced.
17. Considered not migrating: supported vendor product, fine server with a bad front end, or under 500 rows and one user.

## 3. Fix the source first

18. Delete or archive the tables nobody uses, with sign-off from whoever owns the data.
19. Access Single and Double columns changed to Decimal if precision past five places matters (Dataverse floats keep five).
20. Unique indexes listed, because they do not migrate automatically and become alternate keys by hand.
21. Multi-value lookups and choice lists documented, so they map to Choice columns cleanly.
22. Bad dates, orphaned rows and duplicate keys found and fixed in the source, not patched in the target.
23. Column names translated: what `fld_x2` means, written next to it.

`Map-SqlSchemaToDataverse.ps1` produces the starting sheet for 19 to 23.

## 4. Trial load

24. A separate dev environment or site, never the live tenant on the first attempt.
25. Loaded by a repeatable method (Power Platform dataflows, Microsoft's Access export to Dataverse, or a scripted import), so it can run again on cut-over day.
26. Row counts reconciled per table against the source, and a handful of known records checked by hand.
27. Every validator failure read and either fixed at the source or accepted in writing.
28. Autonumbers continue the old sequence for job and invoice numbers where the business relies on them.

## 5. Rebuild the front end and logic

29. Each stored procedure, trigger and macro mapped to a flow, a business rule, app logic, or deliberately dropped, in a table you can read.
30. The app built around the three things people do, not a copy of the old grid.
31. Tested by the two people who know the old system best, on the devices they actually use.
32. Every integration from item 6 re-pointed and tested end to end.
33. Reports rebuilt as views or Power BI, and the one report the owner looks at on Friday confirmed working.

## 6. Cut over

34. A named cut-over day, usually a Friday, with the old system frozen read-only from that afternoon.
35. Final load, counts and totals reconciled, sign-off recorded before Monday.
36. Old server or file kept intact and switched off for 60 days, then wiped and disposed of properly.

## 7. Hand-over

37. Source, credentials and admin rights in your own accounts, not the provider's.
38. A written map of what lives where, which flows exist, who owns each, and what licence each person holds, plus a warranty period and a plain answer to what happens if the provider is unavailable.

## The method, in one paragraph per source

**SQL Server to Dataverse.** Build the Dataverse tables first (names, relationships, autonumber columns that continue the old sequence, alternate keys for anything that had a unique index).
Install the on-premises data gateway on a machine that can reach the server; it makes outbound calls only.
Create a Power Platform dataflow with SQL Server as the source, add the cleaning steps in Power Query, map each query to its table, and run it into a dev environment first.
Load parents before children so lookups resolve.
Reconcile row counts, then repeat on cut-over day.
The full guide: [Moving a SQL Server database into Microsoft 365](https://kove.nz/insights/sql-server-to-microsoft-365).

**Access to Dataverse.** Open a copy in Access from Microsoft 365 (the export tool is not in Access 2016 or 2019), change Single and Double to Decimal where it matters, note every unique index, then External Data, Export to Dataverse.
Read the validator; it keeps failing rows in a local table rather than dropping them.
Recreate unique indexes as alternate keys and multi-value lookups as Choice columns.
The full guide: [Moving an Access database into SharePoint or Dataverse](https://kove.nz/insights/access-database-to-sharepoint-or-dataverse).

**Either source to SharePoint lists.** Create the lists with the right column types, load each table with a Power Automate flow or a dataflow, parents first, and map child rows by an ID column you keep.

## Licence

The checklist and documents are CC BY 4.0 (`LICENSE-docs`): copy them freely, with a link to kove.nz.
The scripts are MIT (`LICENSE`).

Balu Premkumar, [Kove](https://kove.nz), Christchurch, New Zealand.
I move SQL Server, Access and spreadsheet systems into Microsoft 365 for firms with 5 to 50 staff, at a fixed price, with the source handed over.

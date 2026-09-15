# =============================================================================
# Builds, loads and analyses the OlistAnalytics database on SQL Server.
#
#   1. sql/01_schema.sql     database, staging and model
#   2. load the CSVs         -LoadMethod BulkCopy   (default)
#                              client-side, with a real CSV parser: review
#                              comments that contain commas or line breaks load
#                              correctly, and the server never reads your folders
#                            -LoadMethod BulkInsert
#                              runs sql/02_load.sql (pure T-SQL) after copying the
#                              CSVs to C:\Users\Public\OlistAnalytics\data
#   3. sql/03_cleaning.sql   profile, clean, load the model, checks
#   4. sql/04_analysis.sql   the business questions
#
# Put the dataset's CSV files in data/ first (see README). Kaggle names or the
# Scaler case-study names both work: files are matched by the words in them.
#
# Usage:  .\scripts\run_mssql.ps1
#         .\scripts\run_mssql.ps1 -Server .\SQLEXPRESS
# =============================================================================
param(
    [string]$Server     = 'localhost',
    [string]$Database   = 'OlistAnalytics',
    [ValidateSet('BulkCopy', 'BulkInsert')]
    [string]$LoadMethod = 'BulkCopy'
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName Microsoft.VisualBasic

$root   = Split-Path -Parent $PSScriptRoot
$sqlDir = Join-Path $root 'sql'
$data   = Join-Path $root 'data'
$outDir = Join-Path $sqlDir 'output'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

# --- locate sqlcmd (installed with SQL Server, frequently not on PATH) -------
$sqlcmd = $null
$onPath = Get-Command sqlcmd -ErrorAction SilentlyContinue
if ($onPath) { $sqlcmd = $onPath.Source }
if (-not $sqlcmd) {
    $sqlcmd = Get-ChildItem 'C:\Program Files\Microsoft SQL Server', 'C:\Program Files\SqlCmd' `
                -Recurse -Filter sqlcmd.exe -ErrorAction SilentlyContinue |
              Select-Object -First 1 -ExpandProperty FullName
}
if (-not $sqlcmd) { throw 'sqlcmd.exe not found. Install the SQL Server command-line tools.' }

$connStr = "Server=$Server;Database=$Database;Integrated Security=SSPI;TrustServerCertificate=True;"

function Write-Banner([string]$text) {
    Write-Host ''
    Write-Host ('#' * 78) -ForegroundColor DarkCyan
    Write-Host "# $text" -ForegroundColor Cyan
    Write-Host ('#' * 78) -ForegroundColor DarkCyan
}

function Invoke-SqlFile([string]$file) {
    $path = Join-Path $sqlDir $file
    $log  = Join-Path $outDir ([IO.Path]::ChangeExtension($file, '.txt'))
    Write-Banner $file
    # -b abort on error, -C trust local cert, -W trim padding, -s one-char separator
    $out  = & $sqlcmd -S $Server -E -C -b -W -w 500 -s '|' -i $path
    $code = $LASTEXITCODE
    $out | Set-Content -Path $log -Encoding UTF8
    $out | ForEach-Object { Write-Host $_ }
    if ($code -ne 0) { throw "$file failed with exit code $code -- see $log" }
}

# Each staging table, the words that identify its file, and its column count.
$specs = @(
    @{ table = 'stg.customers';            match = 'customer';    exclude = '';                         cols = 5 }
    @{ table = 'stg.sellers';              match = 'seller';      exclude = '';                         cols = 4 }
    @{ table = 'stg.category_translation'; match = 'translation'; exclude = '';                         cols = 2 }
    @{ table = 'stg.products';             match = 'product';     exclude = 'translation';              cols = 9 }
    @{ table = 'stg.orders';               match = 'orders';      exclude = 'item|payment|review';      cols = 8 }
    @{ table = 'stg.order_items';          match = 'item';        exclude = '';                         cols = 7 }
    @{ table = 'stg.payments';             match = 'payment';     exclude = '';                         cols = 5 }
    @{ table = 'stg.reviews';              match = 'review';      exclude = '';                         cols = 7 }
)

function Find-File($spec) {
    $files = @(Get-ChildItem $data -Filter *.csv -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -match $spec.match -and (-not $spec.exclude -or $_.Name -notmatch $spec.exclude) })
    if ($files.Count -ne 1) {
        throw "expected exactly one CSV in data/ matching '$($spec.match)', found $($files.Count): $($files.Name -join ', ')"
    }
    $files[0].FullName
}

function Import-Stage($spec) {
    $path = Find-File $spec
    $p = New-Object Microsoft.VisualBasic.FileIO.TextFieldParser($path, [Text.Encoding]::UTF8)
    $p.TextFieldType = [Microsoft.VisualBasic.FileIO.FieldType]::Delimited
    $p.SetDelimiters(',')
    $p.HasFieldsEnclosedInQuotes = $true
    $header = $p.ReadFields()
    if ($header.Count -ne $spec.cols) {
        $p.Close()
        throw "$(Split-Path $path -Leaf) has $($header.Count) columns, expected $($spec.cols)"
    }

    $dt = New-Object System.Data.DataTable
    for ($i = 0; $i -lt $spec.cols; $i++) { [void]$dt.Columns.Add("c$i", [string]) }

    # TableLock: one table lock for the whole load -- the fast, minimally logged path.
    $bc = New-Object System.Data.SqlClient.SqlBulkCopy($connStr, [System.Data.SqlClient.SqlBulkCopyOptions]::TableLock)
    $bc.DestinationTableName = $spec.table
    $bc.BatchSize = 20000
    $bc.BulkCopyTimeout = 600
    for ($i = 0; $i -lt $spec.cols; $i++) { [void]$bc.ColumnMappings.Add([int]$i, [int]$i) }  # by position

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $n = 0; $bad = 0
    while (-not $p.EndOfData) {
        $f = $p.ReadFields()
        if ($f.Count -ne $spec.cols) { $bad++; continue }
        [void]$dt.Rows.Add([object[]]$f)
        $n++
        if ($dt.Rows.Count -ge 50000) {
            $bc.WriteToServer($dt); $dt.Clear()
            Write-Host ('    ... {0,9:N0} rows sent ({1:N0}s)' -f $n, $sw.Elapsed.TotalSeconds)
        }
    }
    if ($dt.Rows.Count -gt 0) { $bc.WriteToServer($dt) }
    $bc.Close(); $p.Close()
    $note = if ($bad) { "   ($bad malformed rows skipped)" } else { '' }
    Write-Host ('  {0,-44} -> {1,-26} {2,9:N0} rows  {3,5:N0}s{4}' -f (Split-Path $path -Leaf), $spec.table, $n, $sw.Elapsed.TotalSeconds, $note)
}

# -----------------------------------------------------------------------------
$t0 = Get-Date
Write-Host "sqlcmd : $sqlcmd"
Write-Host "server : $Server   database : $Database   load : $LoadMethod"

Invoke-SqlFile '01_schema.sql'

if ($LoadMethod -eq 'BulkInsert') {
    $public = 'C:\Users\Public\OlistAnalytics\data'
    if (-not (Test-Path $public)) { New-Item -ItemType Directory -Force -Path $public | Out-Null }
    Copy-Item (Join-Path $data '*.csv') $public -Force
    Invoke-SqlFile '02_load.sql'
} else {
    Write-Banner 'load -> staging (client-side CSV parser + SqlBulkCopy)'
    foreach ($s in $specs) { Import-Stage $s }
}

Invoke-SqlFile '03_cleaning.sql'
Invoke-SqlFile '04_analysis.sql'

Write-Host ''
Write-Host ("Done in {0:N1}s. Logs in {1}" -f ((Get-Date) - $t0).TotalSeconds, $outDir) -ForegroundColor Green

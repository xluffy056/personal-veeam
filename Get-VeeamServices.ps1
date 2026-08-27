[CmdletBinding()]
param()

$OutputFolder = 'C:\temp'
$OutputFile   = Join-Path $OutputFolder 'VeeamSupport08181311.txt'

Write-Host "Collecting Veeam services on $env:COMPUTERNAME ..." -ForegroundColor Cyan

if (-not (Test-Path -Path $OutputFolder)) {
    try {
        New-Item -Path $OutputFolder -ItemType Directory -Force | Out-Null
        Write-Host "Created folder: $OutputFolder" -ForegroundColor Yellow
    }
    catch {
        Write-Warning "Could not create $OutputFolder : $($_.Exception.Message)"
        return
    }
}

$veeamServices = Get-CimInstance -ClassName Win32_Service -ErrorAction Stop |
    Where-Object { $_.Name -like '*Veeam*' -or $_.DisplayName -like '*Veeam*' } |
    Sort-Object DisplayName

if (-not $veeamServices) {
    Write-Warning "No Veeam services were found on $env:COMPUTERNAME."
    return
}

$results = $veeamServices | ForEach-Object {
    [PSCustomObject]@{
        DisplayName  = $_.DisplayName
        ServiceName  = $_.Name
        State        = $_.State
        Status       = $_.Status
        StartMode    = $_.StartMode
        LogOnAccount = $_.StartName
        ProcessId    = $_.ProcessId
    }
}

$report = New-Object System.Collections.Generic.List[string]
$report.Add('==================================================================')
$report.Add(' Veeam Services Report')
$report.Add(('  Computer : {0}' -f $env:COMPUTERNAME))
$report.Add(('  Generated: {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))
$report.Add(('  Services : {0}' -f $results.Count))
$report.Add('==================================================================')
$report.Add('')

foreach ($svc in $results) {
    $report.Add(('Display Name   : {0}' -f $svc.DisplayName))
    $report.Add(('Service Name   : {0}' -f $svc.ServiceName))
    $report.Add(('State          : {0}' -f $svc.State))
    $report.Add(('Status         : {0}' -f $svc.Status))
    $report.Add(('Start Mode     : {0}' -f $svc.StartMode))
    $report.Add(('Log On Account : {0}' -f $svc.LogOnAccount))
    $report.Add(('Process Id     : {0}' -f $svc.ProcessId))
    $report.Add('------------------------------------------------------------------')
}

$report.Add('')
$report.Add('Summary table:')
$report.Add(($results |
    Format-Table DisplayName, ServiceName, State, StartMode, LogOnAccount -AutoSize |
    Out-String).TrimEnd())

$results | Format-Table DisplayName, ServiceName, State, StartMode, LogOnAccount -AutoSize

try {
    $report | Set-Content -Path $OutputFile -Encoding UTF8
    Write-Host ("Found {0} Veeam service(s). Report saved to: {1}" -f $results.Count, $OutputFile) -ForegroundColor Green
}
catch {
    Write-Warning "Failed to write report to $OutputFile : $($_.Exception.Message)"
}

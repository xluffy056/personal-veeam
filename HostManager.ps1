#Requires -Version 5.1
<#
.SYNOPSIS
    Host Manager - GUI tool for reviewing and removing stale hosts and host
    components from the VBR backup infrastructure.

.DESCRIPTION
    On launch the script:
      1. Checks whether it is blocked (Zone.Identifier) and unblocks itself
      2. Checks execution policy and STA apartment state
      3. Loads the Veeam.Backup.PowerShell module
      4. Verifies an existing VBR session, or prompts to Connect-VBRServer

    It then opens a UI with two views:
      HOSTS       - everything Get-VBRServer returns
      COMPONENTS  - components attached to the selected host(s)

    Both views support multi-selection, a details pane, a non-destructive
    Preview, and a Remove action.

.PARAMETER Server
    Optional. VBR server to auto-connect to. Skips the connect dialog.

.PARAMETER SkipUnblockCheck
    Optional. Bypasses the Zone.Identifier check.

.EXAMPLE
    .\HostManager.ps1

.EXAMPLE
    .\HostManager.ps1 -Server localhost

.NOTES
    Run from the Veeam PowerShell console, or any PowerShell session where the
    Veeam.Backup.PowerShell module is available.

    Removal is destructive. Take a configuration backup first:
    https://helpcenter.veeam.com/docs/backup/vsphere/vbr_config_manually.html?ver=120

    Companion reference: Guide-Remove-Stale-Host-PowerShell.md
#>

[CmdletBinding()]
param(
    [string] $Server,
    [switch] $SkipUnblockCheck
)

$ErrorActionPreference = 'Stop'

# ============================================================================
# LOGGING
# ============================================================================

$script:LogPath = Join-Path $env:TEMP ("HostManager_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

function Write-Log {
    param(
        [Parameter(Mandatory)][string] $Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'ACTION')][string] $Level = 'INFO'
    )
    $line = "{0:yyyy-MM-dd HH:mm:ss} [{1,-6}] {2}" -f (Get-Date), $Level, $Message
    try { Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 } catch { }
    switch ($Level) {
        'ERROR'  { Write-Host $line -ForegroundColor Red }
        'WARN'   { Write-Host $line -ForegroundColor Yellow }
        'ACTION' { Write-Host $line -ForegroundColor Cyan }
        default  { Write-Host $line }
    }
}

Write-Log "Host Manager starting. Log: $script:LogPath"

# ============================================================================
# PRE-FLIGHT CHECKS
# ============================================================================

function Test-ScriptUnblocked {
    <# Returns $true if the script file is not marked as downloaded. #>
    if (-not $PSCommandPath) { return $true }
    try {
        $null = Get-Item -LiteralPath $PSCommandPath -Stream 'Zone.Identifier' -ErrorAction Stop
        return $false
    }
    catch {
        return $true
    }
}

function Invoke-PreFlightCheck {
    # --- Blocked file check -------------------------------------------------
    if (-not $SkipUnblockCheck) {
        if (Test-ScriptUnblocked) {
            Write-Log "File is not blocked."
        }
        else {
            Write-Log "File is blocked (Zone.Identifier present). Attempting to unblock." 'WARN'
            try {
                Unblock-File -LiteralPath $PSCommandPath -ErrorAction Stop
                Write-Log "File unblocked successfully."
            }
            catch {
                Write-Log "Could not unblock automatically: $($_.Exception.Message)" 'ERROR'
                Write-Log "Run manually:  Unblock-File -LiteralPath '$PSCommandPath'" 'WARN'
            }
        }
    }

    # --- Execution policy ---------------------------------------------------
    $policy = Get-ExecutionPolicy
    Write-Log "Execution policy: $policy"
    if ($policy -in @('Restricted', 'AllSigned')) {
        Write-Log "Execution policy may block this script. Relaunch with:" 'WARN'
        Write-Log "  powershell.exe -ExecutionPolicy Bypass -STA -File `"$PSCommandPath`"" 'WARN'
    }

    # --- Apartment state (WinForms requires STA) ----------------------------
    $apartment = [System.Threading.Thread]::CurrentThread.GetApartmentState()
    Write-Log "Apartment state: $apartment"
    if ($apartment -ne 'STA') {
        Write-Log "PowerShell is not running in STA mode. The UI may not render correctly." 'WARN'
        Write-Log "  powershell.exe -STA -File `"$PSCommandPath`"" 'WARN'
    }

    # --- WinForms assemblies ------------------------------------------------
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        [System.Windows.Forms.Application]::EnableVisualStyles()
        Write-Log "Windows Forms loaded."
    }
    catch {
        Write-Log "Failed to load Windows Forms: $($_.Exception.Message)" 'ERROR'
        throw
    }
}

# ============================================================================
# VEEAM MODULE + CONNECTION
# ============================================================================

function Initialize-VeeamModule {
    <# Loads Veeam.Backup.PowerShell. Falls back to known paths, then snap-in. #>

    if (Get-Module -Name 'Veeam.Backup.PowerShell') {
        Write-Log "Veeam.Backup.PowerShell already loaded."
        return $true
    }

    if (Get-Module -ListAvailable -Name 'Veeam.Backup.PowerShell') {
        try {
            Import-Module 'Veeam.Backup.PowerShell' -DisableNameChecking -ErrorAction Stop
            Write-Log "Imported Veeam.Backup.PowerShell from the module path."
            return $true
        }
        catch {
            Write-Log "Import from module path failed: $($_.Exception.Message)" 'WARN'
        }
    }

    $candidatePaths = @(
        (Join-Path $env:ProgramFiles 'Veeam\Backup and Replication\Console\Veeam.Backup.PowerShell\Veeam.Backup.PowerShell.psd1')
        (Join-Path ${env:ProgramFiles(x86)} 'Veeam\Backup and Replication\Console\Veeam.Backup.PowerShell\Veeam.Backup.PowerShell.psd1')
    )
    foreach ($path in $candidatePaths) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            try {
                Import-Module $path -DisableNameChecking -ErrorAction Stop
                Write-Log "Imported Veeam module from: $path"
                return $true
            }
            catch {
                Write-Log "Import failed from ${path}: $($_.Exception.Message)" 'WARN'
            }
        }
    }

    # Legacy fallback for pre-v11 installations
    try {
        if (Get-PSSnapin -Registered -Name 'VeeamPSSnapIn' -ErrorAction SilentlyContinue) {
            Add-PSSnapin -Name 'VeeamPSSnapIn' -ErrorAction Stop
            Write-Log "Loaded legacy VeeamPSSnapIn."
            return $true
        }
    }
    catch {
        Write-Log "Snap-in load failed: $($_.Exception.Message)" 'WARN'
    }

    Write-Log "Veeam PowerShell module not found. Is the VBR console installed on this machine?" 'ERROR'
    return $false
}

function Test-VBRConnected {
    <# Returns $true when a VBR session is already established. #>
    try {
        $session = Get-VBRServerSession -ErrorAction Stop
        if ($null -ne $session) {
            Write-Log "Existing VBR session found: $($session.Server)"
            return $true
        }
        return $false
    }
    catch {
        return $false
    }
}

function Show-ConnectDialog {
    <# Prompts for connection details. Returns a hashtable, or $null on cancel. #>

    $form = New-Object System.Windows.Forms.Form -Property @{
        Text            = 'Connect to Veeam Backup Server'
        Size            = New-Object System.Drawing.Size(430, 260)
        StartPosition   = 'CenterScreen'
        FormBorderStyle = 'FixedDialog'
        MaximizeBox     = $false
        MinimizeBox     = $false
    }

    $lblServer = New-Object System.Windows.Forms.Label -Property @{
        Text = 'Backup server:'; Location = New-Object System.Drawing.Point(15, 20)
        Size = New-Object System.Drawing.Size(100, 20)
    }
    $txtServer = New-Object System.Windows.Forms.TextBox -Property @{
        Text = 'localhost'; Location = New-Object System.Drawing.Point(125, 18)
        Size = New-Object System.Drawing.Size(265, 20)
    }

    $chkCurrent = New-Object System.Windows.Forms.CheckBox -Property @{
        Text = 'Use current Windows credentials'; Checked = $true
        Location = New-Object System.Drawing.Point(125, 50)
        Size = New-Object System.Drawing.Size(265, 24)
    }

    $lblUser = New-Object System.Windows.Forms.Label -Property @{
        Text = 'Username:'; Location = New-Object System.Drawing.Point(15, 84)
        Size = New-Object System.Drawing.Size(100, 20)
    }
    $txtUser = New-Object System.Windows.Forms.TextBox -Property @{
        Location = New-Object System.Drawing.Point(125, 82); Enabled = $false
        Size = New-Object System.Drawing.Size(265, 20)
    }

    $lblPass = New-Object System.Windows.Forms.Label -Property @{
        Text = 'Password:'; Location = New-Object System.Drawing.Point(15, 114)
        Size = New-Object System.Drawing.Size(100, 20)
    }
    $txtPass = New-Object System.Windows.Forms.TextBox -Property @{
        Location = New-Object System.Drawing.Point(125, 112); Enabled = $false
        Size = New-Object System.Drawing.Size(265, 20); UseSystemPasswordChar = $true
    }

    $chkCurrent.Add_CheckedChanged({
        $txtUser.Enabled = -not $chkCurrent.Checked
        $txtPass.Enabled = -not $chkCurrent.Checked
    })

    $btnOk = New-Object System.Windows.Forms.Button -Property @{
        Text = 'Connect'; Location = New-Object System.Drawing.Point(205, 165)
        Size = New-Object System.Drawing.Size(90, 30); DialogResult = 'OK'
    }
    $btnCancel = New-Object System.Windows.Forms.Button -Property @{
        Text = 'Cancel'; Location = New-Object System.Drawing.Point(300, 165)
        Size = New-Object System.Drawing.Size(90, 30); DialogResult = 'Cancel'
    }

    $form.Controls.AddRange(@($lblServer, $txtServer, $chkCurrent, $lblUser, $txtUser, $lblPass, $txtPass, $btnOk, $btnCancel))
    $form.AcceptButton = $btnOk
    $form.CancelButton = $btnCancel

    if ($form.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return $null }

    $result = @{ Server = $txtServer.Text.Trim(); Credential = $null }
    if (-not $chkCurrent.Checked -and $txtUser.Text.Trim()) {
        $secure = ConvertTo-SecureString $txtPass.Text -AsPlainText -Force
        $result.Credential = New-Object System.Management.Automation.PSCredential($txtUser.Text.Trim(), $secure)
    }
    return $result
}

function Connect-ToVBR {
    <# Ensures a VBR session exists. Returns $true on success. #>

    if (Test-VBRConnected) { return $true }

    if ($Server) {
        try {
            Write-Log "Connecting to $Server (from -Server parameter)..." 'ACTION'
            Connect-VBRServer -Server $Server -ErrorAction Stop
            Write-Log "Connected to $Server."
            return $true
        }
        catch {
            Write-Log "Connection to $Server failed: $($_.Exception.Message)" 'ERROR'
        }
    }

    while ($true) {
        $choice = Show-ConnectDialog
        if ($null -eq $choice) {
            Write-Log "Connection cancelled by user." 'WARN'
            return $false
        }
        try {
            Write-Log "Connecting to $($choice.Server)..." 'ACTION'
            if ($choice.Credential) {
                Connect-VBRServer -Server $choice.Server -Credential $choice.Credential -ErrorAction Stop
            }
            else {
                Connect-VBRServer -Server $choice.Server -ErrorAction Stop
            }
            Write-Log "Connected to $($choice.Server)."
            return $true
        }
        catch {
            Write-Log "Connection failed: $($_.Exception.Message)" 'ERROR'
            $retry = [System.Windows.Forms.MessageBox]::Show(
                "Could not connect to '$($choice.Server)'.`n`n$($_.Exception.Message)`n`nTry again?",
                'Connection Failed', 'RetryCancel', 'Error')
            if ($retry -ne [System.Windows.Forms.DialogResult]::Retry) { return $false }
        }
    }
}

# ============================================================================
# DATA RETRIEVAL
# ============================================================================

function Get-PropertySafe {
    param($Object, [string] $Name, $Default = '')
    try {
        $prop = $Object.PSObject.Properties[$Name]
        if ($null -eq $prop) { return $Default }
        $value = $prop.Value
        if ($null -eq $value) { return $Default }
        return $value
    }
    catch { return $Default }
}

function Get-HostRow {
    <# Returns one row per host from Get-VBRServer. #>
    Write-Log "Querying hosts via Get-VBRServer..."
    $rows = @()
    foreach ($vbrHost in (Get-VBRServer)) {
        $rows += [pscustomobject]@{
            Kind        = 'Host'
            Name        = [string](Get-PropertySafe $vbrHost 'Name')
            Type        = [string](Get-PropertySafe $vbrHost 'Type')
            Id          = [string](Get-PropertySafe $vbrHost 'Id')
            Description = [string](Get-PropertySafe $vbrHost 'Description')
            ApiVersion  = [string](Get-PropertySafe $vbrHost 'ApiVersion')
            Object      = $vbrHost
        }
    }
    Write-Log "Retrieved $($rows.Count) host(s)."
    return $rows
}

function Get-ComponentRow {
    <# Returns one row per component for the supplied host rows. #>
    param([Parameter(Mandatory)] $HostRows)

    $rows = @()
    foreach ($row in $HostRows) {
        $physicalHost = $null
        try { $physicalHost = $row.Object.GetPhysicalHost() }
        catch {
            Write-Log "GetPhysicalHost() failed for '$($row.Name)': $($_.Exception.Message)" 'WARN'
            continue
        }
        if ($null -eq $physicalHost) {
            Write-Log "No physical host object for '$($row.Name)'." 'WARN'
            continue
        }

        $components = @()
        try { $components = $physicalHost.GetComponents() }
        catch {
            Write-Log "GetComponents() failed for '$($row.Name)': $($_.Exception.Message)" 'WARN'
            continue
        }

        foreach ($component in $components) {
            $rows += [pscustomobject]@{
                Kind         = 'Component'
                HostName     = $row.Name
                HostId       = $row.Id
                Type         = [string](Get-PropertySafe $component 'Type')
                Version      = [string](Get-PropertySafe $component 'Version')
                IsUpToDate   = [string](Get-PropertySafe $component 'IsUpToDate')
                HostObject   = $row.Object
                PhysicalHost = $physicalHost
                Object       = $component
            }
        }
        Write-Log "Host '$($row.Name)': $($components.Count) component(s)."
    }
    return $rows
}

function Get-JobReference {
    <# Advisory scan for jobs that reference a host. Removal is refused while referenced. #>
    param([Parameter(Mandatory)][string] $HostName)

    $hits = @()
    try {
        foreach ($job in (Get-VBRJob -ErrorAction Stop)) {
            $objects = @()
            try { $objects = $job.GetObjectsInJob() } catch { continue }
            foreach ($object in $objects) {
                $objectName = [string](Get-PropertySafe $object 'Name')
                $location   = [string](Get-PropertySafe $object 'Location')
                if ($objectName -eq $HostName -or
                    $objectName -like "*$HostName*" -or
                    $location   -like "*$HostName*") {
                    $hits += "$($job.Name)  ->  $objectName"
                }
            }
        }
    }
    catch {
        Write-Log "Job reference scan failed: $($_.Exception.Message)" 'WARN'
    }
    return $hits
}

function ConvertTo-DetailText {
    <# Flattens an object's properties into readable text for the details pane. #>
    param($Object, [string] $Title = 'DETAILS')

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("=== $Title ===")
    [void]$sb.AppendLine()

    if ($null -eq $Object) {
        [void]$sb.AppendLine('<no object>')
        return $sb.ToString()
    }

    foreach ($property in ($Object.PSObject.Properties | Sort-Object Name)) {
        $value = $null
        try { $value = $property.Value }
        catch { $value = "<error reading value: $($_.Exception.Message)>" }

        if ($null -eq $value) {
            $value = '<null>'
        }
        elseif ($value -is [string]) {
            # leave as-is
        }
        elseif ($value -is [System.Collections.IEnumerable]) {
            try { $value = (@($value) | ForEach-Object { "$_" }) -join ', ' }
            catch { $value = "<$($value.GetType().Name)>" }
        }

        [void]$sb.AppendLine(("{0,-34}: {1}" -f $property.Name, $value))
    }
    return $sb.ToString()
}

# ============================================================================
# REMOVAL ACTIONS
# ============================================================================

function Remove-SelectedHost {
    param([Parameter(Mandatory)] $Rows)

    $results = @()
    foreach ($row in $Rows) {
        try {
            Write-Log "Removing host '$($row.Name)' (Id $($row.Id))..." 'ACTION'
            Remove-VBRServer -Server $row.Object -ErrorAction Stop
            Write-Log "Removed host '$($row.Name)'." 'ACTION'
            $results += "OK      $($row.Name)  [$($row.Id)]"
        }
        catch {
            Write-Log "Failed to remove '$($row.Name)': $($_.Exception.Message)" 'ERROR'
            $results += "FAILED  $($row.Name)  ->  $($_.Exception.Message)"
        }
    }
    return $results
}

function Remove-SelectedComponent {
    param([Parameter(Mandatory)] $Rows)

    $results = @()
    foreach ($row in $Rows) {
        try {
            Write-Log "Removing component '$($row.Type)' from host '$($row.HostName)'..." 'ACTION'
            $target = $row.PhysicalHost.FindComponent($row.Object.Type)
            if ($null -eq $target) { throw "FindComponent('$($row.Type)') returned nothing." }
            $target.Delete()
            Write-Log "Removed component '$($row.Type)' from '$($row.HostName)'." 'ACTION'
            $results += "OK      $($row.HostName)  ->  $($row.Type)"
        }
        catch {
            Write-Log "Failed to remove component '$($row.Type)' from '$($row.HostName)': $($_.Exception.Message)" 'ERROR'
            $results += "FAILED  $($row.HostName) -> $($row.Type)  ->  $($_.Exception.Message)"
        }
    }
    return $results
}

function Show-TextDialog {
    <# Scrollable read-only text window. Returns the DialogResult. #>
    param(
        [Parameter(Mandatory)][string] $Title,
        [Parameter(Mandatory)][string] $Text,
        [switch] $Confirm
    )

    $form = New-Object System.Windows.Forms.Form -Property @{
        Text = $Title
        Size = New-Object System.Drawing.Size(760, 520)
        StartPosition = 'CenterParent'
    }
    $box = New-Object System.Windows.Forms.TextBox -Property @{
        Multiline = $true; ReadOnly = $true; ScrollBars = 'Both'; WordWrap = $false
        Dock = 'Fill'; Font = New-Object System.Drawing.Font('Consolas', 9)
        Text = $Text; BackColor = [System.Drawing.Color]::White
    }
    $panel = New-Object System.Windows.Forms.Panel -Property @{ Dock = 'Bottom'; Height = 48 }

    if ($Confirm) {
        $btnYes = New-Object System.Windows.Forms.Button -Property @{
            Text = 'Confirm Removal'; Size = New-Object System.Drawing.Size(140, 30)
            Location = New-Object System.Drawing.Point(455, 8); DialogResult = 'Yes'
        }
        $btnNo = New-Object System.Windows.Forms.Button -Property @{
            Text = 'Cancel'; Size = New-Object System.Drawing.Size(100, 30)
            Location = New-Object System.Drawing.Point(605, 8); DialogResult = 'No'
        }
        $panel.Controls.AddRange(@($btnYes, $btnNo))
        $form.AcceptButton = $btnNo
        $form.CancelButton = $btnNo
    }
    else {
        $btnClose = New-Object System.Windows.Forms.Button -Property @{
            Text = 'Close'; Size = New-Object System.Drawing.Size(100, 30)
            Location = New-Object System.Drawing.Point(605, 8); DialogResult = 'OK'
        }
        $panel.Controls.Add($btnClose)
        $form.AcceptButton = $btnClose
        $form.CancelButton = $btnClose
    }

    $form.Controls.AddRange(@($box, $panel))
    return $form.ShowDialog()
}

# ============================================================================
# MAIN UI
# ============================================================================

function Show-MainWindow {

    $script:CurrentView = 'Hosts'   # 'Hosts' | 'Components'
    $script:HostRows    = @()
    $script:Rows        = @()

    # --- Form ---------------------------------------------------------------
    $form = New-Object System.Windows.Forms.Form -Property @{
        Text = 'Host Manager'
        Size = New-Object System.Drawing.Size(1180, 720)
        StartPosition = 'CenterScreen'
        MinimumSize = New-Object System.Drawing.Size(900, 560)
    }

    # --- Toolbar ------------------------------------------------------------
    $toolbar = New-Object System.Windows.Forms.Panel -Property @{ Dock = 'Top'; Height = 84 }

    function New-ToolButton {
        param([string] $Text, [int] $X, [int] $Y, [int] $Width = 130, [string] $Tip = '')
        $button = New-Object System.Windows.Forms.Button -Property @{
            Text = $Text
            Location = New-Object System.Drawing.Point($X, $Y)
            Size = New-Object System.Drawing.Size($Width, 30)
        }
        if ($Tip) {
            $tooltip = New-Object System.Windows.Forms.ToolTip
            $tooltip.SetToolTip($button, $Tip)
        }
        return $button
    }

    $btnHosts      = New-ToolButton 'View Hosts'        10  8 130 'List every host returned by Get-VBRServer'
    $btnComponents = New-ToolButton 'View Components'  148  8 140 'Show components for the selected host(s)'
    $btnRefresh    = New-ToolButton 'Refresh'          296  8 100 'Reload the current view'
    $btnJobRefs    = New-ToolButton 'Check Job Refs'   404  8 130 'Find jobs referencing the selected host(s)'
    $btnPreview    = New-ToolButton 'Preview'          542  8 110 'Non-destructive summary of what would be removed'
    $btnRemove     = New-ToolButton 'Remove Selected'  660  8 140 'Remove the selected item(s)'
    $btnLog        = New-ToolButton 'Open Log'         808  8 100 'Open the session log file'

    $btnRemove.BackColor = [System.Drawing.Color]::MistyRose
    $btnRemove.Enabled   = $false
    $btnPreview.Enabled  = $false
    $btnJobRefs.Enabled  = $false

    $lblFilter = New-Object System.Windows.Forms.Label -Property @{
        Text = 'Filter:'; Location = New-Object System.Drawing.Point(10, 50)
        Size = New-Object System.Drawing.Size(45, 20); TextAlign = 'MiddleLeft'
    }
    $txtFilter = New-Object System.Windows.Forms.TextBox -Property @{
        Location = New-Object System.Drawing.Point(58, 48)
        Size = New-Object System.Drawing.Size(340, 22)
    }
    $lblMode = New-Object System.Windows.Forms.Label -Property @{
        Text = 'View: HOSTS'; Location = New-Object System.Drawing.Point(414, 50)
        Size = New-Object System.Drawing.Size(300, 20); TextAlign = 'MiddleLeft'
        Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    }

    $toolbar.Controls.AddRange(@(
        $btnHosts, $btnComponents, $btnRefresh, $btnJobRefs,
        $btnPreview, $btnRemove, $btnLog, $lblFilter, $txtFilter, $lblMode
    ))

    # --- Split: list on top, details below -----------------------------------
    # NOTE: SplitterDistance is deliberately NOT set here. New-Object -Property uses an
    # unordered hashtable, so it can be applied before Dock/Orientation and throw. It is
    # set in the Shown event once the control has a real size.
    $split = New-Object System.Windows.Forms.SplitContainer -Property @{
        Dock = 'Fill'; Orientation = 'Horizontal'
    }

    $listView = New-Object System.Windows.Forms.ListView -Property @{
        Dock = 'Fill'; View = 'Details'; FullRowSelect = $true; GridLines = $true
        MultiSelect = $true; HideSelection = $false
    }
    $split.Panel1.Controls.Add($listView)

    $detail = New-Object System.Windows.Forms.TextBox -Property @{
        Dock = 'Fill'; Multiline = $true; ReadOnly = $true; ScrollBars = 'Both'
        WordWrap = $false; Font = New-Object System.Drawing.Font('Consolas', 9)
        BackColor = [System.Drawing.Color]::White
    }
    $split.Panel2.Controls.Add($detail)

    # --- Status bar ---------------------------------------------------------
    $statusStrip = New-Object System.Windows.Forms.StatusStrip
    $statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel -Property @{ Text = 'Ready' }
    [void]$statusStrip.Items.Add($statusLabel)

    $form.Controls.AddRange(@($split, $toolbar, $statusStrip))

    # --- Helpers ------------------------------------------------------------

    function Set-Status {
        param([string] $Text)
        $statusLabel.Text = $Text
        $statusStrip.Refresh()
    }

    function Get-SelectedRow {
        $selected = @()
        foreach ($item in $listView.SelectedItems) { $selected += $item.Tag }
        return $selected
    }

    function Update-ActionButton {
        $count = $listView.SelectedItems.Count
        $btnRemove.Enabled  = ($count -gt 0)
        $btnPreview.Enabled = ($count -gt 0)
        $btnJobRefs.Enabled = ($count -gt 0 -and $script:CurrentView -eq 'Hosts')
        $btnComponents.Enabled = ($script:CurrentView -eq 'Hosts')
    }

    function Update-ListView {
        param($Rows)

        $filter = $txtFilter.Text.Trim()
        $listView.BeginUpdate()
        $listView.Items.Clear()
        $listView.Columns.Clear()

        if ($script:CurrentView -eq 'Hosts') {
            [void]$listView.Columns.Add('Name', 220)
            [void]$listView.Columns.Add('Type', 190)
            [void]$listView.Columns.Add('Id', 300)
            [void]$listView.Columns.Add('Description', 380)
        }
        else {
            [void]$listView.Columns.Add('Host', 220)
            [void]$listView.Columns.Add('Component Type', 220)
            [void]$listView.Columns.Add('Version', 140)
            [void]$listView.Columns.Add('Up To Date', 100)
            [void]$listView.Columns.Add('Host Id', 300)
        }

        $shown = 0
        foreach ($row in $Rows) {
            if ($filter) {
                $haystack = ($row.PSObject.Properties |
                    Where-Object { $_.Name -notin @('Object', 'HostObject', 'PhysicalHost') } |
                    ForEach-Object { "$($_.Value)" }) -join ' '
                if ($haystack -notlike "*$filter*") { continue }
            }

            if ($script:CurrentView -eq 'Hosts') {
                $item = New-Object System.Windows.Forms.ListViewItem($row.Name)
                [void]$item.SubItems.Add($row.Type)
                [void]$item.SubItems.Add($row.Id)
                [void]$item.SubItems.Add($row.Description)
            }
            else {
                $item = New-Object System.Windows.Forms.ListViewItem($row.HostName)
                [void]$item.SubItems.Add($row.Type)
                [void]$item.SubItems.Add($row.Version)
                [void]$item.SubItems.Add($row.IsUpToDate)
                [void]$item.SubItems.Add($row.HostId)
            }
            $item.Tag = $row
            [void]$listView.Items.Add($item)
            $shown++
        }

        $listView.EndUpdate()
        $lblMode.Text = "View: $($script:CurrentView.ToUpper())"
        Set-Status "$shown item(s) displayed$(if ($filter) { " (filter: '$filter')" })  |  Log: $script:LogPath"
        Update-ActionButton
    }

    function Show-HostView {
        Set-Status 'Loading hosts...'
        try {
            $script:HostRows = @(Get-HostRow)
            $script:Rows = $script:HostRows
            $script:CurrentView = 'Hosts'
            $detail.Text = ''
            Update-ListView -Rows $script:Rows
        }
        catch {
            Write-Log "Failed to load hosts: $($_.Exception.Message)" 'ERROR'
            [System.Windows.Forms.MessageBox]::Show("Failed to load hosts.`n`n$($_.Exception.Message)",
                'Error', 'OK', 'Error') | Out-Null
        }
    }

    function Show-ComponentView {
        $selected = Get-SelectedRow
        if ($selected.Count -eq 0) {
            $answer = [System.Windows.Forms.MessageBox]::Show(
                "No host selected.`n`nLoad components for ALL hosts? This can take a while on large environments.",
                'Load All Components', 'YesNo', 'Question')
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
            $selected = $script:HostRows
        }

        Set-Status "Loading components for $($selected.Count) host(s)..."
        try {
            $script:Rows = @(Get-ComponentRow -HostRows $selected)
            $script:CurrentView = 'Components'
            $detail.Text = ''
            Update-ListView -Rows $script:Rows
            if ($script:Rows.Count -eq 0) {
                Set-Status 'No components found on the selected host(s).'
            }
        }
        catch {
            Write-Log "Failed to load components: $($_.Exception.Message)" 'ERROR'
            [System.Windows.Forms.MessageBox]::Show("Failed to load components.`n`n$($_.Exception.Message)",
                'Error', 'OK', 'Error') | Out-Null
        }
    }

    # --- Events -------------------------------------------------------------

    $listView.Add_SelectedIndexChanged({
        Update-ActionButton
        if ($listView.SelectedItems.Count -eq 0) { $detail.Text = ''; return }

        $row = $listView.SelectedItems[0].Tag
        if ($row.Kind -eq 'Host') {
            $text = ConvertTo-DetailText -Object $row.Object -Title "HOST: $($row.Name)"
            $text += "`r`n=== SUMMARY ===`r`n"
            $text += ("{0,-34}: {1}`r`n" -f 'Row Type', $row.Type)
            $text += ("{0,-34}: {1}`r`n" -f 'Row Id', $row.Id)
        }
        else {
            $text  = ConvertTo-DetailText -Object $row.Object -Title "COMPONENT: $($row.Type)"
            $text += "`r`n=== PARENT HOST ===`r`n"
            $text += ("{0,-34}: {1}`r`n" -f 'Host Name', $row.HostName)
            $text += ("{0,-34}: {1}`r`n" -f 'Host Id', $row.HostId)
        }

        if ($listView.SelectedItems.Count -gt 1) {
            $text = "*** $($listView.SelectedItems.Count) items selected - showing the first ***`r`n`r`n" + $text
        }
        $detail.Text = $text
    })

    $btnHosts.Add_Click({ Show-HostView })
    $btnComponents.Add_Click({ Show-ComponentView })

    $btnRefresh.Add_Click({
        if ($script:CurrentView -eq 'Hosts') { Show-HostView }
        else { Update-ListView -Rows $script:Rows }
    })

    $txtFilter.Add_TextChanged({ Update-ListView -Rows $script:Rows })

    $btnLog.Add_Click({
        if (Test-Path -LiteralPath $script:LogPath) { Start-Process notepad.exe $script:LogPath }
        else { [System.Windows.Forms.MessageBox]::Show('No log file yet.', 'Log', 'OK', 'Information') | Out-Null }
    })

    $btnJobRefs.Add_Click({
        $selected = Get-SelectedRow
        if ($selected.Count -eq 0) { return }
        Set-Status 'Scanning jobs...'

        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine('JOB REFERENCE SCAN')
        [void]$sb.AppendLine('Removal is refused while a server is referenced by a job.')
        [void]$sb.AppendLine(('-' * 78))
        foreach ($row in $selected) {
            [void]$sb.AppendLine()
            [void]$sb.AppendLine("HOST: $($row.Name)  [$($row.Id)]")
            $hits = Get-JobReference -HostName $row.Name
            if ($hits.Count -eq 0) { [void]$sb.AppendLine('    No job references found.') }
            else { foreach ($hit in $hits) { [void]$sb.AppendLine("    $hit") } }
        }
        Set-Status 'Job scan complete.'
        Show-TextDialog -Title 'Job References' -Text $sb.ToString() | Out-Null
    })

    $btnPreview.Add_Click({
        $selected = Get-SelectedRow
        if ($selected.Count -eq 0) { return }
        Set-Status 'Building preview...'

        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine('PREVIEW - NO CHANGES WILL BE MADE')
        [void]$sb.AppendLine(('-' * 78))
        [void]$sb.AppendLine("View  : $($script:CurrentView)")
        [void]$sb.AppendLine("Items : $($selected.Count)")
        [void]$sb.AppendLine()

        foreach ($row in $selected) {
            if ($row.Kind -eq 'Host') {
                [void]$sb.AppendLine("HOST: $($row.Name)")
                [void]$sb.AppendLine("    Type       : $($row.Type)")
                [void]$sb.AppendLine("    Id         : $($row.Id)")
                [void]$sb.AppendLine("    Description: $($row.Description)")

                $hits = Get-JobReference -HostName $row.Name
                if ($hits.Count -gt 0) {
                    [void]$sb.AppendLine("    !! REFERENCED BY $($hits.Count) JOB OBJECT(S) - removal will likely fail:")
                    foreach ($hit in $hits) { [void]$sb.AppendLine("       $hit") }
                }
                else {
                    [void]$sb.AppendLine('    No job references found.')
                }

                try {
                    $whatIf = (& { Remove-VBRServer -Server $row.Object -WhatIf } *>&1 | Out-String).Trim()
                    if ($whatIf) { [void]$sb.AppendLine("    WhatIf: $whatIf") }
                }
                catch {
                    [void]$sb.AppendLine("    WhatIf raised: $($_.Exception.Message)")
                }
            }
            else {
                [void]$sb.AppendLine("COMPONENT: $($row.Type)")
                [void]$sb.AppendLine("    Host    : $($row.HostName)  [$($row.HostId)]")
                [void]$sb.AppendLine("    Version : $($row.Version)")
                [void]$sb.AppendLine("    UpToDate: $($row.IsUpToDate)")
            }
            [void]$sb.AppendLine()
        }

        Set-Status 'Preview ready.'
        Show-TextDialog -Title 'Preview' -Text $sb.ToString() | Out-Null
    })

    $btnRemove.Add_Click({
        $selected = Get-SelectedRow
        if ($selected.Count -eq 0) { return }

        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine('THE FOLLOWING WILL BE PERMANENTLY REMOVED')
        [void]$sb.AppendLine(('-' * 78))
        [void]$sb.AppendLine()
        foreach ($row in $selected) {
            if ($row.Kind -eq 'Host') {
                [void]$sb.AppendLine("HOST       $($row.Name)   [$($row.Type)]   $($row.Id)")
            }
            else {
                [void]$sb.AppendLine("COMPONENT  $($row.Type)   on host $($row.HostName)")
            }
        }
        [void]$sb.AppendLine()
        [void]$sb.AppendLine(('-' * 78))
        [void]$sb.AppendLine('Confirm you have a current configuration backup and that no jobs are running.')
        [void]$sb.AppendLine('This action cannot be undone from within this tool.')

        $answer = Show-TextDialog -Title 'Confirm Removal' -Text $sb.ToString() -Confirm
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            Write-Log 'Removal cancelled by user.' 'WARN'
            Set-Status 'Removal cancelled.'
            return
        }

        Set-Status "Removing $($selected.Count) item(s)..."
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            if ($script:CurrentView -eq 'Hosts') { $results = Remove-SelectedHost -Rows $selected }
            else { $results = Remove-SelectedComponent -Rows $selected }
        }
        finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }

        $summary = "RESULTS`r`n" + ('-' * 78) + "`r`n" + ($results -join "`r`n") +
                   "`r`n`r`nLog file: $script:LogPath"
        Show-TextDialog -Title 'Removal Results' -Text $summary | Out-Null

        if ($script:CurrentView -eq 'Hosts') { Show-HostView } else { Show-ComponentView }
    })

    $form.Add_Shown({
        $form.Activate()
        try { $split.SplitterDistance = [int]($split.Height * 0.55) } catch { }
        Show-HostView
    })

    [void]$form.ShowDialog()
}

# ============================================================================
# ENTRY POINT
# ============================================================================

try {
    Invoke-PreFlightCheck

    if (-not (Initialize-VeeamModule)) {
        [System.Windows.Forms.MessageBox]::Show(
            "The Veeam PowerShell module could not be loaded.`n`nInstall the Veeam Backup & Replication console on this machine, or run this script from the Veeam PowerShell console.",
            'Veeam Module Not Found', 'OK', 'Error') | Out-Null
        return
    }

    if (-not (Connect-ToVBR)) {
        Write-Log 'No VBR connection established. Exiting.' 'WARN'
        return
    }

    Show-MainWindow
    Write-Log 'UI closed.'
}
catch {
    Write-Log "Unhandled error: $($_.Exception.Message)" 'ERROR'
    Write-Log $_.ScriptStackTrace 'ERROR'
    try {
        [System.Windows.Forms.MessageBox]::Show(
            "Unhandled error:`n`n$($_.Exception.Message)`n`nSee log:`n$script:LogPath",
            'Error', 'OK', 'Error') | Out-Null
    }
    catch { }
}
finally {
    Write-Log "Session log written to: $script:LogPath"
}

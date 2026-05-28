# Requires Veeam Backup & Replication PowerShell Module
# Run on a Veeam Backup Server or a machine with the Veeam Console installed

$RequiredModule = "Veeam.Backup.PowerShell"

if (-not (Get-Module -ListAvailable -Name $RequiredModule)) {
    Write-Output ""
    Write-Output "Required PowerShell module not found: $RequiredModule"
    Write-Output ""
    Write-Output "Install one of the following:"
    Write-Output " - Veeam Backup & Replication Console"
    Write-Output " - Veeam Backup Server"
    Write-Output ""
    Write-Output "Then re-run the script."
    return
}

Import-Module $RequiredModule -ErrorAction Stop

# Interactive Veeam NAS/File Share Backup Search

$VeeamServer = "<your Veeam server FQDN>"
$CredentialPath = "<path to encrypted credential file>"

if (-not (Test-Path $CredentialPath)) {
    Write-Output "Credential file not found: $CredentialPath"
    Write-Output "Create it first with Export-Clixml."
    return
}

$Credential = Import-Clixml -Path $CredentialPath

Connect-VBRServer -Server $VeeamServer -Credential $Credential

try {
    $backups = Get-VBRUnstructuredBackup | Sort-Object Name

    if (-not $backups) {
        Write-Output "No unstructured/File Share backups found."
        return
    }

    Write-Output ""
    Write-Output "Available File Share / Unstructured Backups:"
    Write-Output "--------------------------------------------"

    for ($i = 0; $i -lt $backups.Count; $i++) {
        Write-Output ("[{0}] {1}" -f ($i + 1), $backups[$i].Name)
    }

    Write-Output ""

    do {
        $selection = Read-Host "Enter the number of the backup to search"
    } until (
        $selection -as [int] -and
        [int]$selection -ge 1 -and
        [int]$selection -le $backups.Count
    )

    $backup = $backups[[int]$selection - 1]
    $SearchText = Read-Host "Enter file/folder search text"

    $StartDateInput = Read-Host "Optional FROM date, example 2025-12-01. Press Enter to skip"
    $EndDateInput   = Read-Host "Optional TO date, example 2025-12-31. Press Enter to skip"

    $StartDate = $null
    $EndDate = $null

    if (-not [string]::IsNullOrWhiteSpace($StartDateInput)) {
        $StartDate = [datetime]::Parse($StartDateInput)
    }

    if (-not [string]::IsNullOrWhiteSpace($EndDateInput)) {
        $EndDate = [datetime]::Parse($EndDateInput).Date.AddDays(1).AddSeconds(-1)
    }

    Write-Output ""
    Write-Output ("Selected backup: {0}" -f $backup.Name)
    Write-Output ("Searching for: {0}" -f $SearchText)

    if ($StartDate) {
        Write-Output ("From date: {0}" -f $StartDate)
    }

    if ($EndDate) {
        Write-Output ("To date: {0}" -f $EndDate)
    }

    Write-Output ""

    $restorePoints = Get-VBRUnstructuredBackupRestorePoint -Backup $backup |
        Where-Object {
            ($null -eq $StartDate -or $_.CreationTime -ge $StartDate) -and
            ($null -eq $EndDate -or $_.CreationTime -le $EndDate)
        } |
        Sort-Object CreationTime -Descending

    if (-not $restorePoints) {
        Write-Output "No restore points found for this backup/date range."
        return
    }

    $found = $false
    $SearchTextLower = $SearchText.ToLower()

    foreach ($rp in $restorePoints) {
        Write-Output ("Searching restore point: {0}" -f $rp.CreationTime)

        $session = $null

        try {
            $session = Start-VBRUnstructuredBackupFLRSession -RestorePoint $rp

            $searchResults = Get-VBRUnstructuredBackupFLRItem -Session $session -Recurse |
                Where-Object {
                    $_.Name.ToLower().Contains($SearchTextLower) -or
                    $_.Path.ToLower().Contains($SearchTextLower)
                }

            if ($searchResults) {
                Write-Output ""
                Write-Output ("Match found in restore point: {0}" -f $rp.CreationTime)
                Write-Output ""

                $searchResults | Select-Object `
                    @{Name="RestorePointTime"; Expression={$rp.CreationTime}},
                    Name,
                    Path,
                    Size,
                    Type |
                    Format-Table -AutoSize

                $found = $true
                break
            }
        }
        catch {
            $ErrorMessage = $_.Exception.Message
            Write-Warning ("Failed to process restore point {0}: {1}" -f $rp.CreationTime, $ErrorMessage)
        }
        finally {
            if ($session) {
                Stop-VBRUnstructuredBackupFLRSession -Session $session
            }
        }
    }

    if (-not $found) {
        Write-Output ""
        Write-Output ("No matches found for '{0}' in backup '{1}' using the selected restore point range." -f $SearchText, $backup.Name)
    }
}
finally {
    Disconnect-VBRServer
}
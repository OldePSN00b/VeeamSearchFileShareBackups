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
    Write-Output 'Create it first with:'
    Write-Output 'Get-Credential -UserName "DOMAIN\svc-veeam-search" | Export-Clixml -Path "C:\Secure\veeam-search-credential.xml"'
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
    }
    until (
        $selection -as [int] -and
        [int]$selection -ge 1 -and
        [int]$selection -le $backups.Count
    )

    $backup = $backups[[int]$selection - 1]

    $SearchText = Read-Host "Enter search text"

    $SearchType = Read-Host "Search type: File, Folder, or Any. Default is Folder"

    if ([string]::IsNullOrWhiteSpace($SearchType)) {
        $SearchType = "Folder"
    }

    $SearchRoot = Read-Host "Optional starting folder path, example \Accounting\2nd Folder\3rd Folder. Press Enter for whole backup"

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

        Write-Output ""
        Write-Output ("Searching restore point: {0}" -f $rp.CreationTime)

        $session = $null
        $searchResults = $null

        try {

            Write-Output "Starting FLR session..."

            $session = Start-VBRUnstructuredBackupFLRSession -RestorePoint $rp

            Write-Output "FLR session started."
            Write-Output "Getting top-level items..."

            $rootItems = Get-VBRUnstructuredBackupFLRItem -Session $session

            Write-Output ("Top-level item count: {0}" -f @($rootItems).Count)

            if (-not [string]::IsNullOrWhiteSpace($SearchRoot)) {

                Write-Output ("Walking directly to search root: {0}" -f $SearchRoot)

                $pathParts = $SearchRoot.Trim("\").Split("\")
                $currentItems = $rootItems
                $searchRootFolder = $null

                foreach ($part in $pathParts) {

                    Write-Output ("Looking for folder: {0}" -f $part)

                    $normalizedPart = $part.Trim()

                    $searchRootFolder = $currentItems |
                        Where-Object {

                            $itemName = $_.Name.Trim()

                            (
                                $itemName -ieq $normalizedPart -or
                                $itemName.ToLower().Contains($normalizedPart.ToLower()) -or
                                $normalizedPart.ToLower().Contains($itemName.ToLower())
                            ) -and
                            (
                                $_.Type -like "*Folder*" -or
                                $_.IsDirectory
                            )
                        } |
                        Select-Object -First 1

                    if (-not $searchRootFolder) {

                        Write-Output ("Folder not found while walking path: {0}" -f $part)
                        Write-Output ("Full requested search root was: {0}" -f $SearchRoot)

                        $rootItems = $null
                        break
                    }

                    Write-Output ("Entering folder: {0}" -f $searchRootFolder.Path)

                    $currentItems = Get-VBRUnstructuredBackupFLRItem `
                        -Session $session `
                        -Folder $searchRootFolder
                }

                if ($searchRootFolder) {

                    Write-Output ("Search will start under: {0}" -f $searchRootFolder.Path)

                    $rootItems = $currentItems
                }
            }

            if (-not $rootItems) {
                continue
            }

            $foldersToSearch = New-Object System.Collections.Queue

            foreach ($item in $rootItems) {

                $itemIsFolder = $item.Type -like "*Folder*" -or $item.IsDirectory
                $itemIsFile = -not $itemIsFolder

                $typeMatches =
                    ($SearchType -ieq "Any") -or
                    ($SearchType -ieq "Folder" -and $itemIsFolder) -or
                    ($SearchType -ieq "File" -and $itemIsFile)

                $textMatches =
                    $item.Name.ToLower().Contains($SearchTextLower) -or
                    $item.Path.ToLower().Contains($SearchTextLower)

                if ($typeMatches -and $textMatches) {

                    if (-not $searchResults) {
                        $searchResults = @()
                    }

                    $searchResults += $item
                }

                if ($itemIsFolder) {
                    $foldersToSearch.Enqueue($item)
                }
            }

            while ($foldersToSearch.Count -gt 0) {

                $currentFolder = $foldersToSearch.Dequeue()

                Write-Output ("Searching folder: {0}" -f $currentFolder.Path)

                $childItems = Get-VBRUnstructuredBackupFLRItem `
                    -Session $session `
                    -Folder $currentFolder

                foreach ($item in $childItems) {

                    $itemIsFolder = $item.Type -like "*Folder*" -or $item.IsDirectory
                    $itemIsFile = -not $itemIsFolder

                    $typeMatches =
                        ($SearchType -ieq "Any") -or
                        ($SearchType -ieq "Folder" -and $itemIsFolder) -or
                        ($SearchType -ieq "File" -and $itemIsFile)

                    $textMatches =
                        $item.Name.ToLower().Contains($SearchTextLower) -or
                        $item.Path.ToLower().Contains($SearchTextLower)

                    if ($typeMatches -and $textMatches) {

                        if (-not $searchResults) {
                            $searchResults = @()
                        }

                        $searchResults += $item
                    }

                    if ($itemIsFolder) {
                        $foldersToSearch.Enqueue($item)
                    }
                }
            }

            if ($searchResults) {

                Write-Output ""
                Write-Output ("Found {0} matching item(s) in restore point: {1}" -f $searchResults.Count, $rp.CreationTime)
                Write-Output ""

                for ($i = 0; $i -lt $searchResults.Count; $i++) {

                    $result = $searchResults[$i]

                    Write-Output ("[{0}] {1}" -f ($i + 1), $result.Name)
                    Write-Output ("     Path: {0}" -f $result.Path)
                    Write-Output ("     Type: {0}" -f $result.Type)
                    Write-Output ""
                }

                do {
                    $restoreSelection = Read-Host "Enter the number of the item to restore, or press Enter to skip"

                    if ([string]::IsNullOrWhiteSpace($restoreSelection)) {
                        break
                    }

                }
                until (
                    $restoreSelection -as [int] -and
                    [int]$restoreSelection -ge 1 -and
                    [int]$restoreSelection -le $searchResults.Count
                )

                if (-not [string]::IsNullOrWhiteSpace($restoreSelection)) {

                    $selectedResult = $searchResults[[int]$restoreSelection - 1]

                    $restoreChoice = Read-Host "Restore ONLY this selected item to a sibling Restored_<name> folder? Type RESTORE to continue"

                    if ($restoreChoice -eq "RESTORE") {

                        $safeRecoveredName = $selectedResult.Name -replace '[\\/:*?"<>|]', '_'
                        $restoredFolderName = "Restored_{0}" -f $safeRecoveredName

                        $originalPath = $selectedResult.Path

                        if ([string]::IsNullOrWhiteSpace($originalPath)) {
                            Write-Output "The selected item does not have a usable Path value."
                            break
                        }

                        $originalPath = $originalPath.TrimEnd("\")

                        $parentPath = Split-Path -Path $originalPath -Parent

                        if ([string]::IsNullOrWhiteSpace($parentPath)) {
                            Write-Output "Could not determine parent path from:"
                            Write-Output $originalPath
                            break
                        }

                        $destinationPath = Join-Path `
                            -Path $parentPath `
                            -ChildPath $restoredFolderName

                        $pathServerName = $null

                        if ($selectedResult.Path -match '^\\\\([^\\]+)\\') {
                            $pathServerName = $Matches[1]
                        }

                        $targetServer = $null

                        if ($pathServerName) {

                            $targetServer = Get-VBRUnstructuredServer |
                                Where-Object {
                                    $_.Name -ieq $pathServerName -or
                                    $_.Name -like "$pathServerName.*"
                                } |
                                Select-Object -First 1
                        }

                        if (-not $targetServer) {

                            $unstructuredServers = Get-VBRUnstructuredServer | Sort-Object Name

                            Write-Output ""
                            Write-Output "Could not auto-detect target restore server."

                            for ($i = 0; $i -lt $unstructuredServers.Count; $i++) {
                                Write-Output ("[{0}] {1}" -f ($i + 1), $unstructuredServers[$i].Name)
                            }

                            Write-Output ""

                            do {
                                $serverSelection = Read-Host "Enter the number of the target restore server"
                            }
                            until (
                                $serverSelection -as [int] -and
                                [int]$serverSelection -ge 1 -and
                                [int]$serverSelection -le $unstructuredServers.Count
                            )

                            $targetServer = $unstructuredServers[[int]$serverSelection - 1]
                        }
                        else {
                            Write-Output ("Auto-detected target restore server: {0}" -f $targetServer.Name)
                        }

                        Write-Output ""
                        Write-Output "Restore summary:"
                        Write-Output ("Source item:      {0}" -f $selectedResult.Path)
                        Write-Output ("Destination path: {0}" -f $destinationPath)
                        Write-Output ("Target server:    {0}" -f $targetServer.Name)
                        Write-Output ""

                        $finalConfirm = Read-Host "Type YES to restore ONLY this selected item"

                        if ($finalConfirm -eq "YES") {

                            $selectedResult |
                                Save-VBRUnstructuredBackupFLRItem `
                                    -Server $targetServer `
                                    -Path $destinationPath `
                                    -PreservePermissions

                            Write-Output "Restore command completed."
                        }
                        else {
                            Write-Output "Restore cancelled."
                        }
                    }
                }

                $found = $true
                break
            }
        }
        catch {

            $ErrorMessage = $_.Exception.Message

            Write-Warning (
                "Failed to process restore point {0}: {1}" -f
                $rp.CreationTime,
                $ErrorMessage
            )
        }
        finally {

            if ($session) {
                Stop-VBRUnstructuredBackupFLRSession -Session $session
            }
        }
    }

    if (-not $found) {

        Write-Output ""
        Write-Output (
            "No matches found for '{0}' in backup '{1}' using the selected restore point range." -f
            $SearchText,
            $backup.Name
        )
    }
}
finally {

    Disconnect-VBRServer
}

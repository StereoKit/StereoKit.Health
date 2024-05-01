param (
    [string]$branch = "develop",
    [string]$commit = $null
)

# Define the repository URL and the target directory
$repoUrl   = "https://github.com/StereoKit/StereoKit"
$targetDir = "StereoKit"

# Function to remove ANSI color escape sequences
function Remove-ANSIEscapeSequences {
    param([string]$Text)
    $esc = [char]27
    $Text -replace "$esc\[[0-9;]*m", ""
}

Write-Host "Updating repository..."

# Update the repository
if (Test-Path -Path $targetDir) {
    Push-Location -Path $targetDir
    git fetch --all | Out-Null
    git checkout $branch >$null 2>&1
    git pull origin $branch >$null 2>&1
    Pop-Location
} else {
    git clone "$repoUrl.git" -b $branch $targetDir | Out-Null
}
Push-Location -Path $targetDir

if ($null -ne $commit -and $commit -ne "") {
    git checkout $commit >$null 2>&1
}

$currentCommitHash = git rev-parse HEAD
Write-Host "Repository at: $currentCommitHash"

# Build all of the code
Write-Host "Building native..."
cmake --preset Linux_x64_Release | Out-Null
cmake --build --preset Linux_x64_Release | Out-Null
Write-Host "Building managed..."
dotnet build Examples/StereoKitTest/StereoKitTest.csproj --configuration Release | Out-Null

# Run the tests
Write-Host "Running tests..."
if (-Not (Test-Path -Path "$PSScriptRoot/screenshots")) { New-Item -Path "$PSScriptRoot/screenshots" -ItemType Directory }
$output = dotnet run --project Examples/StereoKitTest/StereoKitTest.csproj --configuration Release -- -test -headless -screenfolder "$PSScriptRoot/screenshots" 2>&1
$stdOut = $output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }
$stdErr = $output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }

Pop-Location

Write-Host "Collecting data..."

if (-Not (Test-Path -Path "logs")) { New-Item -Path "logs" -ItemType Directory }
if (-Not (Test-Path -Path "data")) { New-Item -Path "data" -ItemType Directory }

# Write the log to the file
$logFilename = "logs/$currentCommitHash.linux.txt"
$fileOutput  = $output -join "`n"
$fileOutput  = Remove-ANSIEscapeSequences -Text $fileOutput
$fileOutput  | Out-File -FilePath $logFilename

# Filter the output for SK Errors not preceded by expected error warnings
$filteredErrors = @()
$expectingError = $false
foreach ($line in $stdOut -split "\n") {
    $cleanLine = Remove-ANSIEscapeSequences -Text $line
    if ($cleanLine -match "\[SK warning\] Expected error:") {
        $expectingError = $true
    } elseif ($cleanLine -match "\[SK error\]") {
        if (-not $expectingError) {
            $filteredErrors += $line
        }
        $expectingError = $false
    } else {
        $expectingError = $false
    }
}

# Find the size of the native binary
$binarySize = (Get-Item "StereoKit\bin\distribute\bin\Linux\x64\Release\libStereoKitC.so").length

# Load the list of previous runs so we can insert our latest one
$runDataFile = "data/runs.json"
if (Test-Path $runDataFile) {
    $entriesList = @(Get-Content -Path $runDataFile | ConvertFrom-Json)
} else {
    $entriesList = @()
}

$entryObject = [PSCustomObject]@{
    Branch = $branch
    Commit = $currentCommitHash
    LErrs  = $filteredErrors.Length
    LCrash = $stdErr.Length -ne 0
    LSize  = $binarySize
}

# Remove any item with an identical commit hash
$entriesList = @($entriesList | Where-Object {$_.Commit -ne $currentCommitHash})

$entriesList += $entryObject
$entriesList | ConvertTo-Json | Set-Content -Path $runDataFile

# Print 'em up
$content = @()
$content += "| Branch | Commit | Errors | Crash | Logs | Binary Size |"
$content += "| ------ | ------ | ------ | ----- | ---- | ----------- |"
$startIndex  = [Math]::Max(0, $entriesList.Count - 20)
$lastEntries = @($entriesList[$startIndex..($entriesList.Count-1)])
[array]::Reverse($lastEntries)
foreach ($entry in $lastEntries) {
    $content += "| $($entry.Branch) | [$($entry.Commit.Substring(0, 7))]($repoUrl/commit/$($entry.Commit)) | $($entry.LErrs) | $($entry.LCrash) | [Linux log](logs/$($entry.Commit).linux.txt) | $([Math]::Round($entry.LSize/1024, 2)) kb |"
}
$content | Set-Content "readme.md"

Write-Host "Done! $($entryObject.LErrs) errors, crashed: $($entryObject.LCrash)"
# $date = Get-Date -Format "yyyy-MM-dd"
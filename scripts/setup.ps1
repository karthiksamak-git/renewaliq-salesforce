#Requires -Version 5.1
<#
.SYNOPSIS
    One-command RenewalIQ setup on Windows: scratch org, deploy, permissions, demo data.

.DESCRIPTION
    Creates a scratch org from config/project-scratch-def.json, deploys the project,
    assigns every permission set, loads the synthetic demo book, scores it, schedules
    the nightly jobs and opens the org.

    Idempotent: an existing scratch org with the same alias is reused, the deploy is
    incremental, the seed script skips accounts that already exist, and the scheduler
    replaces its own jobs instead of adding duplicates. Safe to re-run.

.PARAMETER Alias
    Scratch org alias. Default: renewaliq

.PARAMETER DurationDays
    Scratch org lifetime in days. Default: 7

.PARAMETER DevHub
    Dev Hub username or alias. Default: the CLI's default Dev Hub, else the first one found.

.PARAMETER NoBrowser
    Do not open the org in a browser at the end.

.EXAMPLE
    pwsh -File scripts/setup.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts/setup.ps1 -Alias riq-demo -DurationDays 2 -NoBrowser
#>
[CmdletBinding()]
param(
    [string]$Alias = 'renewaliq',
    [int]$DurationDays = 7,
    [string]$DevHub = '',
    [switch]$NoBrowser
)

$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Detail {
    param([string]$Message)
    Write-Host "    $Message" -ForegroundColor DarkGray
}

function Write-Ok {
    param([string]$Message)
    Write-Host "    OK: $Message" -ForegroundColor Green
}

function Write-Caution {
    param([string]$Message)
    Write-Host "    WARNING: $Message" -ForegroundColor Yellow
}

function Stop-Setup {
    param([string]$Message)
    Write-Host "`nFAILED: $Message" -ForegroundColor Red
    exit 1
}

function Invoke-Sf {
    param(
        [Parameter(Mandatory = $true)][string[]]$SfArguments,
        [switch]$AllowFailure
    )

    & sf @SfArguments
    $exitCode = $LASTEXITCODE

    if ($exitCode -ne 0 -and -not $AllowFailure) {
        Stop-Setup "sf $($SfArguments -join ' ') exited with code $exitCode."
    }

    return $exitCode
}

function Get-OrgList {
    $raw = & sf org list --json
    if ($LASTEXITCODE -ne 0) {
        Stop-Setup 'Could not list orgs. Run "sf org login web" first.'
    }
    $parsed = $raw | ConvertFrom-Json
    $result = $parsed.result

    $all = @()
    if ($null -ne $result.nonScratchOrgs) { $all += @($result.nonScratchOrgs) }
    if ($null -ne $result.scratchOrgs) { $all += @($result.scratchOrgs) }

    return $all
}

# ---------------------------------------------------------------------------------------
# 1. Run from the repository root, whatever directory the user started in.
# ---------------------------------------------------------------------------------------
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $repoRoot

if (-not (Test-Path -LiteralPath (Join-Path $repoRoot 'sfdx-project.json'))) {
    Stop-Setup "sfdx-project.json not found in $repoRoot - run this script from inside the repository."
}

Write-Host 'RenewalIQ setup' -ForegroundColor White
Write-Detail "Repository: $repoRoot"

# ---------------------------------------------------------------------------------------
# 2. Prerequisites. Java is only needed for static analysis, so it is a warning.
# ---------------------------------------------------------------------------------------
Write-Step 'Checking prerequisites'

foreach ($tool in @('sf', 'node', 'git')) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Stop-Setup "$tool is not on PATH. Install it, reopen the terminal, and run this script again."
    }
    Write-Ok "$tool found"
}

if (-not (Get-Command java -ErrorAction SilentlyContinue)) {
    Write-Caution 'java not found - setup does not need it, but "npm run prettier" (Apex) and PMD do.'
}
else {
    Write-Ok 'java found'
}

if (-not (Test-Path -LiteralPath (Join-Path $repoRoot 'node_modules'))) {
    Write-Detail 'node_modules is missing (only needed for lint and Jest, not for setup).'
}

# ---------------------------------------------------------------------------------------
# 3. Which Dev Hub creates the org?
# ---------------------------------------------------------------------------------------
Write-Step 'Finding a Dev Hub'

if (-not $DevHub) {
    # "sf config get" returns an empty result object when the value is unset, so the
    # property is read through a lookup rather than assumed to exist.
    $configJson = & sf config get target-dev-hub --json 2>$null
    if ($LASTEXITCODE -eq 0 -and $configJson) {
        $configured = ($configJson | ConvertFrom-Json).result
        if ($null -ne $configured -and $configured.PSObject.Properties.Match('value').Count -gt 0) {
            if ($configured.value) { $DevHub = $configured.value }
        }
    }
}

if (-not $DevHub) {
    $orgs = Get-OrgList
    $hub = $orgs | Where-Object { $_.isDevHub -eq $true } | Select-Object -First 1
    if ($hub) { $DevHub = $hub.username }
}

if (-not $DevHub) {
    Stop-Setup @'
No Dev Hub found. Enable it once:
  Setup -> Dev Hub -> Enable Dev Hub
then authorize it:
  sf org login web --set-default-dev-hub --alias devhub
and run this script again.
'@
}

Write-Ok "Dev Hub: $DevHub"

# ---------------------------------------------------------------------------------------
# 4. Create the scratch org, or reuse one that already has this alias.
# ---------------------------------------------------------------------------------------
Write-Step "Scratch org '$Alias'"

# Case-sensitive and scratch-only on purpose: PowerShell's -eq ignores case, so a
# default alias of "renewaliq" would otherwise match a Developer org aliased
# "RenewalIQ" and the script would try to deploy into someone's real org.
$existingOrg = Get-OrgList |
    Where-Object { $_.isScratch -eq $true -and $_.alias -ceq $Alias } |
    Select-Object -First 1

if ($existingOrg) {
    Write-Ok "Already exists - reusing it (expires $($existingOrg.expirationDate))."
}
else {
    Write-Detail 'Creating from config/project-scratch-def.json (about a minute)...'
    Invoke-Sf -SfArguments @(
        'org', 'create', 'scratch',
        '--target-dev-hub', $DevHub,
        '--definition-file', 'config/project-scratch-def.json',
        '--alias', $Alias,
        '--duration-days', "$DurationDays",
        '--wait', '20'
    ) | Out-Null
    Write-Ok "Created $Alias."
}

# ---------------------------------------------------------------------------------------
# 5. Deploy the source. No tests here: the test suite has its own step below and in CI.
# ---------------------------------------------------------------------------------------
Write-Step 'Deploying the project'
Invoke-Sf -SfArguments @(
    'project', 'deploy', 'start',
    '--target-org', $Alias,
    '--test-level', 'NoTestRun',
    '--wait', '45'
) | Out-Null
Write-Ok 'Source deployed.'

# ---------------------------------------------------------------------------------------
# 6. Permission sets. Metadata deploys do not grant field access, so this is required.
# ---------------------------------------------------------------------------------------
Write-Step 'Assigning permission sets'

$permissionSets = @('RIQ_Admin', 'RIQ_CSM', 'RIQ_Read_Only', 'RIQ_AI_Insight', 'RIQ_Integration_User')
foreach ($permissionSet in $permissionSets) {
    Invoke-Sf -SfArguments @(
        'org', 'assign', 'permset',
        '--name', $permissionSet,
        '--target-org', $Alias
    ) | Out-Null
    Write-Ok $permissionSet
}

# ---------------------------------------------------------------------------------------
# 7. The platform event subscriber config names a real user, and a scratch org's admin
#    username is generated. Render it from the template with this org's username.
# ---------------------------------------------------------------------------------------
Write-Step 'Configuring the platform event subscriber'

$orgInfo = (& sf org display --target-org $Alias --json | ConvertFrom-Json).result
$templatePath = Join-Path $repoRoot 'config/platform-event/RIQ_HealthStatusChangeSubscriber.platformEventSubscriberConfig-meta.xml.template'
$rendered = (Get-Content -LiteralPath $templatePath -Raw).Replace('{{USERNAME}}', $orgInfo.username)

$subscriberDir = Join-Path $repoRoot 'force-app/main/default/platformEventSubscriberConfigs'
New-Item -ItemType Directory -Force -Path $subscriberDir | Out-Null
$subscriberFile = Join-Path $subscriberDir 'RIQ_HealthStatusChangeSubscriber.platformEventSubscriberConfig-meta.xml'
[System.IO.File]::WriteAllText($subscriberFile, $rendered, (New-Object System.Text.UTF8Encoding($false)))

$subscriberExit = Invoke-Sf -AllowFailure -SfArguments @(
    'project', 'deploy', 'start',
    '--source-dir', 'force-app/main/default/platformEventSubscriberConfigs',
    '--target-org', $Alias,
    '--test-level', 'NoTestRun',
    '--wait', '10'
)

# The generated file names this one org's user. Leaving it in the tree would make the
# next full deploy to any other org fail with "no User named ... found", so it is
# removed whether the deploy worked or not.
Remove-Item -LiteralPath $subscriberFile -Force -ErrorAction SilentlyContinue

if ($subscriberExit -eq 0) {
    Write-Ok "Events will run as $($orgInfo.username)."
}
else {
    Write-Caution 'Not configured - the app works, but Tasks created by the event trigger show "Automated Process" as Created By.'
}

# ---------------------------------------------------------------------------------------
# 8. Synthetic demo data, then a real score from the real engine.
# ---------------------------------------------------------------------------------------
Write-Step 'Loading the synthetic demo book (50 invented Indian customers)'
Invoke-Sf -SfArguments @('apex', 'run', '--file', 'scripts/apex/seed-data.apex', '--target-org', $Alias) | Out-Null
Write-Ok 'Seeded and scored.'

Write-Step 'Running the nightly batch once'
Invoke-Sf -SfArguments @('apex', 'run', '--file', 'scripts/apex/run-nightly-batch.apex', '--target-org', $Alias) | Out-Null
Write-Ok 'Batch started (see Setup -> Apex Jobs).'

# ---------------------------------------------------------------------------------------
# 9. Schedule the two jobs.
# ---------------------------------------------------------------------------------------
Write-Step 'Scheduling the nightly jobs'
Invoke-Sf -SfArguments @('apex', 'run', '--file', 'scripts/apex/schedule-jobs.apex', '--target-org', $Alias) | Out-Null
Write-Ok 'Nightly scoring (02:00) and log cleanup (03:00) scheduled.'

# ---------------------------------------------------------------------------------------
# 10. Open the org and say what to click.
# ---------------------------------------------------------------------------------------
if (-not $NoBrowser) {
    Write-Step 'Opening the org'
    Invoke-Sf -AllowFailure -SfArguments @('org', 'open', '--target-org', $Alias) | Out-Null
}

Write-Host ''
Write-Host 'RenewalIQ is ready.' -ForegroundColor Green
Write-Host ''
Write-Host 'What to click first:' -ForegroundColor White
Write-Host '  1. App Launcher (nine dots) -> RenewalIQ'
Write-Host '  2. The Command Center opens on its own: KPI tiles, status donut, at-risk table'
Write-Host '  3. Open any account -> the health card (gauge, churn %, drivers, trend)'
Write-Host '  4. Log a signal on that account and watch the score change'
Write-Host ''
Write-Host 'Optional AI summaries:' -ForegroundColor White
Write-Host '  Off by default, and the app is complete without it. To turn it on, put a Groq'
Write-Host '  API key in Setup -> Named Credentials -> External Credentials -> RIQ LLM API'
Write-Host '  -> Principals -> RIQ LLM Principal -> add parameter apiKey, then tick'
Write-Host '  Is Enabled on the RIQ AI Config custom metadata record. Never put the key in a'
Write-Host '  file, in source, or in this repository.'
Write-Host ''
Write-Host "Scratch org alias: $Alias   (delete it later with: sf org delete scratch --target-org $Alias --no-prompt)" -ForegroundColor DarkGray
Write-Host "Run the tests with: sf apex run test --target-org $Alias --code-coverage --result-format human --wait 20" -ForegroundColor DarkGray

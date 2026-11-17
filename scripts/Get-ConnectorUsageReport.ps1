#Requires -Version 5.1

<#
.SYNOPSIS
    Reports which connectors are used by apps, flows and agents per Power Platform environment, joined to the
    DLP (data) policies that apply, with an optional what-if view for a proposed DLP change.

.DESCRIPTION
    Read-only. The script never changes a data policy, an environment or a resource. It only writes report files
    to -OutputPath (CSV, one HTML summary, one log).

    Usage data comes from Power Platform inventory (the same data as admin center > Manage > Inventory), queried
    through "pac resource-query query-resources" (Preview command, GA API). Data policies come from Get-DlpPolicy
    in Microsoft.PowerApps.Administration.PowerShell, or from a JSON export passed with -DlpPolicyPath.

    Sign-ins: the script uses the active pac auth profile (run "pac auth create" first; no prompt from the
    script) and, unless -DlpPolicyPath is given, one interactive Add-PowerAppsAccount prompt for the admin module.
    Both must be the same tenant. No token is read, stored or written by this script.

    The DLP evaluation is an implementation of the rules documented on Microsoft Learn. It is not Microsoft's
    enforcement engine. Inventory does not see built-in HTTP actions, desktop flows, endpoints or resource
    exemptions, so the result lowers the risk of a DLP change; it does not prove that nothing breaks.

.PARAMETER EnvironmentName
    One or more environment ids (GUID) or display names. All environments when omitted.

.PARAMETER OutputPath
    Folder for the report files. Created when missing. Default: .\ConnectorUsageReport-<yyyyMMdd-HHmm>.

.PARAMETER IncludeFlows
    Include cloud flows, agent flows and workflow agent flows. Apps are always included.

.PARAMETER IncludeAgents
    Include Copilot Studio agents and agents created in Microsoft 365 Copilot Agent Builder.

.PARAMETER ProposedChange
    One or more proposed moves for the impact view. Either hashtables
    @{ Connector = 'shared_sql'; Group = 'Blocked'; Policy = 'optional policy name' } or strings
    'shared_sql=Blocked' / 'shared_sql=Business@Policy name'. Group is Business, NonBusiness or Blocked.
    Without Policy the move is applied to every policy that covers the environment. Where no policy covers an
    environment, a hypothetical new policy is assumed (default group Non-Business).

.PARAMETER DlpPolicyPath
    JSON file with the output of Get-DlpPolicy (ConvertTo-Json -Depth 20). When given, the admin module and its
    sign-in are not needed. See docs\README.md for the export command.

.PARAMETER TenantId
    Expected tenant id. The script stops when the pac profile or the admin module session is on another tenant.

.PARAMETER SkipOwnerLookup
    Do not resolve owner object ids to names. Owner then shows the Entra object id.

.PARAMETER PageSize
    Inventory records per request (1-1000, default 250).

.PARAMETER MaxRetry
    Retries per request when the service throttles (HTTP 429 / 503) or times out. Default 5.

.PARAMETER WhatIf
    (Inherited from CmdletBinding) Collect and evaluate, write no files.

.EXAMPLE
    .\Get-ConnectorUsageReport.ps1 -IncludeFlows -IncludeAgents
    All environments, apps + flows + agents, report in .\ConnectorUsageReport-<timestamp>.

.EXAMPLE
    .\Get-ConnectorUsageReport.ps1 -EnvironmentName 'Contoso Dev' -IncludeFlows -OutputPath C:\Reports\Dev
    One environment by display name.

.EXAMPLE
    .\Get-ConnectorUsageReport.ps1 -IncludeFlows -IncludeAgents -ProposedChange 'shared_sql=Blocked', @{ Connector = 'shared_twitter'; Group = 'Business' }
    Adds Impact.csv: every app, flow and agent that would break if SQL Server were blocked and X moved to Business.

.EXAMPLE
    .\Get-ConnectorUsageReport.ps1 -IncludeFlows -DlpPolicyPath .\dlp.json -WhatIf
    Uses an exported policy file, evaluates everything, writes nothing.

.NOTES
    Required roles: Power Platform administrator (or Global administrator / Dynamics 365 administrator).
                    Global reader is enough for the inventory part, not for Get-DlpPolicy.
    Requires:       Power Platform CLI (pac) 2.x with the resource-query command group;
                    Microsoft.PowerApps.Administration.PowerShell unless -DlpPolicyPath is used
                    (Microsoft documents that module for Windows PowerShell 5.1).
    App-only auth:  not possible. The Inventory API accepts delegated user sign-in only (service principals
                    get HTTP 403).
    Blast radius:   none in the tenant. Files only.
    Author: Sayed Ali, Microsoft CSA. Not an official Microsoft solution.
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string[]] $EnvironmentName,

    [ValidateNotNullOrEmpty()]
    [string] $OutputPath = (Join-Path (Get-Location).Path ('ConnectorUsageReport-{0:yyyyMMdd-HHmm}' -f (Get-Date))),

    [switch] $IncludeFlows,

    [switch] $IncludeAgents,

    [object[]] $ProposedChange,

    [string] $DlpPolicyPath,

    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string] $TenantId,

    [switch] $SkipOwnerLookup,

    [ValidateRange(1, 1000)]
    [int] $PageSize = 250,

    [ValidateRange(0, 10)]
    [int] $MaxRetry = 5
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'ConnectorUsageReport.Dlp.psm1') -Force

$script:LogFile = $null
$script:AdminModuleName = 'Microsoft.PowerApps.Administration.PowerShell'

#region helpers ------------------------------------------------------------------------------------------------

function Write-Log {
    param([string] $Message, [ValidateSet('INFO', 'WARN', 'ERROR')] [string] $Level = 'INFO')
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
    if ($Level -eq 'WARN') { Write-Warning $Message } else { Write-Verbose $Message }
    if ($script:LogFile) { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 -WhatIf:$false -Confirm:$false }
}

function Invoke-WithRetry {
    <# Runs a script block; on throttling (429 / 503) or timeouts waits and retries with exponential backoff. #>
    param(
        [Parameter(Mandatory)] [scriptblock] $ScriptBlock,
        [Parameter(Mandatory)] [string] $Description
    )
    $attempt = 0
    while ($true) {
        try {
            return (& $ScriptBlock)
        }
        catch {
            $text = [string] $_.Exception.Message
            $transient = $text -match '429|Too\s?Many\s?Requests|503|Service\s?Unavailable|thrott|timed? ?out|temporarily|504|Gateway'
            if (-not $transient -or $attempt -ge $MaxRetry) { throw }
            $attempt++
            $wait = [Math]::Min(120, 5 * [Math]::Pow(2, $attempt - 1))
            if ($text -match '(?i)retry[- ]after\D{0,5}(\d+)') { $wait = [Math]::Max($wait, [int] $Matches[1]) }
            Write-Log -Level WARN -Message ("{0}: throttled or transient error, retry {1}/{2} in {3}s. {4}" -f $Description, $attempt, $MaxRetry, $wait, $text.Split("`n")[0])
            Start-Sleep -Seconds $wait
        }
    }
}

function Invoke-Pac {
    <# Runs pac and returns its output lines. Throws with the pac output on a non-zero exit code. #>
    param([Parameter(Mandatory)] [string[]] $Arguments)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'    # Windows PowerShell turns native stderr into terminating errors under 'Stop'
    try {
        $output = & pac @Arguments 2>&1 | ForEach-Object { [string] $_ }
        $exit = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previous }
    if ($exit -ne 0) { throw ("pac {0} failed (exit {1}): {2}" -f ($Arguments[0..1] -join ' '), $exit, (@($output) -join ' ')) }
    return @($output)
}

function Get-PacContext {
    if (-not (Get-Command pac -ErrorAction SilentlyContinue)) {
        throw "Power Platform CLI (pac) was not found. Install it (https://aka.ms/PowerPlatformCLI), then run 'pac auth create'."
    }
    $who = Invoke-Pac -Arguments @('auth', 'who')
    $tenant = $null; $user = $null
    foreach ($line in $who) {
        if ($line -match '^\s*Tenant Id:\s*(\S+)') { $tenant = $Matches[1] }
        elseif ($line -match '^\s*User:\s*(\S+)') { $user = $Matches[1] }
    }
    if (-not $tenant) { throw "No active pac auth profile. Run 'pac auth create' (or 'pac auth select') for the tenant you want to report on." }
    [pscustomobject]@{ TenantId = $tenant; User = $user }
}

function New-QueryClause {
    <# The inventory API needs '$type' as the first property of every clause, hence [ordered]. #>
    param([string] $Type, [hashtable] $Property)
    $clause = [ordered]@{ '$type' = $Type }
    foreach ($k in $Property.Keys) { $clause[$k] = $Property[$k] }
    return $clause
}

function Get-InventoryRecord {
    <# Pages through PowerPlatformResources with the given clauses and returns every record. #>
    param(
        [Parameter(Mandatory)] [object[]] $Clause,
        [Parameter(Mandatory)] [string] $Description
    )
    $all = New-Object System.Collections.Generic.List[object]
    $skipToken = $null
    $page = 0
    do {
        $page++
        $options = [ordered]@{ Top = $PageSize }
        if ($skipToken) { $options['SkipToken'] = $skipToken }
        $body = [ordered]@{ TableName = 'PowerPlatformResources'; Clauses = @($Clause); Options = $options } | ConvertTo-Json -Depth 12
        $bodyFile = [System.IO.Path]::GetTempFileName()
        try {
            [System.IO.File]::WriteAllText($bodyFile, $body, (New-Object System.Text.UTF8Encoding($false)))
            $lines = @(Invoke-WithRetry -Description $Description -ScriptBlock {
                    Invoke-Pac -Arguments @('resource-query', 'query-resources', '--body', "@$bodyFile")
                })
        }
        finally { Remove-Item -LiteralPath $bodyFile -Force -ErrorAction SilentlyContinue -WhatIf:$false -Confirm:$false }

        $start = 0
        while ($start -lt $lines.Count -and -not $lines[$start].TrimStart().StartsWith('{')) { $start++ }
        if ($start -ge $lines.Count) { throw "$Description`: pac returned no JSON. Output: $($lines -join ' ')" }
        $result = ($lines[$start..($lines.Count - 1)] -join "`n") | ConvertFrom-Json

        foreach ($record in @(Get-PropertyValue $result 'data')) { if ($null -ne $record) { $all.Add($record) } }
        $skipToken = Get-PropertyValue $result 'skipToken'
        $total = Get-PropertyValue $result 'totalRecords'
        Write-Progress -Activity 'Reading Power Platform inventory' -Status ("{0}: {1} of {2}" -f $Description, $all.Count, $total)
        Write-Log ("{0}: page {1}, {2} of {3} records" -f $Description, $page, $all.Count, $total)
    } while ($skipToken)
    Write-Progress -Activity 'Reading Power Platform inventory' -Completed
    return $all.ToArray()
}

function Get-DlpPolicyRaw {
    <# Returns raw policy objects (Get-DlpPolicy shape), each with a connectorConfigurations property when available. #>
    param([string] $ExpectedTenantId)

    if ($DlpPolicyPath) {
        if (-not (Test-Path -LiteralPath $DlpPolicyPath)) { throw "DlpPolicyPath '$DlpPolicyPath' not found." }
        Write-Log "Reading data policies from file $DlpPolicyPath"
        $raw = Get-Content -LiteralPath $DlpPolicyPath -Raw | ConvertFrom-Json
    }
    else {
        if (-not (Get-Module -ListAvailable -Name $script:AdminModuleName)) {
            throw "Module $($script:AdminModuleName) is not installed. Run 'Install-Module $($script:AdminModuleName) -Scope CurrentUser', or pass -DlpPolicyPath with an exported policy file."
        }
        Import-Module $script:AdminModuleName -ErrorAction Stop -Verbose:$false -DisableNameChecking -WarningAction SilentlyContinue
        $session = Get-Variable -Name currentSession -Scope Global -ValueOnly -ErrorAction SilentlyContinue
        if (-not $session -or -not (Get-PropertyValue $session 'loggedIn')) {
            Write-Host "Sign in to Power Platform (admin module) as a Power Platform administrator of tenant $ExpectedTenantId ..."
            Add-PowerAppsAccount -Endpoint prod -TenantID $ExpectedTenantId | Out-Null
            $session = Get-Variable -Name currentSession -Scope Global -ValueOnly -ErrorAction SilentlyContinue
        }
        $sessionTenant = [string] (Get-PropertyValue $session 'tenantId')
        if ($sessionTenant -and $sessionTenant -ne $ExpectedTenantId) {
            throw "The admin module is signed in to tenant $sessionTenant but pac is on tenant $ExpectedTenantId. Sign both in to the same tenant (Remove-PowerAppsAccount, then run again)."
        }
        Write-Log 'Reading data policies with Get-DlpPolicy'
        $raw = Invoke-WithRetry -Description 'Get-DlpPolicy' -ScriptBlock { Get-DlpPolicy }
    }

    $policies = @()
    $value = Get-PropertyValue $raw 'value'
    if ($null -ne $value) { $policies = @($value) }
    elseif ($null -ne $raw -and $null -ne (Get-PropertyValue $raw 'name')) { $policies = @($raw) }
    elseif ($raw -is [System.Array]) { $policies = @($raw) }
    $policies = @($policies | Where-Object { $null -ne $_ })

    if (-not $DlpPolicyPath) {
        foreach ($policy in $policies) {
            $policyName = [string] (Get-PropertyValue $policy 'name')
            $config = $null
            try {
                $config = Invoke-WithRetry -Description "Connector configurations of policy $policyName" -ScriptBlock {
                    Get-PowerAppDlpPolicyConnectorConfigurations -TenantId $ExpectedTenantId -PolicyName $policyName
                }
            }
            catch {
                # A policy without action or endpoint rules has no configuration object; that is not an error.
                Write-Log "Policy $policyName has no connector configurations ($($_.Exception.Message.Split("`n")[0]))"
            }
            $policy | Add-Member -NotePropertyName connectorConfigurations -NotePropertyValue $config -Force
        }
    }
    return , $policies
}

function Resolve-OwnerName {
    <# Best effort: object id -> display name through the admin module's Graph helper. Falls back to the id. #>
    param([string] $ObjectId, [hashtable] $Cache)
    if ([string]::IsNullOrWhiteSpace($ObjectId)) { return '' }
    if ($Cache.ContainsKey($ObjectId)) { return $Cache[$ObjectId] }
    $name = $ObjectId
    if ($script:OwnerLookupEnabled) {
        try {
            $entry = Get-UsersOrGroupsFromGraph -ObjectId $ObjectId
            $display = Get-PropertyValue $entry 'DisplayName'
            $upn = Get-PropertyValue $entry 'UserPrincipalName'
            if ($display -and $upn) { $name = "$display ($upn)" }
            elseif ($display) { $name = [string] $display }
        }
        catch {
            Write-Log -Level WARN -Message "Owner lookup failed ($($_.Exception.Message.Split("`n")[0])). Owners are reported as object ids from here on."
            $script:OwnerLookupEnabled = $false
        }
    }
    $Cache[$ObjectId] = $name
    return $name
}

function ConvertTo-IsoDate {
    <# PowerShell 7 turns JSON date strings into DateTime, 5.1 keeps strings. Always report ISO 8601 UTC. #>
    param($Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string] $Value)) { return '' }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
    $parsed = [datetimeoffset]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal
    if ([datetimeoffset]::TryParse([string] $Value, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref] $parsed)) {
        return $parsed.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    return [string] $Value
}

function ConvertTo-SafeFileName {
    param([string] $Name)
    $safe = $Name
    foreach ($ch in [System.IO.Path]::GetInvalidFileNameChars()) { $safe = $safe.Replace([string] $ch, '_') }
    $safe = ($safe -replace '\s+', '_').Trim('_')
    if ($safe.Length -gt 60) { $safe = $safe.Substring(0, 60) }
    return $safe
}

function ConvertTo-HtmlText { param($Value) return [System.Net.WebUtility]::HtmlEncode([string] $Value) }

function ConvertTo-HtmlTable {
    param([AllowEmptyCollection()] [object[]] $Row = @(), [string[]] $Column, [string] $Empty = 'Nothing to show.')
    $rows = @($Row | Where-Object { $null -ne $_ })
    if ($rows.Count -eq 0) { return "<p class='muted'>$(ConvertTo-HtmlText $Empty)</p>" }
    $sb = New-Object System.Text.StringBuilder
    [void] $sb.Append('<table><thead><tr>')
    foreach ($c in $Column) { [void] $sb.Append("<th>$(ConvertTo-HtmlText $c)</th>") }
    [void] $sb.Append('</tr></thead><tbody>')
    foreach ($r in $rows) {
        [void] $sb.Append('<tr>')
        foreach ($c in $Column) {
            $value = [string] (Get-PropertyValue $r $c)
            $class = ''
            if ($value -match '^(WouldBreak|Violation|Blocked)') { $class = " class='bad'" }
            elseif ($value -match '^(AlreadyViolating|UsedNotClassified)') { $class = " class='warn'" }
            [void] $sb.Append("<td$class>$(ConvertTo-HtmlText $value)</td>")
        }
        [void] $sb.Append('</tr>')
    }
    [void] $sb.Append('</tbody></table>')
    return $sb.ToString()
}

#endregion

#region 1. context --------------------------------------------------------------------------------------------

$started = Get-Date
$canWrite = $PSCmdlet.ShouldProcess($OutputPath, 'Write connector usage report files')
if ($canWrite) {
    if (-not (Test-Path -LiteralPath $OutputPath)) { New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null }
    $OutputPath = (Resolve-Path -LiteralPath $OutputPath).Path
    $script:LogFile = Join-Path $OutputPath 'run.log'
    Set-Content -Path $script:LogFile -Value ("Get-ConnectorUsageReport started {0:u}" -f $started) -Encoding UTF8
}

$pac = Get-PacContext
if ($TenantId -and $pac.TenantId -ne $TenantId) {
    throw "The active pac profile is on tenant $($pac.TenantId) ($($pac.User)) but -TenantId is $TenantId. Run 'pac auth select' for the right profile."
}
Write-Log "pac profile: $($pac.User), tenant $($pac.TenantId)"
Write-Host "Tenant $($pac.TenantId) as $($pac.User) (pac profile)"

$changes = @(ConvertTo-DlpProposedChange -ProposedChange $ProposedChange)
foreach ($ch in $changes) {
    $target = 'every applicable policy'; if ($ch.Policy) { $target = "policy '$($ch.Policy)'" }
    Write-Log "Proposed change: $($ch.Connector) -> $($ch.Group) in $target"
}

#endregion

#region 2. inventory ------------------------------------------------------------------------------------------

Write-Host 'Reading environments ...'
$environmentRecords = Get-InventoryRecord -Description 'Environments' -Clause @(
    (New-QueryClause 'where' @{ FieldName = 'type'; Operator = '=='; Values = @("'microsoft.powerplatform/environments'") }),
    (New-QueryClause 'project' @{ FieldList = @('id', 'name', 'displayName = tostring(properties.displayName)',
            'environmentType = tostring(properties.environmentType)', 'isManaged = tostring(properties.isManaged)') })
)
$environments = @{}
foreach ($e in $environmentRecords) {
    $environments[([string] $e.name).ToLowerInvariant()] = [pscustomobject]@{
        Id      = ([string] $e.name).ToLowerInvariant()
        Name    = [string] $e.displayName
        Type    = [string] $e.environmentType
        Managed = ([string] $e.isManaged -match '^(true|1)$')
    }
}
if ($environments.Count -eq 0) { throw 'The inventory returned no environments. Check the role of the signed-in account (Power Platform administrator or Global reader).' }

$selectedIds = @($environments.Keys)
if ($EnvironmentName) {
    $selectedIds = @()
    foreach ($wanted in $EnvironmentName) {
        $match = @($environments.Values | Where-Object { $_.Id -eq $wanted.ToLowerInvariant() -or $_.Name -eq $wanted })
        if ($match.Count -eq 0) { throw "Environment '$wanted' not found. Pass the environment id (GUID) or the exact display name." }
        if ($match.Count -gt 1) { throw "Environment name '$wanted' matches $($match.Count) environments. Pass the environment id instead." }
        $selectedIds += $match[0].Id
    }
    $selectedIds = @($selectedIds | Sort-Object -Unique)
}
Write-Log "Environments in scope: $($selectedIds.Count) of $($environments.Count)"

Write-Host 'Reading connector catalogue ...'
$catalogRecords = Get-InventoryRecord -Description 'Connector catalogue' -Clause @(
    (New-QueryClause 'where' @{ FieldName = 'type'; Operator = '=='; Values = @("'microsoft.powerplatformconnector/connectors'") }),
    (New-QueryClause 'project' @{ FieldList = @('id', 'name', 'displayName = tostring(properties.displayName)',
            'tier = tostring(properties.tier)', 'publisher = tostring(properties.publisher)') })
)
$catalog = @{}
foreach ($c in $catalogRecords) {
    $catalog[([string] $c.name).ToLowerInvariant()] = [pscustomobject]@{ Name = [string] $c.displayName; Tier = [string] $c.tier; Publisher = [string] $c.publisher }
}

$typeLabels = [ordered]@{
    'microsoft.powerapps/canvasapps'      = 'CanvasApp'
    'microsoft.powerapps/modeldrivenapps' = 'ModelDrivenApp'
    'microsoft.powerapps/apps'            = 'ManagedApp'
}
if ($IncludeFlows) {
    $typeLabels['microsoft.powerautomate/cloudflows'] = 'CloudFlow'
    $typeLabels['microsoft.powerautomate/agentflows'] = 'AgentFlow'
    $typeLabels['microsoft.powerautomate/m365agentflows'] = 'WorkflowAgentFlow'
}
if ($IncludeAgents) { $typeLabels['microsoft.copilotstudio/agents'] = 'Agent' }

Write-Host ("Reading resources ({0}) ..." -f (($typeLabels.Values | Sort-Object -Unique) -join ', '))
$resourceClauses = @(
    (New-QueryClause 'where' @{ FieldName = 'type'; Operator = 'in~'; Values = @($typeLabels.Keys | ForEach-Object { "'$_'" }) })
)
if ($EnvironmentName) {
    $resourceClauses += (New-QueryClause 'where' @{ FieldName = 'tolower(tostring(properties.environmentId))'; Operator = 'in'; Values = @($selectedIds | ForEach-Object { "'$_'" }) })
}
$resourceClauses += (New-QueryClause 'project' @{ FieldList = @('id', 'name', 'type',
        'displayName = tostring(properties.displayName)', 'environmentId = tostring(properties.environmentId)',
        'ownerId = tostring(properties.ownerId)', 'lastModifiedAt = tostring(properties.lastModifiedAt)',
        'lastPublishedAt = tostring(properties.lastPublishedAt)', 'createdAt = tostring(properties.createdAt)',
        'status = tostring(properties.status)', 'connectors = properties.powerPlatformConnectors', 'trigger = properties.trigger') })
$resourceRecords = Get-InventoryRecord -Description 'Apps, flows and agents' -Clause $resourceClauses
Write-Log "Resources read: $($resourceRecords.Count)"

#endregion

#region 3. data policies --------------------------------------------------------------------------------------

Write-Host 'Reading data policies ...'
$rawPolicies = Get-DlpPolicyRaw -ExpectedTenantId $pac.TenantId
$policies = @($rawPolicies | ForEach-Object { ConvertTo-DlpPolicyModel -RawPolicy $_ })
Write-Log "Data policies read: $($policies.Count)"

$script:OwnerLookupEnabled = (-not $SkipOwnerLookup) -and [bool] (Get-Module -Name $script:AdminModuleName) -and
    [bool] (Get-Variable -Name currentSession -Scope Global -ValueOnly -ErrorAction SilentlyContinue)
if (-not $script:OwnerLookupEnabled -and -not $SkipOwnerLookup) {
    Write-Log 'Owner names are not resolved (no admin module session). Owner shows the Entra object id.'
}

$policiesByEnvironment = @{}
$policiesAfterByEnvironment = @{}
foreach ($envId in $selectedIds) {
    $applicable = @($policies | Where-Object { Test-DlpPolicyAppliesToEnvironment -Policy $_ -EnvironmentId $envId })
    $policiesByEnvironment[$envId] = $applicable
    $afterSet = Get-DlpProposedPolicySet -Policy $applicable -ProposedChange $changes
    $policiesAfterByEnvironment[$envId] = @($afterSet | Where-Object { $null -ne $_ })
}

#endregion

#region 4. evaluate -------------------------------------------------------------------------------------------

$ownerCache = @{}
$usageRows = New-Object System.Collections.Generic.List[object]
$impactRows = New-Object System.Collections.Generic.List[object]
$resourceStats = New-Object System.Collections.Generic.List[object]
$changedConnectors = @($changes | ForEach-Object { $_.Connector })
$counter = 0
$skippedResources = 0

foreach ($record in $resourceRecords) {
    $counter++
    if ($counter % 200 -eq 0) { Write-Progress -Activity 'Evaluating resources' -Status "$counter of $($resourceRecords.Count)" -PercentComplete (100 * $counter / $resourceRecords.Count) }

    $envId = ([string] $record.environmentId).ToLowerInvariant()
    if ($selectedIds -notcontains $envId) { $skippedResources++; continue }
    $environment = $environments[$envId]
    $resourceType = $typeLabels[([string] $record.type).ToLowerInvariant()]
    if (-not $resourceType) { $resourceType = [string] $record.type }

    # Connector set of the resource: connectors invoked + the trigger connector of a flow.
    $connectorSet = [ordered]@{}
    foreach ($c in @(Get-PropertyValue $record 'connectors')) {
        if ($null -eq $c) { continue }
        $id = Get-ConnectorShortId ([string] (Get-PropertyValue $c 'connectorId'))
        if (-not $id) { continue }
        $operations = @(@(Get-PropertyValue $c 'operations') | Where-Object { $null -ne $_ } | ForEach-Object { [string] (Get-PropertyValue $_ 'operationId') } | Where-Object { $_ })
        if ($connectorSet.Contains($id)) { $connectorSet[$id].Operations = @($connectorSet[$id].Operations + $operations | Sort-Object -Unique) }
        else { $connectorSet[$id] = [pscustomobject]@{ ConnectorId = $id; Operations = $operations; IsCustom = (-not $catalog.ContainsKey($id)); Role = 'Action' } }
    }
    $trigger = Get-PropertyValue $record 'trigger'
    if ($null -ne $trigger) {
        # Learn documents a string; the service returns an object. Handle both.
        $triggerId = ''; $triggerOperation = ''
        if ($trigger -is [string]) { $triggerId = $trigger }
        else { $triggerId = [string] (Get-PropertyValue $trigger 'connectorId'); $triggerOperation = [string] (Get-PropertyValue $trigger 'operationId') }
        if ($triggerId) {
            if ($triggerId -notmatch '^shared_') { $triggerId = "shared_$triggerId" }
            $triggerId = Get-ConnectorShortId $triggerId
            $ops = @(); if ($triggerOperation) { $ops = @($triggerOperation) }
            if ($connectorSet.Contains($triggerId)) {
                $connectorSet[$triggerId].Operations = @($connectorSet[$triggerId].Operations + $ops | Sort-Object -Unique)
                $connectorSet[$triggerId].Role = 'Trigger+Action'
            }
            else { $connectorSet[$triggerId] = [pscustomobject]@{ ConnectorId = $triggerId; Operations = $ops; IsCustom = (-not $catalog.ContainsKey($triggerId)); Role = 'Trigger' } }
        }
    }
    $connectors = @($connectorSet.Values)

    $applicable = @($policiesByEnvironment[$envId])
    $compliance = Test-DlpResourceCompliance -Connector $connectors -Policy $applicable
    $dlpStatus = 'NoPolicy'
    if ($applicable.Count -gt 0) { $dlpStatus = 'Compliant'; if (-not $compliance.Compliant) { $dlpStatus = 'Violation' } }

    $lastModified = ConvertTo-IsoDate $record.lastModifiedAt
    if (-not $lastModified) { $lastModified = ConvertTo-IsoDate $record.lastPublishedAt }
    if (-not $lastModified) { $lastModified = ConvertTo-IsoDate $record.createdAt }
    $owner = Resolve-OwnerName -ObjectId ([string] $record.ownerId) -Cache $ownerCache

    $resourceStats.Add([pscustomobject]@{
            EnvironmentId = $envId; ResourceType = $resourceType; ResourceId = [string] $record.name
            ConnectorCount = $connectors.Count; DlpStatus = $dlpStatus
        })

    foreach ($c in $connectors) {
        $meta = $null; if ($catalog.ContainsKey($c.ConnectorId)) { $meta = $catalog[$c.ConnectorId] }
        $connectorName = $c.ConnectorId; $tier = 'Custom'; $publisher = ''
        if ($meta) { $connectorName = $meta.Name; $tier = $meta.Tier; $publisher = $meta.Publisher }

        $policyNames = '(none)'; $groupNames = '(no policy)'
        if ($applicable.Count -gt 0) {
            $policyNames = ($applicable | ForEach-Object { $_.DisplayName }) -join '; '
            $groupNames = ($applicable | ForEach-Object {
                    $cls = Get-DlpConnectorClassification -Policy $_ -ConnectorId $c.ConnectorId -IsCustom $c.IsCustom
                    if ($cls.Explicit) { $cls.Group } else { "$($cls.Group) (default)" }
                }) -join '; '
        }

        $usageRows.Add([pscustomobject][ordered]@{
                Connector          = $c.ConnectorId
                ResourceType       = $resourceType
                ResourceName       = [string] $record.displayName
                Owner              = $owner
                LastModified       = $lastModified
                Environment        = $environment.Name
                EnvironmentType    = $environment.Type
                ManagedEnvironment = $environment.Managed
                DlpPolicy          = $policyNames
                DlpGroup           = $groupNames
                ConnectorName      = $connectorName
                Tier               = $tier
                Publisher          = $publisher
                ConnectorRole      = $c.Role
                Operations         = ($c.Operations -join '; ')
                ResourceStatus     = [string] $record.status
                DlpStatus          = $dlpStatus
                DlpViolation       = ($compliance.Violations -join ' | ')
                OwnerId            = [string] $record.ownerId
                ResourceId         = [string] $record.name
                EnvironmentId      = $envId
            })
    }

    if ($changes.Count -gt 0) {
        $impact = Get-DlpImpact -Connector $connectors -PolicyBefore $applicable -PolicyAfter @($policiesAfterByEnvironment[$envId])
        $usesChanged = @($connectors | Where-Object { $changedConnectors -contains $_.ConnectorId }).Count -gt 0
        if ($impact.Impact -ne 'NoImpact' -or $usesChanged) {
            $impactRows.Add([pscustomobject][ordered]@{
                    Impact          = $impact.Impact
                    Environment     = $environment.Name
                    EnvironmentType = $environment.Type
                    ResourceType    = $resourceType
                    ResourceName    = [string] $record.displayName
                    Owner           = $owner
                    LastModified    = $lastModified
                    ResourceStatus  = [string] $record.status
                    Connectors      = (($connectors | ForEach-Object { $_.ConnectorId }) -join '; ')
                    Before          = $impact.Before
                    After           = $impact.After
                    Reason          = $impact.Reason
                    PolicyAfter     = ((@($policiesAfterByEnvironment[$envId]) | ForEach-Object { $_.DisplayName }) -join '; ')
                    ResourceId      = [string] $record.name
                    EnvironmentId   = $envId
                })
        }
    }
}
Write-Progress -Activity 'Evaluating resources' -Completed
if ($skippedResources -gt 0) {
    Write-Log -Level WARN -Message "$skippedResources resource(s) belong to an environment the inventory does not list (for example a deleted environment) and are not in the report."
}

# Summary: connector x environment.
$summaryRows = @(
    $usageRows | Group-Object EnvironmentId, Connector | ForEach-Object {
        $rows = @($_.Group); $first = $rows[0]
        $countOf = { param($type) @($rows | Where-Object { $_.ResourceType -eq $type } | Select-Object -ExpandProperty ResourceId -Unique).Count }
        [pscustomobject][ordered]@{
            Connector          = $first.Connector
            ConnectorName      = $first.ConnectorName
            Tier               = $first.Tier
            Environment        = $first.Environment
            EnvironmentType    = $first.EnvironmentType
            ManagedEnvironment = $first.ManagedEnvironment
            CanvasApps         = (& $countOf 'CanvasApp')
            ModelDrivenApps    = (& $countOf 'ModelDrivenApp')
            ManagedApps        = (& $countOf 'ManagedApp')
            CloudFlows         = (& $countOf 'CloudFlow')
            AgentFlows         = (@('AgentFlow', 'WorkflowAgentFlow') | ForEach-Object { & $countOf $_ } | Measure-Object -Sum).Sum
            Agents             = (& $countOf 'Agent')
            TotalResources     = @($rows | Select-Object -ExpandProperty ResourceId -Unique).Count
            Owners             = @($rows | Select-Object -ExpandProperty OwnerId -Unique).Count
            LastModified       = ($rows | Sort-Object LastModified -Descending | Select-Object -First 1).LastModified
            DlpPolicy          = $first.DlpPolicy
            DlpGroup           = $first.DlpGroup
            EnvironmentId      = $first.EnvironmentId
        }
    } | Sort-Object Environment, @{ Expression = 'TotalResources'; Descending = $true }, Connector
)

# Policy view: explicit classification, rules, and the gaps (classified but unused / used but unclassified).
$policyRows = New-Object System.Collections.Generic.List[object]
$gapRows = New-Object System.Collections.Generic.List[object]
foreach ($policy in $policies) {
    $coveredIds = @($selectedIds | Where-Object { Test-DlpPolicyAppliesToEnvironment -Policy $policy -EnvironmentId $_ })
    $coveredNames = (($coveredIds | ForEach-Object { $environments[$_].Name } | Sort-Object) -join '; ')
    $usedHere = @{}
    foreach ($row in $usageRows) { if ($coveredIds -contains $row.EnvironmentId) { if (-not $usedHere.ContainsKey($row.Connector)) { $usedHere[$row.Connector] = @{} }; $usedHere[$row.Connector][$row.ResourceId] = $true } }

    if (($policy.Groups.Count + $policy.ActionRules.Count + @($policy.EndpointRuleConnectors).Count) -eq 0) {
        $policyRows.Add([pscustomobject][ordered]@{ Policy = $policy.DisplayName; Scope = $policy.Scope; EnvironmentsCovered = $coveredNames; DefaultGroup = $policy.DefaultGroup
                Connector = '(none classified)'; ConnectorName = ''; Group = ''; ActionRules = ''; EndpointRules = ''; ResourcesUsingIt = 0; PolicyId = $policy.Name })
    }
    # Connectors the policy names in a group, plus connectors that only carry action or endpoint rules.
    $listed = @(@($policy.Groups.Keys) + @($policy.ActionRules.Keys) + @($policy.EndpointRuleConnectors) | Where-Object { $_ } | Sort-Object -Unique)
    foreach ($connectorId in $listed) {
        $name = $connectorId; if ($catalog.ContainsKey($connectorId)) { $name = $catalog[$connectorId].Name }
        $isExplicit = $policy.Groups.ContainsKey($connectorId)
        $groupText = "$($policy.DefaultGroup) (default)"; if ($isExplicit) { $groupText = $policy.Groups[$connectorId] }
        $actionText = ''
        if ($policy.ActionRules.ContainsKey($connectorId)) {
            $rule = $policy.ActionRules[$connectorId]
            $actionText = "default=$($rule.Default)"
            if ($rule.Rules.Count -gt 0) { $actionText += '; ' + ((@($rule.Rules.Keys | Sort-Object) | ForEach-Object { "$_=$($rule.Rules[$_])" }) -join '; ') }
        }
        $endpointText = ''; if ($policy.EndpointRuleConnectors -contains $connectorId) { $endpointText = 'Yes (not evaluated)' }
        $usedCount = 0; if ($usedHere.ContainsKey($connectorId)) { $usedCount = $usedHere[$connectorId].Count }
        $policyRows.Add([pscustomobject][ordered]@{ Policy = $policy.DisplayName; Scope = $policy.Scope; EnvironmentsCovered = $coveredNames; DefaultGroup = $policy.DefaultGroup
                Connector = $connectorId; ConnectorName = $name; Group = $groupText; ActionRules = $actionText; EndpointRules = $endpointText
                ResourcesUsingIt = $usedCount; PolicyId = $policy.Name })
        if ($usedCount -eq 0 -and $isExplicit) {
            $gapRows.Add([pscustomobject][ordered]@{ Gap = 'ClassifiedNotUsed'; Policy = $policy.DisplayName; Connector = $connectorId; ConnectorName = $name
                    Group = $groupText; ResourcesUsingIt = 0; EnvironmentsCovered = $coveredNames })
        }
    }
    foreach ($connectorId in @($usedHere.Keys | Sort-Object)) {
        if ($policy.Groups.ContainsKey($connectorId)) { continue }
        $name = $connectorId; if ($catalog.ContainsKey($connectorId)) { $name = $catalog[$connectorId].Name }
        $cls = Get-DlpConnectorClassification -Policy $policy -ConnectorId $connectorId -IsCustom (-not $catalog.ContainsKey($connectorId))
        $gapRows.Add([pscustomobject][ordered]@{ Gap = 'UsedNotClassified'; Policy = $policy.DisplayName; Connector = $connectorId; ConnectorName = $name
                Group = "$($cls.Group) (default)"; ResourcesUsingIt = $usedHere[$connectorId].Count; EnvironmentsCovered = $coveredNames })
    }
}

$environmentRows = @(
    foreach ($envId in $selectedIds) {
        $environment = $environments[$envId]
        $stats = @($resourceStats | Where-Object { $_.EnvironmentId -eq $envId })
        [pscustomobject][ordered]@{
            Environment        = $environment.Name
            EnvironmentType    = $environment.Type
            ManagedEnvironment = $environment.Managed
            DlpPolicies        = ((@($policiesByEnvironment[$envId]) | ForEach-Object { $_.DisplayName }) -join '; ')
            Resources          = $stats.Count
            WithConnectors     = @($stats | Where-Object { $_.ConnectorCount -gt 0 }).Count
            DistinctConnectors = @($usageRows | Where-Object { $_.EnvironmentId -eq $envId } | Select-Object -ExpandProperty Connector -Unique).Count
            CurrentViolations  = @($stats | Where-Object { $_.DlpStatus -eq 'Violation' }).Count
            WouldBreak         = @($impactRows | Where-Object { $_.EnvironmentId -eq $envId -and $_.Impact -eq 'WouldBreak' }).Count
            EnvironmentId      = $envId
        }
    }
) | Sort-Object @{ Expression = 'Resources'; Descending = $true }, Environment

$tenantConnectorRows = @(
    $usageRows | Group-Object Connector | ForEach-Object {
        $rows = @($_.Group)
        [pscustomobject][ordered]@{
            Connector     = $_.Name
            ConnectorName = $rows[0].ConnectorName
            Tier          = $rows[0].Tier
            Environments  = @($rows | Select-Object -ExpandProperty EnvironmentId -Unique).Count
            Apps          = @($rows | Where-Object { $_.ResourceType -match 'App$' } | Select-Object -ExpandProperty ResourceId -Unique).Count
            Flows         = @($rows | Where-Object { $_.ResourceType -match 'Flow$' } | Select-Object -ExpandProperty ResourceId -Unique).Count
            Agents        = @($rows | Where-Object { $_.ResourceType -eq 'Agent' } | Select-Object -ExpandProperty ResourceId -Unique).Count
            Total         = @($rows | Select-Object -ExpandProperty ResourceId -Unique).Count
            DlpGroups     = (@($rows | Select-Object -ExpandProperty DlpGroup -Unique) -join ' / ')
        }
    } | Sort-Object @{ Expression = 'Total'; Descending = $true }, Connector
)

#endregion

#region 5. write ----------------------------------------------------------------------------------------------

$wouldBreak = @($impactRows | Where-Object { $_.Impact -eq 'WouldBreak' }).Count
$violations = @($resourceStats | Where-Object { $_.DlpStatus -eq 'Violation' }).Count
$files = New-Object System.Collections.Generic.List[string]

if ($canWrite) {
    foreach ($envId in $selectedIds) {
        $rows = @($usageRows | Where-Object { $_.EnvironmentId -eq $envId })
        if ($rows.Count -eq 0) { continue }
        $file = Join-Path $OutputPath ('ConnectorUsage_{0}_{1}.csv' -f (ConvertTo-SafeFileName $environments[$envId].Name), (($envId -replace '^default-', '') + '00000000').Substring(0, 8))
        $rows | Sort-Object Connector, ResourceType, ResourceName | Export-Csv -Path $file -NoTypeInformation -Encoding UTF8
        $files.Add($file)
    }
    $summaryFile = Join-Path $OutputPath 'Summary.csv'
    $summaryRows | Export-Csv -Path $summaryFile -NoTypeInformation -Encoding UTF8; $files.Add($summaryFile)
    $environmentFile = Join-Path $OutputPath 'Environments.csv'
    $environmentRows | Export-Csv -Path $environmentFile -NoTypeInformation -Encoding UTF8; $files.Add($environmentFile)
    if ($policyRows.Count -gt 0) {
        $policyFile = Join-Path $OutputPath 'DlpPolicies.csv'
        $policyRows | Export-Csv -Path $policyFile -NoTypeInformation -Encoding UTF8; $files.Add($policyFile)
    }
    if ($gapRows.Count -gt 0) {
        $gapFile = Join-Path $OutputPath 'PolicyGaps.csv'
        $gapRows | Export-Csv -Path $gapFile -NoTypeInformation -Encoding UTF8; $files.Add($gapFile)
    }
    if ($changes.Count -gt 0) {
        $impactFile = Join-Path $OutputPath 'Impact.csv'
        $order = @{ WouldBreak = 0; AlreadyViolating = 1; WouldBeFixed = 2; NoImpact = 3 }
        @($impactRows | Sort-Object @{ Expression = { $order[$_.Impact] } }, Environment, ResourceType, ResourceName) |
            Select-Object Impact, Environment, EnvironmentType, ResourceType, ResourceName, Owner, LastModified, ResourceStatus, Connectors, Before, After, Reason, PolicyAfter, ResourceId, EnvironmentId |
            Export-Csv -Path $impactFile -NoTypeInformation -Encoding UTF8
        $files.Add($impactFile)
    }

    $scope = 'Apps'; if ($IncludeFlows) { $scope += ', flows' }; if ($IncludeAgents) { $scope += ', agents' }
    $changeText = 'none'
    if ($changes.Count -gt 0) { $changeText = ($changes | ForEach-Object { $t = "$($_.Connector) -> $($_.Group)"; if ($_.Policy) { $t += " in '$($_.Policy)'" }; $t }) -join '; ' }
    $impactSection = ''
    if ($changes.Count -gt 0) {
        $impactSection = "<h2>Impact of the proposed change</h2><p>Proposed: <b>$(ConvertTo-HtmlText $changeText)</b>. WouldBreak = compliant today, in violation after the change.</p>" +
            (ConvertTo-HtmlTable -Row @($impactRows | Where-Object { $_.Impact -ne 'NoImpact' } | Sort-Object Impact -Descending | Select-Object -First 200) -Column Impact, Environment, ResourceType, ResourceName, Owner, Connectors, Reason -Empty 'No app, flow or agent in scope changes its DLP status with this change.')
    }
    $html = @"
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>Connector usage report</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#1b1b1b;background:#fff}
h1{font-size:22px;margin:0 0 4px}h2{font-size:16px;margin:28px 0 8px;border-bottom:1px solid #ddd;padding-bottom:4px}
.muted{color:#666;font-size:12px}.tiles{display:flex;flex-wrap:wrap;gap:12px;margin:16px 0}
.tile{border:1px solid #ddd;border-radius:6px;padding:10px 16px;min-width:120px}.tile b{display:block;font-size:22px}
.tile.bad b{color:#a4262c}table{border-collapse:collapse;width:100%;font-size:12px}
th,td{border:1px solid #ddd;padding:4px 8px;text-align:left;vertical-align:top}th{background:#f3f2f1}
td.bad{color:#a4262c;font-weight:600}td.warn{color:#8a5a00}
</style></head><body>
<h1>Connector usage report</h1>
<p class="muted">Generated $(ConvertTo-HtmlText ('{0:yyyy-MM-dd HH:mm}' -f $started)) by $(ConvertTo-HtmlText $pac.User) &middot; tenant $(ConvertTo-HtmlText $pac.TenantId) &middot; scope: $(ConvertTo-HtmlText $scope) &middot; proposed change: $(ConvertTo-HtmlText $changeText)</p>
<div class="tiles">
<div class="tile"><b>$($selectedIds.Count)</b>environments</div>
<div class="tile"><b>$($resourceStats.Count)</b>apps, flows, agents</div>
<div class="tile"><b>$(@($resourceStats | Where-Object { $_.ConnectorCount -gt 0 }).Count)</b>use a connector</div>
<div class="tile"><b>$($tenantConnectorRows.Count)</b>connectors in use</div>
<div class="tile"><b>$($policies.Count)</b>data policies</div>
<div class="tile$(if ($violations -gt 0) { ' bad' })"><b>$violations</b>in violation today</div>
<div class="tile$(if ($wouldBreak -gt 0) { ' bad' })"><b>$wouldBreak</b>would break</div>
</div>
$impactSection
<h2>Connectors in use (top 50 of $($tenantConnectorRows.Count))</h2>
$(ConvertTo-HtmlTable -Row @($tenantConnectorRows | Select-Object -First 50) -Column Connector, ConnectorName, Tier, Environments, Apps, Flows, Agents, Total, DlpGroups -Empty 'No connector usage found in scope.')
<h2>Environments</h2>
$(ConvertTo-HtmlTable -Row $environmentRows -Column Environment, EnvironmentType, ManagedEnvironment, DlpPolicies, Resources, WithConnectors, DistinctConnectors, CurrentViolations, WouldBreak)
<h2>Policy gaps (first 100 of $($gapRows.Count))</h2>
<p class="muted">UsedNotClassified = used in a covered environment but only in the policy's default group. ClassifiedNotUsed = named in the policy, used by nothing in scope.</p>
$(ConvertTo-HtmlTable -Row @($gapRows | Select-Object -First 100) -Column Gap, Policy, Connector, ConnectorName, Group, ResourcesUsingIt -Empty 'No data policy applies to the environments in scope, or every used connector is classified.')
<h2>Read this before changing a policy</h2>
<ul class="muted">
<li>Source: Power Platform inventory, refreshed within about 15 minutes. Built-in HTTP actions, desktop flows, code apps and endpoints are not in the inventory.</li>
<li>Not evaluated: endpoint filtering, tenant-level custom connector URL patterns, desktop flow modules, Copilot Studio virtual connectors, resource exemptions.</li>
<li>Resource types not included in this run are not counted as usage. Run with -IncludeFlows and -IncludeAgents before a policy decision.</li>
<li>Enforcement after a policy change is asynchronous: usually within an hour, up to 24 hours. Test in a non-production environment first.</li>
<li>This is not an official Microsoft tool and not Microsoft's enforcement engine.</li>
</ul>
</body></html>
"@
    $htmlFile = Join-Path $OutputPath 'Summary.html'
    Set-Content -Path $htmlFile -Value $html -Encoding UTF8; $files.Add($htmlFile)
    Write-Log ("Finished in {0:n0}s. Files: {1}" -f ((Get-Date) - $started).TotalSeconds, $files.Count)
}

#endregion

Write-Host ''
Write-Host ("Environments: {0}   Resources: {1}   Connectors in use: {2}   Data policies: {3}" -f $selectedIds.Count, $resourceStats.Count, $tenantConnectorRows.Count, $policies.Count)
Write-Host ("In violation today: {0}" -f $violations)
if ($changes.Count -gt 0) { Write-Host ("Would break with the proposed change: {0}" -f $wouldBreak) }
if (-not $IncludeFlows -or -not $IncludeAgents) { Write-Host 'Note: flows and/or agents were not included. Add -IncludeFlows -IncludeAgents before deciding on a policy change.' }
if ($canWrite) { Write-Host "Report: $OutputPath (open Summary.html)" } else { Write-Host 'WhatIf: no files written.' }

[pscustomobject]@{
    OutputPath        = $(if ($canWrite) { $OutputPath } else { $null })
    Environments      = $selectedIds.Count
    Resources         = $resourceStats.Count
    ConnectorsInUse   = $tenantConnectorRows.Count
    DataPolicies      = $policies.Count
    CurrentViolations = $violations
    WouldBreak        = $wouldBreak
    Files             = $files.ToArray()
}

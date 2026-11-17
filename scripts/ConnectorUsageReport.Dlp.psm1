#Requires -Version 5.1

<#
    ConnectorUsageReport.Dlp.psm1
    Pure DLP evaluation logic for Get-ConnectorUsageReport.ps1. No network calls, no tenant access,
    so every function here can be tested with fake data (see tests\ConnectorUsageReport.Dlp.Tests.ps1).

    Rules implemented (Microsoft Learn, retrieved 2026-11-17, see research\connector-usage-sources.md):
      - Business / Non-Business / Blocked groups; API names Confidential / General / Blocked.
      - All connectors of one app, flow or agent must sit in the same group in every policy that applies.
      - A Blocked connector in any applicable policy makes the resource non-compliant.
      - Unclassified connectors fall into the policy's default group (Non-Business unless changed).
      - Connector action rules (allow / block per operation) where operations are known.
    Not evaluated: endpoint filtering, tenant-level custom connector URL patterns, desktop flow modules,
    Copilot Studio virtual connectors, resource exemptions.

    Author: Sayed Ali, Microsoft CSA. Not an official Microsoft solution.
#>

Set-StrictMode -Version Latest

# Connectors that data policies cannot block (Learn: "List of connectors that you can't block").
# Learn lists display names; the ids below are our mapping and can go stale when Microsoft adds connectors.
# Only used when a policy's default group is Blocked: these then count as Non-Business.
$script:UnblockableConnectorIds = @(
    'shared_sharepointonline', 'shared_office365', 'shared_office365users', 'shared_office365groups',
    'shared_office365groupsmail', 'shared_teams', 'shared_onedriveforbusiness', 'shared_excelonlinebusiness',
    'shared_onenote', 'shared_planner', 'shared_powerbi', 'shared_todo', 'shared_yammer', 'shared_shifts',
    'shared_skypeforbiz', 'shared_kaizala', 'shared_microsoftformspro', 'shared_cloudappsecurity',
    'shared_approvals', 'shared_flowpush', 'shared_commondataservice', 'shared_commondataserviceforapps',
    'shared_powerappsnotification', 'shared_powerappsnotificationv2', 'shared_powervirtualagents'
)

function Get-PropertyValue {
    <# Null-safe property read that works under Set-StrictMode for PSObjects and hashtables. #>
    param($InputObject, [string] $Name)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $null
    }
    $p = $InputObject.PSObject.Properties[$Name]
    if ($null -ne $p) { return $p.Value }
    return $null
}

function Get-ConnectorShortId {
    <# '/providers/Microsoft.PowerApps/apis/shared_sql' -> 'shared_sql'. #>
    param([string] $ConnectorId)
    if ([string]::IsNullOrWhiteSpace($ConnectorId)) { return '' }
    return ($ConnectorId.Trim().TrimEnd('/') -split '/')[-1].ToLowerInvariant()
}

function ConvertTo-DlpGroupName {
    <# API classification -> the name the admin center shows. #>
    param([string] $Classification)
    switch -Regex ($Classification) {
        '^(Confidential|Business)$'                    { return 'Business' }
        '^(General|NonBusiness|Non-Business|Non-business)$' { return 'NonBusiness' }
        '^Blocked$'                                    { return 'Blocked' }
        default                                        { return 'NonBusiness' }
    }
}

function ConvertTo-DlpPolicyModel {
    <#
    .SYNOPSIS
        Turns one raw policy object (Get-DlpPolicy shape) into the model the evaluation functions use.
    #>
    param(
        [Parameter(Mandatory)] $RawPolicy,
        $ConnectorConfigurations
    )

    $groups = @{}
    foreach ($g in @(Get-PropertyValue $RawPolicy 'connectorGroups')) {
        if ($null -eq $g) { continue }
        $groupName = ConvertTo-DlpGroupName (Get-PropertyValue $g 'classification')
        foreach ($c in @(Get-PropertyValue $g 'connectors')) {
            if ($null -eq $c) { continue }
            $id = Get-ConnectorShortId (Get-PropertyValue $c 'id')
            if ($id) { $groups[$id] = $groupName }
        }
    }

    $envIds = @()
    foreach ($e in @(Get-PropertyValue $RawPolicy 'environments')) {
        if ($null -eq $e) { continue }
        $name = Get-PropertyValue $e 'name'
        if (-not $name) { $name = Get-ConnectorShortId (Get-PropertyValue $e 'id') }
        if ($name) { $envIds += ([string] $name).ToLowerInvariant() }
    }

    if ($null -eq $ConnectorConfigurations) {
        $ConnectorConfigurations = Get-PropertyValue $RawPolicy 'connectorConfigurations'
    }
    $actionRules = @{}
    foreach ($cfg in @(Get-PropertyValue $ConnectorConfigurations 'connectorActionConfigurations')) {
        if ($null -eq $cfg) { continue }
        $id = Get-ConnectorShortId (Get-PropertyValue $cfg 'connectorId')
        if (-not $id) { continue }
        $rules = @{}
        foreach ($r in @(Get-PropertyValue $cfg 'actionRules')) {
            if ($null -eq $r) { continue }
            $rules[([string] (Get-PropertyValue $r 'actionId')).ToLowerInvariant()] = [string] (Get-PropertyValue $r 'behavior')
        }
        $default = [string] (Get-PropertyValue $cfg 'defaultConnectorActionRuleBehavior')
        if (-not $default) { $default = 'Allow' }
        $actionRules[$id] = @{ Default = $default; Rules = $rules }
    }
    $endpointConnectors = @()
    foreach ($cfg in @(Get-PropertyValue $ConnectorConfigurations 'endpointConfigurations')) {
        if ($null -eq $cfg) { continue }
        $id = Get-ConnectorShortId (Get-PropertyValue $cfg 'connectorId')
        if ($id) { $endpointConnectors += $id }
    }

    $scope = [string] (Get-PropertyValue $RawPolicy 'environmentType')
    if (-not $scope) { $scope = 'AllEnvironments' }
    $defaultGroup = ConvertTo-DlpGroupName (Get-PropertyValue $RawPolicy 'defaultConnectorsClassification')
    $displayName = [string] (Get-PropertyValue $RawPolicy 'displayName')
    $name = [string] (Get-PropertyValue $RawPolicy 'name')
    if (-not $displayName) { $displayName = $name }

    [pscustomobject]@{
        Name                    = $name
        DisplayName             = $displayName
        Scope                   = $scope
        EnvironmentIds          = @($envIds)
        DefaultGroup            = $defaultGroup
        Groups                  = $groups
        ActionRules             = $actionRules
        EndpointRuleConnectors  = @($endpointConnectors)
        HasCustomUrlPatterns    = ($null -ne (Get-PropertyValue $RawPolicy 'customConnectorUrlPatternsDefinition'))
        Hypothetical            = $false
    }
}

function Test-DlpPolicyAppliesToEnvironment {
    <# Scope rule: AllEnvironments, OnlyEnvironments / SingleEnvironment (listed), ExceptEnvironments (not listed). #>
    param(
        [Parameter(Mandatory)] $Policy,
        [Parameter(Mandatory)] [string] $EnvironmentId
    )
    $envId = $EnvironmentId.ToLowerInvariant()
    $listed = @($Policy.EnvironmentIds) -contains $envId
    switch ($Policy.Scope) {
        'AllEnvironments'    { return $true }
        'ExceptEnvironments' { return (-not $listed) }
        default              { return $listed }   # OnlyEnvironments, SingleEnvironment
    }
}

function Get-DlpConnectorClassification {
    <#
    .SYNOPSIS
        Where one connector sits in one policy: Business, NonBusiness, Blocked or Ignored.
    .OUTPUTS
        Object with Group and Explicit (true when the policy names the connector, false when it fell to the default group).
    #>
    param(
        [Parameter(Mandatory)] $Policy,
        [Parameter(Mandatory)] [string] $ConnectorId,
        [bool] $IsCustom = $false
    )
    $id = Get-ConnectorShortId $ConnectorId
    if ($Policy.Groups.ContainsKey($id)) {
        return [pscustomobject]@{ Group = $Policy.Groups[$id]; Explicit = $true }
    }
    # Tenant-level policies classify custom connectors by host URL pattern, default rule '*' = Ignore.
    # The inventory has no host URL, so an unlisted custom connector is not evaluated there.
    if ($IsCustom -and $Policy.Scope -ne 'SingleEnvironment' -and -not $Policy.Hypothetical) {
        return [pscustomobject]@{ Group = 'Ignored'; Explicit = $false }
    }
    $group = $Policy.DefaultGroup
    if ($group -eq 'Blocked' -and ($script:UnblockableConnectorIds -contains $id)) { $group = 'NonBusiness' }
    return [pscustomobject]@{ Group = $group; Explicit = $false }
}

function Test-DlpResourceCompliance {
    <#
    .SYNOPSIS
        Evaluates one resource (its full connector set) against every policy that applies to its environment.
    .PARAMETER Connector
        Objects with ConnectorId, optional Operations (string[]) and optional IsCustom.
    .PARAMETER Policy
        Policy models that apply to the resource's environment. Empty = no policy = compliant.
    .OUTPUTS
        Object with Compliant, Violations (string[]) and Classifications (Policy, Connector, Group, Explicit).
    #>
    param(
        [AllowEmptyCollection()] [object[]] $Connector = @(),
        [AllowEmptyCollection()] [object[]] $Policy = @()
    )
    $violations = New-Object System.Collections.Generic.List[string]
    $classifications = New-Object System.Collections.Generic.List[object]

    foreach ($p in @($Policy)) {
        if ($null -eq $p) { continue }
        $byGroup = @{ Business = @(); NonBusiness = @(); Blocked = @() }
        foreach ($c in @($Connector)) {
            if ($null -eq $c) { continue }
            $id = Get-ConnectorShortId (Get-PropertyValue $c 'ConnectorId')
            if (-not $id) { continue }
            $isCustom = [bool] (Get-PropertyValue $c 'IsCustom')
            $cls = Get-DlpConnectorClassification -Policy $p -ConnectorId $id -IsCustom $isCustom
            $classifications.Add([pscustomobject]@{ Policy = $p.DisplayName; Connector = $id; Group = $cls.Group; Explicit = $cls.Explicit })
            if ($byGroup.ContainsKey($cls.Group)) { $byGroup[$cls.Group] += $id }

            # Connector action control: only where the inventory reported operations for this connector.
            if ($cls.Group -ne 'Blocked' -and $p.ActionRules.ContainsKey($id)) {
                $rule = $p.ActionRules[$id]
                foreach ($op in @(Get-PropertyValue $c 'Operations')) {
                    if ([string]::IsNullOrWhiteSpace($op)) { continue }
                    $behavior = $rule.Default
                    $key = ([string] $op).ToLowerInvariant()
                    if ($rule.Rules.ContainsKey($key)) { $behavior = $rule.Rules[$key] }
                    if ($behavior -eq 'Block') {
                        $violations.Add(("[{0}] Blocked action: {1} / {2}" -f $p.DisplayName, $id, $op))
                    }
                }
            }
        }
        foreach ($b in @($byGroup.Blocked | Sort-Object -Unique)) {
            $violations.Add(("[{0}] Blocked connector: {1}" -f $p.DisplayName, $b))
        }
        if (@($byGroup.Business).Count -gt 0 -and @($byGroup.NonBusiness).Count -gt 0) {
            $violations.Add(("[{0}] Business and Non-Business mixed: Business = {1}; Non-Business = {2}" -f `
                    $p.DisplayName, (($byGroup.Business | Sort-Object -Unique) -join ', '), (($byGroup.NonBusiness | Sort-Object -Unique) -join ', ')))
        }
    }

    [pscustomobject]@{
        Compliant       = ($violations.Count -eq 0)
        Violations      = $violations.ToArray()
        Classifications = $classifications.ToArray()
    }
}

function ConvertTo-DlpProposedChange {
    <#
    .SYNOPSIS
        Normalises -ProposedChange input. Accepts hashtables / objects (Connector, Group, optional Policy)
        or strings 'connector=Group' / 'connector=Group@Policy name'.
    #>
    param([AllowEmptyCollection()] [object[]] $ProposedChange = @())
    foreach ($item in @($ProposedChange)) {
        if ($null -eq $item) { continue }
        $connector = $null; $group = $null; $policy = $null
        if ($item -is [string]) {
            if ($item -notmatch '^\s*(?<c>[^=:]+)\s*[=:]\s*(?<g>[^@]+?)\s*(@\s*(?<p>.+))?$') {
                throw "ProposedChange '$item' is not valid. Use 'shared_connector=Blocked' or @{ Connector = 'shared_connector'; Group = 'Business' }."
            }
            $connector = $Matches['c']; $group = $Matches['g']
            if ($Matches.ContainsKey('p')) { $policy = $Matches['p'] }
        }
        else {
            $connector = Get-PropertyValue $item 'Connector'
            $group = Get-PropertyValue $item 'Group'
            $policy = Get-PropertyValue $item 'Policy'
        }
        if ([string]::IsNullOrWhiteSpace($connector) -or [string]::IsNullOrWhiteSpace($group)) {
            throw "ProposedChange needs both Connector and Group (Business, NonBusiness or Blocked)."
        }
        if (([string] $group).Trim() -notmatch '^(Business|NonBusiness|Non-Business|Blocked)$') {
            throw "ProposedChange group '$group' is not valid. Use Business, NonBusiness or Blocked."
        }
        $policyName = $null
        if ($policy) { $policyName = ([string] $policy).Trim() }
        [pscustomobject]@{
            Connector = Get-ConnectorShortId ([string] $connector)
            Group     = ConvertTo-DlpGroupName (([string] $group).Trim())
            Policy    = $policyName
        }
    }
}

function Copy-DlpPolicyModel {
    param([Parameter(Mandatory)] $Policy)
    $copy = $Policy.PSObject.Copy()
    $copy.Groups = @{} + $Policy.Groups
    return $copy
}

function Get-DlpProposedPolicySet {
    <#
    .SYNOPSIS
        Returns the policies that would apply to one environment after the proposed changes.
    .DESCRIPTION
        A change without Policy is applied to every applicable policy. A change with Policy only touches the
        policy with that name or display name. When no policy applies to the environment, a hypothetical
        policy is built (default group Non-Business, proposed connectors in their target group) so the admin
        can see what a new policy would do.
    #>
    param(
        [AllowEmptyCollection()] [object[]] $Policy = @(),
        [AllowEmptyCollection()] [object[]] $ProposedChange = @()
    )
    $changes = @($ProposedChange | Where-Object { $null -ne $_ })
    $current = @($Policy | Where-Object { $null -ne $_ })
    if ($changes.Count -eq 0) { return , $current }

    if ($current.Count -eq 0) {
        $groups = @{}
        foreach ($ch in $changes) { if (-not $ch.Policy) { $groups[$ch.Connector] = $ch.Group } }
        if ($groups.Count -eq 0) { return , @() }
        $hypothetical = [pscustomobject]@{
            Name = 'proposed-new-policy'; DisplayName = '(proposed new policy)'; Scope = 'AllEnvironments'
            EnvironmentIds = @(); DefaultGroup = 'NonBusiness'; Groups = $groups; ActionRules = @{}
            EndpointRuleConnectors = @(); HasCustomUrlPatterns = $false; Hypothetical = $true
        }
        return , @($hypothetical)
    }

    $after = @()
    foreach ($p in $current) {
        $copy = Copy-DlpPolicyModel -Policy $p
        foreach ($ch in $changes) {
            if ($ch.Policy -and $ch.Policy -ne $p.Name -and $ch.Policy -ne $p.DisplayName) { continue }
            $copy.Groups[$ch.Connector] = $ch.Group
        }
        $after += $copy
    }
    return , $after
}

function Get-DlpImpact {
    <#
    .SYNOPSIS
        Compares one resource before and after the proposed change.
    .OUTPUTS
        Object with Impact (WouldBreak, AlreadyViolating, WouldBeFixed, NoImpact), Before, After, Reason.
    #>
    param(
        [AllowEmptyCollection()] [object[]] $Connector = @(),
        [AllowEmptyCollection()] [object[]] $PolicyBefore = @(),
        [AllowEmptyCollection()] [object[]] $PolicyAfter = @()
    )
    $before = Test-DlpResourceCompliance -Connector $Connector -Policy $PolicyBefore
    $after = Test-DlpResourceCompliance -Connector $Connector -Policy $PolicyAfter
    $impact = 'NoImpact'
    if ($before.Compliant -and -not $after.Compliant) { $impact = 'WouldBreak' }
    elseif (-not $before.Compliant -and -not $after.Compliant) { $impact = 'AlreadyViolating' }
    elseif (-not $before.Compliant -and $after.Compliant) { $impact = 'WouldBeFixed' }

    $beforeText = 'Compliant'; if (-not $before.Compliant) { $beforeText = 'Violation' }
    $afterText = 'Compliant'; if (-not $after.Compliant) { $afterText = 'Violation' }
    [pscustomobject]@{
        Impact = $impact
        Before = $beforeText
        After  = $afterText
        Reason = (@($after.Violations) -join ' | ')
    }
}

Export-ModuleMember -Function Get-PropertyValue, Get-ConnectorShortId, ConvertTo-DlpGroupName, ConvertTo-DlpPolicyModel,
    Test-DlpPolicyAppliesToEnvironment, Get-DlpConnectorClassification, Test-DlpResourceCompliance,
    ConvertTo-DlpProposedChange, Get-DlpProposedPolicySet, Get-DlpImpact

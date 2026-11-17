#Requires -Version 5.1
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

<#
    Pester 5 tests for the DLP evaluation logic. Fake data only, no tenant access.
    Run:  Invoke-Pester -Path .\scripts\tests
#>

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\ConnectorUsageReport.Dlp.psm1') -Force

    function New-FakeRawPolicy {
        param(
            [string] $Name = 'p1',
            [string] $DisplayName = 'Policy 1',
            [string] $Scope = 'AllEnvironments',
            [string[]] $Environments = @(),
            [string] $Default = 'General',
            [string[]] $Business = @(),
            [string[]] $NonBusiness = @(),
            [string[]] $Blocked = @(),
            $ConnectorConfigurations = $null
        )
        $toConnectors = { param($ids) @($ids | ForEach-Object { [pscustomobject]@{ id = "/providers/Microsoft.PowerApps/apis/$_"; name = $_ } }) }
        [pscustomobject]@{
            name                            = $Name
            displayName                     = $DisplayName
            environmentType                 = $Scope
            defaultConnectorsClassification = $Default
            environments                    = @($Environments | ForEach-Object { [pscustomobject]@{ id = "/providers/Microsoft.BusinessAppPlatform/scopes/admin/environments/$_"; name = $_ } })
            connectorGroups                 = @(
                [pscustomobject]@{ classification = 'Confidential'; connectors = (& $toConnectors $Business) }
                [pscustomobject]@{ classification = 'General'; connectors = (& $toConnectors $NonBusiness) }
                [pscustomobject]@{ classification = 'Blocked'; connectors = (& $toConnectors $Blocked) }
            )
            connectorConfigurations         = $ConnectorConfigurations
        }
    }

    function New-FakeConnector {
        param([string] $Id, [string[]] $Operations = @(), [bool] $IsCustom = $false)
        [pscustomobject]@{ ConnectorId = $Id; Operations = $Operations; IsCustom = $IsCustom }
    }
}

Describe 'Helpers' {
    It 'takes the last path segment as the connector id, lower case' {
        Get-ConnectorShortId '/providers/Microsoft.PowerApps/apis/shared_SQL' | Should -Be 'shared_sql'
    }
    It 'maps API classifications to admin center names' {
        ConvertTo-DlpGroupName 'Confidential' | Should -Be 'Business'
        ConvertTo-DlpGroupName 'General' | Should -Be 'NonBusiness'
        ConvertTo-DlpGroupName 'Blocked' | Should -Be 'Blocked'
    }
}

Describe 'Policy scope' {
    It 'AllEnvironments applies everywhere' {
        $p = ConvertTo-DlpPolicyModel (New-FakeRawPolicy -Scope AllEnvironments)
        Test-DlpPolicyAppliesToEnvironment -Policy $p -EnvironmentId 'env-a' | Should -BeTrue
    }
    It 'OnlyEnvironments applies to listed environments only (case-insensitive)' {
        $p = ConvertTo-DlpPolicyModel (New-FakeRawPolicy -Scope OnlyEnvironments -Environments 'ENV-A')
        Test-DlpPolicyAppliesToEnvironment -Policy $p -EnvironmentId 'env-a' | Should -BeTrue
        Test-DlpPolicyAppliesToEnvironment -Policy $p -EnvironmentId 'env-b' | Should -BeFalse
    }
    It 'ExceptEnvironments skips listed environments' {
        $p = ConvertTo-DlpPolicyModel (New-FakeRawPolicy -Scope ExceptEnvironments -Environments 'env-a')
        Test-DlpPolicyAppliesToEnvironment -Policy $p -EnvironmentId 'env-a' | Should -BeFalse
        Test-DlpPolicyAppliesToEnvironment -Policy $p -EnvironmentId 'env-b' | Should -BeTrue
    }
    It 'SingleEnvironment applies to its one environment' {
        $p = ConvertTo-DlpPolicyModel (New-FakeRawPolicy -Scope SingleEnvironment -Environments 'env-a')
        Test-DlpPolicyAppliesToEnvironment -Policy $p -EnvironmentId 'env-a' | Should -BeTrue
        Test-DlpPolicyAppliesToEnvironment -Policy $p -EnvironmentId 'env-b' | Should -BeFalse
    }
}

Describe 'Connector classification' {
    It 'returns the explicit group' {
        $p = ConvertTo-DlpPolicyModel (New-FakeRawPolicy -Business 'shared_sharepointonline')
        $c = Get-DlpConnectorClassification -Policy $p -ConnectorId 'shared_sharepointonline'
        $c.Group | Should -Be 'Business'
        $c.Explicit | Should -BeTrue
    }
    It 'falls back to the default group (Non-Business) for unclassified connectors' {
        $p = ConvertTo-DlpPolicyModel (New-FakeRawPolicy -Business 'shared_sharepointonline')
        $c = Get-DlpConnectorClassification -Policy $p -ConnectorId 'shared_twitter'
        $c.Group | Should -Be 'NonBusiness'
        $c.Explicit | Should -BeFalse
    }
    It 'honours a default group of Blocked' {
        $p = ConvertTo-DlpPolicyModel (New-FakeRawPolicy -Default Blocked)
        (Get-DlpConnectorClassification -Policy $p -ConnectorId 'shared_twitter').Group | Should -Be 'Blocked'
    }
    It 'puts unblockable connectors in Non-Business when the default group is Blocked' {
        $p = ConvertTo-DlpPolicyModel (New-FakeRawPolicy -Default Blocked)
        (Get-DlpConnectorClassification -Policy $p -ConnectorId 'shared_sharepointonline').Group | Should -Be 'NonBusiness'
    }
    It 'does not evaluate an unlisted custom connector in a tenant-level policy' {
        $p = ConvertTo-DlpPolicyModel (New-FakeRawPolicy -Scope AllEnvironments)
        (Get-DlpConnectorClassification -Policy $p -ConnectorId 'shared_my-5fapi' -IsCustom $true).Group | Should -Be 'Ignored'
    }
    It 'uses the default group for an unlisted custom connector in an environment-level policy' {
        $p = ConvertTo-DlpPolicyModel (New-FakeRawPolicy -Scope SingleEnvironment -Environments 'env-a')
        (Get-DlpConnectorClassification -Policy $p -ConnectorId 'shared_my-5fapi' -IsCustom $true).Group | Should -Be 'NonBusiness'
    }
}

Describe 'Resource compliance' {
    BeforeAll {
        $script:policy = ConvertTo-DlpPolicyModel (New-FakeRawPolicy -Business 'shared_sharepointonline', 'shared_sql' -Blocked 'shared_facebook')
    }
    It 'is compliant when no policy applies' {
        $r = Test-DlpResourceCompliance -Connector (New-FakeConnector 'shared_facebook') -Policy @()
        $r.Compliant | Should -BeTrue
    }
    It 'is compliant when all connectors are Business' {
        $r = Test-DlpResourceCompliance -Connector (New-FakeConnector 'shared_sharepointonline'), (New-FakeConnector 'shared_sql') -Policy $policy
        $r.Compliant | Should -BeTrue
    }
    It 'is compliant when all connectors are Non-Business' {
        $r = Test-DlpResourceCompliance -Connector (New-FakeConnector 'shared_twitter'), (New-FakeConnector 'shared_rss') -Policy $policy
        $r.Compliant | Should -BeTrue
    }
    It 'flags Business mixed with Non-Business' {
        $r = Test-DlpResourceCompliance -Connector (New-FakeConnector 'shared_sharepointonline'), (New-FakeConnector 'shared_twitter') -Policy $policy
        $r.Compliant | Should -BeFalse
        $r.Violations[0] | Should -Match 'Business and Non-Business mixed'
    }
    It 'flags a Blocked connector even when it is the only one' {
        $r = Test-DlpResourceCompliance -Connector (New-FakeConnector 'shared_facebook') -Policy $policy
        $r.Compliant | Should -BeFalse
        $r.Violations[0] | Should -Match 'Blocked connector: shared_facebook'
    }
    It 'is compliant for a resource without connectors' {
        (Test-DlpResourceCompliance -Connector @() -Policy $policy).Compliant | Should -BeTrue
    }
}

Describe 'Combined effect of multiple policies' {
    It 'Blocked in any applicable policy wins' {
        $a = ConvertTo-DlpPolicyModel (New-FakeRawPolicy -Name a -DisplayName A -Business 'shared_twitter')
        $b = ConvertTo-DlpPolicyModel (New-FakeRawPolicy -Name b -DisplayName B -Blocked 'shared_twitter')
        $r = Test-DlpResourceCompliance -Connector (New-FakeConnector 'shared_twitter') -Policy $a, $b
        $r.Compliant | Should -BeFalse
        ($r.Violations -join ' ') | Should -Match '\[B\] Blocked connector'
    }
    It 'requires the same group in every policy (Learn example: SharePoint + Salesforce split by policy B)' {
        $a = ConvertTo-DlpPolicyModel (New-FakeRawPolicy -Name a -DisplayName A -Business 'shared_sharepointonline', 'shared_salesforce')
        $b = ConvertTo-DlpPolicyModel (New-FakeRawPolicy -Name b -DisplayName B -Business 'shared_sharepointonline' -NonBusiness 'shared_salesforce')
        $r = Test-DlpResourceCompliance -Connector (New-FakeConnector 'shared_sharepointonline'), (New-FakeConnector 'shared_salesforce') -Policy $a, $b
        $r.Compliant | Should -BeFalse
        @($r.Violations).Count | Should -Be 1
        $r.Violations[0] | Should -Match '^\[B\]'
    }
    It 'is compliant when the connectors share a group in every policy' {
        $a = ConvertTo-DlpPolicyModel (New-FakeRawPolicy -Name a -DisplayName A -Business 'shared_sharepointonline', 'shared_basecamp3')
        $b = ConvertTo-DlpPolicyModel (New-FakeRawPolicy -Name b -DisplayName B -NonBusiness 'shared_sharepointonline', 'shared_basecamp3')
        (Test-DlpResourceCompliance -Connector (New-FakeConnector 'shared_sharepointonline'), (New-FakeConnector 'shared_basecamp3') -Policy $a, $b).Compliant | Should -BeTrue
    }
}

Describe 'Connector action rules' {
    BeforeAll {
        $cfg = [pscustomobject]@{
            connectorActionConfigurations = @(
                [pscustomobject]@{
                    connectorId                        = '/providers/Microsoft.PowerApps/apis/shared_msnweather'
                    actionRules                        = @([pscustomobject]@{ actionId = 'TodaysForecast'; behavior = 'Block' })
                    defaultConnectorActionRuleBehavior = 'Allow'
                }
                [pscustomobject]@{
                    connectorId                        = '/providers/Microsoft.PowerApps/apis/shared_github'
                    actionRules                        = @([pscustomobject]@{ actionId = 'GetRepositoryById'; behavior = 'Allow' })
                    defaultConnectorActionRuleBehavior = 'Block'
                }
            )
            endpointConfigurations        = @([pscustomobject]@{ connectorId = '/providers/Microsoft.PowerApps/apis/shared_sql'; endpointRules = @() })
        }
        $script:policy = ConvertTo-DlpPolicyModel (New-FakeRawPolicy -ConnectorConfigurations $cfg)
    }
    It 'flags an operation that a rule blocks' {
        $r = Test-DlpResourceCompliance -Connector (New-FakeConnector 'shared_msnweather' -Operations 'TodaysForecast') -Policy $policy
        $r.Compliant | Should -BeFalse
        $r.Violations[0] | Should -Match 'Blocked action: shared_msnweather / TodaysForecast'
    }
    It 'allows an operation that no rule names when the default is Allow' {
        (Test-DlpResourceCompliance -Connector (New-FakeConnector 'shared_msnweather' -Operations 'CurrentWeather') -Policy $policy).Compliant | Should -BeTrue
    }
    It 'blocks an operation that no rule names when the default is Block' {
        (Test-DlpResourceCompliance -Connector (New-FakeConnector 'shared_github' -Operations 'ListIssues') -Policy $policy).Compliant | Should -BeFalse
    }
    It 'allows an explicitly allowed operation when the default is Block' {
        (Test-DlpResourceCompliance -Connector (New-FakeConnector 'shared_github' -Operations 'GetRepositoryById') -Policy $policy).Compliant | Should -BeTrue
    }
    It 'cannot judge action rules when the inventory reports no operations' {
        (Test-DlpResourceCompliance -Connector (New-FakeConnector 'shared_github') -Policy $policy).Compliant | Should -BeTrue
    }
    It 'records which connectors have endpoint rules' {
        $policy.EndpointRuleConnectors | Should -Contain 'shared_sql'
    }
}

Describe 'Proposed change parsing' {
    It 'accepts a hashtable' {
        $c = @(ConvertTo-DlpProposedChange @{ Connector = 'shared_Twitter'; Group = 'Blocked' })
        $c[0].Connector | Should -Be 'shared_twitter'
        $c[0].Group | Should -Be 'Blocked'
        $c[0].Policy | Should -BeNullOrEmpty
    }
    It 'accepts the string form with a policy name' {
        $c = @(ConvertTo-DlpProposedChange 'shared_sql=Business@Tenant baseline')
        $c[0].Connector | Should -Be 'shared_sql'
        $c[0].Group | Should -Be 'Business'
        $c[0].Policy | Should -Be 'Tenant baseline'
    }
    It 'rejects an unknown group' {
        { ConvertTo-DlpProposedChange 'shared_sql=Sometimes' } | Should -Throw
    }
    It 'rejects a change without a connector' {
        { ConvertTo-DlpProposedChange @{ Group = 'Blocked' } } | Should -Throw
    }
}

Describe 'Impact view' {
    BeforeAll {
        $script:policy = ConvertTo-DlpPolicyModel (New-FakeRawPolicy -Business 'shared_sharepointonline', 'shared_sql' -Blocked 'shared_facebook')
        $script:spSql = @((New-FakeConnector 'shared_sharepointonline'), (New-FakeConnector 'shared_sql'))
    }
    It 'reports WouldBreak when a move splits a resource across groups' {
        $change = @(ConvertTo-DlpProposedChange 'shared_sql=NonBusiness')
        $after = Get-DlpProposedPolicySet -Policy $policy -ProposedChange $change
        $i = Get-DlpImpact -Connector $spSql -PolicyBefore $policy -PolicyAfter $after
        $i.Impact | Should -Be 'WouldBreak'
        $i.Reason | Should -Match 'mixed'
    }
    It 'reports WouldBreak when a used connector is blocked' {
        $change = @(ConvertTo-DlpProposedChange 'shared_sql=Blocked')
        $after = Get-DlpProposedPolicySet -Policy $policy -ProposedChange $change
        (Get-DlpImpact -Connector $spSql -PolicyBefore $policy -PolicyAfter $after).Impact | Should -Be 'WouldBreak'
    }
    It 'reports NoImpact when the resource does not use the connector' {
        $change = @(ConvertTo-DlpProposedChange 'shared_twitter=Blocked')
        $after = Get-DlpProposedPolicySet -Policy $policy -ProposedChange $change
        (Get-DlpImpact -Connector $spSql -PolicyBefore $policy -PolicyAfter $after).Impact | Should -Be 'NoImpact'
    }
    It 'reports WouldBeFixed when the change resolves an existing violation' {
        $mixed = @((New-FakeConnector 'shared_sharepointonline'), (New-FakeConnector 'shared_twitter'))
        $change = @(ConvertTo-DlpProposedChange 'shared_twitter=Business')
        $after = Get-DlpProposedPolicySet -Policy $policy -ProposedChange $change
        (Get-DlpImpact -Connector $mixed -PolicyBefore $policy -PolicyAfter $after).Impact | Should -Be 'WouldBeFixed'
    }
    It 'reports AlreadyViolating when it was and stays in violation' {
        $fb = @((New-FakeConnector 'shared_facebook'))
        $change = @(ConvertTo-DlpProposedChange 'shared_sql=NonBusiness')
        $after = Get-DlpProposedPolicySet -Policy $policy -ProposedChange $change
        (Get-DlpImpact -Connector $fb -PolicyBefore $policy -PolicyAfter $after).Impact | Should -Be 'AlreadyViolating'
    }
    It 'does not modify the original policy model' {
        $change = @(ConvertTo-DlpProposedChange 'shared_sql=Blocked')
        $null = Get-DlpProposedPolicySet -Policy $policy -ProposedChange $change
        $policy.Groups['shared_sql'] | Should -Be 'Business'
    }
    It 'only touches the named policy when Policy is given' {
        $a = ConvertTo-DlpPolicyModel (New-FakeRawPolicy -Name a -DisplayName A -Business 'shared_sql')
        $b = ConvertTo-DlpPolicyModel (New-FakeRawPolicy -Name b -DisplayName B -Business 'shared_sql')
        $after = Get-DlpProposedPolicySet -Policy $a, $b -ProposedChange @(ConvertTo-DlpProposedChange 'shared_sql=Blocked@B')
        ($after | Where-Object DisplayName -eq 'A').Groups['shared_sql'] | Should -Be 'Business'
        ($after | Where-Object DisplayName -eq 'B').Groups['shared_sql'] | Should -Be 'Blocked'
    }
    It 'builds a hypothetical policy when no policy applies to the environment' {
        $change = @(ConvertTo-DlpProposedChange 'shared_sql=Business')
        $after = Get-DlpProposedPolicySet -Policy @() -ProposedChange $change
        @($after).Count | Should -Be 1
        $after[0].Hypothetical | Should -BeTrue
        $i = Get-DlpImpact -Connector $spSql -PolicyBefore @() -PolicyAfter $after
        $i.Impact | Should -Be 'WouldBreak'   # SQL -> Business, SharePoint stays in the default Non-Business group
    }
    It 'returns the current policies unchanged when there is no proposed change' {
        $after = Get-DlpProposedPolicySet -Policy $policy -ProposedChange @()
        @($after).Count | Should -Be 1
        $after[0].Groups['shared_sql'] | Should -Be 'Business'
    }
}

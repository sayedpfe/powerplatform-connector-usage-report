# Connector usage report for a DLP review

`Get-ConnectorUsageReport.ps1` lists, per Power Platform environment, which connectors your apps, flows and agents
use, who owns them, and which data (DLP) policy group each connector sits in. With `-ProposedChange` it also lists
what would break if you moved or blocked a connector.

The script is read-only. It does not change a policy, an environment, an app, a flow or an agent. It writes report
files to a folder on your machine and nothing else.

Not an official Microsoft solution. Provided as is, without warranty.

A complete sample report with an explanation of every file is in [samples](../samples/README.md).

## What you need

| Item | Detail |
|---|---|
| Role | Power Platform administrator (Global administrator or Dynamics 365 administrator also work). Global reader can read the usage data but not the data policies. |
| Power Platform CLI | `pac` 2.x with the `resource-query` command group (Preview). Tested with 2.12.2. Install: https://aka.ms/PowerPlatformCLI |
| PowerShell | Windows PowerShell 5.1 or PowerShell 7 |
| Admin module | `Microsoft.PowerApps.Administration.PowerShell`, only when the script reads the policies itself. Microsoft documents this module for Windows PowerShell 5.1. |
| Sign-in | Interactive, as a user. A service principal cannot be used: the Power Platform inventory API accepts delegated user sign-in only. |
| Files | `Get-ConnectorUsageReport.ps1` and `ConnectorUsageReport.Dlp.psm1` in the same folder |

## Install

```powershell
# Power Platform CLI (one of the documented ways)
winget install Microsoft.PowerAppsCLI

# Admin module, current user only
Install-Module Microsoft.PowerApps.Administration.PowerShell -Scope CurrentUser

# Sign pac in to the tenant you want to report on, then check it
pac auth create
pac auth who
```

## Run

```powershell
# Everything: apps, flows and agents in all environments
.\Get-ConnectorUsageReport.ps1 -IncludeFlows -IncludeAgents

# One environment (id or exact display name), into a folder of your choice
.\Get-ConnectorUsageReport.ps1 -EnvironmentName 'Finance Prod' -IncludeFlows -IncludeAgents -OutputPath C:\Reports\FinanceProd

# What breaks if SQL Server is blocked and RSS moves to Business?
.\Get-ConnectorUsageReport.ps1 -IncludeFlows -IncludeAgents `
    -ProposedChange 'shared_sql=Blocked', 'shared_rss=Business'

# Same, but only in one named policy
.\Get-ConnectorUsageReport.ps1 -IncludeFlows -IncludeAgents `
    -ProposedChange @{ Connector = 'shared_sql'; Group = 'Blocked'; Policy = 'Tenant baseline' }

# Preview: collect and evaluate, write no files
.\Get-ConnectorUsageReport.ps1 -IncludeFlows -IncludeAgents -WhatIf
```

You get one sign-in prompt from the admin module (`Add-PowerAppsAccount`). The script uses the pac profile that is
already active and stops if the two are on different tenants. Add `-TenantId <guid>` to make the script refuse any
other tenant.

| Parameter | Meaning |
|---|---|
| `-EnvironmentName` | Environment ids or display names. All environments when omitted. |
| `-OutputPath` | Report folder. Default `.\ConnectorUsageReport-<timestamp>`. |
| `-IncludeFlows` | Add cloud flows, agent flows and workflow agent flows. |
| `-IncludeAgents` | Add Copilot Studio agents and Agent Builder agents. |
| `-ProposedChange` | Moves to test: `'connector=Group'`, `'connector=Group@Policy'` or a hashtable. Group is `Business`, `NonBusiness` or `Blocked`. |
| `-DlpPolicyPath` | Use an exported policy file instead of the admin module (see below). |
| `-TenantId` | Stop unless pac and the admin module are on this tenant. |
| `-SkipOwnerLookup` | Show owner object ids, do not look up names. |
| `-PageSize`, `-MaxRetry` | Inventory page size (default 250) and retries on throttling (default 5). |

Connector ids look like `shared_sharepointonline`. You find them in the `Connector` column of any report file.

### Policies from a file (optional)

If the person who runs the report may not sign in to the admin module, a Power Platform administrator can export the
policies once and hand over the file:

```powershell
Add-PowerAppsAccount
$tenantId = '<tenant id>'
$policies = Get-DlpPolicy
foreach ($p in $policies.value) {
    $cfg = $null
    try { $cfg = Get-PowerAppDlpPolicyConnectorConfigurations -TenantId $tenantId -PolicyName $p.name } catch { }
    $p | Add-Member -NotePropertyName connectorConfigurations -NotePropertyValue $cfg -Force
}
$policies | ConvertTo-Json -Depth 20 | Set-Content .\dlp.json

.\Get-ConnectorUsageReport.ps1 -IncludeFlows -IncludeAgents -DlpPolicyPath .\dlp.json
```

## What you get

| File | Content |
|---|---|
| `Summary.html` | Start here. Totals, impact of the proposed change, connectors in use, environments, policy gaps. |
| `ConnectorUsage_<environment>.csv` | One row per connector per app, flow or agent. |
| `Summary.csv` | Connector by environment: number of canvas apps, model-driven apps, cloud flows, agent flows, agents, owners. |
| `Environments.csv` | Per environment: type, Managed Environment, policies that apply, resources, current violations, would break. |
| `DlpPolicies.csv` | Per policy: scope, default group, each classified connector with its group, action rules, endpoint rules. Only when the tenant has policies. |
| `PolicyGaps.csv` | Connectors named in a policy but used nowhere, and connectors in use that only sit in the default group. |
| `Impact.csv` | Only with `-ProposedChange`. One row per app, flow or agent that uses a changed connector or changes status. |
| `run.log` | What was read, paging, retries, warnings. |

### Columns of the per-environment file

| Column | Meaning |
|---|---|
| `Connector`, `ConnectorName`, `Tier`, `Publisher` | Connector id, display name, Standard / Premium / Custom, publisher. `Custom` = not in the certified catalogue. |
| `ResourceType`, `ResourceName`, `ResourceStatus` | CanvasApp, ModelDrivenApp, ManagedApp, CloudFlow, AgentFlow, WorkflowAgentFlow, Agent. Flow status as reported (Activated, Deactivated, Suspended). |
| `Owner`, `OwnerId` | Owner name when it could be resolved, otherwise the Entra object id. |
| `LastModified` | Last modified. For agents: last published, otherwise created. |
| `Environment`, `EnvironmentType`, `ManagedEnvironment` | Where the resource lives. |
| `DlpPolicy`, `DlpGroup` | Every policy that covers the environment and the connector's group in each, in the same order. `(default)` = the policy does not name the connector, it falls into the default group. |
| `ConnectorRole`, `Operations` | Action, Trigger or both, and the operations used where the inventory reports them. |
| `DlpStatus`, `DlpViolation` | `NoPolicy`, `Compliant` or `Violation` today, and why. |

### How to read the impact view

| Impact | Meaning | What to do |
|---|---|---|
| `WouldBreak` | Compliant today, in violation after the change | Talk to the owner, or change the plan, before you save the policy |
| `AlreadyViolating` | In violation today and after | Already suspended or blocked; clean up separately |
| `WouldBeFixed` | In violation today, compliant after | The change repairs it |
| `NoImpact` | Uses a changed connector, stays compliant | Nothing |

The rules behind it: all connectors of one app, flow or agent must be in the same group (Business or Non-Business)
in every policy that covers its environment; a Blocked connector in any of those policies stops the resource;
a connector the policy does not name is in the policy's default group; a blocked action stops a resource that uses
that action.

When no policy covers an environment, the impact view assumes a new policy with your proposed connectors in their
target group and everything else in Non-Business. It shows as `(proposed new policy)`.

## Limits

| Limit | Why | What it means for you |
|---|---|---|
| Built-in HTTP actions are not seen | The inventory lists connectors, not built-in actions | A flow that calls a service with the built-in HTTP action shows no connector for it. Review HTTP separately before you reclassify HTTP. |
| Desktop flows are not included | Not an inventory resource type | Desktop flow modules in a policy are not evaluated |
| Endpoint filtering is listed, not evaluated | The inventory has no endpoints; the feature is in preview | Check SQL / HTTP / Blob endpoint rules by hand |
| Custom connectors in tenant-level policies | Classified by host URL pattern, which the inventory does not have | Shown as `Ignored` unless the policy names the connector |
| Code apps, vibe apps, App Builder apps | They report no connector data | Not counted |
| Model-driven apps rarely show connectors | They use connectors only through embedded canvas pages | Expected |
| No "last run" | Not in the inventory | Use `LastModified` and `ResourceStatus`; a quiet flow can still be a yearly process |
| Copilot Studio channel / authentication rules | These are virtual connectors, not real usage | Not evaluated |
| Resource exemptions | Not read | An exempt resource may be reported as a violation |
| Data is up to 15 minutes old | Inventory refresh | Run again right before you change the policy |
| Unblockable connectors | Microsoft lists names, the script holds an id list that can age | Only matters when a policy's default group is Blocked |
| No unattended run | The inventory API does not accept service principals | Run it as an admin |

The report lowers the risk of a policy change. It does not prove that nothing breaks. Policy enforcement is
asynchronous (usually within an hour, up to 24 hours), so test the change in a non-production environment and watch
for suspended flows afterwards.

## Troubleshooting

| Message | Fix |
|---|---|
| `No active pac auth profile` | `pac auth create`, or `pac auth select --index <n>` |
| `The active pac profile is on tenant ...` | Select the right pac profile or correct `-TenantId` |
| `The admin module is signed in to tenant ...` | `Remove-PowerAppsAccount`, run again and sign in to the same tenant as pac |
| `The inventory returned no environments` | The account lacks the admin role, or has never opened the Power Platform admin center |
| `KQLOM format is wrong` | pac version too old or too new for this script; send `run.log` |
| Throttling warnings | The script waits and retries by itself; raise `-MaxRetry` or lower `-PageSize` if it gives up |

## Sources

Microsoft Learn, retrieved 2026-11-17:
[Power Platform inventory](https://learn.microsoft.com/en-us/power-platform/admin/power-platform-inventory),
[Inventory API](https://learn.microsoft.com/en-us/power-platform/admin/inventory-api),
[Inventory schema and known limitations](https://learn.microsoft.com/en-us/power-platform/admin/inventory-schema),
[Connector classification](https://learn.microsoft.com/en-us/power-platform/admin/dlp-connector-classification),
[Combined effect of multiple data policies](https://learn.microsoft.com/en-us/power-platform/admin/dlp-combined-effect-multiple-policies),
[Impact of data policies on apps and flows](https://learn.microsoft.com/en-us/power-platform/admin/dlp-impact-policies-apps-flows),
[Connector action control](https://learn.microsoft.com/en-us/power-platform/admin/connector-action-control),
[Connector endpoint filtering (preview)](https://learn.microsoft.com/en-us/power-platform/admin/connector-endpoint-filtering),
[PowerShell support for Power Apps and Power Automate](https://learn.microsoft.com/en-us/power-platform/admin/powerapps-powershell).

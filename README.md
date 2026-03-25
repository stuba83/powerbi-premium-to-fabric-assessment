# Power BI Tenant Inventory Script
### Pre-Assessment Tool for Power BI Premium P → Microsoft Fabric F Migration

This PowerShell script connects to the **Power BI REST API** and **Microsoft Graph** to generate a complete tenant inventory for planning a capacity migration from Power BI Premium P SKUs to Microsoft Fabric F SKUs.

It classifies users as **Developers** (require PRO license) or **Viewer Only** (Free on Fabric F capacity), identifies PPU license holders, and surfaces M365 users with licenses assigned but no workspace membership — all feeding into a cost analysis that quantifies the net monthly delta between your current P capacity and the target F capacity.

---

## Output Files

| File | Description |
|------|-------------|
| `PBI_Workspaces.csv` | All active shared workspaces with capacity, owner, content counts, and flags for orphaned/empty |
| `PBI_WorkspaceUsers.csv` | One row per user per workspace with role and PPU flag |
| `PBI_UserSummary.csv` | One row per unique user with Developer/Viewer classification and license recommendation |
| `PBI_UsersWithoutWorkspace.csv` | M365 users with a license assigned but NOT a member of any workspace |
| `PBI_CapacitySummary.csv` | Workspace counts grouped by capacity |
| `PBI_ExecutiveSummary.txt` | Cost analysis: current state vs future state on Fabric F |

---

## Prerequisites

### 1. Power BI Administrator role
Your account must have the **Power BI Administrator** role in the tenant you want to inventory.

### 2. PowerShell 7
> ⚠️ Do **not** use PowerShell ISE — it is frozen at version 5.1 and will not work correctly.

Download and install PowerShell 7:
👉 https://aka.ms/powershell

Verify your version:
```powershell
$PSVersionTable.PSVersion
# Major should be 7
```

### 3. Azure CLI
The script uses Azure CLI to obtain a Microsoft Graph token for M365 user enumeration.

Download and install:
👉 https://aka.ms/installazurecliwindows

After installing, log in to your tenant:
```powershell
az login --tenant <your-tenant-id>
```

> Your Tenant ID is found in **Azure Portal → Azure Active Directory → Overview → Tenant ID**

---

## Installation

### Option A — Clone the repo
```powershell
git clone https://github.com/<your-username>/pbi-tenant-inventory.git
cd pbi-tenant-inventory
```

### Option B — Download the script directly
Download `Get-PBIInventory.ps1` and place it in a folder of your choice.

---

## Running the Script

Open **PowerShell 7** (not ISE) and navigate to the folder containing the script:

```powershell
cd C:\path\to\script

# Unblock the file (required for downloaded scripts on Windows)
Unblock-File .\Get-PBIInventory.ps1

# Run
.\Get-PBIInventory.ps1
```

### Setup Prompts

The script will prompt you interactively — no code editing required:

```
================================================
  POWER BI TENANT INVENTORY — SETUP
  Power BI Premium P to Fabric F Migration
================================================

  Tenant ID (Azure Portal > Azure AD > Overview): xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

  Monthly contract prices (USD) — press Enter to accept the default value:
  P1 capacity price/month      [default: 3863.63]:
  F64 capacity price/month     [default: 5000.00]:
  PRO license price/user/month [default: 10.00]:
  PPU license price/user/month [default: 20.00]:
  Number of active P1 capacities   [default: 2]:
```

> Press **Enter** on any pricing field to use the default value. Update with your actual contract prices for accurate cost analysis.

### Authentication

The script authenticates **twice**:

1. **Power BI Service** — a browser login window will open. Sign in with your Power BI Admin account.
2. **Microsoft Graph** — uses your active Azure CLI session (`az login`) to obtain a Graph token. No additional login required if `az login` was already run.

---

## User Classification Logic

| Classification | Criteria | License on Fabric F |
|---|---|---|
| **Developer** | Holds Admin, Member, or Contributor role in **any** workspace | PRO (keep) |
| **Developer (was PPU)** | Developer role + workspace `licenseType = PremiumPerUser` | PRO (downgrade from PPU — saves cost) |
| **Viewer Only** | Exclusively Viewer role across **all** workspaces | **Free** (significant savings) |
| **Unknown** | No role found — review manually | Review manually |

> A user with Viewer role in 10 workspaces but Member role in 1 workspace is classified as **Developer**.

---

## Cost Analysis

The `PBI_ExecutiveSummary.txt` file compares:

- **Current state**: P capacity cost + PRO licenses + PPU licenses
- **Future state**: F capacity cost + PRO licenses (viewers downgraded to Free)
- **Savings**: PPU → PRO conversions + PRO viewer → Free conversions
- **Net monthly delta**: positive value = net savings after migration

---

## Governance Insights

Beyond the cost analysis, the script surfaces:

- **Orphaned workspaces** — active workspaces with no admin assigned
- **Empty workspaces** — workspaces with no reports, datasets, or dataflows
- **Users without workspace** — M365 licensed users not assigned to any workspace (potential license waste)

These are indicators of ungoverned organic growth common in tenants where Premium capacity was adopted after PRO licenses were already distributed broadly.

---

## Requirements Summary

| Requirement | Details |
|---|---|
| PowerShell | 7.x (5.1 supported with limitations) |
| Module | `MicrosoftPowerBIMgmt` (auto-installed if missing) |
| Role | Power BI Administrator |
| Azure CLI | Required for M365 user gap analysis |
| Permissions | Power BI Admin API + `User.Read.All` via Graph |

---

## Author

**Steven Uba** — Sr. Azure Solution Engineer, Data & Analytics  
Microsoft LATAM  

---

## References

- [Power BI Admin REST API](https://learn.microsoft.com/en-us/rest/api/power-bi/admin)
- [Microsoft Fabric licensing](https://learn.microsoft.com/en-us/fabric/enterprise/licenses)
- [Migrate from Power BI Premium to Fabric](https://learn.microsoft.com/en-us/fabric/enterprise/migrate-azure-capacity)
- [MicrosoftPowerBIMgmt module](https://learn.microsoft.com/en-us/powershell/power-bi/overview)

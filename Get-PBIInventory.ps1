#Requires -Version 5.1
<#
.SYNOPSIS
    Power BI Tenant Inventory Script — Viewers vs Developers Analysis
    Power BI Premium P to Fabric F Migration Pre-Assessment

.DESCRIPTION
    Connects to the Power BI REST API and Microsoft Graph to export:
      - All active shared workspaces with capacity, owner, and content counts
      - All users per workspace with role and classification
      - PPU license detection via workspace licenseType
      - M365 users with PBI license NOT assigned to any workspace (governance gap)
      - Cost analysis comparing P1 vs F64 with license optimization savings

    OUTPUT FILES (in same folder as script):
      PBI_Workspaces.csv          — One row per workspace
      PBI_WorkspaceUsers.csv      — One row per user per workspace
      PBI_UserSummary.csv         — One row per unique user (role + license recommendation)
      PBI_UsersWithoutWorkspace.csv — M365 users with PBI license but no workspace membership
      PBI_CapacitySummary.csv     — Workspace + capacity breakdown
      PBI_ExecutiveSummary.txt    — Cost analysis for migration decision

.REQUIREMENTS
    - MicrosoftPowerBIMgmt module  (Install-Module MicrosoftPowerBIMgmt)
    - Power BI Administrator role in the tenant
    - PowerShell 7+ recommended (5.1 supported)

.NOTES
    Author  : Steven Uba — Microsoft STU LATAM
    Purpose : Pre-migration inventory for Power BI Premium P to Fabric F capacity migration
    Date    : March 2026
    API Ref : https://learn.microsoft.com/en-us/rest/api/power-bi/admin
#>

# ============================================================
# SCRIPT SETTINGS (do not edit)
# ============================================================
$AuthMode     = "Interactive"
$ClientId     = ""
$ClientSecret = ""
$ScriptRoot   = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$OutputFolder = Join-Path $ScriptRoot "output"
if (-not (Test-Path $OutputFolder)) { New-Item -ItemType Directory -Path $OutputFolder | Out-Null }
$BatchSize    = 100
$DelayMs      = 200

# ============================================================
# INTERACTIVE SETUP — script will prompt for these at runtime
# ============================================================

function Read-Config {
    Write-Host ""
    Write-Host "================================================" -ForegroundColor Cyan
    Write-Host "  POWER BI TENANT INVENTORY — SETUP" -ForegroundColor Cyan
    Write-Host "  Power BI Premium P to Fabric F Migration" -ForegroundColor Cyan
    Write-Host "================================================" -ForegroundColor Cyan
    Write-Host ""

    # Tenant ID
    do {
        $tid = Read-Host "  Tenant ID (Azure Portal > Azure AD > Overview)"
        $tid = $tid.Trim()
        if (-not $tid) { Write-Host "  WARNING: Tenant ID is required." -ForegroundColor Yellow }
    } while (-not $tid)

    Write-Host ""
    Write-Host "  Monthly contract prices (USD) — press Enter to use the default value:" -ForegroundColor Gray

    # Pricing inputs with defaults
    $p1Input = Read-Host "  P1 capacity price/month      [default: 3863.63]"
    $p1 = if ($p1Input.Trim()) { [double]$p1Input.Trim() } else { 3863.63 }

    $f64Input = Read-Host "  F64 capacity price/month     [default: 5000.00]"
    $f64 = if ($f64Input.Trim()) { [double]$f64Input.Trim() } else { 5000.00 }

    $proInput = Read-Host "  PRO license price/user/month [default: 10.00]"
    $pro = if ($proInput.Trim()) { [double]$proInput.Trim() } else { 10.00 }

    $ppuInput = Read-Host "  PPU license price/user/month [default: 20.00]"
    $ppu = if ($ppuInput.Trim()) { [double]$ppuInput.Trim() } else { 20.00 }

    $capInput = Read-Host "  Number of active P1 capacities   [default: 2]"
    $cap = if ($capInput.Trim()) { [int]$capInput.Trim() } else { 2 }

    Write-Host ""
    Write-Host "  Configuration summary:" -ForegroundColor Green
    Write-Host "    Tenant ID        : $tid"
    Write-Host "    P1/month         : `$$p1"
    Write-Host "    F64/month        : `$$f64"
    Write-Host "    PRO/user/month   : `$$pro"
    Write-Host "    PPU/user/month   : `$$ppu"
    Write-Host "    P1 Capacities    : $cap"
    Write-Host ""

    return @{
        TenantId            = $tid
        Price_P1_PerMonth   = $p1
        Price_F64_PerMonth  = $f64
        Price_PRO_PerUser   = $pro
        Price_PPU_PerUser   = $ppu
        NumberOfCapacities  = $cap
    }
}

# ============================================================
# FUNCTIONS
# ============================================================

function Connect-PBIService {
    param([string]$TenantId)
    Write-Host "[AUTH] Connecting to Power BI Service..." -ForegroundColor Cyan
    $WarningPreference = "SilentlyContinue"
    $ConnectParams = @{}
    if ($TenantId) { $ConnectParams["Tenant"] = $TenantId }
    Connect-PowerBIServiceAccount @ConnectParams
    $WarningPreference = "Continue"
    Write-Host "[AUTH] Connected successfully.`n" -ForegroundColor Green
}

function Invoke-PBIAdminAPI {
    param([string]$Endpoint, [hashtable]$QueryParams = @{})
    $BaseUrl  = "https://api.powerbi.com/v1.0/myorg/admin/$Endpoint"
    $Results  = @()
    $Skip     = 0
    $MaxRetry = 5   # max retries on 429 throttle

    do {
        $QueryParams['$top']  = $BatchSize
        $QueryParams['$skip'] = $Skip
        $QS  = ($QueryParams.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join "&"
        $Url = "$BaseUrl`?$QS"

        $Attempt = 0
        $Success = $false
        while (-not $Success -and $Attempt -lt $MaxRetry) {
            try {
                $Response = Invoke-PowerBIRestMethod -Url $Url -Method Get | ConvertFrom-Json
                $Success  = $true
            } catch {
                $ErrMsg = $_.ToString()
                if ($ErrMsg -like "*429*") {
                    $Attempt++
                    $Wait = [math]::Pow(2, $Attempt) * 1000  # exponential backoff: 2s, 4s, 8s, 16s, 32s
                    Write-Host "      [429 Throttle] Waiting $([int]($Wait/1000))s before retry $Attempt/$MaxRetry..." -ForegroundColor Yellow
                    Start-Sleep -Milliseconds $Wait
                } else {
                    Write-Warning "API call failed for $Url : $_"
                    break
                }
            }
        }

        if (-not $Success) { break }

        $Items = if ($Response.PSObject.Properties['value']) { $Response.value } else { $Response }
        if (-not $Items -or $Items.Count -eq 0) { break }
        $Results += $Items
        $Skip    += $BatchSize
        Start-Sleep -Milliseconds $DelayMs

    } while ($Items.Count -eq $BatchSize)
    return $Results
}

function Get-CapacityMap {
    Write-Host "[1/5] Fetching capacity details..." -ForegroundColor Yellow
    try {
        $Response   = Invoke-PowerBIRestMethod -Url "https://api.powerbi.com/v1.0/myorg/admin/capacities" -Method Get | ConvertFrom-Json
        $Capacities = if ($Response.PSObject.Properties['value']) { $Response.value } else { @($Response) }
    } catch {
        Write-Warning "Could not fetch capacities: $_"
        $Capacities = @()
    }
    $Map = @{}
    foreach ($Cap in $Capacities) { $Map[$Cap.id] = $Cap.displayName }
    Write-Host "      Found $($Capacities.Count) capacities." -ForegroundColor Green
    return $Map
}

function Get-AllWorkspaces {
    Write-Host "[2/5] Fetching all workspaces (Admin API)..." -ForegroundColor Yellow
    $All = Invoke-PBIAdminAPI -Endpoint "groups" -QueryParams @{
        '$expand' = 'users,reports,datasets,dataflows'
    }
    Write-Host "      Raw workspaces from API : $($All.Count)" -ForegroundColor DarkGray
    # Only active shared workspaces — exclude PersonalGroup (My Workspace) and deleted
    $Filtered = @($All | Where-Object { $_.state -eq "Active" -and $_.type -eq "Workspace" })
    Write-Host "      Active shared workspaces: $($Filtered.Count)" -ForegroundColor Green
    return $Filtered
}

function Get-GraphToken {
    param([string]$TenantId)
    # Use Azure CLI to get a Graph-scoped token — avoids MSAL threading issues in PowerShell
    # Requires: az CLI installed and logged in (az login)
    Write-Host "      Requesting Graph token via Azure CLI..." -ForegroundColor DarkGray
    try {
        # Check az CLI is available
        $AzPath = Get-Command az -ErrorAction SilentlyContinue
        if (-not $AzPath) {
            Write-Warning "Azure CLI (az) not found. Install from https://aka.ms/installazurecliwindows and run 'az login' before retrying."
            return $null
        }

        # Check if already logged in to the correct tenant
        $Account = (az account show 2>$null | ConvertFrom-Json)
        if (-not $Account -or $Account.tenantId -ne $TenantId) {
            Write-Host "      Azure CLI not logged in to tenant $TenantId. Running az login..." -ForegroundColor Yellow
            az login --tenant $TenantId --allow-no-subscriptions | Out-Null
        }

        $AccessToken = (az account get-access-token --resource "https://graph.microsoft.com" | ConvertFrom-Json).accessToken
        if (-not $AccessToken) {
            Write-Warning "az account get-access-token returned empty token."
            return $null
        }
        return "Bearer $AccessToken"
    } catch {
        Write-Warning "Could not acquire Graph token via az CLI: $_"
        return $null
    }
}

function Get-M365PBIUsers {
    param([string]$TenantId)
    Write-Host "      Fetching M365 users via Graph API..." -ForegroundColor DarkGray
    $PBIUsers = @{}
    try {
        $Token = Get-GraphToken -TenantId $TenantId
        if (-not $Token) {
            Write-Warning "Graph token unavailable — skipping M365 user gap analysis. Install az CLI and run az login to enable this feature."
            return $PBIUsers
        }

        $Headers  = @{ Authorization = $Token; "Content-Type" = "application/json" }
        $Url      = "https://graph.microsoft.com/v1.0/users?`$select=id,displayName,userPrincipalName,assignedLicenses&`$top=999"
        $AllUsers = @()

        do {
            $Response  = Invoke-RestMethod -Uri $Url -Headers $Headers -Method Get -ErrorAction Stop
            $AllUsers += $Response.value
            $Url       = $Response.'@odata.nextLink'
        } while ($Url)

        # Power BI specific SKU IDs
        # These are the well-known GUIDs for PBI licenses across M365 plans
        $PBISkuIds = @(
            "f8a1db68-be16-40ed-86d5-cb42ce701560",  # Power BI Pro
            "b8a9ee8d-8a95-4f7c-82c8-6b43f5b6e67c",  # Power BI Premium Per User
            "de376a03-6e0f-4d4c-b4cf-9b9a345b8a06",  # Power BI Premium Per User Add-On
            "a403ebcc-fae0-4ca2-8c8c-7a907fd6c235",  # Power BI (free) — Fabric Free
            "d05e6a75-3461-4c0f-9da8-31a9aac51b3d"   # Power BI Pro (GCC)
        )

        foreach ($U in $AllUsers) {
            if (-not $U.userPrincipalName -or $U.userPrincipalName -notlike "*@*") { continue }
            if ($U.userPrincipalName -like "*#EXT#*") { continue }

            # Check if user has any Power BI specific license
            $UserSkuIds = @($U.assignedLicenses | ForEach-Object { $_.skuId })
            $HasPROLicense  = $UserSkuIds -contains "f8a1db68-be16-40ed-86d5-cb42ce701560"
            $HasPPULicense  = ($UserSkuIds -contains "b8a9ee8d-8a95-4f7c-82c8-6b43f5b6e67c") -or
                              ($UserSkuIds -contains "de376a03-6e0f-4d4c-b4cf-9b9a345b8a06")
            $HasFreeLicense = $UserSkuIds -contains "a403ebcc-fae0-4ca2-8c8c-7a907fd6c235"
            $HasAnyPBILicense = $HasPROLicense -or $HasPPULicense -or $HasFreeLicense

            # Only include users with a Power BI related license
            if (-not $HasAnyPBILicense) { continue }

            $LicenseType = if ($HasPPULicense) { "PPU" } elseif ($HasPROLicense) { "PRO" } else { "Free" }

            $PBIUsers[$U.userPrincipalName.ToLower()] = [PSCustomObject]@{
                UserUpn      = $U.userPrincipalName
                DisplayName  = $U.displayName
                HasLicense   = $true
                LicenseType  = $LicenseType
                HasPRO       = $HasPROLicense
                HasPPU       = $HasPPULicense
                HasFree      = $HasFreeLicense
            }
        }
        Write-Host "      M365 users fetched: $($PBIUsers.Count)" -ForegroundColor DarkGray
    } catch {
        Write-Warning "Could not fetch M365 users via Graph: $_"
    }
    return $PBIUsers
}

function Export-WorkspaceInventory {
    param($Workspaces, $CapacityMap)
    Write-Host "[3/5] Processing workspace inventory..." -ForegroundColor Yellow

    $WsRows      = @()
    $UserRows    = @()
    $UserAgg     = @{}
    $WorkspaceUserUpns = @{}  # track all UPNs seen in workspaces

    $Counter = 0
    foreach ($Ws in $Workspaces) {
        $Counter++
        if ($Counter % 500 -eq 0) {
            Write-Host "      Processing $Counter / $($Workspaces.Count)..." -ForegroundColor DarkGray
        }

        $CapName = if ($Ws.capacityId) {
            $Resolved = $CapacityMap[$Ws.capacityId]
            if ($Resolved) { $Resolved } else { "Unknown ($($Ws.capacityId))" }
        } else { "(No Capacity - PRO/Free)" }

        # PPU workspace = licenseType property on the group object equals PremiumPerUser
        # ALL users in a PPU workspace must have PPU license assigned in M365 by definition
        $IsPPUWorkspace = ($Ws.licenseType -eq "PremiumPerUser")

        $ReportCount   = if ($Ws.reports)   { @($Ws.reports).Count   } else { 0 }
        $DatasetCount  = if ($Ws.datasets)  { @($Ws.datasets).Count  } else { 0 }
        $DataflowCount = if ($Ws.dataflows) { @($Ws.dataflows).Count } else { 0 }

        $WsAdmins  = @($Ws.users | Where-Object { $_.groupUserAccessRight -eq "Admin" })
        $OwnerUpns = ($WsAdmins | ForEach-Object {
            if ($_.emailAddress) { $_.emailAddress }
            elseif ($_.identifier) { $_.identifier }
            else { $_.displayName }
        }) -join "; "

        $WsRows += [PSCustomObject]@{
            WorkspaceId      = $Ws.id
            WorkspaceName    = $Ws.name
            State            = $Ws.state
            Type             = $Ws.type
            LicenseType      = $Ws.licenseType
            CapacityId       = $Ws.capacityId
            CapacityName     = $CapName
            IsPPUWorkspace   = $IsPPUWorkspace
            IsOrphaned       = ($WsAdmins.Count -eq 0)
            AdminCount       = $WsAdmins.Count
            AdminUpns        = $OwnerUpns
            TotalUsers       = if ($Ws.users) { @($Ws.users).Count } else { 0 }
            ReportCount      = $ReportCount
            DatasetCount     = $DatasetCount
            DataflowCount    = $DataflowCount
            IsEmpty          = ($ReportCount + $DatasetCount + $DataflowCount -eq 0)
        }

        if ($Ws.users) {
            foreach ($User in $Ws.users) {
                # Skip non-human principals
                if ($User.principalType -and $User.principalType -ne "User") { continue }
                $RawUpn = if ($User.emailAddress) { $User.emailAddress } elseif ($User.identifier) { $User.identifier } else { $User.displayName }
                if (-not $RawUpn -or $RawUpn -notlike "*@*") { continue }

                $Upn         = $RawUpn.ToLower()
                $Role        = $User.groupUserAccessRight
                $IsPPU       = $IsPPUWorkspace
                $IsDeveloper = $Role -in @("Admin", "Member", "Contributor")
                $IsViewer    = $Role -eq "Viewer"

                $WorkspaceUserUpns[$Upn] = $true

                $UserRows += [PSCustomObject]@{
                    WorkspaceId   = $Ws.id
                    WorkspaceName = $Ws.name
                    CapacityName  = $CapName
                    UserUpn       = $RawUpn
                    DisplayName   = $User.displayName
                    Role          = $Role
                    UserType      = $User.userType
                    LikelyPPU     = $IsPPU
                    IsDeveloper   = $IsDeveloper
                    IsViewerOnly  = $IsViewer
                }

                if (-not $UserAgg.ContainsKey($Upn)) {
                    $UserAgg[$Upn] = [PSCustomObject]@{
                        UserUpn               = $RawUpn
                        DisplayName           = if ($User.displayName) { $User.displayName } else { $RawUpn }
                        UserType              = $User.userType
                        LikelyPPU             = $IsPPU
                        WorkspaceCount        = 0
                        AdminCount            = 0
                        MemberCount           = 0
                        ContributorCount      = 0
                        ViewerCount           = 0
                        HasDeveloperRole      = $false
                        HasViewerOnlyRole     = $false
                        Classification        = ""
                        LicenseRecommendation = ""
                    }
                }
                $Agg = $UserAgg[$Upn]
                $Agg.WorkspaceCount++
                if ($IsPPU -and -not $Agg.LikelyPPU) { $Agg.LikelyPPU = $true }
                switch ($Role) {
                    "Admin"       { $Agg.AdminCount++;       $Agg.HasDeveloperRole = $true }
                    "Member"      { $Agg.MemberCount++;      $Agg.HasDeveloperRole = $true }
                    "Contributor" { $Agg.ContributorCount++; $Agg.HasDeveloperRole = $true }
                    "Viewer"      { $Agg.ViewerCount++ }
                }
            }
        }
    }

    # Classify each unique user
    foreach ($Upn in $UserAgg.Keys) {
        $Agg = $UserAgg[$Upn]
        $Agg.HasViewerOnlyRole = ($Agg.ViewerCount -gt 0 -and -not $Agg.HasDeveloperRole)
        if ($Agg.HasDeveloperRole) {
            $Agg.Classification        = "Developer"
            $Agg.LicenseRecommendation = if ($Agg.LikelyPPU) { "PRO (was PPU — savings on F64)" } else { "PRO (keep)" }
        } elseif ($Agg.HasViewerOnlyRole) {
            $Agg.Classification        = "Viewer Only"
            $Agg.LicenseRecommendation = "Free on F64 (downgrade from PRO/PPU)"
        } else {
            $Agg.Classification        = "Unknown"
            $Agg.LicenseRecommendation = "Review manually"
        }
    }

    Write-Host "      Workspace rows  : $($WsRows.Count)" -ForegroundColor Green
    Write-Host "      User-ws rows    : $($UserRows.Count)" -ForegroundColor Green
    Write-Host "      Unique users    : $($UserAgg.Count)" -ForegroundColor Green

    return @{
        Workspaces         = $WsRows
        UserRows           = $UserRows
        UserAgg            = $UserAgg.Values
        WorkspaceUserUpns  = $WorkspaceUserUpns
    }
}

function Get-UsersWithoutWorkspace {
    param($WorkspaceUserUpns)
    Write-Host "[4/5] Checking M365 users without workspace membership..." -ForegroundColor Yellow

    $M365Users = Get-M365PBIUsers -TenantId $Script:TenantId
    $NoWsRows  = @()

    foreach ($Upn in $M365Users.Keys) {
        if (-not $WorkspaceUserUpns.ContainsKey($Upn)) {
            $U = $M365Users[$Upn]
            $NoWsRows += [PSCustomObject]@{
                UserUpn      = $U.UserUpn
                DisplayName  = $U.DisplayName
                LicenseType  = $U.LicenseType
                HasPRO       = $U.HasPRO
                HasPPU       = $U.HasPPU
                HasFree      = $U.HasFree
                Note         = "Has M365 license but is NOT a member of any Power BI workspace — review for license optimization"
            }
        }
    }

    Write-Host "      M365 licensed users with no workspace: $($NoWsRows.Count)" -ForegroundColor $(if ($NoWsRows.Count -gt 0) { "Yellow" } else { "Green" })
    return $NoWsRows
}

function Export-Summary {
    param($Data, $Config)
    Write-Host "[5/5] Building summary reports..." -ForegroundColor Yellow

    $Workspaces = $Data.Workspaces
    $UserAgg    = @($Data.UserAgg)
    $NoWsCount     = if ($Data.UsersWithoutWorkspace) { @($Data.UsersWithoutWorkspace).Count } else { 0 }
    $NoWsPRO       = if ($Data.UsersWithoutWorkspace) { @($Data.UsersWithoutWorkspace | Where-Object { $_.HasPRO }).Count } else { 0 }
    $NoWsPPU       = if ($Data.UsersWithoutWorkspace) { @($Data.UsersWithoutWorkspace | Where-Object { $_.HasPPU }).Count } else { 0 }
    $NoWsFree      = if ($Data.UsersWithoutWorkspace) { @($Data.UsersWithoutWorkspace | Where-Object { $_.HasFree }).Count } else { 0 }
    $NoWsPROCost   = [math]::Round($NoWsPRO * $pro, 2)
    $NoWsPPUCost   = [math]::Round($NoWsPPU * $ppu, 2)

    $CapSummary = $Workspaces |
        Group-Object CapacityName |
        Select-Object @{N="CapacityName";        E={$_.Name}},
                      @{N="WorkspaceCount";      E={$_.Count}},
                      @{N="PPUWorkspaces";       E={($_.Group | Where-Object { $_.IsPPUWorkspace -eq $true }).Count}},
                      @{N="OrphanedWorkspaces";  E={($_.Group | Where-Object IsOrphaned).Count}},
                      @{N="EmptyWorkspaces";     E={($_.Group | Where-Object IsEmpty).Count}} |
        Sort-Object WorkspaceCount -Descending

    $TotalUnique   = $UserAgg.Count
    $Developers    = @($UserAgg | Where-Object { $_.Classification -eq "Developer" }).Count
    $ViewersOnly   = @($UserAgg | Where-Object { $_.Classification -eq "Viewer Only" }).Count
    $Unknown       = @($UserAgg | Where-Object { $_.Classification -eq "Unknown" }).Count
    $PPUDevelopers = @($UserAgg | Where-Object { $_.Classification -eq "Developer"   -and $_.LikelyPPU }).Count
    $PPUViewers    = @($UserAgg | Where-Object { $_.Classification -eq "Viewer Only" -and $_.LikelyPPU }).Count
    $PPUTotal      = @($UserAgg | Where-Object { $_.LikelyPPU }).Count
    $OrphanedWs    = @($Workspaces | Where-Object IsOrphaned).Count
    $EmptyWs       = @($Workspaces | Where-Object IsEmpty).Count
    $NoCap         = @($Workspaces | Where-Object { $_.CapacityName -eq "(No Capacity - PRO/Free)" }).Count
    $PPUWs         = @($Workspaces | Where-Object { $_.IsPPUWorkspace -eq $true }).Count
    $PremiumWs     = @($Workspaces | Where-Object { $_.CapacityName -ne "(No Capacity - PRO/Free)" -and $_.IsPPUWorkspace -ne $true }).Count

    $p1   = $Config.Price_P1_PerMonth
    $f64  = $Config.Price_F64_PerMonth
    $pro  = $Config.Price_PRO_PerUser
    $ppu  = $Config.Price_PPU_PerUser
    $caps = $Config.NumberOfCapacities

    $CurrentCapCost      = $p1  * $caps
    $CurrentPROCost      = $Developers * $pro
    $CurrentPPUCost      = $PPUTotal   * $ppu
    $CurrentTotal        = $CurrentCapCost + $CurrentPROCost + $CurrentPPUCost
    $FutureCapCost       = $f64 * $caps
    $FuturePROCost       = $Developers * $pro
    $PPUDevSavings       = $PPUDevelopers * ($ppu - $pro)
    $PPUViewerSavings    = $PPUViewers    * $ppu
    $PROReclassified     = $ViewersOnly   * $pro
    $TotalSavings        = $PPUDevSavings + $PPUViewerSavings + $PROReclassified
    $FutureTotal         = $FutureCapCost + $FuturePROCost
    $NetDelta            = $CurrentTotal - $FutureTotal - $TotalSavings

    $Summary = @"
================================================
  POWER BI TENANT INVENTORY — EXECUTIVE SUMMARY
  Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')
================================================

WORKSPACE BREAKDOWN
  Total active workspaces       : $($Workspaces.Count)
  On Premium/Fabric capacity    : $PremiumWs
  On PPU (licenseType=PPU)      : $PPUWs
  On PRO/Free (no capacity)     : $NoCap
  Orphaned (no admin)           : $OrphanedWs
  Empty (no content)            : $EmptyWs

USER CLASSIFICATION  (from workspace roles)
  Total unique users in workspaces : $TotalUnique
  Developers (keep PRO)            : $Developers
    of which on PPU today          : $PPUDevelopers   <- move to PRO on F64
  Viewer-only (Free on F64)        : $ViewersOnly
    of which on PPU today          : $PPUViewers      <- move to Free on F64
  Unclassified (review manually)   : $Unknown
  Total PPU users identified       : $PPUTotal

  GOVERNANCE ALERT — Power BI licensed users NOT in any workspace: $NoWsCount
    PRO licenses (no workspace)  : $NoWsPRO  -> `$$([math]::Round($NoWsPROCost, 2))/mo wasted
    PPU licenses (no workspace)  : $NoWsPPU  -> `$$([math]::Round($NoWsPPUCost, 2))/mo wasted
    Free licenses (no workspace) : $NoWsFree -> `$0/mo (no cost impact)
  These users have a Power BI license but are not members of any shared
  workspace. PRO and PPU licenses assigned to inactive users represent
  direct cost savings opportunity. Review PBI_UsersWithoutWorkspace.csv.

  NOTE: Developer = Admin/Member/Contributor in ANY workspace.
        Viewer Only = exclusively Viewer in ALL workspaces.
        PPU detection based on workspace licenseType = PremiumPerUser.
        Cross-reference with M365 Admin Center to confirm actual license assignments.

COST ANALYSIS — CURRENT STATE (monthly estimates)
  P1 capacity ($caps x `$$p1)       : `$$([math]::Round($CurrentCapCost, 2))
  PRO licenses (~$Developers users) : `$$([math]::Round($CurrentPROCost, 2))
  PPU licenses (~$PPUTotal users)   : `$$([math]::Round($CurrentPPUCost, 2))
  TOTAL CURRENT                     : `$$([math]::Round($CurrentTotal, 2))

COST ANALYSIS — FUTURE STATE on F64 (monthly estimates)
  F64 capacity ($caps x `$$f64)      : `$$([math]::Round($FutureCapCost, 2))
  PRO licenses ($Developers devs)   : `$$([math]::Round($FuturePROCost, 2))
  Viewer licenses (Free on F64)     : `$0.00

SAVINGS FROM LICENSE OPTIMIZATION
  PPU devs -> PRO ($PPUDevelopers users x `$$([math]::Round($ppu-$pro,2))/mo) : `$$([math]::Round($PPUDevSavings, 2))
  PPU viewers -> Free ($PPUViewers users x `$$ppu/mo)                         : `$$([math]::Round($PPUViewerSavings, 2))
  PRO viewers -> Free ($ViewersOnly users x `$$pro/mo)                        : `$$([math]::Round($PROReclassified, 2))
  TOTAL LICENSE SAVINGS/mo                                                    : `$$([math]::Round($TotalSavings, 2))

NET MONTHLY DELTA (positive = net savings vs today)
  `$$([math]::Round($NetDelta, 2))

NEXT STEPS
  1. Review PBI_UsersWithoutWorkspace.csv — validate licenses for users not in any workspace
  2. Cross-reference PBI_UserSummary.csv with M365 Admin to confirm PRO/PPU assignments
  3. Convert viewer-only PRO users to Free on F64
  4. Review orphaned and empty workspaces for cleanup (governance)
  5. Confirm F64, PRO, and PPU unit prices with your License Provider and Microsoft Account Representative
================================================
"@

    return @{ CapSummary = $CapSummary; Summary = $Summary }
}

# ============================================================
# MAIN EXECUTION
# ============================================================

$WarningPreference = "SilentlyContinue"   # suppress MSAL internal warnings

if (-not (Get-Module -ListAvailable -Name MicrosoftPowerBIMgmt)) {
    Write-Host "Installing MicrosoftPowerBIMgmt module..." -ForegroundColor Cyan
    Install-Module MicrosoftPowerBIMgmt -Scope CurrentUser -Force
}
Import-Module MicrosoftPowerBIMgmt -ErrorAction Stop

# Interactive setup — prompts user for Tenant ID and prices
$Config = Read-Config
$Script:TenantId = $Config.TenantId   # store in script scope for Graph token

Connect-PBIService -TenantId $Config.TenantId

$CapacityMap = Get-CapacityMap
$Workspaces  = Get-AllWorkspaces
$Data        = Export-WorkspaceInventory -Workspaces $Workspaces -CapacityMap $CapacityMap
$NoWsUsers   = Get-UsersWithoutWorkspace -WorkspaceUserUpns $Data.WorkspaceUserUpns
$Data["UsersWithoutWorkspace"] = $NoWsUsers
$Summary     = Export-Summary -Data $Data -Config $Config

# Export files
$WsPath    = Join-Path $OutputFolder "PBI_Workspaces.csv"
$UserPath  = Join-Path $OutputFolder "PBI_WorkspaceUsers.csv"
$AggPath   = Join-Path $OutputFolder "PBI_UserSummary.csv"
$NoWsPath  = Join-Path $OutputFolder "PBI_UsersWithoutWorkspace.csv"
$CapPath   = Join-Path $OutputFolder "PBI_CapacitySummary.csv"
$SumPath   = Join-Path $OutputFolder "PBI_ExecutiveSummary.txt"

$Data.Workspaces              | Export-Csv -Path $WsPath   -NoTypeInformation -Encoding UTF8
$Data.UserRows                | Export-Csv -Path $UserPath -NoTypeInformation -Encoding UTF8
$Data.UserAgg                 | Export-Csv -Path $AggPath  -NoTypeInformation -Encoding UTF8
$NoWsUsers                    | Export-Csv -Path $NoWsPath -NoTypeInformation -Encoding UTF8
$Summary.CapSummary           | Export-Csv -Path $CapPath  -NoTypeInformation -Encoding UTF8
$Summary.Summary              | Out-File   -FilePath $SumPath -Encoding UTF8

Write-Host "`n================================================" -ForegroundColor Cyan
Write-Host "  EXPORT COMPLETE" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  PBI_Workspaces.csv               -> $WsPath"
Write-Host "  PBI_WorkspaceUsers.csv           -> $UserPath"
Write-Host "  PBI_UserSummary.csv              -> $AggPath"
Write-Host "  PBI_UsersWithoutWorkspace.csv    -> $NoWsPath"
Write-Host "  PBI_CapacitySummary.csv          -> $CapPath"
Write-Host "  PBI_ExecutiveSummary.txt         -> $SumPath"
Write-Host ""
Write-Host $Summary.Summary -ForegroundColor White

Disconnect-PowerBIServiceAccount

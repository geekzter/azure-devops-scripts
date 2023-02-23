function Get-AccessToken () {
    # Log in with Azure CLI (if not logged in yet)
    Login-Az -DisplayMessages
    az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 `
                                --query "accessToken" `
                                --output tsv `
                                | Set-Variable aadToken
    if (!$aadToken) {
        Write-Warning "Could not obtain AAD token, exiting"
        exit 1
    }
    Write-Debug "AAD Token length: $($aadToken.Length)"

    return $aadToken
}

function Get-AgentPackageUrl (
    [parameter(Mandatory=$false)][switch]
    $ExcludeNode6,

    [parameter(Mandatory=$false)][string]
    [ValidateSet("Previous", "Current", "Prerelease")]
    $VersionPreference="Current",

    [parameter(Mandatory=$false)]
    [ValidateSet(2, 3)]
    [int]
    $MajorVersion=2
) {

    (Invoke-RestMethod -Uri https://api.github.com/repos/microsoft/azure-pipelines-agent/releases) `
                       | Where-Object {!$_.draft} `
                       | Where-Object {$_.name -match "^v${MajorVersion}"} `
                       | Sort-Object -Property @{Expression = "created_at"; Descending = $true} `
                       | Set-Variable releases
    switch ($VersionPreference) {
        "Previous" {
            $releases | Where-Object {!$_.prerelease} `
                    | Select-Object -Skip 1 -First 1 `
                    | Set-Variable release
            break
        }
        default { # Latest
            $releases | Where-Object {!$_.prerelease} `
                    | Select-Object -Skip 0 -First 1 `
                    | Set-Variable release
            break
        }
        "Prerelease" {
            $releases | Select-Object -Skip 0 -First 1 `
                    | Set-Variable release
            break
        }
    }

    if (!$release) {
        Write-Warning "No agent release found for v${MajorVersion}, '${VersionPreference}' VersionPreference"
        exit
    }
    $release | Format-List | Out-String | Write-Debug
    $release.name -replace "^v","" | Set-Variable agentVersion

    if ($IsWindows) {
        $os = "Windows"
        $osString = [Environment]::Is64BitProcess ? "win-x64" : "win-x86"
        $extension = "zip"
    }
    if ($IsMacOS) {
        $os = "macOS"
        $osString = (($PSVersionTable.OS -imatch "ARM64") -and $MajorVersion -ge 3) ? "osx-arm64" : "osx-x64"
        $extension = "tar.gz"
    }
    if ($IsLinux) {
        $os = "Linux"
        $osString = "linux-"
        $arch = $(uname -m)
        if ($arch -in @("arm", "arm64")) {
            $osString += $arch
        } elseif ($arch -eq "x86_64") {
            $osString += "x64"
        } else {
            Write-Warning "Unknown architecture '${arch}', defaulting to x64"
            $osString += "x64"
        }
        $extension = "tar.gz"
    }

    $packagePrefix = $ExcludeNode6 ? "pipelines" : "vsts"
    "{0}-agent-{1}-{2}.{3}" -f $packagePrefix, $osString, $agentVersion, $extension | Set-Variable agentPackage
    "https://vstsagentpackage.azureedge.net/agent/{0}/{1}" -f $agentVersion, $agentPackage | Set-Variable packageUrl

    # try {
        Write-Verbose "Validating whether package exists at '${packageUrl}'..."
        Invoke-WebRequest -method HEAD $packageUrl | Set-Variable packageResponse
        $packageResponse | Format-List | Out-String | Write-Debug
        "Agent package for '{0}' ({1},{2}):`n{3}" -f $PSVersionTable.OS, `
                                                     $VersionPreference, `
                                                     ($ExcludeNode6 ? "ExcludeNode6" : "IncludeNode6"), `
                                                     $packageUrl `
                                                   | Write-Verbose
        return $packageUrl
    # } catch {
    #     Write-Warning "Could not access agent package for ${os} ($($VersionPreference.ToLower())): ${packageUrl}`n$($_.Exception.Message)"
    #     exit 1
    # }

    return $null
}

function Login-Az (
    [parameter(Mandatory=$false)][switch]$DisplayMessages=$false
) {
    # Are we logged in? If so, is it the right tenant?
    $azureAccount = $null
    az account show 2>$null | ConvertFrom-Json | Set-Variable azureAccount
    if ($azureAccount -and "${env:ARM_TENANT_ID}" -and ($azureAccount.tenantId -ine $env:ARM_TENANT_ID)) {
        Write-Warning "Logged into tenant $($azureAccount.tenant_id) instead of $env:ARM_TENANT_ID (`$env:ARM_TENANT_ID)"
        $azureAccount = $null
    }
    if (-not $azureAccount) {
        if ($IsLinux) {
            $azLoginSwitches = "--use-device-code"
        }
        if ($env:ARM_TENANT_ID) {
            az login -t $env:ARM_TENANT_ID -o none $($azLoginSwitches)
        } else {
            az login -o none $($azLoginSwitches)
        }
    }

    if ($DisplayMessages) {
        if ($env:ARM_SUBSCRIPTION_ID -or ($(az account list --query "length([])" -o tsv) -eq 1)) {
            Write-Host "Using subscription '$(az account show --query "name" -o tsv)'"
        } else {
            if ($env:TF_IN_AUTOMATION -ine "true") {
                # Active subscription may not be the desired one, prompt the user to select one
                $subscriptions = (az account list --query "sort_by([].{id:id, name:name},&name)" -o json | ConvertFrom-Json) 
                $index = 0
                $subscriptions | Format-Table -Property @{name="index";expression={$script:index;$script:index+=1}}, id, name
                Write-Host "Set `$env:ARM_SUBSCRIPTION_ID to the id of the subscription you want to use to prevent this prompt" -NoNewline

                do {
                    Write-Host "`nEnter the index # of the subscription you want Terraform to use: " -ForegroundColor Cyan -NoNewline
                    $occurrence = Read-Host
                } while (($occurrence -notmatch "^\d+$") -or ($occurrence -lt 1) -or ($occurrence -gt $subscriptions.Length))
                $env:ARM_SUBSCRIPTION_ID = $subscriptions[$occurrence-1].id
            
                Write-Host "Using subscription '$($subscriptions[$occurrence-1].name)'" -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            } else {
                Write-Host "Using subscription '$(az account show --query "name" -o tsv)', set `$env:ARM_SUBSCRIPTION_ID if you want to use another one"
            }
        }
    }

    if ($env:ARM_SUBSCRIPTION_ID) {
        az account set -s $env:ARM_SUBSCRIPTION_ID -o none
    }

    # Populate Terraform azurerm variables where possible
    if ($userType -ine "user") {
        # Pass on pipeline service principal credentials to Terraform
        $env:ARM_CLIENT_ID       ??= $env:servicePrincipalId
        $env:ARM_CLIENT_SECRET   ??= $env:servicePrincipalKey
        $env:ARM_TENANT_ID       ??= $env:tenantId
        # Get from Azure CLI context
        $env:ARM_TENANT_ID       ??= $(az account show --query tenantId -o tsv)
        $env:ARM_SUBSCRIPTION_ID ??= $(az account show --query id -o tsv)
    }
    # Variables for Terraform azurerm Storage backend
    if (!$env:ARM_ACCESS_KEY -and !$env:ARM_SAS_TOKEN) {
        if ($env:TF_VAR_backend_storage_account -and $env:TF_VAR_backend_storage_container) {
            $env:ARM_SAS_TOKEN=$(az storage container generate-sas -n $env:TF_VAR_backend_storage_container --as-user --auth-mode login --account-name $env:TF_VAR_backend_storage_account --permissions acdlrw --expiry (Get-Date).AddDays(7).ToString("yyyy-MM-dd") -o tsv)
        }
    }
}
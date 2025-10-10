#set bypass policy for one session
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process

function Confirm-Install($moduleName) {
    $response = Read-Host "Module '$moduleName' appears to be already installed. Do you want to install it anyway? (yes/no)"
    return $response -eq "yes"
}

function Install-IIS {
    Write-Host "Checking IIS installation..."

    if ([Environment]::Is64BitProcess -eq $false) {
        Write-Warning "You are using the 32-bit version of PowerShell. Please start the 64-bit version to continue."
        exit 1
    }

    $iisInstalled = Get-WindowsFeature -Name Web-Server | Where-Object { $_.Installed }
    if ($iisInstalled) {
        if (-not (Confirm-Install "IIS")) {
            Write-Host "Skipping IIS installation."
            return
        }
    }

    try {
        Install-WindowsFeature -Name Web-Server -IncludeManagementTools
        Enable-WindowsOptionalFeature -Online -FeatureName IIS-ISAPIExtensions -All
        Enable-WindowsOptionalFeature -Online -FeatureName IIS-ISAPIFilter -All
    } catch {
        Write-Warning "IIS installation failed: $_"
        exit 1
    }
}

function RemoveAndAddWebConfigurationProperty {
    param (
        [string] $pspath,
        [string] $filter,
        [string] $name,
        [string] $value_name,
        [string] $value_value = '====',
        [string] $value_replace = ''
    )

    $CurrentWarningPreference = $WarningPreference
    $WarningPreference = 'SilentlyContinue'
    Remove-WebConfigurationProperty -pspath "$pspath" -filter "$filter" -name "$name" -AtElement @{name="$value_name"}
    $WarningPreference = $CurrentWarningPreference

    if ($value_value -eq '====') {
        Add-WebConfigurationProperty -pspath "$pspath" -filter "$filter" -name "$name" -value @{name="$value_name"}
    } else {
        Add-WebConfigurationProperty -pspath "$pspath" -filter "$filter" -name "$name" -value @{name="$value_name";value="$value_value";replace="$value_replace"}
    }
}

function installUrlRewriteRules {
    param (
        [string] $site,
        [string] $filterName,
        [string] $ivyEngineUrl,
        [string] $filterRoot
    )

    Write-Host "Installing URL rewrite rule for $ivyEngineUrl"

    $existingRule = Get-WebConfigurationProperty -pspath $site -filter "system.webServer/rewrite/rules/rule[@name='$filterName']" -name "name" -ErrorAction SilentlyContinue
    if ($existingRule) {
        Write-Host "Rewrite rule '$filterName' already exists. Skipping creation."
        return
    }

    Add-WebConfigurationProperty -pspath $site -filter "system.webServer/rewrite/rules" -name "." -value @{name=$filterName;patternSyntax='Regular Expressions';stopProcessing='False'}
    Set-WebConfigurationProperty -pspath $site -filter "$filterRoot/match" -name "url" -value ".*"
    Set-WebConfigurationProperty -pspath $site -filter "$filterRoot/conditions" -name "logicalGrouping" -value "MatchAny"
    Set-WebConfigurationProperty -pspath $site -filter "$filterRoot/action" -name "type" -value "Rewrite"
    Set-WebConfigurationProperty -pspath $site -filter "$filterRoot/action" -name "url" -value "$ivyEngineUrl/{R:0}"
}

function allowWebSocketCommunication {
    param (
        [string] $filterRoot
    )

    Write-Host "Enabling WebSocket communication via IIS"
    $globalPath = "MACHINE/WEBROOT/APPHOST"
    RemoveAndAddWebConfigurationProperty -pspath $globalPath -filter "system.webServer/rewrite/allowedServerVariables" -name "." -value_name 'HTTP_SEC_WEBSOCKET_EXTENSIONS'
    RemoveAndAddWebConfigurationProperty -pspath $globalPath -filter "$filterRoot/servervariables" -name "." -value_name 'HTTP_SEC_WEBSOCKET_EXTENSIONS' -value_value '' -value_replace 'True'
}
function Install-ISAPIRewriteWithLogging {
    param (
        [string] $modulePath,
        [string] $filedate = (Get-Date -Format "yyyyMMdd-HHmmss")
    )

    $file = $modulePath
    $infoFile = "${file}.${filedate}.log"
    Write-Host "Installing ISAPI Rewrite (Log: $infoFile)"
    Start-Process "msiexec.exe" -ArgumentList "/i `"$file`" /quiet /l* `"$infoFile`" AcceptEULA=Yes" -Wait

    if (Test-Path -Path $infoFile -PathType Leaf) {
        $configFile = 'C:\Program Files\Helicon\ISAPI_Rewrite3\httpd.conf'
        if (Test-Path -Path $configFile -PathType Leaf) {
            Write-Host "Configuring ISAPI Rewrite header"
            Set-Content -Path $configFile -Value 'RewriteHeader X-Forwarded-User: .* %{LOGON_USER}'
            return $true
        }
    }

    Write-Warning "ISAPI Rewrite could not be successfully installed or configured."
    return $false
}

# === STEP 0: ONLINE/OFFLINE MODE ===
$installMode = Read-Host "Are you online or offline? (online/offline)"
if ($installMode -ne "online" -and $installMode -ne "offline") {
    Write-Warning "Invalid installation mode: '$installMode'. Please enter 'online' or 'offline'."
    exit 1
}

$offlinePath = ""
$expectedFiles = @(
    "ISAPI_Rewrite3_0112_Lite_x64.msi",
    "rewrite_amd64_en-US.msi",
    "requestRouter_amd64.msi"
)

if ($installMode -eq "offline") {
    Write-Host "You selected offline mode."
    Write-Host "The following files are required:"
    foreach ($file in $expectedFiles) {
        Write-Host "- $file"
    }

    $defaultOfflinePath = "C:\Users\Administrator\Downloads"
    $offlinePath = Read-Host "Path to installation files (Default: $defaultOfflinePath)"
    if ([string]::IsNullOrWhiteSpace($offlinePath)) {
        $offlinePath = $defaultOfflinePath
    }

    if (-not (Test-Path $offlinePath)) {
        Write-Warning "The specified path does not exist: $offlinePath. Script will exit."
        exit 1
    }
}

# === STEP 1: INSTALL IIS ===
Install-IIS

# === STEP 2: WEBSITE AND ENGINE URL ===
$defaultSite = "Default Web Site"
$path = "MACHINE/WEBROOT/APPHOST"
$sitename = Read-Host "Name of the IIS website for Ivy (Default: $defaultSite)"
if ([string]::IsNullOrWhiteSpace($sitename)) { $sitename = $defaultSite }
$site = "$path/$sitename"
$physicalPath = "$env:SystemDrive\inetpub\wwwroot\$sitename"

# Ensure IIS site exists
$siteExists = Get-Website | Where-Object { $_.Name -eq $sitename }
if (-not $siteExists) {
    Write-Host "IIS site '$sitename' does not exist. Creating it now..."
    New-Item -ItemType Directory -Path $physicalPath -Force | Out-Null
    "<configuration></configuration>" | Out-File -Encoding UTF8 -FilePath (Join-Path $physicalPath "web.config")
    New-Website -Name $sitename -Port 80 -PhysicalPath $physicalPath -Force
}

$ivyEngineUrl = Read-Host "Ivy Engine URL (Default: http://localhost:8080)"
if ([string]::IsNullOrWhiteSpace($ivyEngineUrl)) { $ivyEngineUrl = "http://localhost:8080" }
$filterName = "Ivy Rewrite"
$filterRoot = "system.webServer/rewrite/rules/rule[@name='Ivy Rewrite']"

# === STEP 3: MODULE DEFINITIONS ===
$modules = @(
    @{ Name = "ISAPI_Rewrite"; Url = "https://www.helicontech.com/download/isapi_rewrite/ISAPI_Rewrite3_0112_Lite_x64.msi"; File = "ISAPI_Rewrite3_0112_Lite_x64.msi"; CheckPath = "C:\Program Files\Helicon\ISAPI_Rewrite3\ISAPI_Rewrite.dll" },
    @{ Name = "URL_Rewrite"; Url = "https://download.microsoft.com/download/1/2/8/128E2E22-C1B9-44A4-BE2A-5859ED1D4592/rewrite_amd64_en-US.msi"; File = "rewrite_amd64_en-US.msi"; CheckPath = "$env:SystemRoot\System32\inetsrv\rewrite.dll" },
    @{ Name = "ARR"; Url = "https://download.microsoft.com/download/e/9/8/e9849d6a-020e-47e4-9fd0-a023e99b54eb/requestRouter_amd64.msi"; File = "requestRouter_amd64.msi"; CheckPath = "$env:SystemRoot\System32\inetsrv\requestRouter.dll" }
)

# === STEP 4: MODULE INSTALLATION ===
$downloadPath = "$env:TEMP\iis_modules"
if ($installMode -eq "online") {
    New-Item -ItemType Directory -Path $downloadPath -Force | Out-Null
}

foreach ($mod in $modules) {
    $fileName = $mod.File
    $filePath = switch ($installMode) {
        "online"  { Join-Path $downloadPath $fileName }
        "offline" { Join-Path $offlinePath $fileName }
    }

    $alreadyInstalled = Test-Path $mod.CheckPath
    if ($alreadyInstalled) {
        if (-not (Confirm-Install $mod.Name)) {
            Write-Host "Skipping installation of '$($mod.Name)'."
            continue
        }
    }

    if ($mod.Name -eq "ISAPI_Rewrite") {
        if ($installMode -eq "online") {
            Write-Host "Downloading '$($mod.Name)' from:"
            Write-Host "  $($mod.Url)"
            Write-Host "Saving to:"
            Write-Host "  $filePath"
            Write-Host ""

            try {
                Start-BitsTransfer -Source $mod.Url -Destination $filePath
                Write-Host "Download completed: $filePath"
            } catch {
                Write-Warning "BITS download failed for '$($mod.Name)': $_"
                continue
            }
        }

        Install-ISAPIRewriteWithLogging -modulePath $filePath
        continue
    }

    if ($installMode -eq "online") {
        Write-Host "Downloading '$($mod.Name)' from:"
        Write-Host "  $($mod.Url)"
        Write-Host "Saving to:"
        Write-Host "  $filePath"
        Write-Host ""

        try {
            Start-BitsTransfer -Source $mod.Url -Destination $filePath
            Write-Host "Download completed: $filePath"
        } catch {
            Write-Warning "BITS download failed for '$($mod.Name)': $_"
            continue
        }
    } else {
        if (-not (Test-Path $filePath)) {
            Write-Warning "File '$fileName' not found in path '$offlinePath'. Skipping '$($mod.Name)'."
            continue
        }
    }

    Write-Host "Installing: $($mod.Name)"
    Start-Process msiexec.exe -ArgumentList "/i `"$filePath`" /quiet /norestart" -Wait
}
function enableSSO {
    param (
        [string] $path,
        [string] $sitename
    )

    Write-Host "Enabling SSO for '$sitename'"

    Set-WebConfigurationProperty -pspath $path -location $sitename -filter "system.webServer/security/authentication/anonymousAuthentication" -Name Enabled -Value False
    Set-WebConfigurationProperty -pspath $path -location $sitename -filter "system.webServer/security/authentication/windowsAuthentication" -Name Enabled -Value True

    $providerFilter = "/system.webServer/security/authentication/windowsAuthentication/providers"
    Remove-WebConfigurationProperty -pspath $path -location $sitename -filter $providerFilter -name "."
    Add-WebConfiguration -Force -pspath $path -location $sitename -filter $providerFilter -Value NTLM
    Add-WebConfiguration -Force -pspath $path -location $sitename -filter $providerFilter -Value Negotiate

    Set-WebConfigurationProperty -pspath $path -location $sitename -filter "system.webServer/security/authentication/basicAuthentication" -Name Enabled -Value True
}

function enableSslTermination {
    param (
        [string] $filterRoot
    )

    Write-Host "Configuring SSL termination on IIS (X-Forwarded-Proto)"
    $globalPath = "MACHINE/WEBROOT/APPHOST"
    RemoveAndAddWebConfigurationProperty -pspath $globalPath -filter "system.webServer/rewrite/allowedServerVariables" -name "." -value_name 'HTTP_X-Forwarded-Proto'
    RemoveAndAddWebConfigurationProperty -pspath $globalPath -filter "$filterRoot/servervariables" -name "." -value_name 'HTTP_X-Forwarded-Proto' -value_value 'https' -value_replace 'True'
}

# === STEP 5: ENABLE ARR AND HOST HEADER ===
$globalPath = "MACHINE/WEBROOT/APPHOST"

Write-Host "Enabling Application Request Routing globally..."
Set-WebConfigurationProperty -pspath $globalPath -filter "system.webServer/proxy" -name "enabled" -value "True"

Write-Host "Setting 'Preserve Host Header' to True globally..."
Set-WebConfigurationProperty -pspath $globalPath -filter "system.webServer/proxy" -name "preserveHostHeader" -value "True"

# === STEP 6: REWRITE RULE AND WEBSOCKET ===
installUrlRewriteRules -site $site -filterName $filterName -ivyEngineUrl $ivyEngineUrl -filterRoot $filterRoot
allowWebSocketCommunication -filterRoot $filterRoot

# === STEP 7: ENABLE SSO ===
$useSSO = Read-Host "Do you want to enable Single Sign-On (SSO)? (yes/no)"
Write-Host "WARNING: If you enable SSO, you need to make sure that your users can access the Axon Ivy Engine exclusively via IIS."
if ($useSSO -eq "yes") {
    Write-Host "Ensuring required IIS authentication features are installed..."
    Install-WindowsFeature Web-Windows-Auth
    Install-WindowsFeature Web-Basic-Auth
    enableSSO -path $path -sitename $sitename
    Write-Host "IIS SSO has been enabled, but you still have to enable SSO in your ivy.yaml or via Engine Cockpit"
} else {
    Write-Host "SSO configuration was skipped."
}

# === STEP 8: SSL TERMINATION ===
$terminateSSL = Read-Host "Only if you use HTTPS from browser to IIS! Do you want to terminate SSL on IIS and forward HTTP to Ivy Engine internally? (yes/no)"
if ($terminateSSL -eq "yes") {
    enableSslTermination -filterRoot $filterRoot
} else {
    Write-Host "SSL termination was skipped."
}

# === COMPLETION ===
Write-Host ""
Write-Host "All tasks completed."

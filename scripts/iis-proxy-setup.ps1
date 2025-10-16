Set-ExecutionPolicy Bypass -Scope Process
# standard filter routes all requests arriving at the IIS Ivy website to the engine.
$filterName = 'ivy-route-all'
$filterRoot = "system.webServer/rewrite/rules/rule[@name='$filterName']"
$choices = '&Yes', '&No'

function Read-Default($title, $text, $defaultValue) { 
  Write-Information " "
  Write-Information $title
  $prompt = Read-Host "$($text) [Default: '$($defaultValue)']";
  return ($defaultValue,$prompt)[[bool]$prompt]; 
}

function PromptForChoice( $title, $question, $choices, $defaultValue) {
  if ($autoConfirm) {
    Write-Information "Auto-confirming : $title"
    return $true
  }
  return ($Host.UI.PromptForChoice($title, $question, $choices, $defaultValue) -eq 0)
}

function isNotElevated() {
  return (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator"))
}

function isFeatureInstalled( [string] $name) {
  $state = (Get-WindowsFeature -Name $name).InstallState
  if ($state -ne "Installed" -and $state -ne "Available") {
    Write-Error "Feature $name is in state $state - a reboot might be required to complete a pending installation or removal."
  }
  return ($state -eq "Installed")
}

function detectMissingIISfeatures() {
  $iisFeatures = @(
    "Web-Server",         # IIS
    "Web-Filtering",      # Request Filtering
    "Web-Basic-Auth",     # Basic Authentication
    "Web-Windows-Auth",   # Windows Authentication
    "Web-ISAPI-Ext",      # ISAPI Extensions
    "Web-ISAPI-Filter",   # ISAPI Filters
    "Web-WebSockets"      # Web Sockets
  )

  $missing = @()
  foreach ($feature in $iisFeatures) {
    if (-not (isFeatureInstalled $feature)) {
      $missing += $feature
    }
  }
  return $missing
}

function enableIISfeatures() {
  Write-Information "Enabling IIS Features"
  # FYI: "-Online" means that the features are taken from the running Windows system instead of from a Windows installation image.
  # so, no online access to Microsoft's download sites is required.

  # IIS Base
  Enable-WindowsOptionalFeature -Online -FeatureName IIS-WebServerRole
  Enable-WindowsOptionalFeature -Online -FeatureName IIS-WebServer

  # SSO
  Enable-WindowsOptionalFeature -Online -FeatureName IIS-WindowsAuthentication
  Enable-WindowsOptionalFeature -Online -FeatureName IIS-BasicAuthentication

  # required for Ivy process viewer
  Install-WindowsFeature -name Web-WebSockets

  # required for Helicontech ISAPI filter - SSO 
  Enable-WindowsOptionalFeature -Online -FeatureName IIS-ISAPIExtensions
  Enable-WindowsOptionalFeature -Online -FeatureName IIS-ISAPIFilter
}

function provideIISfeatures() {
  $requiredFeatures = detectMissingIISfeatures
  if ($requiredFeatures.Count -eq 0) {
    Write-Information "All required IIS features are installed."
    return;
  }

  Write-Information "The following required IIS features are not installed: $($requiredFeatures -join ', ')"
  if (PromptForChoice 'IIS Feature Installation' 'Do you want to install the missing IIS features now?' $choices 0) {
    enableIISfeatures
    $requiredFeatures = detectMissingIISfeatures
    if ($requiredFeatures.Count -gt 0) {
      Write-Error "The following required IIS features are still missing after installation: $($requiredFeatures -join ', ')"
      exit 1
    }
  } else {
    Write-Error "Cannot continue without required IIS features. Please install them first."
    exit 1
  }
}

function downloadModule( [string] $name, [string] $file, [string] $url) {
  Write-Information "Downloading module ${name}" 
  $file = Join-Path $modulePath $file
  Invoke-WebRequest -Uri $url -OutFile $file

  return Test-Path -Path $file -PathType Leaf
}

function installModule( [string] $name, [string] $file, [string] $logFile = $($logFile)) {
  $file = Join-Path $modulePath $file
  $infoFile = "${file}.${filedate}.log"
  Write-Information "Installing module ${name} (check results in ${infoFile})"

  # because of date in log file we do not need to delete existing logs.
  Start-Process "msiexec.exe" -Argumentlist "/i $file /quiet /l* $infoFile AcceptEULA=Yes" -wait
  # check if execution has been successful
  return (Test-Path -Path $infoFile -PathType Leaf)
}

function enableProxy {
  Write-Information "Enabling Proxy"
  $assembly = [System.Reflection.Assembly]::LoadFrom("$env:systemroot\system32\inetsrv\Microsoft.Web.Administration.dll")
  $server = new-object Microsoft.Web.Administration.ServerManager
  $sectionGroupConfig = $server.GetApplicationHostConfiguration()
 
  $sectionName = 'proxy';
  $webserver = $sectionGroupConfig.RootSectionGroup.SectionGroups['system.webServer'];
  if (!$webserver.Sections[$sectionName]) {
    $proxySection = $webserver.Sections.Add($sectionName);
    $proxySection.OverrideModeDefault = "Allow";
    $proxySection.AllowDefinition="AppHostOnly";    
    $server.CommitChanges();
  }
 
  $config = $server.GetApplicationHostConfiguration()
  $section = $config.GetSection('system.webServer/' + $sectionName)
  $section.SetAttributeValue('enabled', 'true');
  $section.SetAttributeValue('preserveHostHeader', 'True');
  $section.SetAttributeValue('reverseRewriteHostInResponseHeaders', 'False');
  $server.CommitChanges();
}

function installUrlRewriteRules {
  Write-Information "Install URL rewrite rules for ${ivyEngineUrl}"
  Clear-WebConfiguration -pspath $site -filter $filterRoot 
  Add-WebConfigurationProperty -pspath $site -filter "system.webServer/rewrite/rules" -name "." -value @{name=$filterName;patternSyntax='Regular Expressions';stopProcessing='False'}
  Set-WebConfigurationProperty -pspath $site -filter "$filterRoot/match" -name "url" -value ".*"
  Set-WebConfigurationProperty -pspath $site -filter "$filterRoot/conditions" -name "logicalGrouping" -value "MatchAny"
  Set-WebConfigurationProperty -pspath $site -filter "$filterRoot/action" -name "type" -value "Rewrite"
  Set-WebConfigurationProperty -pspath $site -filter "$filterRoot/action" -name "url" -value "$ivyEngineUrl/{R:0}"
}

function RemoveAndAddWebConfigurationProperty( [string] $pspath, [string] $filter, [string] $name, [string] $value_name, [string] $value_value = '====', [string] $value_replace = '') {
  $CurrentWarningPreference = $WarningPreference
  $WarningPreference = 'SilentlyContinue';
  Remove-WebConfigurationProperty -pspath "$pspath" -filter "$filter" -name "$name" -AtElement @{name="$value_name"}
  $WarningPreference = $CurrentWarningPreference
  
  if ($value_value -eq '====') {
    Add-WebConfigurationProperty -pspath "$pspath" -filter "$filter" -name "$name" -value @{name="$value_name"}  
  } else {
    Add-WebConfigurationProperty -pspath "$pspath" -filter "$filter" -name "$name" -value @{name="$value_name";value="$value_value";replace="$value_replace"}  
  }
}

function terminateSSL {
  Write-Information "Terminate SSL on IIS"
  unlockSystemWebServer

  # add on server level
  RemoveAndAddWebConfigurationProperty -pspath "$site" -filter "system.webServer/rewrite/allowedServerVariables" -name "." -value_name 'HTTP_X-Forwarded-Proto'
  # add on web site level
  RemoveAndAddWebConfigurationProperty -pspath "$site" -filter "$filterRoot/servervariables" -name "." -value_name 'HTTP_X-Forwarded-Proto' -value_value 'https' -value_replace 'True'
}

function allowWebSocketCommunication {
  Write-Information "Allow Web Socket communication over IIS"
  unlockSystemWebServer
  # IIS ARR Module can not negotiate websocket compression
  # https://stackoverflow.com/questions/34316825/websockets-reverse-proxy-in-iis-8
     
  # add on server level
  RemoveAndAddWebConfigurationProperty -pspath "$site" -filter "system.webServer/rewrite/allowedServerVariables" -name "." -value_name 'HTTP_SEC_WEBSOCKET_EXTENSIONS'
  # add on web site level
  RemoveAndAddWebConfigurationProperty -pspath "$site" -filter "$filterRoot/servervariables" -name "." -value_name 'HTTP_SEC_WEBSOCKET_EXTENSIONS' -value_value '' -value_replace 'True'
}

function enableSSO {
  Write-Information "Enable SSO" 

  Write-Information "- Disable Anonymous Authentication"
  $filterAnonymous = "system.webServer/security/authentication/anonymousAuthentication"  
  Set-WebConfigurationProperty -pspath $path -location $sitename  -filter $filterAnonymous -Name Enabled -Value False

  Write-Information "- Enable Windows Authentication"
  $filterWindows = "system.webServer/security/authentication/windowsAuthentication"
  Set-WebConfigurationProperty -pspath $path -location $sitename  -filter $filterWindows -Name Enabled -Value True

  # the Remove-WebConfigurationProperty inserts a <clean /> tag which removes all inherited settings.
  $filter = "/system.webServer/security/authentication/windowsAuthentication/providers"
  Remove-WebConfigurationProperty -pspath $path -location $sitename -filter $filter -name "."
  Add-WebConfiguration -Force -pspath $path -location $sitename -filter $filter -Value NTLM
  Add-WebConfiguration -Force -pspath $path -location $sitename -filter $filter -Value Negotiate

  # REST Clients will need to have basic authentication enabled
  Write-Information "- Enable Basic Authentication"
  $filter = "system.webServer/security/authentication/basicAuthentication"
  Set-WebConfigurationProperty -pspath $path -location $sitename -filter $filter -Name Enabled -Value True
}

# sets the currently logged in user in http header 'X-Forwarded-User'
function installISAPIRewrite {
  Write-Information "Setting up ISAPI Rewrite"
  if (installModule "ISAPI Rewrite" "ISAPI_Rewrite3_0112_Lite_x64.msi") {
    $configFile = 'C:\Program Files\Helicon\ISAPI_Rewrite3\httpd.conf'
    if (Test-Path -Path $configFile -PathType Leaf) {
      Write-Information "- Configure ISAPI Rewrite"
      Set-Content -Path $configFile -Value 'RewriteHeader X-Forwarded-User: .* %{LOGON_USER}'
      return $true
    }
  }
  return $false
}
  
function restartIIS {
  Write-Information "Restarting IIS"
  IISReset /restart
}

function unlockSystemWebServer {
  Write-Information "Unlocking system.webServer section"
  $assembly = [System.Reflection.Assembly]::LoadFrom("$env:systemroot\system32\inetsrv\Microsoft.Web.Administration.dll")
  $mgr = new-object Microsoft.Web.Administration.ServerManager
  $conf = $mgr.GetApplicationHostConfiguration()
  unlockSectionGroup($conf.RootSectionGroup.SectionGroups["system.webServer"])
  $mgr.CommitChanges()
  # commit takes some time to complete, so wait a bit.
  Start-Sleep -Seconds 5
  Write-Information "Unlocking system.webServer done"
}

function unlockSectionGroup($group) {
  foreach ($subGroup in $group.SectionGroups) {
    unlockSectionGroup($subGroup)
  }
  foreach ($section in $group.Sections) {
    $section.OverrideModeDefault = "Allow"
  }
}

##################
# IIS Setup Main #
##################

# control output of Write-Debug, -Information, -Warning, and -Error.
# default values are SilentlyContinue - discard the message.
# value Continue shows the respective output type.
$DebugPreference      	= 'SilentlyContinue';
$InformationPreference  = 'Continue';
$WarningPreference 		  = 'Continue';
$ErrorActionPreference  = 'Continue';

if (isNotElevated) {
  Write-Error "This script needs to be executed in elevated mode!"
  Write-Error "Please start the shell executing this script 'as Administrator'"
  Write-Error "*** aborting"
  exit 1
}

$ep = Get-ExecutionPolicy
write-information "Your effective Execution Policy is ${ep}."

# prepare and start transcript
$scriptPath = Split-Path -Path $MyInvocation.MyCommand.Path
$scriptName = Split-Path  -Leaf -Path $MyInvocation.MyCommand.Path

$fileDate = Get-Date -f 'yyyy-MM-dd-HH-mm-ss'
$logFile = "${scriptPath}/${scriptName}.${fileDate}.log"

Start-Transcript -Path $logFile

$autoConfirm = $false
if ($env:AUTO_CONFIRM) {
  $autoConfirm = ($env:AUTO_CONFIRM -eq '1' -or $env:AUTO_CONFIRM -eq 'true')
}

# location of user-provided MSI packages for URL rewrite, ARR, ISAPI filter.
# default is in the script directory.
$modulePath = '.'

function downloadModules {
  $allOk = $true
  $allOk = downloadModule "Application Request Router (ARR)" "requestRouter_amd64.msi" "https://download.microsoft.com/download/E/9/8/E9849D6A-020E-47E4-9FD0-A023E99B54EB/requestRouter_amd64.msi"
  $allOk = $allOk -and (downloadModule "URL Rewrite" "rewrite_amd64_en-US.msi" "https://download.microsoft.com/download/1/2/8/128E2E22-C1B9-44A4-BE2A-5859ED1D4592/rewrite_amd64_en-US.msi")
  $allOk = $allOk -and (downloadModule "ISAPI Rewrite" "ISAPI_Rewrite3_0112_Lite_x64.msi" "https://www.helicontech.com/download/isapi_rewrite/ISAPI_Rewrite3_0112_Lite_x64.msi")
  if ( -not $allOk ) {
    Write-Error "Cannot download all modules. Please provide the missing files at ${modulePath}, or try again."
    throw "Module download error"
  }
  return $modulePath | Resolve-Path
}

function verifyModules {
  Do {
    $modulePath = Read-Default "IIS Modules Source Path" "Enter the path to the IIS modules you have downloaded yourself" "$modulePath"
  } Until ((Test-Path $modulePath -PathType Container))

  $modulePath = $modulePath | Resolve-Path

  Write-Information "ModulePath: '$modulePath'"
  # check if files are available already - else display an instruction message and terminate.
  $moduleFiles = (
      "requestRouter_amd64.msi",
      "rewrite_amd64_en-US.msi",
      "ISAPI_Rewrite3_0112_Lite_x64.msi"
  )
  $missing=@()
  foreach( $moduleFile in $moduleFiles) {
    if ( ! (Test-Path -Path (Join-Path "$modulePath" "$moduleFile") -PathType Leaf)) {
      Write-Error "${moduleFile} not found"
      $missing += $moduleFile
    }
  }
  if ( $missing.Count -gt 0 ) {
    Write-Error "Please provide the missing files, or have the script download them."
    throw "Missing module files"
  }
  return $modulePath | Resolve-Path
}

function provideModules() {
  try{
    $downloadFromInternet = PromptForChoice 'IIS Module Source' 'Do you want this script to download the required IIS modules from the internet?' $choices 0
    if ($downloadFromInternet) {
      $modulePath = downloadModules
    } else {   
      $modulePath = verifyModules
    }
    Write-Information "All Modules are available at: '$modulePath'"
  } catch {
    Write-Error "**** aborting: missing module files."
    exit 1
  }
}


# questions and checks 
# --------------------
provideIISfeatures
provideModules

# basic feature questions
$urlRewrite   = PromptForChoice 'URL Rewrite Rules' 'Do you want to setup the URL rewrite rules?' $choices 0
$terminateSsl = PromptForChoice 'Terminate SSL on IIS' 'Only if you use HTTPS from Browser to IIS! Do you want to terminate SSL on IIS to communicate from IIS to Axon Ivy Engine with HTTP instead of HTTPS?' $choices 0
$setupSso     = PromptForChoice 'Setup SSO' 'Do you want to enable SSO?' $choices 0

# details of the installation - IIS web site and Ivy Engine URL.
$defaultSite = "Default Web Site"
$path        = "iis:\sites"
$sitename    = Read-Default "IIS Ivy Website Name" "What is the name of the IIS Website that will serve Ivy?" "${defaultSite}"
$site        = "$path\$sitename"

$ivyEngineUrl = Read-Default "Ivy Engine URL" "What is your Ivy Engine URL?" "http://localhost:8080"


# start the installation and configuration
Write-Information "*"
Write-Information "* starting installation and setup *"
Write-Information "*"

$ok = installModule "Application Request Router (ARR)" "requestRouter_amd64.msi" 
$ok = $ok -and (installModule "URL Rewrite" "rewrite_amd64_en-US.msi")
if (-not $ok) {
  Write-Error "Cannot install Application Request Router and/or URL Rewrite - aborting"
  exit 1
}
enableProxy


if ($urlRewrite) {  
  installUrlRewriteRules
  allowWebSocketCommunication
  Write-Warning "Please change the standard search RE '.*' to allow only the contexts you want to be reachable from the outside"
}
if ($terminateSsl) {
  terminateSSL
  Write-Warning "Please enable HTTPS on IIS manually and import certificates, if required"

}
if ($setupSso) {
  installISAPIRewrite
  enableSSO
  Write-Warning "Please turn on SSO in Ivy (ivy.yaml: SSO.Enabled: true)"
}

restartIIS

Write-Information "Setup of IIS as a reverse proxy for Ivy completed."
Stop-Transcript
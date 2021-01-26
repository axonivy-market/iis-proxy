Set-ExecutionPolicy Bypass -Scope Process

$sitename = "Default Web Site"
$path = "iis:\sites"
$site = "$path\$sitename"

function enableIISFeatures() {
  Write-Host "Enable IIS Fetaures"
  Enable-WindowsOptionalFeature -Online -FeatureName IIS-WebServerRole
  Enable-WindowsOptionalFeature -Online -FeatureName IIS-WebServer

  # SSO
  Enable-WindowsOptionalFeature -Online -FeatureName IIS-WindowsAuthentication
  Enable-WindowsOptionalFeature -Online -FeatureName IIS-BasicAuthentication

  # required for isapi filter helicontech
  Enable-WindowsOptionalFeature -Online -FeatureName IIS-ISAPIExtensions
  Enable-WindowsOptionalFeature -Online -FeatureName IIS-ISAPIFilter
}

function installChoco {
  if(-not(test-path "C:\ProgramData\chocolatey\choco.exe")){
    Write-Host "Install chocolatey"
    Set-ExecutionPolicy Bypass -Scope Process -Force; iex ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1')) 
  }
}

function installUrlRewrite {
  Write-Host "Install Url Rewrite"
  choco install -y urlrewrite
  Write-Host "Install IIS Application Request Routing (ARR)"
  choco install -y iis-arr
}

function enableProxy {
  Write-Host "Enable Proxy"
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
  $server.CommitChanges();
}

function installUrlRewriteRules {
  $ivyEngineUrl = 'http://localhost:8080'  
  Write-Host "Install url rewrite rules for " -NoNewline
  Write-Host $ivyEngineUrl -ForegroundColor Green

  $filterName = "ivy-route-all"
  $filterRoot = "system.webServer/rewrite/rules/rule[@name='$filterName']"
  Clear-WebConfiguration -pspath $site -filter $filterRoot 
  Add-WebConfigurationProperty -pspath $site -filter "system.webServer/rewrite/rules" -name "." -value @{name=$filterName;patternSyntax='Regular Expressions';stopProcessing='False'}
  Set-WebConfigurationProperty -pspath $site -filter "$filterRoot/match" -name "url" -value ".*"
  Set-WebConfigurationProperty -pspath $site -filter "$filterRoot/conditions" -name "logicalGrouping" -value "MatchAny"
  Set-WebConfigurationProperty -pspath $site -filter "$filterRoot/action" -name "type" -value "Rewrite"
  Set-WebConfigurationProperty -pspath $site -filter "$filterRoot/action" -name "url" -value "$ivyEngineUrl/{R:0}"
}

function enableSSO {
  Write-Host "Enable SSO" 

  $filterAnonymous = "system.webServer/security/authentication/anonymousAuthentication"  
  Set-WebConfigurationProperty -pspath $path -location $sitename  -filter $filterAnonymous -Name Enabled -Value False

  $filterWindows = "system.webServer/security/authentication/windowsAuthentication"
  Set-WebConfigurationProperty -pspath $path -location $sitename  -filter $filterWindows -Name Enabled -Value True

  $filter = "/system.webServer/security/authentication/windowsAuthentication/providers"
  Remove-WebConfigurationProperty -pspath $path -location $sitename -filter $filter -name "."
  Add-WebConfiguration -Force -pspath $path -location $sitename -filter $filter -Value NTLM
  Add-WebConfiguration -Force -pspath $path -location $sitename -filter $filter -Value Negotiate  
}

function installISAPIRewrite {
  Write-Host "Download ISAPI Rewrite" 
  $url = "https://www.helicontech.com/download/isapi_rewrite/ISAPI_Rewrite3_0112_Lite_x64.msi"
  $output = "isapi-rewrite-lite.msi"
  Invoke-WebRequest -Uri $url -OutFile $output

  Write-Host "Install ISAPI Rewrite $output"
  Start-Process msiexec -ArgumentList "/i $output /passive AcceptEULA=Yes" -wait
  Remove-Item $output

  Write-Host "Configure ISAPI Rewrite"
  Set-Content -Path 'C:\Program Files\Helicon\ISAPI_Rewrite3\httpd.conf' -Value 'RewriteHeader user: .* %{LOGON_USER}'
}

function enableBasicAuth {
  Write-Host "Enable Basic Authentication"
  $filter = "system.webServer/security/authentication/basicAuthentication"
  Set-WebConfigurationProperty -pspath $path -location $sitename -filter $filter -Name Enabled -Value True
}

function restartIIS {
  Write-Host "Restart IIS"
  IISReset /restart
}


################
# Guided Setup #
################
$title    = 'IIS Setup'
$question = 'Do you want to install IIS and its features?'
$choices  = '&Yes', '&No'
$decision = $Host.UI.PromptForChoice($title, $question, $choices, 1)
if ($decision -eq 0) {
  enableIISFeatures
  installChoco
  installUrlRewrite
  enableProxy
}

$title    = 'Rewrite Rule'
$question = 'Do you want to install rewrite rule?'
$choices  = '&Yes', '&No'
$decision = $Host.UI.PromptForChoice($title, $question, $choices, 1)
if ($decision -eq 0) {  
  installUrlRewriteRules
}

$title    = 'Setup SSO'
$question = 'Do you want to enable SSO?'
$choices  = '&Yes', '&No'
$decision = $Host.UI.PromptForChoice($title, $question, $choices, 1)
if ($decision -eq 0) {
  enableSSO
  installISAPIRewrite
}

$title    = 'Setup Basic Authentication for REST Services'
$question = 'Do you want to enable basic authentication for REST Services?'
$choices  = '&Yes', '&No'
$decision = $Host.UI.PromptForChoice($title, $question, $choices, 1)
if ($decision -eq 0) {
  enableBasicAuth
}

restartIIS

Set-ExecutionPolicy Bypass -Scope Process

$sitename = "Default Web Site"
$path = "iis:\sites"
$site = "$path\$sitename"
$filterName = "ivy-route-all"
$filterRoot = "system.webServer/rewrite/rules/rule[@name='$filterName']"

function enableIISFeatures() {
  Write-Host "Enable IIS Fetaures"
  Enable-WindowsOptionalFeature -Online -FeatureName IIS-WebServerRole
  Enable-WindowsOptionalFeature -Online -FeatureName IIS-WebServer

  # SSO
  Enable-WindowsOptionalFeature -Online -FeatureName IIS-WindowsAuthentication
  Enable-WindowsOptionalFeature -Online -FeatureName IIS-BasicAuthentication

  # required for process viewer
  Install-WindowsFeature -name Web-WebSockets

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

  Clear-WebConfiguration -pspath $site -filter $filterRoot 
  Add-WebConfigurationProperty -pspath $site -filter "system.webServer/rewrite/rules" -name "." -value @{name=$filterName;patternSyntax='Regular Expressions';stopProcessing='False'}
  Set-WebConfigurationProperty -pspath $site -filter "$filterRoot/match" -name "url" -value ".*"
  Set-WebConfigurationProperty -pspath $site -filter "$filterRoot/conditions" -name "logicalGrouping" -value "MatchAny"
  Set-WebConfigurationProperty -pspath $site -filter "$filterRoot/action" -name "type" -value "Rewrite"
  Set-WebConfigurationProperty -pspath $site -filter "$filterRoot/action" -name "url" -value "$ivyEngineUrl/{R:0}"
}

function terminateSSL {
  Write-Host "Terminate SSL on IIS"
  Write-Host "You need to manually enable HTTPS!"  
  unlockSystemWebServer

  Remove-WebConfigurationProperty -pspath $site -filter "system.webServer/rewrite/allowedServerVariables" -name "." -AtElement @{name='HTTP_X-Forwarded-Proto'}
  Add-WebConfigurationProperty -pspath $site -filter "system.webServer/rewrite/allowedServerVariables" -name "." -value @{name='HTTP_X-Forwarded-Proto'}  

  Remove-WebConfigurationProperty -pspath $site -filter "$filterRoot/servervariables" -name "." -AtElement @{name='HTTP_X-Forwarded-Proto'}
  Add-WebConfigurationProperty -pspath $site -filter "$filterRoot/servervariables" -name "." -value @{name='HTTP_X-Forwarded-Proto';value='https';replace='True'}
}

function allowWebSocketCommunication {
  Write-Host "Allow Web Socket communication over IIS"
  unlockSystemWebServer
  # IIS ARR Module can not negotiate websocket compression
  # https://stackoverflow.com/questions/34316825/websockets-reverse-proxy-in-iis-8
  Remove-WebConfigurationProperty -pspath $site -filter "system.webServer/rewrite/allowedServerVariables" -name "." -AtElement @{name='HTTP_SEC_WEBSOCKET_EXTENSIONS'}
  Add-WebConfigurationProperty -pspath $site -filter "system.webServer/rewrite/allowedServerVariables" -name "." -value @{name='HTTP_SEC_WEBSOCKET_EXTENSIONS'}

  Remove-WebConfigurationProperty -pspath $site -filter "$filterRoot/servervariables" -name "." -AtElement @{name='HTTP_SEC_WEBSOCKET_EXTENSIONS'}
  Add-WebConfigurationProperty -pspath $site -filter "$filterRoot/servervariables" -name "." -value @{name='HTTP_SEC_WEBSOCKET_EXTENSIONS';value='';replace='True'}
}

function enableSSO {
  Write-Host "Enable SSO" 

  Write-Host "Disable Anonymous Authentication"
  $filterAnonymous = "system.webServer/security/authentication/anonymousAuthentication"  
  Set-WebConfigurationProperty -pspath $path -location $sitename  -filter $filterAnonymous -Name Enabled -Value False

  Write-Host "Enable Windows Authentication"
  $filterWindows = "system.webServer/security/authentication/windowsAuthentication"
  Set-WebConfigurationProperty -pspath $path -location $sitename  -filter $filterWindows -Name Enabled -Value True

  $filter = "/system.webServer/security/authentication/windowsAuthentication/providers"
  Remove-WebConfigurationProperty -pspath $path -location $sitename -filter $filter -name "."
  Add-WebConfiguration -Force -pspath $path -location $sitename -filter $filter -Value NTLM
  Add-WebConfiguration -Force -pspath $path -location $sitename -filter $filter -Value Negotiate

  # REST Clients will need to have basic authentication enabled
  Write-Host "Enable Basic Authentication"
  $filter = "system.webServer/security/authentication/basicAuthentication"
  Set-WebConfigurationProperty -pspath $path -location $sitename -filter $filter -Name Enabled -Value True
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
  Set-Content -Path 'C:\Program Files\Helicon\ISAPI_Rewrite3\httpd.conf' -Value 'RewriteHeader X-Forwarded-User: .* %{LOGON_USER}'
}

function restartIIS {
  Write-Host "Restart IIS"
  IISReset /restart
}

function unlockSystemWebServer {
  Write-Host "Unlocking system.webServer section"
  $assembly = [System.Reflection.Assembly]::LoadFrom("$env:systemroot\system32\inetsrv\Microsoft.Web.Administration.dll")
  $mgr = new-object Microsoft.Web.Administration.ServerManager
  $conf = $mgr.GetApplicationHostConfiguration()
  unlockSectionGroup($conf.RootSectionGroup.SectionGroups["system.webServer"])
  $mgr.CommitChanges()
  Start-Sleep -Seconds 5
  Write-Host "Unlocking system.webServer done"
}

function unlockSectionGroup($group) {
  foreach ($subGroup in $group.SectionGroups) {
    unlockSectionGroup($subGroup)
  }
  foreach ($section in $group.Sections) {
    $section.OverrideModeDefault = "Allow"
  }
}

################
# Guided Setup #
################
$title    = 'IIS Setup'
$question = 'Do you want to install IIS and its features?'
$choices  = '&Yes', '&No'
$decision = $Host.UI.PromptForChoice($title, $question, $choices, 0)
if ($decision -eq 0) {
  enableIISFeatures
  installChoco
  installUrlRewrite
  enableProxy
}

$title    = 'Rewrite Rule'
$question = 'Do you want to install rewrite rule?'
$choices  = '&Yes', '&No'
$decision = $Host.UI.PromptForChoice($title, $question, $choices, 0)
if ($decision -eq 0) {  
  installUrlRewriteRules
  allowWebSocketCommunication
}

$title    = 'Terminate SSL on IIS'
$question = 'Only if you use HTTPS from Browser to IIS! Do you want to terminate SSL on IIS to communicate from IIS to Axon Ivy Engine with HTTP instead of HTTPS?'
$choices  = '&Yes', '&No'
$decision = $Host.UI.PromptForChoice($title, $question, $choices, 1)
if ($decision -eq 0) {
  terminateSSL
}

$title    = 'Setup SSO'
$question = 'Do you want to enable SSO?'
$choices  = '&Yes', '&No'
$decision = $Host.UI.PromptForChoice($title, $question, $choices, 1)
if ($decision -eq 0) {
  enableSSO
  installISAPIRewrite
}

restartIIS

function runIvyEngine( [string] $link ) {
  if (Test-Path 'engine') {
    Write-Output "Engine directory already exists, skipping download and extraction."
  } else {
    curl -L $link -o engine.zip
    Expand-Archive -Path 'engine.zip' -DestinationPath 'engine'
  }
  Start-Process -FilePath './engine/bin/AxonIvyEngine.exe' -NoNewWindow
}

function call( [string] $url) {
  Write-Output "Calling $url"
  try {
    $base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes('admin:admin'))
    $headers = @{ Authorization = "Basic $base64Auth" }
    $response = Invoke-WebRequest -Uri $url -UseBasicParsing -Headers $headers -SkipCertificateCheck
    Write-Host "::notice::Status $($response.StatusCode)"
    Write-Output "::warning:: $response.Content"
    if ($response.StatusCode -ne 200) {
      Write-Error "Unexpected status code: $($response.StatusCode)"
      exit 1
    }
  } catch {
    Write-Output "Status: $($_.Exception.Response.StatusCode.value__)"
    Write-Error $_.Exception.Message
    exit 1
  }
}

function createIISUser( [string] $username, [string] $password ) {
  Write-Output "Creating user $username/$password for IIS SSO"
  allowSimplePasswords
  net user $username $password /add
}

function allowSimplePasswords() {
  net accounts /minpwlen:3
  # Disable password complexity
  secedit /export /cfg C:\secpol.cfg
  (Get-Content C:\secpol.cfg) -replace 'PasswordComplexity = 1','PasswordComplexity = 0' | Set-Content C:\secpol.cfg
  secedit /configure /db secedit.sdb /cfg C:\secpol.cfg /areas SECURITYPOLICY
  Remove-Item C:\secpol.cfg
}

function enableIvyYamlSSO() {
  $ivyYaml='engine/configuration/ivy.yaml'
  Add-Content -Path $ivyYaml -Value "SecuritySystems:"
  Add-Content -Path $ivyYaml -Value "  default:"
  Add-Content -Path $ivyYaml -Value "    SSO:"
  Add-Content -Path $ivyYaml -Value "      enabled: true"
}

function enableSelfSignedSSL() {
  Write-Output "Enabling HTTPS on IIS Proxy (self-signed)"
  $cert = New-SelfSignedCertificate -DnsName "localhost" -CertStoreLocation "cert:\LocalMachine\My"
  $thumb = $cert.Thumbprint
  
  Import-Module WebAdministration
  $siteName = "Default Web Site"
  if (-not (Get-WebBinding -Name $siteName -Protocol "https")) {
    New-WebBinding -Name $siteName -Protocol https -Port 443 -IPAddress "*" -HostHeader ""
  }
  netsh http add sslcert ipport=0.0.0.0:443 certhash=$thumb appid='{00112233-4455-6677-8899-AABBCCDDEEFF}'
}

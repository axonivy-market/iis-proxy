function runIvyEngine( [string] $link ) {
  curl -L $link -o engine.zip
  Expand-Archive -Path 'engine.zip' -DestinationPath 'engine'
  Start-Process -FilePath './engine/bin/AxonIvyEngine.exe' -NoNewWindow
}

function call( [string] $url) {
  Write-Output "Calling $url"
  try {
    $base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes('admin:admin'))
    $headers = @{ Authorization = "Basic $base64Auth" }
    $response = Invoke-WebRequest -Uri $url -UseBasicParsing -Headers $headers
    Write-Output "Status: $($response.StatusCode)"
    Write-Host "$response.Content" -ForegroundColor Green
  } catch {
    Write-Output "Status: $($_.Exception.Response.StatusCode.value__)"
    Write-Output $_.Exception.Message
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

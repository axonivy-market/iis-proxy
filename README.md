# IIS Proxy Scripts

[![CI Build](https://github.com/axonivy-market/iis-proxy/actions/workflows/ci.yml/badge.svg)](https://github.com/axonivy-market/iis-proxy/actions/workflows/ci.yml)
![2025](https://img.shields.io/badge/Windows-Server_2025-blue)
![2022](https://img.shields.io/badge/Windows-Server_2022-green)

Scripts to configure an IIS webserver as reverse proxy for an Axon Ivy Engine: [reverse-proxy/IIS].

## Installation


1. Download the IIS proxy installer script [iis-proxy-setup.ps1](https://github.com/axonivy-market/iis-proxy/raw/refs/heads/master/scripts/iis-proxy-setup.ps1) onto the host where the Axon Ivy Engine will run.
2. Right click on the file and pick `Run with PowerShell`. Run this script in privileged mode `as Administrator`.
3. The first time when you execute this script, you may be asked for a Execution Policy Change so that this script can be executed. You need to answer this question with `[A] Yes to All`.

> [!NOTE]  
> This script works best with a freshly installed IIS. If IIS or any of its modules are already installed, the script may fail to run or some modules might not be installed correctly. In that case, please refer to the documentation [reverse-proxy/IIS] for manual installation.

> [!WARNING]  
> Windows Server 2025: This script does not support IIS on Windows Server 2025. For manual installation, please consult the official documentation..

### Requirements

- You have at least Windows Powershell (v5.1) installed and available.
- The Server Manager PowerShell interface is available.

#### Preferred

- IIS is on the same host as the Axon Ivy Engine.
- The Axon Ivy Engine is accessed via the Default Web Site of IIS.
- There are no other applications served by this IIS. Otherwise, you need to adapt the IIS server level URL rewrite rules.
- The script will download the additional IIS modules required.

## Troubleshooting

### Module download restriction

If your IIS server cannot access external links, you need to download the modules externally and upload them to your IIS server. Please check the download links for the modules in our script by searching for `downloadModule`. Once you have downloaded them, upload them onto the IIS server in a directory of your choice. Using the directory where you store our script is the most simple solution. Then, start the script and select No to the question titled `IIS Module Source`, and enter the path where you stored the modules in question `IIS Modules Source Path`.

### Execution policy

If you have not been asked about the Execution Policy Change but the script is still not running, you maybe need to unblock it via the Options menu (Properties -> General -> Security -> Unblock) or by running the following command in the PowerShell `Unblock-File iis-proxy-setup.ps1`


[reverse-proxy/IIS]: https://developer.axonivy.com/doc/dev/en/engine-guide/integration/reverse-proxy/microsoft-iis/index.html

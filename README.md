# IIS Proxy Scripts

Scripts to configure an IIS webserver as [reverse-proxy] for an Axon Ivy Engine.

[![CI Build](https://github.com/axonivy-market/iis-proxy/actions/workflows/ci.yml/badge.svg)](https://github.com/axonivy-market/iis-proxy/actions/workflows/ci.yml)

Supports:

![LE](https://img.shields.io/badge/AxonIvy-LE-blue)
![12](https://img.shields.io/badge/AxonIvy-LTS12-green)
![10](https://img.shields.io/badge/AxonIvy-LTS10-yellow)

![2025](https://img.shields.io/badge/Windows-Server_2025-blue)
![2022](https://img.shields.io/badge/Windows-Server_2022-green)
![2019](https://img.shields.io/badge/Untested::Windows-Server_2019-yellow)

## Installation ▶️

1. Download the IIS proxy installer script [iis-proxy-setup.ps1](https://github.com/axonivy-market/iis-proxy/raw/refs/heads/master/scripts/iis-proxy-setup.ps1) onto the host where the Axon Ivy Engine will run.
2. Right click on the file and pick `Run with PowerShell`. Run this script in privileged mode `as Administrator`.
3. The first time when you execute this script, you may be asked for a Execution Policy Change so that this script can be executed. You need to answer this question with `[A] Yes to All`.

### Manual 🤚️
This script works best with a freshly installed IIS. If you face issues, please refer to the documentation for [manual installation](docs/Manual.md).

### HTTPS 🔐️

For a secure HTTPS setup manual steps are required to enact your certifcate: see the guidance on [Serve with HTTPS](docs/Manual.md#serve-with-https).

### Requirements

- You have at least Windows Powershell (v5.1) installed and available.
- The Server Manager PowerShell interface is available.

#### Preferred

- IIS is on the same host as the Axon Ivy Engine.
- The Axon Ivy Engine is accessed via the Default Web Site of IIS.
- There are no other applications served by this IIS. Otherwise, you need to adapt the IIS server level URL rewrite rules.
- The script will download the additional IIS modules required.

## Troubleshooting 🩺️

### Module download restriction

If your IIS server cannot access external links, you need to download the modules externally and upload them to your IIS server. Please check the download links for the modules in our script by searching for `$requiredModules`. Once you have downloaded them, upload them onto the IIS server to the directory where you store our script. Then, start the script again.

### Execution policy

If you have not been asked about the Execution Policy Change but the script is still not running, you maybe need to unblock it via the Options menu (Properties -> General -> Security -> Unblock) or by running the following command in the PowerShell `Unblock-File iis-proxy-setup.ps1`


[reverse-proxy]: https://developer.axonivy.com/doc/dev/en/engine-guide/integration/reverse-proxy/index.html

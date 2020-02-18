# Azure App Service - Hybrid Connections

Hybrid connections are the often forgotten networking option for the Azure App Service, they are surprisingly powerful and provide a real credible option where traditional VPNs are not available.  The [setup.sh](setup.sh) script will create a load balanced mocked test environment, consisting of 

- An Azure Relay, the heart of the Hybrid connection, where messages are queued  
- An Azure Function, with hybrid connections configuired
- A Virtual Network containing a single subnet, this simulates our on-premises environment.
- A private DNS Zone so that the VMs are addressable by name.
- 2 x API VMs.  These are Windows 2019 VMs which have IIS installed and a single json file dropped in the root directory that acts as a simple GET API.
- 2 x Hybrid Connection Manager (HCM) VMs.  Again, these are Win 2019 and have the Hybrid Connection Manager tool installed and configured to point at the connections requested by the function.

Each Hybrid Connection Manager VM points at all the Hybrid Connection Endpoints so if the HCM crashes on a machine there is still a valid connection. High Availability with Hybrid connection manager!

Lessons learnt along the way...

- String management in bash is tricky, particularly when working with Azure Custom Extensions, escaped strings within escaped strings.
- Azure CLI continues to impress.
- Should probably use Managed Identities to access the storage accounts when deploying files.  One to investigate in the future.
- The HCM application is a .net app that has a config file that can be updated to add connections. (see [updateHCM.ps1](updateHCM.ps1) for more details)
- The HCM application saves its connectionStrings in a different format that which is served up from the Azure Portal or the CLI.

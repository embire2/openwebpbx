# OpenWebPBX Free Phone for Windows1.0.0

Native Windows11 and WindowsServer2025DesktopExperience calling client, in development. The application uses C#/.NET10, WinUI3 and native Liblinphone. The Store edition uses MSIX and Store updates; the direct edition targets machines where Store installation is unavailable.

No Windows client release or Store approval is claimed yet. See [actual Android parity](docs/FEATURE_PARITY.md), [architecture](docs/ARCHITECTURE.md) and the component build reports as implementation proceeds.

The current native startup component passes real Windows DPAPI/Core privacy checks and23 interface controls. Controlled calling, hardware, signed package installation/update and Store certification remain separate pending qualifications. The direct release verifier and installer are independent of PBX Server and Android update feeds.

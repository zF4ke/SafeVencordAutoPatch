# Safe Vencord Auto Patch

Auto-runs the official Vencord installer only after Discord changes.

Runs at startup/login and once daily at noon.

Windows install:

```powershell
# Run PowerShell as Administrator for setup
powershell -NoProfile -ExecutionPolicy Bypass -File .\safe-vencord-autopatch.ps1 -Install
```

macOS/Linux install:

```sh
chmod +x ./safe-vencord-autopatch.sh
./safe-vencord-autopatch.sh install
```

Windows remove:

```powershell
# Run PowerShell as Administrator for removal
powershell -NoProfile -ExecutionPolicy Bypass -File .\safe-vencord-autopatch.ps1 -Uninstall
```

macOS/Linux remove:

```sh
./safe-vencord-autopatch.sh uninstall
```

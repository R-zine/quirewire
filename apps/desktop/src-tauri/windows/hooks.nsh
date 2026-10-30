!macro PrintBridgeRunLifecycle ACTION
  ExecWait '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$INSTDIR\scripts\m8\windows\Invoke-M8Lifecycle.ps1" -Action ${ACTION} -InstallRoot "$INSTDIR"' $0
  ${If} $0 != 0
    MessageBox MB_ICONSTOP "PrintBridge ${ACTION} failed. No unowned printer, VM, task, setting, or file was removed. Review the installer details and retry."
    SetErrorLevel 1
    Abort
  ${EndIf}
!macroend

!macro NSIS_HOOK_PREINSTALL
  ${If} ${FileExists} "$INSTDIR\scripts\m8\windows\Invoke-M8Lifecycle.ps1"
    !insertmacro PrintBridgeRunLifecycle PrepareUpgrade
  ${EndIf}
!macroend

!macro NSIS_HOOK_POSTINSTALL
  !insertmacro PrintBridgeRunLifecycle Install
!macroend

!macro NSIS_HOOK_PREUNINSTALL
  !insertmacro PrintBridgeRunLifecycle Uninstall
!macroend

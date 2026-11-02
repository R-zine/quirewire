!macro PrintBridgeRunLifecycle ACTION
  ${If} ${RunningX64}
    StrCpy $8 "$WINDIR\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
  ${Else}
    StrCpy $8 "$SYSDIR\WindowsPowerShell\v1.0\powershell.exe"
  ${EndIf}
  ExecWait '"$8" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$INSTDIR\scripts\m8\windows\Invoke-M8Lifecycle.ps1" -Action ${ACTION} -InstallRoot "$INSTDIR"' $0
  CreateDirectory "$LOCALAPPDATA\PrintBridge\logs"
  FileOpen $9 "$LOCALAPPDATA\PrintBridge\logs\installer-lifecycle.log" a
  FileSeek $9 0 END
  FileWrite $9 "${ACTION} exit=$0$\r$\n"
  FileClose $9
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

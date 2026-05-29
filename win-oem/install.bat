@echo off
rem 6v6 Windows endpoint 종합 자동계측 — Sysmon + Wazuh + OpenSSH + hosts
set LOG=C:\oem-install.log
echo [6v6] OEM start %DATE% %TIME% > %LOG%
ping -n 20 127.0.0.1 >/dev/null

rem --- Sysmon + SwiftOnSecurity ---
powershell -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol='Tls12'; Invoke-WebRequest -UseBasicParsing 'https://live.sysinternals.com/Sysmon64.exe' -OutFile 'C:\Windows\Sysmon64.exe'" >> %LOG% 2>&1
powershell -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol='Tls12'; Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/SwiftOnSecurity/sysmon-config/master/sysmonconfig-export.xml' -OutFile 'C:\Windows\sysmonconfig.xml'" >> %LOG% 2>&1
C:\Windows\Sysmon64.exe -accepteula -i C:\Windows\sysmonconfig.xml >> %LOG% 2>&1

rem --- Wazuh agent 4.10.0 + 명시 등록 + Sysmon 채널 ---
powershell -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol='Tls12'; Invoke-WebRequest -UseBasicParsing 'https://packages.wazuh.com/4.x/windows/wazuh-agent-4.10.0-1.msi' -OutFile 'C:\Windows\wazuh-agent.msi'" >> %LOG% 2>&1
msiexec /i C:\Windows\wazuh-agent.msi /qn WAZUH_MANAGER=10.20.32.100 WAZUH_AGENT_NAME=6v6-win >> %LOG% 2>&1
ping -n 8 127.0.0.1 >/dev/null
"C:\Program Files (x86)\ossec-agent\agent-auth.exe" -m 10.20.32.100 -A 6v6-win >> %LOG% 2>&1
powershell -ExecutionPolicy Bypass -Command "$p='C:\Program Files (x86)\ossec-agent\ossec.conf'; if(Test-Path $p){ $c=Get-Content $p -Raw; if($c -notmatch 'Sysmon/Operational'){ $b='<ossec_config><localfile><location>Microsoft-Windows-Sysmon/Operational</location><log_format>eventchannel</log_format></localfile></ossec_config>'; ($c.TrimEnd()+[Environment]::NewLine+$b)|Set-Content $p -Encoding ASCII } }" >> %LOG% 2>&1

rem --- OpenSSH Server (원격 명령/랩 자동화), 기본셸 PowerShell ---
powershell -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol='Tls12'; Invoke-WebRequest -UseBasicParsing 'https://github.com/PowerShell/Win32-OpenSSH/releases/download/v9.8.1.0p1-Preview/OpenSSH-Win64.zip' -OutFile 'C:\Windows\Temp\OpenSSH.zip'; Expand-Archive -Force 'C:\Windows\Temp\OpenSSH.zip' 'C:\Program Files\OpenSSH'" >> %LOG% 2>&1
powershell -ExecutionPolicy Bypass -File "C:\Program Files\OpenSSH\OpenSSH-Win64\install-sshd.ps1" >> %LOG% 2>&1
powershell -Command "New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22" >> %LOG% 2>&1
powershell -Command "New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -PropertyType String -Force" >> %LOG% 2>&1
sc config sshd start= auto >> %LOG% 2>&1
net start sshd >> %LOG% 2>&1

rem --- hosts: *.6v6.lab → web/WAF (victim 브라우징) ---
powershell -Command "Add-Content -Path C:\Windows\System32\drivers\etc\hosts -Value '10.20.32.80 juice.6v6.lab dvwa.6v6.lab neobank.6v6.lab govportal.6v6.lab mediforum.6v6.lab admin.6v6.lab ai.6v6.lab'" >> %LOG% 2>&1

rem --- 핑 허용 + Wazuh 재기동 ---
netsh advfirewall firewall add rule name="ICMPv4 Allow" protocol=icmpv4:8,any dir=in action=allow >> %LOG% 2>&1
net stop WazuhSvc >> %LOG% 2>&1
net start WazuhSvc >> %LOG% 2>&1
echo [6v6] OEM done %DATE% %TIME% >> %LOG%
copy /Y %LOG% \\host.lan\Data\oem-install.log >/dev/null 2>&1
echo DONE > \\host.lan\Data\OEM_DONE.txt 2>/dev/null

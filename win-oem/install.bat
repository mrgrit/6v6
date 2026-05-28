@echo off
rem 6v6 Windows endpoint 자동 계측 — Sysmon + Wazuh agent (manager 10.20.32.100)
set LOG=C:\oem-install.log
echo [6v6] OEM start %DATE% %TIME% > %LOG%

rem 네트워크 안정 대기
ping -n 20 127.0.0.1 >/dev/null

rem --- Sysmon + SwiftOnSecurity config ---
powershell -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing 'https://live.sysinternals.com/Sysmon64.exe' -OutFile 'C:\Windows\Sysmon64.exe'" >> %LOG% 2>&1
powershell -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/SwiftOnSecurity/sysmon-config/master/sysmonconfig-export.xml' -OutFile 'C:\Windows\sysmonconfig.xml'" >> %LOG% 2>&1
C:\Windows\Sysmon64.exe -accepteula -i C:\Windows\sysmonconfig.xml >> %LOG% 2>&1

rem --- Wazuh agent 4.10.0 ---
powershell -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing 'https://packages.wazuh.com/4.x/windows/wazuh-agent-4.10.0-1.msi' -OutFile 'C:\Windows\wazuh-agent.msi'" >> %LOG% 2>&1
msiexec /i C:\Windows\wazuh-agent.msi /qn WAZUH_MANAGER=10.20.32.100 WAZUH_AGENT_NAME=6v6-win >> %LOG% 2>&1
ping -n 10 127.0.0.1 >/dev/null

rem --- 명시 등록(authd) + Sysmon 채널 수집 + 서비스 기동 ---
"C:\Program Files (x86)\ossec-agent\agent-auth.exe" -m 10.20.32.100 -A 6v6-win >> %LOG% 2>&1
powershell -ExecutionPolicy Bypass -Command "$p='C:\Program Files (x86)\ossec-agent\ossec.conf'; if(Test-Path $p){ $c=Get-Content $p -Raw; if($c -notmatch 'Sysmon/Operational'){ $b='<ossec_config><localfile><location>Microsoft-Windows-Sysmon/Operational</location><log_format>eventchannel</log_format></localfile></ossec_config>'; ($c.TrimEnd()+[Environment]::NewLine+$b)|Set-Content $p -Encoding ASCII } }" >> %LOG% 2>&1
netsh advfirewall firewall add rule name="ICMPv4 Allow" protocol=icmpv4:8,any dir=in action=allow >> %LOG% 2>&1
net stop WazuhSvc >> %LOG% 2>&1
net start WazuhSvc >> %LOG% 2>&1
echo [6v6] OEM done %DATE% %TIME% >> %LOG%

rem --- 검증용: 로그를 공유폴더로 복사 ---
copy /Y %LOG% \\host.lan\Data\oem-install.log >/dev/null 2>&1
echo OEM_DONE %DATE% %TIME% > \\host.lan\Data\OEM_DONE.txt 2>/dev/null

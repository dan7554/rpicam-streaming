===========================================================
📋 SIM ACTIVATION INFORMATION EXTRACTOR
===========================================================
Collecting all data needed for eiotclub/1NCE support

🔍 EXTRACTING DEVICE INFORMATION...

1. HARDWARE INFORMATION:
========================
Device: Raspberry Pi 5 with SIM8262A-M2 5G Module
Connection: PCIe (MHI interface)
Location: USA
📱 Checking SIM card details...

2. SIM CARD INFORMATION:
========================
Getting device IMEI...
IMEI: 866713060018570
Getting SIM ICCID...
ICCID (SIM Serial): 
Getting IMSI...
IMSI: 
📡 Checking network registration...

3. NETWORK REGISTRATION:
========================
Registration state: 'not-registered-searching'
Roaming status: 'on'
MCC: '311'
MNC: '480'
Description: ''
MCC: '311'
MNC: '480'
MNC with PCS digit: 'yes'

Network Details:
- Mobile Country Code (MCC): 311
- Mobile Network Code (MNC): 480
- Carrier: 
- Combined PLMN: 311480
📶 Checking signal strength...

4. SIGNAL INFORMATION:
======================
Network 'lte': '-77 dBm'
Network 'lte': '-77 dBm'
Network 'lte': '-2.5 dBm'
SINR (8): '9.0 dB'
RSRQ:
Network 'lte': '-19 dB'
Network 'lte': '-3.2 dB'
RSRP:
Network 'lte': '-114 dBm'
⚙️ Checking device capabilities...

5. DEVICE CAPABILITIES:
=======================
SIM: 'supported'
Networks: 'umts, lte, 5gnr'
❌ Recording connection errors...

6. CONNECTION ERROR DETAILS:
============================
Testing connection to capture exact error...
Error when connecting with APN 'iot.1nce.net':
error: couldn't start network: QMI protocol error (14): 'CallFailed'
call end reason (3): generic-no-service
verbose call end reason (3,1042): [cm] acl-failure

7. INTERFACE INFORMATION:
=========================
Network Interface: rmnet_mhi0
Interface Type: MHI (Modem Host Interface)
Driver: mhi_q
QMI Device: /dev/mhi_QMI0

8. RECOMMENDED APN CONFIGURATIONS:
==================================
Primary APN: iot.1nce.net
Alternative APNs to test:
- 1nce.net
- internet.1nce.net
- m2m.1nce.net
Authentication: None (username/password empty)
IP Type: IPv4, IPv6, or IPv4v6

9. CARRIER-SPECIFIC ROAMING INFO:
=================================
ROAMING ON: Verizon Wireless (USA)
Issue: Verizon blocks most roaming data connections
Required: Roaming agreement between eiotclub and Verizon
Alternative: Request different roaming partner (AT&T, T-Mobile)

10. TECHNICAL SPECIFICATIONS:
=============================
Modem: Qualcomm-based SIM8262A-M2
Protocols: QMI, MBIM
Bands: 5G NR, LTE, UMTS
Interface: PCIe via MHI driver
OS: Debian GNU/Linux on Raspberry Pi

📄 COMPLETE INFORMATION SAVED TO: /tmp/sim_activation_info.txt

===========================================================
📋 SUMMARY FOR EIOTCLUB/1NCE SUPPORT:
===========================================================
IMEI: 866713060018570
ICCID: 8910300000029517128
Current Network:  (MCC: 311, MNC: 480)
Error: pdn-ipv4-call-throttled (carrier blocking connection)
Hardware: Working perfectly (tested with Verizon SIM)
Issue: Roaming restrictions on current carrier

🎯 KEY QUESTIONS FOR EIOTCLUB SUPPORT:
1. Is this SIM activated for US roaming?
2. Does eiotclub have roaming agreement with Verizon (311-480)?
3. What APN should be used for US roaming?
4. Can you switch to AT&T or T-Mobile roaming partner?
5. Is there an activation waiting period?

📧 Email this file (/tmp/sim_activation_info.txt) to eiotclub support
===========================================================

📋 FILE CONTENTS (for copy/paste to support):
==============================================
📋 SIM ACTIVATION INFORMATION - Thu 20 Nov 18:22:36 GMT 2025
==========================================================

1. HARDWARE INFORMATION:
========================
Device: Raspberry Pi 5 with SIM8262A-M2 5G Module
Connection: PCIe (MHI interface)
Location: USA

2. SIM CARD INFORMATION:
========================
IMEI: 866713060018570
ICCID (SIM Serial): 
IMSI: 

3. NETWORK REGISTRATION:
========================
Registration state: 'not-registered-searching'
Roaming status: 'on'
MCC: '311'
MNC: '480'
Description: ''
MCC: '311'
MNC: '480'
MNC with PCS digit: 'yes'

Network Details:
- Mobile Country Code (MCC): 311
- Mobile Network Code (MNC): 480
- Carrier: 
- Combined PLMN: 311480

4. SIGNAL INFORMATION:
======================
Network 'lte': '-77 dBm'
Network 'lte': '-77 dBm'
Network 'lte': '-2.5 dBm'
SINR (8): '9.0 dB'
RSRQ:
Network 'lte': '-19 dB'
Network 'lte': '-3.2 dB'
RSRP:
Network 'lte': '-114 dBm'

5. DEVICE CAPABILITIES:
=======================
SIM: 'supported'
Networks: 'umts, lte, 5gnr'

6. CONNECTION ERROR DETAILS:
============================
Error when connecting with APN 'iot.1nce.net':
error: couldn't start network: QMI protocol error (14): 'CallFailed'
call end reason (3): generic-no-service
verbose call end reason (3,1042): [cm] acl-failure

7. INTERFACE INFORMATION:
=========================
Network Interface: rmnet_mhi0
Interface Type: MHI (Modem Host Interface)
Driver: mhi_q
QMI Device: /dev/mhi_QMI0

8. RECOMMENDED APN CONFIGURATIONS:
==================================
Primary APN: iot.1nce.net
Alternative APNs to test:
- 1nce.net
- internet.1nce.net
- m2m.1nce.net
Authentication: None (username/password empty)
IP Type: IPv4, IPv6, or IPv4v6

9. CARRIER-SPECIFIC ROAMING INFO:
=================================
ROAMING ON: Verizon Wireless (USA)
Issue: Verizon blocks most roaming data connections
Required: Roaming agreement between eiotclub and Verizon
Alternative: Request different roaming partner (AT&T, T-Mobile)

10. TECHNICAL SPECIFICATIONS:
=============================
Modem: Qualcomm-based SIM8262A-M2
Protocols: QMI, MBIM
Bands: 5G NR, LTE, UMTS
Interface: PCIe via MHI driver
OS: Debian GNU/Linux on Raspberry Pi
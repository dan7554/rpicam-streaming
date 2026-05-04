give me commands to set rpi networks to:

SSID: rpicam-starlink-2
password: rpicamera 
priority: 100

SSID: bestskiieronthemountain 
password: dananddessa
priority: 50



sudo nmcli connection add type wifi con-name "bestskiieronthemountain" ssid "bestskiieronthemountain" \
  wifi-sec.key-mgmt wpa-psk wifi-sec.psk "dananddessa" \
  connection.autoconnect yes connection.autoconnect-priority 50;
sudo nmcli connection up "bestskiieronthemountain";


sudo nmcli connection add type wifi con-name "bestskiieronthemountain_5G" ssid "bestskiieronthemountain_5G" \
  wifi-sec.key-mgmt wpa-psk wifi-sec.psk "dananddessa" \
  connection.autoconnect yes connection.autoconnect-priority 80;
sudo nmcli connection up "bestskiieronthemountain_5G";



sudo nmcli connection add type wifi con-name "rpicam-starlink-2" ssid "rpicam-starlink-2" \
  wifi-sec.key-mgmt wpa-psk wifi-sec.psk "rpicamera" \
  connection.autoconnect yes connection.autoconnect-priority 10 \
  802-11-wireless.band bg
sudo nmcli connection up "rpicam-starlink-2"



sudo nmcli connection add type wifi con-name "rpicam-starlink-5" ssid "rpicam-starlink-5" \
  wifi-sec.key-mgmt wpa-psk wifi-sec.psk "rpicamera" \
  connection.autoconnect yes connection.autoconnect-priority 20 \
  802-11-wireless.band bg
sudo nmcli connection up "rpicam-starlink-5"


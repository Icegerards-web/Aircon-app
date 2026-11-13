# Controlling your aircons away from home

## How it works (plain version)
The aircon Wi-Fi adapters only answer on your home network. To reach them from outside, the app opens a small
**WireGuard tunnel to your home** — but only *inside the app* (not a phone-wide VPN):

- it starts when you open the app away from home and stops when you close it
- no VPN icon in the status bar, and your other apps' internet is untouched
- at home it is never used: the app talks to the adapters directly

Something at home has to answer that tunnel (a "WireGuard server"). Your Ziggo SmartWifi modem (Sagemcom F3896LG) cannot do
that, so you need one small always-on device. Cheapest: a **Raspberry Pi Zero 2 W** (~€20, about 1 W) plugged into power and
connected to your Wi-Fi (or to the modem by cable with a Pi 3/4/5).

## One-time setup with a Raspberry Pi (PiVPN)
1. **Check you can be reached from outside.** Ziggo cable normally gives a public IPv4 address. Compare the "WAN IP" on your
   modem's status page with what e.g. whatismyip.com shows; if they differ you are behind carrier-grade NAT and this
   approach won't work (tell me and we'll look at alternatives).
2. **Install Raspberry Pi OS Lite** on the Pi, give it a fixed address (reserve it in the modem's DHCP settings).
3. On the Pi run the installer and choose **WireGuard**, port **51820**:
   `curl -L https://install.pivpn.io | bash`
   When it asks for the public address, choose a **DNS entry** and use a free DuckDNS name (e.g. `mijnhuis.duckdns.org`),
   because home IP addresses change. Install DuckDNS's update script on the Pi so the name follows your IP.
4. **Port forward** UDP 51820 to the Pi in the modem's settings (Ziggo Connect app or the modem's web page).
5. On the Pi run `pivpn add` and name the client "iphone". The file appears in `~/configs/iphone.conf`.
6. **Only send aircon traffic through the tunnel.** Open that file and change the line
   `AllowedIPs = 0.0.0.0/0, ::/0` to your home network, e.g. `AllowedIPs = 192.168.178.0/24`
   (use the same first three numbers as your aircons' IP addresses). Add `PersistentKeepalive = 25` under `[Peer]` if it isn't there.
7. Get the file to your iPhone safely (AirDrop or iCloud Drive; don't email it, it contains a private key).
8. In the Airco app: **Settings → Away from home → Import WireGuard file…**. Done.

Test: turn Wi-Fi off on the phone, open the app; the aircons should show up after a few seconds (the first request has to
set up the tunnel).

## Notes
- Anything else at home that is always on and can run WireGuard (a NAS, a router with WireGuard, an old always-on PC) works the same way.
- Keep the config file private: anyone with it can reach your home network.

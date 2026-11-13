# Airco (iOS)

A SwiftUI app that controls Mitsubishi Heavy "Smart M-Air" aircons (WF-RAC Wi-Fi adapters) **directly over your Wi-Fi**.
It is a Swift port of the Python Airco web tool: the same protocol, the same state handling, and the approved 3D design.

## How it works
- Each aircon's Wi-Fi adapter answers small JSON requests on port 51443 (`/beaver/command/...`). The app registers itself as one of the
  adapter's 4 "remote controls" and reads/changes the state. No Mitsubishi cloud and no login.
- State is a short binary block (base64 inside the JSON). `Airco/Protocol/RacParser.swift` encodes and decodes it,
  `WfRacClient.swift` does the requests (one at a time, 1 s apart, HTTP then HTTPS, write-lock retry).
- `Airco/Model/AirconUnit.swift` keeps what the unit reports, what you just asked for ("Sending…"), and notices when the unit
  didn't do what you asked.
- `Airco/UI/SceneView.swift` is the live 3D aircon (drawn with SwiftUI `Canvas`).

## Away from home
There is no server. The adapters are only reachable on your home network, so use a VPN into your home network
(e.g. WireGuard on your router + the WireGuard app on your phone). With the VPN on, the app works unchanged.

## Building a sideloadable IPA (no Apple Developer account needed)
- **Codemagic:** connect this repository, pick `codemagic.yaml`, run the `airco-unsigned-ipa` workflow, download `Airco.ipa`.
- **GitHub Actions:** the `Build` workflow also produces `Airco.ipa` as a downloadable artifact.
- Install the IPA with **AltStore** or **Sideloadly** (they sign it with your free Apple ID; the app then needs a refresh every 7 days).

On first start iOS asks to allow "Local Network" access: press Allow, otherwise the app cannot see the adapters.

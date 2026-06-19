# EndChat iOS

thank you chat for this readme 

EndChat is now a native iOS app. There is no web build, no Capacitor wrapper, no hosted website dependency, and no bundled browser app.

## Features

- Native SwiftUI interface with Apple-style materials.
- Liquid Glass on supported iOS 26 devices, with standard material fallback on older/non-Liquid-Glass phones.
- Nearby peer discovery and chat using MultipeerConnectivity (Wi-Fi, peer-to-peer Wi-Fi and Bluetooth as selected by iOS).
- Required encrypted peer sessions plus application-layer Curve25519/ChaChaPoly end-to-end encryption for messages and acknowledgements.
- Persistent QR identities and custom nicknames.
- QR contact exchange with editable local names, profile photos, and encryption-key verification checkmarks.
- Persistent text messages with receiver acknowledgements, retry, delivery state, and cancel.
- LAN peers are discovered independently of saved contacts; every incoming connection requires approval.
- An on-device chat list is the main screen; each peer has separate history that can be cleared or deleted locally.
- Image sharing.
- File sharing with a 10 GB per-file limit.
- Chat wallpapers using built-in gradients, photos, or images.

## Project

Open the native project on macOS:

```bash
open EndChat.xcodeproj
```

Then run the `EndChat` scheme on an iPhone or simulator.

## Notes

The app is fully independent from a website. It does not load `localhost`, a LAN web URL, or a remote web page.

The deployment target is iOS 17. Liquid Glass is guarded behind compile-time and runtime checks, so non-Liquid-Glass phones use `.ultraThinMaterial` instead of the iOS 26 glass APIs.

Peer discovery is local/nearby-network based. iOS requires local-network permission, and both devices need to be reachable on a nearby path.

LAN Only is the default and uses no push, account, relay, rendezvous, or storage server. Consequently, iOS cannot guarantee delivery while both apps are suspended. The app retries queued text while active and when foreground execution resumes.

## Optional self-hosted WAN relay

The app now supports a LAN-first, self-hosted WAN fallback for encrypted text packets. Deploy the Docker service in [`relay/`](relay/README.md), enter its HTTPS URL and token in Settings, and turn off **LAN Only**. The relay never receives message plaintext. When **LAN Only** is enabled, the app makes zero relay requests and continues to use only direct nearby networking.

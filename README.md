# PacketPeek

**PacketPeek** is a macOS app built with SwiftUI that lets you **inspect, intercept, and mock HTTP/HTTPS traffic** from your local network. It acts as a local proxy server and provides a developer-friendly UI to monitor and manipulate network requests in real-time.


## 🔍 Features

- 🧭 **Real-time traffic inspection** (HTTP & HTTPS)
- 🧪 **Mocking system** to define custom responses
- 📊 **Detailed request/response view** (headers, body, latency, etc.)
- ⚙️ **Toggle decryption** per app/device
- ✨ SwiftUI interface with live updates

## ⚙️ How it works

1. PacketPeek runs a local proxy on your Mac.
2. You connect devices (or your Mac itself) to this proxy.
3. PacketPeek intercepts and displays all HTTP/HTTPS traffic.
4. You can inspect or override (mock) responses directly from the UI.

> Note: For HTTPS, PacketPeek dynamically generates certificates signed by its own CA. You'll need to trust the CA certificate on your devices.

## 🚀 Getting Started

1. [Download the latest release](https://github.com/FraStabile/ProxyApp/releases/latest)
2. Launch the app and install the certificate when prompted
3. Set your proxy settings (Mac or external device) to:
   - Host: your Mac's local IP
   - Port: 8080 (default)

## 📦 Tech Stack

- SwiftUI + Combine
- Swift Concurrency (async/await)
- Custom CA + TLS certificate generation (Go)
- Papyrus for networking

## 🧪 Mocking API

PacketPeek supports adding and editing mocks directly from the app. Each mock includes:

- HTTP method, host, path
- Static or regex path match
- Status code and latency
- Custom response body and content type

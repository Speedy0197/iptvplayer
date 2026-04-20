# IPTV Player — Setup Guide

## Prerequisites

| Tool | Version | Install |
|---|---|---|
| Go | 1.22+ | https://go.dev/dl |
| Docker + Compose | latest | https://www.docker.com |
| Node.js | 20+ | https://nodejs.org |
| Rust + Cargo | stable | https://rustup.rs |
| Tauri CLI prerequisites | — | https://tauri.app/start/prerequisites |

For **iOS** builds: Xcode 15+ on macOS  
For **Android** builds: Android Studio + NDK

---

## 1. Configure server URL

Edit [`app/utils/config.ts`](app/utils/config.ts) and set `SERVER_URL` to your server's IP:

```ts
export const SERVER_URL = 'http://192.168.1.100:8080'
```

---

## 2. Start the backend

```bash
# From project root
docker compose up -d --build
```

The API is now running on port **8080**.  
Set a strong `JWT_SECRET` in `docker-compose.yml` before exposing it outside your LAN.

---

## 3. Run the desktop app (dev)

```bash
cd app
npm install
npm run tauri:dev
```

This opens the Tauri window with hot-reload.

---

## 4. Build for production

### Desktop (Windows / macOS)

```bash
cd app
npm run tauri:build
```

Installers are output to `app/src-tauri/target/release/bundle/`.

### iOS

```bash
cd app
npm run tauri -- ios init
npm run tauri -- ios build
```

### Android

```bash
cd app
npm run tauri -- android init
npm run tauri -- android build
```

---

## Backend — manual run (without Docker)

```bash
cd backend
go mod tidy
DB_PATH=./iptv.db JWT_SECRET=your-secret go run .
```

---

## First launch

1. Open the app and click **Register** to create your account.
2. Go to **Playlists** (list icon in sidebar) → **Add Playlist**.
3. Choose M3U or Xtream Codes, fill in your provider's details.
4. Click the **refresh icon** (↺) to load channels.
5. Go back to the main view and start watching.

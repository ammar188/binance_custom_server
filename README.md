# binance_custom_server

A custom Binance integration server that listens to price feeds, manages Gaussian triggers, and executes trades via Supabase & Binance Futures.

---

## Prerequisites

- Dart SDK (≥ 3.0)
- Supabase project (with service role key)
- Binance Futures API key & secret

---

## Setup ⚙️

1. Clone the repo and install dependencies:

```sh
git clone https://github.com/ammar188/binance_custom_server.git
cd binance_custom_server
dart pub get
```

2. Build the server executable:

```sh
dart compile exe bin/binance_custom_server.dart -o binance_custom_server
```

3. Create a `config.json` file in the project root:

```json
{
  "supabase_url": "https://your-project.supabase.co",
  "supabase_service_role_key": "your-service-role-key",
  "binance_api_key": "your-binance-api-key",
  "binance_secret_key": "your-binance-secret-key"
}
```

---

## Running Manually 🚀

```sh
./binance_custom_server gaussian-listen -f config.json
```

---

## Running with systemd 🛠️

1. Create a systemd unit file `/etc/systemd/system/gaussian-bot.service`:

```ini
[Unit]
Description=Gaussian Binance Bot
After=network.target

[Service]
ExecStart=/path/to/binance_custom_server gaussian-listen -f /path/to/config.json
WorkingDirectory=/path/to/project
Restart=always
RestartSec=5
User=youruser

[Install]
WantedBy=multi-user.target
```

2. Reload systemd and enable the service:

```sh
sudo systemctl daemon-reload
sudo systemctl enable gaussian-bot.service
sudo systemctl start gaussian-bot.service
```

---

## Logs & Debugging 📜

Check live logs:

```sh
journalctl -u gaussian-bot.service -f
```

Check older logs:

```sh
journalctl -u gaussian-bot.service --since "2 hours ago"
```

Restart service:

```sh
sudo systemctl restart gaussian-bot.service
```

---

## Testing 🧪

Run tests locally:

```sh
dart test
```
# Elixir Nawala

Elixir Nawala is a Phoenix-based domain monitoring platform for domain status observability, Telegram notification management, and shortlink management in one integrated system.

## 1. Folder Structure

```text
elixir_nawala/
├─ assets/                      # Frontend source (CSS, JS, npm dependencies)
│  ├─ css/
│  ├─ js/
│  ├─ package.json
│  └─ package-lock.json
├─ config/                      # Environment configuration (dev/test/prod/runtime)
│  ├─ config.exs
│  ├─ dev.exs
│  ├─ test.exs
│  ├─ prod.exs
│  └─ runtime.exs
├─ lib/
│  ├─ elixir_nawala/            # Domain logic and business contexts
│  │  ├─ accounts/              # Admin authentication and password reset
│  │  ├─ checker/               # Checker scheduler
│  │  ├─ monitor/               # Domain, check result, notification, setting
│  │  ├─ sflink/                # External SFLINK client
│  │  ├─ shortlink/             # Shortlink entities and rotator logic
│  │  ├─ telegram/              # Telegram client, notifier, scheduler
│  │  ├─ workers/               # Oban background jobs
│  │  ├─ application.ex         # OTP supervision tree
│  │  └─ repo.ex                # Ecto repository
│  ├─ elixir_nawala.ex
│  └─ elixir_nawala_web/        # Web layer (Router, Controllers, LiveView, Components)
├─ priv/
│  ├─ repo/
│  │  ├─ migrations/            # Database schema evolution
│  │  └─ seeds.exs
│  ├─ gettext/
│  └─ static/
├─ test/
│  ├─ support/
│  └─ test_helper.exs
├─ .env.example
├─ .formatter.exs
├─ .gitignore
├─ mix.exs
├─ mix.lock
└─ README.md
```

## 2. System Architecture

```text
[Admin/User Browser]
        |
        v
[Phoenix Router + Controllers + LiveView]
        |
        v
[Domain Contexts]
Accounts | Monitor | Shortlink | Telegram | Sflink
        |
        v
[Ecto Repo + PostgreSQL]
        |
        +--> [Oban Queues]
        |      - checker
        |      - notifications
        |
        +--> [External Integrations]
               - SFLINK API
               - Telegram Bot API
```

Core architecture components:

- `Phoenix Web Layer` handles HTTP routing, admin session flow, and real-time dashboard interactions via LiveView.
- `Context Modules` isolate business logic by domain (`Accounts`, `Monitor`, `Shortlink`).
- `Oban Workers` execute asynchronous workloads such as domain checks, alerts, and periodic summaries.
- `Ecto + PostgreSQL` acts as the system of record for application state.
- `External Clients` (`Sflink.Client`, `Telegram.Client`) encapsulate third-party service communication.

## 3. Tech Stack

| Layer | Technology |
|---|---|
| Language | Elixir `~> 1.15` |
| Web Framework | Phoenix `~> 1.7` |
| Realtime UI | Phoenix LiveView `~> 1.0` |
| Database | PostgreSQL + Ecto SQL |
| Background Jobs | Oban |
| HTTP Client | Req |
| Password Hashing | pbkdf2_elixir |
| Web Server | Bandit |
| Frontend Build | Tailwind CSS + esbuild |
| Serialization | Jason |
| Observability | Telemetry Metrics + Telemetry Poller |
| i18n | Gettext |
| Email Layer | Swoosh + Finch |

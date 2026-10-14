# MacroFinance

A personal, self-hosted finance app.

> [!NOTE]
> MacroFinance is a fork of [Maybe Finance](https://github.com/maybe-finance/maybe)
> (v0.6.0, the final upstream release). It is **not affiliated with or endorsed by**
> Maybe Finance Inc. "Maybe" is a trademark of Maybe Finance Inc.

## Local development

Requirements: Ruby (see `.ruby-version`), PostgreSQL, Redis.

```sh
cp .env.local.example .env.local
bin/setup
bin/dev

# Optionally, load demo data
bin/rails demo_data:default
```

Visit http://localhost:3000 (or the `PORT` in `.env.local`). Demo login:

- Email: `user@macrofinance.local`
- Password: `password`

## Self hosting

See [docs/hosting/docker.md](docs/hosting/docker.md).

## License

Distributed under the [AGPLv3 license](LICENSE), as inherited from Maybe Finance.

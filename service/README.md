# ZeroTier Service (`service/`)

Upstream service/API docs.

ZeroTea service work under `src/` targets broad parity, but is still narrower today.

For Zig work, start with:

- `ZIG.md`
- `DEVELOPMENT.md`
- `TESTING.md`
- `src/zerotea.zig`
- `src/zerotea_service.zig`

## Local Configuration File

A file called `local.conf` in the ZeroTier home folder contains local node settings.

Use `zerotier-cli info -j` to confirm the active home directory and whether the configuration is being loaded.

### Example `local.conf`

```javascript
{
	"physical": {
		"10.0.0.0/24": {
			"blacklist": true
		},
		"10.10.10.0/24": {
			"trustedPathId": 101010024
		}
	},
	"virtual": {
		"feedbeef12": {
			"role": "UPSTREAM",
			"try": [ "10.10.20.1/9993" ],
			"blacklist": [ "192.168.0.0/24" ]
		}
	},
	"settings": {
		"softwareUpdate": "apply",
		"softwareUpdateChannel": "release"
	}
}
```

### Zig HTTP API Caveat

The minimal Zig HTTP API in `src/node/http_api.zig` currently implements only:

- `GET /status`
- `GET /network`
- `POST /network/{id}`
- `DELETE /network/{id}`

Do not assume broader Zig API support unless the Zig code implements it.

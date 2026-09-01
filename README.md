# AzerothCore Playerbots — Windows One-Click Compiler

A Windows batch/PowerShell installer that downloads the required build tools, compiles AzerothCore with Playerbots, prepares a portable MySQL database, and generates launch scripts.

Any contributions are appreciated!

It uses the required Playerbots-compatible AzerothCore fork:

- [mod-playerbots/azerothcore-wotlk](https://github.com/mod-playerbots/azerothcore-wotlk), `Playerbot` branch
- [mod-playerbots/mod-playerbots](https://github.com/mod-playerbots/mod-playerbots), `master` branch

## Repository files

```text
Compile-AzerothCore-Playerbots.bat
Compile-AzerothCore-Playerbots.ps1
```

Keep the BAT and PS1 files together in the same directory.

## Supported systems

- Windows 10 or Windows 11
- 64-bit Windows
- Administrator access
- Internet connection
- Several gigabytes of free disk space
- A legally obtained World of Warcraft 3.3.5a client, build 12340, for client-data extraction or pre-extracted data files from *elsewhere*

## Quick start

1. Download or clone this repository.
2. Place it in the directory where you want the complete installation. A short path is recommended, for example:

   ```text
   E:\ACore
   ```

3. Double-click:

   ```text
   Compile-AzerothCore-Playerbots.bat
   ```

4. Approve the Windows Administrator/UAC prompt.
5. Follow the instructions shown in the console.

Everything is downloaded, built, and stored relative to the directory containing the scripts.

## What the script does

The compiler:

1. Checks the Windows version and Administrator permissions.
2. Detects suitable existing dependencies where possible.
3. Downloads missing dependencies.
4. Verifies pinned downloads before using them.
5. Downloads the Playerbots AzerothCore fork and required Playerbots module.
6. Pauses before compilation so additional modules can be added. <--- AT this point you can place\add modules into shown folder
7. Builds AzerothCore in 64-bit `RelWithDebInfo` mode.
8. Builds all client-data extractor tools.
9. Installs the compiled server into `Server`.
10. Installs portable MySQL into `DB`.
11. Creates the AzerothCore and Playerbots databases and database user.
12. Generates active server and module configuration files.
13. Generates `START-DATABASE.cmd` and `START-SERVER.cmd`.
14. Safely stops the temporary database process when setup is complete.

The setup process does **not** launch `worldserver.exe` before client data is available.

## Directory layout

After setup, the installation directory will resemble:

```text
ACore\
├── Compile-AzerothCore-Playerbots.bat
├── Compile-AzerothCore-Playerbots.ps1
├── START-DATABASE.cmd
├── START-SERVER.cmd
├── Dependencies\
│   ├── Build\
│   ├── CMake\
│   ├── Downloads\
│   ├── Git\
│   ├── Source\
│   │   └── modules\
│   │       └── mod-playerbots\
│   ├── VSBuildTools\
│   ├── boost_1_87_0\
│   └── openssl-3.5.7-x64\
├── DB\
│   ├── data\
│   ├── mysql\
│   └── my.ini
├── Server\
│   ├── Data\
│   ├── configs\
│   ├── authserver.exe
│   ├── worldserver.exe
│   └── extraction tools
└── logs\
```

Some dependency folders may be absent when a compatible system installation is detected and reused.

## Downloads and progress

HTTP and BITS downloads report progress to the console and installation log where the total size is available. The script can use three download methods:

1. Direct HTTP streaming
2. Windows BITS
3. Windows `curl.exe`

Pinned Boost, MySQL, and OpenSSL downloads are checked using SHA-256 before installation.

## Adding modules before compilation

After requirements and source files are ready, the script deliberately pauses before CMake configuration and compilation.

At that point, add each additional AzerothCore module as its own directory under:

```text
Dependencies\Source\modules
```

Example from Command Prompt:

```bat
cd /d E:\ACore\Dependencies\Source\modules
git clone https://github.com/OWNER/MODULE.git mod-example
```

After adding all desired modules, return to the compiler window and press **Enter**.

Important:

- Use modules compatible with AzerothCore WotLK.
- The module must also be compatible with the custom Playerbots core fork.
- Follow any module-specific installation or SQL instructions supplied by its author.
- New module `*.conf.dist` files are activated automatically as `*.conf`.
- Existing active configuration files are preserved during recompilation.
- Custom module directories are preserved during future recompiles.

## Recompiling an existing server

If `Server\worldserver.exe` or `Server\authserver.exe` already exists, the script does not immediately rebuild it.

It asks:

```text
Recompile the existing server now? Type YES to continue [default: NO]
```

Only the exact response `YES` starts a clean recompilation. Any other response exits without recompiling.

During a confirmed recompile:

- `Server\Data` is preserved.
- The portable database is preserved.
- Existing active configurations and their custom settings are preserved.
- Custom module source directories are preserved.
- The build directory is recreated for a clean build.

When asked for the database password during recompilation, enter the existing database password.

## Client data

AzerothCore requires data extracted from a compatible World of Warcraft 3.3.5a client. Blizzard client data is not included or downloaded by this project.

Required or recommended directories:

| Directory | Status |
|---|---|
| `dbc` | Required |
| `maps` | Required |
| `vmaps` | Strongly recommended |
| `mmaps` | Strongly recommended for Playerbots |
| `cameras` | Recommended |

The extractor executables are compiled into:

```text
Server
```

Move the generated data into:

```text
Server\Data\dbc
Server\Data\maps
Server\Data\vmaps
Server\Data\mmaps
Server\Data\cameras
```

Do not interrupt vmap or mmap extraction.

## Starting the database only

Run:

```text
START-DATABASE.cmd
```

This starts portable MySQL in a visible console window. Keep that window open while the server is running. Closing it stops the database process.

The database binds to localhost on:

```text
127.0.0.1:3307
```

## Starting the complete server

After placing the client data in `Server\Data`, run:

```text
START-SERVER.cmd
```

The launcher:

1. Refuses to continue if DBC or map files are missing.
2. Warns if vmaps or mmaps are missing.
3. Opens the portable database console if the database is not already running.
4. Waits for MySQL to become available.
5. Starts `authserver.exe`.
6. Waits for authserver and its first database update.
7. Starts `worldserver.exe`.

Keep the database, authserver, and worldserver console windows open while using the server.

## Creating the first account

After worldserver has initialized, enter these commands in the worldserver console:

```text
account create ADMIN your-password
account set gmlevel ADMIN 3 -1
```

Replace `ADMIN` and `your-password` with your desired credentials.

For a local client, set the client realmlist to:

```text
set realmlist 127.0.0.1
```

## Logs

Installer and database logs are written under:

```text
logs
```

Important files include:

```text
logs\install.log
logs\transcript.log
logs\mysql-error.log
```

When reporting a setup failure, include `install.log` and `transcript.log`. If MySQL fails, also include `mysql-error.log`.

## Security notes

- The database listens only on `127.0.0.1` by default.
- Do not expose the database port to the internet.
- Choose a strong database password.
- AzerothCore configuration files necessarily contain the database connection password.
- Do not publish your generated configuration files or database directory.
- Public server operation involves additional firewall, networking, security, and legal considerations not covered by this compiler.

## Troubleshooting

### PowerShell closes or does not start

Run the BAT rather than opening the PS1 directly. Keep both files in the same directory. The BAT requests Administrator access and pauses after errors so the message remains visible.

### A download fails

The script automatically tries HTTP, BITS, and curl where available. Check internet filtering, antivirus, VPN, proxy, and available disk space. Partial or invalid pinned downloads are rejected.

### Existing server is detected unexpectedly

The check is triggered when either of these files exists:

```text
Server\worldserver.exe
Server\authserver.exe
```

Type anything other than `YES` to cancel without rebuilding.

### Database does not start

Check:

```text
logs\mysql-error.log
```

Also confirm port `3307` is not occupied by another application.

### Server launcher refuses to start

Confirm the following contain actual extracted files:

```text
Server\Data\dbc
Server\Data\maps
```

The presence of empty directories is not sufficient.

## Upstream documentation

- [AzerothCore installation guide](https://www.azerothcore.org/wiki/classic-installation)
- [AzerothCore Windows requirements](https://www.azerothcore.org/wiki/windows-requirements)
- [Playerbots module](https://github.com/mod-playerbots/mod-playerbots)
- [Playerbots AzerothCore fork](https://github.com/mod-playerbots/azerothcore-wotlk)

## Disclaimer

This project is an independent build/setup helper. It is not affiliated with Blizzard Entertainment. World of Warcraft and related names are trademarks of their respective owners. Use only client data you are legally entitled to use and follow the licenses and terms of all upstream projects.

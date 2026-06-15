# Auto NGINX VPS Setup

<p align="center">

![Shell](https://img.shields.io/badge/Shell-Bash-green?style=for-the-badge&logo=gnu-bash)
![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04_|_24.04-E95420?style=for-the-badge&logo=ubuntu)
![NGINX](https://img.shields.io/badge/NGINX-Stable-009639?style=for-the-badge&logo=nginx)
![CrowdSec](https://img.shields.io/badge/CrowdSec-Supported-00AEEF?style=for-the-badge)
![License](https://img.shields.io/badge/License-MIT-blue?style=for-the-badge)

</p>

<p align="center">

**Automatic VPS deployment script for Ubuntu**

Install and configure **NGINX**, **Website from GitHub**, **Let's Encrypt SSL**, **CrowdSec**, **CyberOK Skipa IPs**, **TCP BBR** and **myserverinfo** in a few minutes.

</p>

---

# Features

✔ Install and configure NGINX

✔ Deploy website directly from GitHub

✔ Automatic SSL certificate via Let's Encrypt

✔ Install and configure CrowdSec

✔ Install CyberOK Skipa IPs

✔ Enable TCP BBR

✔ Install `myserverinfo`

✔ Server status monitoring

✔ Interactive menu

---

# Screenshots

## Main menu

> Add screenshot here:

```text
+--------------------------------+
|       AUTO NGINX VPS           |
+--------------------------------+

1. Install everything

2. Install/Update website

3. Install/Update SSL

4. Install/Update CrowdSec

5. Install/Update CyberOK Skipa IPs

6. Enable BBR

7. Install/Update myserverinfo

8. Show server information

0. Exit
```

Screenshot example:

```markdown
![Main menu](images/main-menu.png)
```

---

## myserverinfo

> Add screenshot here:

```markdown
![myserverinfo](images/myserverinfo.png)
```

Example output:

```text
====================================

Server Information

====================================

OS: Ubuntu 24.04

Kernel: 6.x

CPU: Intel Xeon

RAM: 2 GB

Disk: 20 GB

IPv4: xxx.xxx.xxx.xxx

------------------------------------

NGINX: Running

SSL: Installed

CrowdSec: Running

Firewall Bouncer: Running

CyberOK: Installed

BBR: Enabled

====================================
```

---

# Supported OS

Recommended:

- Ubuntu 24.04 LTS

Also supported:

- Ubuntu 22.04 LTS

---

# Installed components

| Component | Description |
|-----------|-------------|
| NGINX | Stable web server |
| Website | HTML template from GitHub |
| SSL | Let's Encrypt + Certbot |
| CrowdSec | Intrusion prevention |
| Firewall Bouncer | Firewall integration |
| CyberOK | Trusted IP lists |
| TCP BBR | TCP congestion control |
| myserverinfo | Server monitoring |

---

# Quick Start

Download and run:

```bash
curl -fsSL https://raw.githubusercontent.com/vaalaav/auto_ngnx/main/setup-vps.sh -o setup-vps.sh && sudo bash setup-vps.sh
```

---

# Interactive Menu

```text
1. Install everything
2. Install/Update website
3. Install/Update SSL
4. Install/Update CrowdSec
5. Install/Update CyberOK Skipa IPs
6. Enable BBR
7. Install/Update myserverinfo
8. Show server information
0. Exit
```

---

# Menu Description

## 1. Install everything

Installs:

- NGINX
- Website
- SSL
- CrowdSec
- Firewall Bouncer
- CyberOK
- BBR
- myserverinfo

---

## 2. Install/Update website

Allows:

- specify GitHub repository;
- download website template;
- update existing site.

---

## 3. Install/Update SSL

Installs:

- Certbot;
- Let's Encrypt certificate;
- automatic renewal.

---

## 4. Install/Update CrowdSec

Installs:

- CrowdSec Engine;
- Firewall Bouncer;
- Linux collection;
- NGINX collection;
- SSH collection.

Useful commands:

```bash
sudo cscli metrics
```

```bash
sudo cscli decisions list
```

```bash
sudo cscli collections list
```

---

## 5. Install/Update CyberOK Skipa IPs

Installs and updates trusted IP lists.

---

## 6. Enable BBR

Enables:

```text
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
```

Check:

```bash
sysctl net.ipv4.tcp_congestion_control
```

Expected:

```text
net.ipv4.tcp_congestion_control = bbr
```

---

## 7. Install/Update myserverinfo

Installs:

```bash
myserverinfo
```

Displays:

- OS
- Kernel
- CPU
- RAM
- Disk
- IP addresses
- NGINX status
- SSL status
- CrowdSec status
- Firewall Bouncer status
- CyberOK status
- BBR status

---

## 8. Show server information

Menu:

```text
1. All information

2. System

3. NGINX

4. Website

5. SSL

6. CrowdSec

7. Firewall Bouncer

8. CyberOK Skipa IPs

9. BBR
```

---

# Requirements

- Ubuntu 22.04 or Ubuntu 24.04
- Root privileges
- Internet connection
- Free ports:
  - 80/tcp
  - 443/tcp
- Domain name for SSL

---

# Security Recommendations

It is recommended to:

- Disable SSH password authentication;
- Use SSH keys;
- Keep the system updated:

```bash
sudo apt update && sudo apt upgrade -y
```

- Use CrowdSec to protect SSH and NGINX.

---

# Project Structure

```text
auto_ngnx/

├── setup-vps.sh

├── README.md

└── LICENSE
```

---

# Roadmap

Planned features:

- [ ] Docker installation
- [ ] Docker Compose installation
- [ ] Automatic backups
- [ ] Fail2Ban optional support
- [ ] Telegram notifications
- [ ] Automatic updates
- [ ] WireGuard installation
- [ ] AmneziaWG support
- [ ] Reverse Proxy templates
- [ ] Multi-site support

---

# Contributing

Contributions, pull requests and suggestions are welcome.

Feel free to open an issue or submit a PR.

---

# License

MIT License

---

# Author

**vaalaav**

GitHub:

`https://github.com/vaalaav`

If this project helped you, please consider giving it a ⭐.

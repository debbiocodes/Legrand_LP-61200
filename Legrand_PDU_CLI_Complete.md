
# Legrand PDU CLI Reference (Xerus Firmware v3.5.0)

---

## 🔐 CLI Access & Modes

- **User Mode (`>`)**
- **Administrator Mode (`#`)**
- **Configuration Mode (`config:#`)**
- **Diagnostic Mode (`diag:#`)**

Switch modes by typing:
```
# config
# diagnose
```

---

## ❓ Help & Navigation

- Show available commands: `?`
- Query parameters: `command ?`
- Auto-complete: press `Tab` or `Ctrl+i`
- Previous command: press ↑ arrow

---

## 🔌 Power Control Commands

```
# power outlets <ids> on [/y]
# power outlets <ids> off [/y]
# power outlets <ids> cycle [/y]
# power cancelSequence [/y]
```

Examples:
```
# power outlets all off
# power outlets 2,4,9,11-13,15 cycle /y
```

---

## ⚙️ Actuator Control Commands

```
# control actuator <n> on [/y]
# control actuator <n> off [/y]
```

Where `<n>` is actuator ID (1–32)

---

## 🔄 Reset & Clear

```
# reset factorydefaults [/y]
# clear eventlog [/y]
# clear wlanlog [/y]
```

---

## 📡 Network Diagnostics (in `diag:#`)

```
ping <host> [count <n>] [size <bytes>] [timeout <sec>]
traceroute <host>
```

Example:
```
diag> ping 192.168.84.222 count 5
```

---

## 🖥️ Show Commands

```
# show network
# show network ip common
# show network ip interface eth1
# show outlets
# show actuator
# show reliability hwfailures
```

---

## 🧰 Configuration Mode Commands (`config:#`)

### General
```
# apply
# cancel
```

### PDU Settings
```
pdu name "<Device Name>"
pdu outletSequence <default|1,2,3,...>
```

### Outlet Group Control
- Group creation, rename, control
- Requires specific roles/permissions

---

## 🔑 User & Role Management

```
config:# user add <username>
config:# role create <name>
```

Uses LDAP or RADIUS if configured.

---

## 🗂 SCP & File Operations

```
scp <firmware file> <user>@<ip>:/fwupdate
```

Use for:
- Firmware updates
- Bulk configuration
- Backup/restore
- Upload config.txt via USB or SCP

---

## 🌐 Network Configuration

```
config:# network ipv4 address <ip>
config:# network ipv4 gateway <ip>
config:# network dns <ip>
```

---

## 🌡 Environmental Sensors & Thresholds

- Assign coordinates: `sensor set x/y/z`
- Set thresholds: `sensor threshold <type> value`

---

## 📝 Notes

- Commands are case-sensitive
- Always use `apply` to save config changes
- `/y` skips confirmation prompts
- Available commands vary by model/firmware

---

This file is intended to be added to Cursor or internal documentation for engineers working with Legrand PDUs.

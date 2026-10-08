# Terminal Onboarding

Bring one shop-floor terminal PC into the MES, with its label printer.

**One visit per terminal.** Do the parts in order — each one depends on
the one before it.

1. Collect two facts at the PC
2. Configure the Terminal in the MES Config app
3. Add its Printer
4. Install the Zebra Bridge on the PC
5. Test the printer
6. Launch the workstation

No printer at this terminal? Do parts 1, 2 and 6 only.

---

## Before you start

You need:

- An AD login for the **MES Config** app
- Local administrator rights on the terminal PC
- The bridge flash drive, with **both** files:
  - `MesZebraBridge.exe`
  - `MesZebraBridge.conf`
- The Zebra printer plugged in by USB and powered on

---

## 1. At the PC: collect two facts

Open PowerShell on the terminal PC.

**The PC's IP address:**

```
ipconfig
```

Write down the IPv4 address, for example `172.17.21.45`.

**The printer's queue name:**

```
Get-Printer | Select-Object Name, PortName
```

Write down the Zebra's `Name` **exactly** as shown — spacing and
brackets included. You will check against it in part 4.

If no Zebra is listed, install the Zebra driver first, then run the
command again.

---

## 2. Config app: set up the Terminal

Open the **MES Config** app and sign in.

1. In the sidebar choose **Plant → Plant Hierarchy**.
2. Find the terminal in the tree. Use **Search locations…** and type
   part of its name or code.
3. Click it. Its details open on the right.

> Terminal not in the tree yet? Click the line or area it belongs to,
> press **+ Add Location**, set **Type** = `Cell` and
> **Definition** = `Terminal`, then fill in **Name** and **Code**.

### The settings that matter

Under **Attributes**:

**IpAddress** — the address from part 1.

- Digits and dots only: `172.17.21.45`
- No `http://`, no port, no trailing slash
- This is how the MES recognises the PC, **and** how it finds the
  printer. Get this wrong and both break.

**DefaultScreen** — the screen this terminal opens to. Pick from the
list (Die Cast Entry, Trim Station, Machining IN, Assembly, Shipping
Dock, …).

**HasBarcodeScanner** — on if a scanner is attached.

### Leave these alone unless told otherwise

- **CurrentClosureMethod**, **VisionAppIp**, **CrtEnabled** —
  assembly-out terminals only
- **SuppressAimAndLabel** — parallel-run only. When on, this terminal
  prints **no** shipping labels.
- **RequiresCompletionConfirm**
- **DefaultPrinter** — not used to pick the printer. The printer is
  the Printer location you add in part 3.

Press **Save**.

---

## 3. Config app: add the Printer

Skip this part if the terminal has no printer.

First check: expand the terminal in the tree. If a Printer is already
under it, click it and just confirm the settings below.

To add one:

1. Click the **Terminal** in the tree, so it is selected.
2. Press **+ Add Location**.
3. **Type** = `Cell`
4. **Definition** = `Printer`
5. **Name** and **Code** — follow the terminal's code, for example
   `MA2-6MACH-AOUT3-PRN`.

Under **Attributes**:

**ConnectionKind** = `UsbBridge`

**Endpoint** — **leave blank.** The MES works it out from the
Terminal's IpAddress. Nobody types a printer address.

**Model** — the printer model, for example `ZD421`.

Press **Save**.

> **Other connection kinds** (rare):
> - `Networked` — a printer with its own network port. Endpoint is
>   `ip:port`, for example `172.17.20.228:9100`. No bridge needed.
> - `Hardwired` — a Windows print queue on the Gateway server.

---

## 4. At the PC: install the Zebra Bridge

The bridge is a small Windows service. It receives labels from the MES
Gateway and hands them to the USB printer.

1. Copy **both** files from the flash drive into:

   ```
   C:\BlueRidge\
   ```

2. Open a Command Prompt **as administrator**.

3. Run:

   ```
   cd C:\BlueRidge
   MesZebraBridge.exe install
   ```

4. Read the last line. It should say:

   ```
   BOUND QUEUE: <your printer name>
   ```

   **Check it matches the name from part 1.**

That is the whole install. The service starts by itself now and after
every reboot, and the firewall rule is already added.

### If install asks a question

**More than one Zebra, or none found** — it installs nothing and lists
what it sees. Run it again with the exact name:

```
MesZebraBridge.exe install --queue "ZDesigner ZD421"
```

**`no GatewayAddress`** — the `.conf` file is not beside the `.exe`.
Copy it and run install again.

**Windows SmartScreen warning** — the program is not signed. Choose
**More info → Run anyway**.

### Check it any time

```
MesZebraBridge.exe status
```

Shows the queue it is using, whether Windows has that queue, and
whether the service is running.

---

## 5. Test the printer

### Step A — Test printer (uses no label)

Back in the Config app:

1. **Plant → Plant Hierarchy**
2. Click the **Printer** you added
3. Press **Test printer**

A green **Printer ready** message means the network, the firewall, the
service and the printer queue are all good.

If it says **Save first** or **Unsaved changes**, press **Save** and
test again — the test reads the saved settings.

### Step B — one real label

*Printer ready* proves the path. It cannot prove paper comes out.
Print one real label from the terminal's own screen during its first
production action and confirm it is readable and scans.

### What the messages mean

**Bridge unreachable — Connection refused**
The service is not running. At the PC: `MesZebraBridge.exe status`.

**Bridge unreachable — Connect timed out**
The firewall is blocking it, or the IpAddress is wrong. Recheck part
2, then run `MesZebraBridge.exe install` again.

**Bridge refused — queue unconfigured**
The bridge is running but was never given a printer. Run
`MesZebraBridge.exe install` at the PC.

**Bridge refused — queue not found**
The printer name is wrong or the printer was swapped. The message
lists the names it can see. At the PC:

```
MesZebraBridge.exe set-queue "<exact name>"
```

**Queue not ready**
The printer is offline, paused or in error. Check the printer itself.

**Queue not draining**
Labels are waiting and not printing. The printer is almost always
unplugged or switched off. Fix it and test again — a healthy printer
shows 0 waiting.

**Not the bridge**
Something else answered on that address. Check the Terminal's
IpAddress belongs to this PC.

**No endpoint / endpoint unresolved**
The Terminal has no IpAddress, or it contains `http://`. Fix part 2.

---

## 6. Launch the workstation — last

Start Perspective Workstation on the terminal PC **after** everything
above is saved and tested.

The terminal looks up its screen and printer **once, at startup**. A
session that was already open will not see your changes.

Confirm:

- It opens on the DefaultScreen you chose
- The header shows this terminal's name — not *Madison Facility*
  (that name means the PC's IP was not recognised; recheck part 2)

---

## Later: swapping a printer

At the PC:

```
MesZebraBridge.exe detect
MesZebraBridge.exe set-queue "<exact new name>"
```

Then:

1. Config app → **Test printer**
2. **Restart the workstation session** — otherwise it keeps printing
   to the old printer

---

## Checklist

- [ ] IP address and printer name written down
- [ ] Terminal **IpAddress** saved — digits and dots only
- [ ] Terminal **DefaultScreen** saved
- [ ] Printer added under the Terminal — `UsbBridge`, Endpoint blank
- [ ] Both bridge files in `C:\BlueRidge\`
- [ ] `install` printed the correct **BOUND QUEUE**
- [ ] **Test printer** shows *Printer ready*
- [ ] Workstation launched last, opens on the right screen
- [ ] First real label printed and scanned

---

## Where the logs are

On the terminal PC:

```
C:\ProgramData\BlueRidge\MesZebraBridge\logs\
```

One file per day, kept for 14 days.
